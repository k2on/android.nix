# This flake uses its own module, the way a consumer would — so `android` is
# in scope for `packages.nix`, and the module is exercised by every
# `nix flake check` here.
{
  imports = [ ./_android.nix ];
}
