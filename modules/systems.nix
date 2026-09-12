# Where this evaluates. The SDK itself is x86_64-linux and nothing else; on
# the other three it is emulated, which is the whole point of half of `lib/`.
{
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  perSystem = { pkgs, ... }: {
    formatter = pkgs.nixpkgs-fmt;
  };
}
