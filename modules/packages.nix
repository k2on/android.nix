# This repository's own outputs: the SDK as pinned by default, and the check
# that its compiler runs here. Both exist so that `nix build .#ndk-check` on a
# new machine answers in twenty seconds whether the rest can work at all.
{
  perSystem = { android, ... }:
    let sdk = android.mkSdk { }; in
    {
      packages = {
        android-sdk = sdk;
        ndk-check = android.ndkCheck { inherit sdk; };
      };
    };
}
