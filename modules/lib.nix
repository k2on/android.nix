# The library, for a consumer that is not flake-parts:
#
#     android = inputs.android.lib.mkAndroid pkgs;
{
  flake.lib.mkAndroid = pkgs: import ../lib { inherit pkgs; };
}
