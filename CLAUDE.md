# android.nix

The reusable half of building an Android app with nix. `README.md` says what
each piece is; this file is what to keep true when changing it.

- **Nothing here may know about a framework or an app.** Expo, React Native,
  Rust and uniffi are `expo.nix`'s and `petros-js`'s business. If a change
  needs to name `node_modules`, it belongs one repository up.
- **`lib/` is the only place with logic.** `flake.nix` and `modules/` are
  wiring: the dendritic flake-parts pattern, one file per module, and the
  library reachable three ways — `flakeModules.default`, `lib.mkAndroid`, and
  `default.nix` for no flake at all. All three go through `lib/default.nix`.
- **`flakeModules.default` is a path, not an attribute set.** The module
  system deduplicates modules by key and a path is its own key, so a consumer
  that imports this directly and again through `expo.nix` gets it once.
- **The library takes `pkgs` and nothing else.** The SDK is composed from
  `pkgs.path` for x86_64-linux, so whatever nixpkgs the consumer has is the
  only nixpkgs in the closure.
- **A shell fragment interpolated into a phase must have its heredoc
  terminators at column zero.** Nix strips the smallest indentation of the
  *literal* lines; interpolated blocks are inserted afterwards and their
  lines start at column zero. Keep every line of a fragment at the same
  indentation, including heredoc terminators.
- **`mkGradleState` and `mkGradleBuild` must produce the same tree at the
  same path.** They share `mkBuildAttrs`, `sdkSetup` and the caller's
  `prepare`; the layer's source must carry the build's name. Read the task
  counts, not the clock, to know whether a layer is being used.
- **Changing `mkSdk`'s inputs changes the SDK's store path**, which
  invalidates every layer built on it. That is correct and expensive.

Verified against the app this was extracted from: `mkSdk { }` and
`ndkCheck` evaluate to the same store paths the app's own flake produced.
