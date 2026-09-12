# Gradle's build state as a layer, the way cargo's `target/` is one.
#
# nix caches a derivation's output whole and gradle starts every derivation
# from nothing, so without help every build recompiles every gradle plugin
# from Kotlin, re-transforms every AAR, and re-runs CMake for every native
# library — none of which has anything to do with the app being built. A
# layer does that once, from a source that holds only the project's manifests,
# and the real build restores it and carries on.
#
# Carrying it needs the paths to match exactly: gradle's task history and
# ninja's `.cxx` both record absolute paths, so a layer built at one path tells
# a build at another nothing. A sandboxed derivation runs at `/build`
# everywhere, and the source unpacks to its own name in both — which is why
# the layer's source must be named the same as the build's.
#
# Both halves are shell fragments rather than derivations, because the
# derivation they belong to is the caller's: `mkGradleState` records and
# `mkGradleBuild` restores, in `gradle-build.nix`.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # What a layer keeps, run from the gradle project's parent after the build.
  #
  # Two things, and the second is the expensive one. `gradle-home` is
  # `GRADLE_USER_HOME`: the transformed AARs above all, which AGP re-derives
  # from every dependency otherwise. `tree` is the build state itself — every
  # `build`, `.cxx` and `.gradle` directory under `roots`, which is where the
  # libraries actually build; `.gradle` is the task history that makes gradle
  # willing to believe any of it.
  #
  # Which directories belong is decided by the build file beside them, not by
  # where they live. React Native's gradle plugin, Expo's module plugin and
  # the dev-launcher's are gradle projects that do not live under any
  # `android/`, and a rule that only looked there left their compiled state
  # behind; a `build/` in a JavaScript package is source, and has no
  # `build.gradle` next to it.
  #
  # `cp -a` throughout: gradle and ninja both decide staleness from
  # timestamps, and a plain `cp` stamps everything with now.
  recordGradleState =
    {
      # Where to look, relative to the gradle project's parent.
      roots ? [ "." ]
    }: ''
      mkdir -p $out/tree

      find ${lib.escapeShellArgs roots} -type d \
        \( -name build -o -name .cxx -o -name .gradle \) \
        -prune -print0 |
        while IFS= read -r -d ''' d; do
          p=$(dirname "$d")
          is_gradle_project=
          for f in build.gradle build.gradle.kts settings.gradle settings.gradle.kts; do
            [ -e "$p/$f" ] && is_gradle_project=1
          done
          [ -n "$is_gradle_project" ] || continue
          mkdir -p "$out/tree/$(dirname "$d")"
          cp -a "$d" "$out/tree/$d"
        done

      cp -a "$GRADLE_USER_HOME" $out/gradle-home

      # The timestamps, before the store erases them.
      #
      # nix sets every file in an output to mtime 1 when it registers the
      # path, and `cp -a` from the store faithfully carries that 1 into the
      # next build. Gradle does not mind — it hashes content — but AGP's C++
      # configure does not hash: its fingerprint is (lastModified, length)
      # per input, compared for equality, and a mismatch is a reconfigure.
      # So every `.cxx` carried here was judged changed, CMake ran again for
      # every library and every ABI, and ninja rebuilt what a fresh prefab
      # directory made newer than its objects: five minutes of the native
      # build, paid on a warm run, with 593 tasks up to date around it.
      # Recorded here at nanosecond precision and replayed after the copy,
      # the fingerprints compare equal again.
      ( cd $out && find tree gradle-home -type f -printf '%T@\t%p\n' ) > $out/mtimes

      echo "--- carried:"
      du -sh $out/tree $out/gradle-home
      wc -l $out/mtimes
    '';

  # The layer put back, run from the gradle project's parent before gradle,
  # with `GRADLE_USER_HOME` already exported.
  restoreGradleState =
    {
      # The layer, as `recordGradleState` wrote it.
      state
      # The same roots it was recorded from; the copy has to be made writable.
    , roots ? [ "." ]
      # Carried directories to delete again: anything the layer recorded that
      # is a list of what the *layer* saw rather than what this build has. A
      # configuration-time cache keyed on inputs the layer shares with the
      # build is exactly that, and reads as up to date while linking the
      # wrong things.
    , exclude ? [ ]
    }: ''
      echo "--- gradle's state, from the layer that already paid for it"
      # `cp -a`, for the same reason the layer used it: gradle decides
      # up-to-dateness from timestamps as well as content, and `cp -r` stamps
      # every file with now.
      cp -a ${state}/gradle-home $GRADLE_USER_HOME
      cp -a ${state}/tree/. .
      chmod -R u+w $GRADLE_USER_HOME ${lib.escapeShellArgs roots}
      ${lib.concatMapStrings (d: ''
        rm -rf ${lib.escapeShellArg d}
      '') exclude}
      # Put the timestamps back. The store set them all to 1, and AGP's C++
      # configure compares them for equality against what it recorded — see
      # `recordGradleState` for the whole story. Python rather than `touch`,
      # because this is several hundred thousand files and a process per
      # file is minutes.
      python3 - "${state}/mtimes" "$GRADLE_USER_HOME" <<'PY'
      import os, sys
      manifest, gradle_home = sys.argv[1], sys.argv[2]
      n = 0
      with open(manifest) as f:
          for line in f:
              stamp, _, path = line.rstrip("\n").partition("\t")
              secs, _, frac = stamp.partition(".")
              ns = int(secs) * 10**9 + int((frac + "000000000")[:9])
              if path.startswith("tree/"):
                  path = path[len("tree/"):]
              elif path.startswith("gradle-home/"):
                  path = os.path.join(gradle_home, path[len("gradle-home/"):])
              try:
                  os.utime(path, ns=(ns, ns), follow_symlinks=False)
                  n += 1
              except FileNotFoundError:
                  pass
      print(f"restored {n} timestamps")
      PY
    '';
}
