# The Android SDK, pinned, and a check that its compiler runs here.
{ pkgs, emulation }:
let
  inherit (pkgs) lib;
in
rec {
  # The version every part of an Android build has to agree on. `cargo ndk` and
  # the Android Gradle Plugin looking at two different NDKs is a whole
  # afternoon, so it is named once.
  defaultNdk = "27.1.12297006";

  # The Android SDK, pinned.
  #
  # Everything Google publishes here is `linux-x86_64` and nothing else, so on
  # an ARM machine these run under qemu — supplied by `emulateX86` rather than
  # by the host's `binfmt_misc`, which is what lets the builds that use this be
  # sandboxed.
  #
  # Every component a build touches has to be listed. The Android Gradle Plugin
  # resolves versions against the SDK directory and *installs* what is missing,
  # and what it installs is a raw Google binary that NixOS cannot run; nixpkgs'
  # copies are patched and do. So the rule is: anything Google's build
  # downloads for itself will not run, anything nixpkgs packaged will, and every
  # such component must be pinned and pointed at.
  mkSdk =
    { ndkVersion ? defaultNdk
    , platformVersions ? [ "36" ]
    , buildToolsVersions ? [ "35.0.0" "36.0.0" ]
      # A project with an `externalNativeBuild` wants CMake as well as the NDK.
    , cmakeVersions ? [ "3.22.1" ]
      # Wrap the SDK's executables for emulation. True wherever the machine
      # doing the building is not the machine Google built for, which is the
      # only case where it changes anything.
    , emulate ? emulation.needsEmulation
    }:
    let
      # `pkgs.path` is the nixpkgs this package set was made from, so an SDK
      # composed here is composed from the same nixpkgs as everything else —
      # and it works the same whether `pkgs` arrived through a flake or an
      # `import <nixpkgs>`.
      x86 = import pkgs.path {
        system = "x86_64-linux";
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };

        # No 32-bit set. `build-tools.nix` adds i686 glibc, zlib and ncurses5
        # whenever the host platform is x86_64 — and this instance always is,
        # because everything Google ships for Android is. On an aarch64 machine
        # that asks nix to build ncurses for a third architecture:
        #
        #   Required system: 'i686-linux'   Current system: 'aarch64-linux'
        #
        # which binfmt is not set up for and which nothing here would run. The
        # only 32-bit files in build-tools 35 and 36 are RenderScript libraries
        # for *Android* targets — `armeabi-v7a` and `x86` — nested several
        # directories below where `autoPatchelf --no-recurse` looks. Verified by
        # composing both versions with this overlay: they build.
        #
        # `final` rather than `prev`, which is not a style question. `prev` is a
        # separate fixpoint, so pointing at it gives a second x86_64 package set
        # whose derivations hash differently from the ordinary ones — and
        # nothing in it substitutes. It removed the i686 build and replaced it
        # with glibc, zlib and ncurses compiled from source on every machine.
        # With `final`, `pkgsi686Linux.glibc` is the same derivation as
        # `glibc`, which the cache already has.
        overlays = [ (final: prev: { pkgsi686Linux = final; }) ];
      };
      sdk = (x86.androidenv.composeAndroidPackages {
        ndkVersions = [ ndkVersion ];
        inherit platformVersions buildToolsVersions cmakeVersions;
        includeNDK = true;
        includeEmulator = false;
        includeSystemImages = false;
      }).androidsdk;
    in
    if emulate then emulation.emulateX86 "android-sdk-emulated" sdk else sdk;

  # Does the NDK's compiler run here, sandboxed? Twenty seconds instead of
  # twenty minutes.
  #
  # On x86_64 the answer is uninteresting. Everywhere else the toolchain is
  # emulated, and a whole APK rests on that working inside a build sandbox —
  # which it did not, under the host's `binfmt_misc`:
  #
  #   clang: symbol lookup error: undefined symbol: ceilf,
  #   version GLIBC_2.2.5
  #
  # An ordinary derivation, so it is sandboxed exactly the way the real build
  # is, and it compiles something rather than only asking for a version string:
  # `--version` is answered before much of clang is loaded, and the failure
  # above came from loading the rest of it.
  #
  # It answers a narrower question than it looks like. It catches a toolchain
  # that cannot start, find its resource headers, or exec its linker. It does
  # *not* catch the two traps that need a real compile to surface — lazy
  # binding, and a 16 KiB-page host — so it asserts the wrapper still forces
  # eager binding rather than pretending to test it.
  ndkCheck =
    { sdk
    , ndkVersion ? defaultNdk
    }:
    let
      ndk = "${sdk}/libexec/android-sdk/ndk/${ndkVersion}";
      prebuilt = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64";
    in
    pkgs.runCommand "ndk-check" { } ''
      # `#include`, so the resource headers have to be found, and a
      # shared object rather than an object file, so the driver has to
      # exec `ld.lld`. Both are things a compiler does by knowing where
      # it lives, which is exactly what emulation takes away — and both
      # pass happily if the test is a `--version` and a `-c` of a
      # builtin, which is what this was at first.
      cat > a.c <<'SRC'
      #include <math.h>
      float f(float x) { return ceilf(x); }
      SRC

      # When it fails under emulation it fails in the dynamic
      # loader, and the message names a symbol rather than a file:
      #
      #   clang: symbol lookup error: …/clang:
      #   undefined symbol: ceilf, version GLIBC_2.2.5
      #
      # which is what the loader says when a symbol *is* found and its
      # version is not — so some libm was loaded and it was the wrong
      # one. Nothing in the message says which, and that is the only
      # question worth asking, so ask it here rather than leaving the
      # next person to reconstruct the run by hand.
      diagnose() {
        echo "--- the NDK does not run here. What the loader did:"
        echo "--- ldd:"
        LD_TRACE_LOADED_OBJECTS=1 ${prebuilt}/bin/clang || true
        echo "--- LD_DEBUG=libs,versions (tail):"
        LD_DEBUG=libs,versions ${prebuilt}/bin/clang --version \
          > ld.log 2>&1 || true
        grep -E 'libm|ceilf|version' ld.log | tail -60 || true
        echo "--- the search path the guest was given:"
        echo "LD_LIBRARY_PATH=''${LD_LIBRARY_PATH-<unset>}"
        echo "LD_PRELOAD=''${LD_PRELOAD-<unset>}"
        echo "--- the wrapper:"
        cat ${prebuilt}/bin/clang || true
        exit 1
      }

      set -x
      ${prebuilt}/bin/clang --version || diagnose

      # Where the toolchain is emulated, the wrapper has to be the
      # thing forcing eager binding — not this check, and not the
      # caller.
      #
      # Lazy binding resolves a PLT entry at first call, through
      # machinery that does not survive emulation, and it fails as a
      # lookup error naming a symbol that is demonstrably present:
      #
      #   checking for version `GLIBC_2.2.5' in file …/libm.so.6 [0]
      #     required by file …/clang [0]        ← passes, at load time
      #   …/clang: error: symbol lookup error: undefined symbol:
      #     ceilf, version GLIBC_2.2.5 (fatal)  ← later, at first call
      #
      # So there is nothing to find and nothing missing. Asserting the
      # wrapper still carries the workaround is worth more than running
      # clang again here, because the failure depends on a code path
      # `--version` does not take — which is how this check passed on a
      # machine that could not build.
      if head -c2 ${prebuilt}/bin/clang | grep -q '#!'; then
        grep -q LD_BIND_NOW ${prebuilt}/bin/clang || {
          echo "the wrapper no longer forces eager binding" >&2
          exit 1
        }
      fi
      ${prebuilt}/bin/clang --target=aarch64-linux-android26 \
        -shared -o a.so a.c || diagnose
      ${prebuilt}/bin/llvm-nm -D a.so | grep ' T f'
      ${prebuilt}/bin/llvm-readelf -h a.so | grep Machine
      set +x
      echo "the NDK works here" | tee $out
    '';
}
