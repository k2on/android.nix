# Gradle at the version a project asks for, from nixpkgs' own builder.
{ pkgs }:
{
  # A generated project's wrapper would download its own gradle, which a
  # builder cannot do. `gradle-packages.mkGradle` builds the exact version
  # instead and `wrapGradle` puts nixpkgs' setup hook and `passthru.fetchDeps`
  # on it — the setup hook is what turns a bare `gradle` in a build phase into
  # `--no-daemon --console plain` with an init script, and `fetchDeps` is the
  # recorder behind `mkGradleBuild`'s Maven mirror. Unpacking the distribution
  # zip and wrapping the launcher gives neither.
  #
  # Two things follow from taking gradle from nixpkgs rather than the zip. The
  # native libraries are patched properly — `ncurses` joins the closure, since
  # gradle's `native-platform` jars link it. And building gradle means
  # *compiling* ncurses: `ncurses-abi5-compat` is multi-output, Hydra never
  # pushed its `dev` output, and nix substitutes per-output but builds
  # per-derivation. One 404 costs the whole compile, so root the result.
  mkGradle =
    { version
    , hash
    , jdk ? pkgs.jdk17
    }:
    pkgs.callPackage pkgs.gradle-packages.wrapGradle {
      gradle-unwrapped = pkgs.gradle-packages.mkGradle {
        inherit version hash;
        defaultJava = jdk;
      };
    };
}
