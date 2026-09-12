# The flake-parts module a consumer imports.
#
#     imports = [ inputs.android.flakeModules.default ];
#     perSystem = { android, ... }: { packages.sdk = android.mkSdk { }; };
#
# It puts the library in scope as `android`, built over the consumer's own
# `pkgs` — so a consumer that sets `_module.args.pkgs` (an overlay, a
# different nixpkgs) gets an SDK composed from that one, and there is only
# ever one nixpkgs in the closure.
#
# A path rather than an attribute set, deliberately. The module system
# deduplicates modules by key, and a path is its own key: a consumer that
# imports this directly *and* through a library built on it (expo.nix, and
# whatever is built on that) gets it once, rather than two definitions of
# `_module.args.android` and an error naming neither.
{
  flake.flakeModules.default = ./_android.nix;
}
