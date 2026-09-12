# The non-flake entry point: the same library over whatever nixpkgs you have.
#
#     android = import (fetchTarball "https://github.com/k2on/android.nix/archive/main.tar.gz") { inherit pkgs; };
#
# or pin it with niv or npins and import the result the same way.
{ pkgs ? import <nixpkgs> { } }:
import ./lib { inherit pkgs; }
