{
  go,
  newScope,
  lib,
}:
lib.makeScope newScope (
  final:
  let
    inherit (final) callPackage;
  in
  {
    # Tooling
    inherit go;

    require = [ ];

    goPackages = final;

    gobuild-nix-gocacheprog = callPackage ../go/gobuild-nix-gocacheprog { };

    fetchers = callPackage ./fetchers { };

    hooks = callPackage ./hooks { };

    # Go standard library.
    "std" = callPackage (
      {
        stdenv,
        hooks,
      }:
      stdenv.mkDerivation {
        inherit (go) pname version;
        dontUnpack = true;

        # Only the standard library: `...` in GOROOT also compiles cmd/* (the
        # toolchain itself), which nothing links against.
        goBuildPackages = "std";

        nativeBuildInputs = [
          hooks.configureGoCache
          hooks.configureGo
          hooks.buildGo
          hooks.buildGoCacheOutputSetupHook
          go
        ];
      }
    ) { };
  }
)
