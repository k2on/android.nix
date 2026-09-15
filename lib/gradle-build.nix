# A gradle build of an Android project that does not reach the network.
#
# The pieces: the environment every gradle derivation of one project has to
# share, the SDK made writable and pointed at, the Maven graph replayed from a
# recording — and the two derivations built from them, the build and the
# state layer it restores.
{ pkgs, emulation, gradleState, defaultNdk }:
let
  inherit (pkgs) lib;
in
rec {
  # cc-rs looks for a compiler under the target triple with its dashes turned
  # into underscores, and prefers that over the bare `CC`. This is the machine
  # doing the building, so the same expression is right on an ARM laptop and an
  # x86_64 runner.
  hostTriple = builtins.replaceStrings [ "-" ] [ "_" ] pkgs.stdenv.buildPlatform.config;

  # What every gradle derivation of one project is built with, named once.
  #
  # Shared for correctness rather than tidiness: `PATH` decides which `ninja`
  # and which compiler CMake finds, and CMake writes those paths into
  # `build.ninja`. A layer configured with a different `PATH` produces state
  # the next build cannot use, and says nothing about why.
  mkBuildAttrs =
    { sdk
    , gradle
    , jdk ? pkgs.jdk17
    , ndkVersion ? defaultNdk
      # Whatever else the project's build runs, ahead of these on `PATH`.
    , nativeBuildInputs ? [ ]
    }: {
      nativeBuildInputs = nativeBuildInputs ++ [
        gradle
        sdk
        pkgs.cacert
        pkgs.git
        jdk
        pkgs.ninja
        pkgs.nodejs
        pkgs.python3
        pkgs.unzip
        pkgs.which
      ];

      ANDROID_HOME = "${sdk}/libexec/android-sdk";
      ANDROID_SDK_ROOT = "${sdk}/libexec/android-sdk";
      ANDROID_NDK_HOME = "${sdk}/libexec/android-sdk/ndk/${ndkVersion}";
      JAVA_HOME = "${jdk}";
    };

  # The SDK as gradle can use it, run from the gradle project's parent.
  #
  # AGP resolves the versions a project asks for against the SDK directory and
  # installs whatever is missing, which a store path can never allow. A copy
  # it can write to is the only way through — and every component it could
  # want is pinned in `mkSdk`, so it never actually installs anything.
  sdkSetup =
    {
      # The gradle project, relative to where this runs.
      projectDir ? "."
    , ndkVersion ? defaultNdk
      # Whose `aapt2` to use; see below.
    , aapt2BuildTools ? "36.0.0"
    }: ''
      cp -a $ANDROID_HOME $TMPDIR/sdk
      chmod -R u+w $TMPDIR/sdk
      # nixpkgs puts the NDK in two places and AGP complains about the
      # second one on every task.
      rm -rf $TMPDIR/sdk/ndk-bundle
      export ANDROID_HOME=$TMPDIR/sdk ANDROID_SDK_ROOT=$TMPDIR/sdk
      export ANDROID_NDK_HOME=$TMPDIR/sdk/ndk/${ndkVersion}

      cat > ${projectDir}/local.properties <<EOF
      sdk.dir=$TMPDIR/sdk
      EOF

      # AGP does not use the SDK's `aapt2`. It resolves
      # `com.android.tools.build:aapt2` from Maven and unpacks a raw Google
      # binary, which wants `/lib64/ld-linux-x86-64.so.2` and reports its
      # absence as
      #
      #   AAPT2 aapt2-8.12.0-13700139-linux Daemon #0: Daemon startup failed
      #
      # naming neither the file nor the loader. nixpkgs' copy is patched to a
      # store interpreter and runs, and AGP takes an override for exactly
      # this. An Ubuntu runner *does* have that loader, so an unsandboxed
      # build ran Google's binary and nobody was any the wiser about which
      # aapt2 was compiling the resources; sandboxing is what asked.
      printf '\n' >> ${projectDir}/gradle.properties
      echo "android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/${aapt2BuildTools}/aapt2" \
        >> ${projectDir}/gradle.properties

      # `GRADLE_USER_HOME` explicitly, because the JVM does not read `$HOME`:
      # `user.home` comes from the passwd entry, which for a nix build user
      # is `/var/empty`. An `export HOME=$TMPDIR` is invisible to anything
      # running on the JVM, so gradle would put its caches somewhere it
      # cannot write however that is set. The setup hook honours it if it is
      # already set.
      export GRADLE_USER_HOME=$TMPDIR/gradle
    '';

  # The build.
  #
  # Nothing here reaches the network, so this is an ordinary sandboxed build:
  # the Maven graph is replayed from the recording, the SDK is a store path,
  # and gradle is the pinned one. Which also buys the stable path — `/build`
  # everywhere rather than something ending in a pid and a random number —
  # that carrying state between derivations depends on.
  #
  # Not a fixed-output derivation, and it cannot be one: an APK is a zip and a
  # signed one at that, so it is not reproducible byte-for-byte. Everything it
  # needs from the network is fetched by a derivation that *is*, and the build
  # itself runs offline.
  mkGradleBuild =
    { name
      # The tree to build. It unpacks to `src.name`, and a state layer this
      # restores must have been built from a tree of the same name.
    , src
      # The gradle project inside it.
    , projectDir ? "."
      # The module whose APK is the product.
    , appModule ? "app"
      # `debug` or `release`: gradle's build type, the directory the APK lands
      # in, and — capitalised — half the name of the task that builds it.
    , variant ? "debug"
    , sdk
    , gradle
    , jdk ? pkgs.jdk17
    , ndkVersion ? defaultNdk
    , aapt2BuildTools ? "36.0.0"
    , nativeBuildInputs ? [ ]
      # Gradle's own dependency graph, recorded once and replayed from the
      # store — see `mitmCache` below.
    , gradleDeps
      # What the recording runs. Both assembles by default, so that a release
      # build sharing the recording finds Hermes and the release toolchain in
      # it as well as the debug half.
    , gradleUpdateTask ? "assembleDebug assembleRelease"
      # A recording to share instead of making one. `fetchDeps` names its
      # derivation after the package, so two packages recording the same graph
      # materialise it twice.
    , mitmCache ? null
      # Shell run in the source root before the SDK is set up: for a generated
      # project, generating it. Leaves the shell where it found it.
    , prepare ? ""
      # A layer from `mkGradleState`, put back before gradle runs.
    , restore ? null
      # What `restore` makes writable and what a layer records; see
      # `gradle-state.nix`.
    , stateRoots ? [ "." ]
    , stateExclude ? [ ]
    , buildPhase ? ''
        runHook preBuild
        gradle "assemble''${variant^}"
        runHook postBuild
      ''
    , installPhase ? ''
        runHook preInstall
        mkdir -p $out
        cp ${appModule}/build/outputs/apk/$variant/*.apk $out/
        runHook postInstall
      ''
      # Anything else the derivation should carry.
    , extraAttrs ? { }
    }:
    let
      parent = dirOf projectDir;
      base = baseNameOf projectDir;

      # The same phase with and without a layer to put back, because the
      # recording needs the one without; see `mitmCache` below.
      configureWith = restore': ''
        runHook preConfigure

        # Emulated here too — gradle drives the NDK's clang, and CMake
        # drives it a great many times. Same refusal as everywhere else.
        ${lib.optionalString emulation.needsEmulation emulation.emulationGuard}

        export HOME=$TMPDIR

        ${prepare}

        cd ${lib.escapeShellArg parent}
        ${sdkSetup { projectDir = base; inherit ndkVersion aapt2BuildTools; }}

        ${lib.optionalString (restore' != null) (gradleState.restoreGradleState {
          state = restore';
          roots = stateRoots;
          exclude = stateExclude;
        })}

        # Leave the shell in the gradle project. The update script runs
        # gradle straight after this phase and does no `cd` of its own.
        cd ${lib.escapeShellArg base}

        runHook postConfigure
      '';
    in
    pkgs.stdenv.mkDerivation (finalAttrs:
    mkBuildAttrs { inherit sdk gradle jdk ndkVersion nativeBuildInputs; } // {
      inherit name src variant gradleUpdateTask buildPhase installPhase;

      # There is no lockfile to vendor a Maven graph from, because working
      # out what a gradle build fetches is a Turing-complete question; so
      # nixpkgs answers it by running the build once behind a recording
      # proxy and keeping what came back. `gradleDeps` is that recording.
      #
      # What it records from is this build *without its state layer*, and that
      # is the whole of why `configureWith` exists. `update-deps.nix` derives
      # the recording from this package, and a `restore` puts the layer's
      # store path in `configurePhase` — so realising the recording would
      # first realise a layer that replays the very graph being recorded.
      # Offline, from a lockfile that by definition does not have the thing
      # being added, which makes the one case recording exists for — a new
      # dependency — the one case it cannot do. It reads as the *build*
      # failing to resolve an artifact that is plainly published.
      #
      # Recording without the layer is also the more honest graph: a build
      # with nothing to restore fetches every artifact itself, so what comes
      # back is everything the project needs rather than everything it missed.
      mitmCache =
        if mitmCache != null then mitmCache
        else gradle.fetchDeps {
          pkg = finalAttrs.finalPackage.overrideAttrs (_: {
            configurePhase = configureWith null;
            # Overridden so this expression is not reached again through the
            # new package's own `finalAttrs`, which would not terminate.
            # `update-deps.nix` sets it to the same thing for its own reasons.
            mitmCache = "";
          });
          data = gradleDeps;
        };

      # Preparing the project is `configurePhase`, not `buildPhase`, and
      # that is load-bearing rather than tidiness. `fetchDeps`' update
      # script runs `unpackPhase patchPhase configurePhase` and then gradle
      # — it never calls `buildPhase`. With the preparation in `buildPhase`
      # there would be no project for it to record from.
      configurePhase = configureWith restore;
    } // extraAttrs);

  # The layer: the same project built once with whatever it holds, and the
  # state gradle left behind kept.
  #
  # What it is built *from* is the caller's whole decision, and the point:
  # give it a source holding only the manifests and nothing that changes per
  # commit, and a commit cannot invalidate a gradle build that never saw it.
  # A layer whose inputs are too wide is indistinguishable from a layer that
  # does not work, because both present as "the step got longer"; the task
  # counts tell them apart and the clock does not.
  mkGradleState =
    {
      # The tasks to run. Assembling the app rather than naming the libraries,
      # because the list of libraries is one this file must not hold.
      task ? "assembleDebug"
    , stateRoots ? [ "." ]
    , ...
    }@args:
    mkGradleBuild ((builtins.removeAttrs args [ "task" ]) // {
      inherit stateRoots;
      restore = null;
      buildPhase = ''
        runHook preBuild
        gradle ${task}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cd "$NIX_BUILD_TOP/$sourceRoot/${lib.escapeShellArg (dirOf (args.projectDir or "."))}"
        ${gradleState.recordGradleState { roots = stateRoots; }}
        runHook postInstall
      '';
      extraAttrs = (args.extraAttrs or { }) // {
        # Nothing here is a program to be fixed up, and the fixup was doing
        # real work: 980 `patchelf --shrink-rpath` calls over the Android
        # objects in `.cxx` and `build/`, eighty seconds of it. Had any of
        # them carried an rpath the file would have changed under gradle,
        # which hashes its outputs.
        dontFixup = true;
      };
    });
}
