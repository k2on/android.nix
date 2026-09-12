# android.nix

Building Android apps with nix — sandboxed, offline, and on any machine,
including one that is not x86_64.

Nothing here knows about any particular app or framework. It is the part of an
Android build that is the same every time: the SDK pinned and composed so the
Android Gradle Plugin never tries to install its own, gradle at the exact
version a project asks for, gradle's Maven graph replayed from a recording
instead of fetched, the SDK's x86_64-only binaries emulated where the machine
is not x86_64, and gradle's build state carried between derivations the way
cargo's `target/` is. `expo.nix` builds Expo apps on top of it.

## Using it

As a flake-parts module — every `perSystem` gets `android`:

```nix
inputs.android.url = "github:k2on/android.nix";
inputs.android.inputs.nixpkgs.follows = "nixpkgs";

# in a module
{ imports = [ inputs.android.flakeModules.default ]; }

perSystem = { android, ... }:
  let
    sdk = android.mkSdk { };
    gradle = android.mkGradle { version = "9.3.1"; hash = "sha256-…"; };
    state = android.mkGradleState {
      name = "myapp-gradle-state";
      src = ./.;                       # …or a tree without the app's code
      inherit sdk gradle;
      gradleDeps = ./gradle-deps.json;
      mitmCache = apk.mitmCache;
    };
    apk = android.mkGradleBuild {
      name = "myapp-debug-apk";
      src = ./.;
      inherit sdk gradle;
      gradleDeps = ./gradle-deps.json;
      restore = state;
    };
  in
  { packages = { inherit apk; }; };
```

As a plain library, from a flake that is not flake-parts:
`inputs.android.lib.mkAndroid pkgs`. Without flakes:
`import ./android.nix { inherit pkgs; }` over the repository.

`nix build .#ndk-check` here answers in twenty seconds whether the NDK's
compiler runs on this machine at all.

## What is in `lib/`

| file               | what                                                        |
|--------------------|-------------------------------------------------------------|
| `sdk.nix`          | `mkSdk`, `ndkCheck`, `defaultNdk`                           |
| `emulation.nix`    | `emulateX86`, `emulationGuard`, `needsEmulation`            |
| `gradle.nix`       | `mkGradle` — nixpkgs' builder, with `fetchDeps` on it       |
| `gradle-build.nix` | `mkGradleBuild`, `mkGradleState`, `mkBuildAttrs`, `sdkSetup`, `hostTriple` |
| `gradle-state.nix` | `recordGradleState`, `restoreGradleState`                   |

`default.nix` in that directory merges them into one attribute set.

## The Maven graph is a recording

There is no lockfile to vendor a Maven graph from, because working out what a
gradle build fetches is a Turing-complete question; so nixpkgs answers it by
running the build once behind a recording proxy and keeping what came back.
`mkGradleBuild` takes that recording as `gradleDeps` and replays it through
nixpkgs' `mitm-cache`. Regenerate it with the update script the derivation
carries:

```sh
script=$(nix build --no-link --print-out-paths .#apk.mitmCache.updateScript)
USE_BWRAP=0 "$script"
```

A state layer shares the build's recording rather than making its own —
`fetchDeps` names its derivation after the package, so two packages recording
the same graph materialise it twice.

## Gradle's state is a layer

nix caches a derivation's output whole and gradle starts every derivation
from nothing, so `mkGradleState` builds the project once from a source of
the caller's choosing and keeps every `build`, `.cxx` and `.gradle` directory
that belongs to a gradle project, plus `GRADLE_USER_HOME`. `mkGradleBuild`
puts it back before gradle runs. Give the layer a source that holds only the
manifests and a commit cannot invalidate a gradle build that never saw it.

What makes carrying it work, and what each cost a run to learn:

- **The paths must match.** Gradle's task history and ninja's `.cxx` record
  absolute paths. A sandboxed derivation runs at `/build` everywhere and the
  source unpacks to its own name, so the layer's source has to be *named* the
  same as the build's.
- **`cp -a` throughout.** Gradle and ninja decide staleness from timestamps.
- **The store erases timestamps, and AGP's C++ configure compares them for
  equality.** nix sets every file in an output to mtime 1. Gradle hashes
  content and does not care; AGP's configure fingerprint is
  `(lastModified, length)` per input, and a mismatch reconfigures — after
  which ninja rebuilds everything a fresh prefab directory made newer. The
  layer records every file's mtime at nanosecond precision and the build
  replays them after the copy.
- **A configuration-time cache in the carried tree is a list of what the
  layer saw.** `stateExclude` deletes such directories on restore; `expo.nix`
  names React Native's autolinking cache there.
- **The layer must not be fixed up.** stdenv's fixup ran `patchelf` over 980
  Android objects, eighty seconds a build. `dontFixup` is set.
- **The environment must be shared.** `PATH` decides which `ninja` and which
  compiler CMake finds, and CMake writes those paths into `build.ninja`. Both
  derivations are built from `mkBuildAttrs` for this reason.

## The SDK, and what will not run

Everything Google publishes for Android is a `linux-x86_64` binary. On any
other machine `mkSdk` wraps every host executable in the SDK in a pinned
`qemu-x86_64` from nixpkgs, so a build needs nothing registered on the
machine — a sandboxed build cannot use the kernel's `binfmt_misc` anyway.

Three things about that, each found the hard way:

- **An emulated compiler has to be told where it lives.** clang reads its own
  path to find its resource headers and the linker it execs, and under
  emulation `/proc/self/exe` does not tell it. The wrappers pass their own
  full path as `argv[0]`.
- **An emulated toolchain has to bind eagerly.** Lazy PLT binding goes
  through machinery that does not survive emulation, and fails as
  `undefined symbol: ceilf, version GLIBC_2.2.5` — a lookup error naming a
  symbol that is present. The wrappers export `LD_BIND_NOW`.
- **The host's pages must be 4 KiB.** qemu presents a 4 KiB-page address
  space to the guest; on a 16 KiB kernel (Apple Silicon) a large compile
  corrupts itself fourteen minutes in. `emulationGuard` refuses to start.

And the rule behind the SDK's composition: **anything Google's build
downloads for itself is unpatched and will not run on NixOS; anything nixpkgs
packaged is patched and will.** So every component a build touches is pinned
in `mkSdk`, the build copies the SDK somewhere writable only so AGP can write
its own metadata beside them, and `sdkSetup` points AGP at the SDK's `aapt2`
rather than the one it fetches from Maven.

## Layout

```
flake.nix        inputs, and `mkFlake` over import-tree — nothing else
default.nix      the non-flake entry point
lib/             the library, one file per concern
modules/         flake-parts modules: the library as a flake output, the
                 module a consumer imports, this flake's own packages
```
