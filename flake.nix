{
  description = "Building Android apps with nix, sandboxed, on any machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    import-tree.url = "github:vic/import-tree";
  };

  # Dendritic: every file under `modules/` is a flake-parts module, and this
  # file names no outputs at all. What a consumer wants is
  # `flakeModules.default` — it puts `android` in scope of every `perSystem`
  # — or `lib.mkAndroid pkgs` for a flake that is not flake-parts.
  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
