# Everything here, as one attribute set over a package set.
#
#     android = import ./lib { inherit pkgs; };
#
# `pkgs` is any nixpkgs instance for the machine doing the building. The SDK
# is composed from the same nixpkgs — `pkgs.path` — for x86_64-linux, which is
# the only platform Google publishes for, and emulated where that is not the
# machine at hand.
{ pkgs }:
let
  emulation = import ./emulation.nix { inherit pkgs; };
  sdk = import ./sdk.nix { inherit pkgs emulation; };
  gradle = import ./gradle.nix { inherit pkgs; };
  gradleState = import ./gradle-state.nix { inherit pkgs; };
  gradleBuild = import ./gradle-build.nix {
    inherit pkgs emulation gradleState;
    inherit (sdk) defaultNdk;
  };
in
emulation // sdk // gradle // gradleState // gradleBuild
