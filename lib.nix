let
  inherit (builtins)
    isAttrs
    fromTOML
    readFile
    concatMap
    elem
    groupBy
    attrNames
    mapAttrs
    genericClosure
    ;
  lockSchemaVersion = 1;

in
{
  mkGoSet =
    {
      goLock,
      go,
      callPackage,
      lib,
      overridePackage ? drv: drv,
      rootDir ? throw "Local package was used but no root directory passed",
    }:
    let
      lockFile = if isAttrs goLock then goLock else fromTOML (readFile goLock);

      overlay' =
        assert lockFile.schema == lockSchemaVersion;
        final: prev:
        let
          cycles = lockFile.cycles or { };

          # Cycle packages by their group IDs
          cyclesByGroup =
            mapAttrs
              (
                cycleIdx: cycle:
                final.callPackage (
                  {
                    stdenv,
                    fetchers,
                    hooks,
                  }:
                  let
                    # Same rule as a single module (see below), over the union
                    # of the packages the workspace imports from each member.
                    packages = concatMap (goPackagePath: lockFile.locked.${goPackagePath}.packages or [ ]) cycle;
                  in
                  stdenv.mkDerivation (
                  lib.optionalAttrs (lockFile ? workspace) (
                    if packages == [ ] then
                      { dontUseGoBuild = true; }
                    else
                      { env.goBuildPackages = builtins.concatStringsSep " " packages; }
                  )
                  // {
                    name = "go-cycle-${cycleIdx}";

                    srcs = map (
                      goPackagePath:
                      let
                        locked = lockFile.locked.${goPackagePath};
                      in
                      fetchers.fetchModuleProxy {
                        inherit goPackagePath;
                        inherit (locked) version hash;
                      }
                    ) cycle;

                    nativeBuildInputs = [
                      hooks.goModuleHook
                    ];

                    propagatedBuildInputs = concatMap (
                      goPackagePath:
                      let
                        locked = lockFile.locked.${goPackagePath};
                      in
                      concatMap (req: if elem req cycle then [ ] else [ final.${req} ]) (locked.require or [ ])
                    ) cycle;

                  })
                ) { }
              )
              (
                # Attrset of cycles by their numeric group -> list of members
                groupBy (n: toString cycles.${n}) (attrNames cycles)
              );

          # Map goPackagePath -> cycle package
          cyclePkgs = mapAttrs (goPackagePath: cycleGroup: cyclesByGroup.${toString cycleGroup}) final.cycles;

        in
        {
          inherit cycles;

          require = map (goPackagePath: final.${goPackagePath}) (attrNames lockFile.locked);

          # Third-party modules each workspace `use` module needs, by its
          # directory relative to go.work (see workspace.go in the generator).
          #
          # `proxy` is a GOPROXY (file://) to run Go in workspace mode on that
          # module without network: the original sources (zip, mod, info) of
          # `sources` plus the go.mod files of the whole graph (`modGraph`).
          # Original, not the rewritten go.mod of the module derivations: the
          # checkout's go.sum verifies them.
          workspace = mapAttrs (
            dir: ws:
            let
              sources = map (
                goPackagePath:
                final.fetchers.fetchModuleProxy {
                  inherit goPackagePath;
                  inherit (lockFile.locked.${goPackagePath}) version hash;
                }
              ) (ws.sources or [ ]);
            in
            {
              require = map (goPackagePath: final.${goPackagePath}) (ws.require or [ ]);
              testRequire = map (goPackagePath: final.${goPackagePath}) (ws.testRequire or [ ]);
              inherit sources;
              proxy = final.callPackage (
                { runCommand, lndir }:
                runCommand "go-proxy-${baseNameOf dir}" { nativeBuildInputs = [ lndir ]; } ''
                  mkdir -p $out
                  ${lib.concatMapStrings (src: ''
                    lndir -silent ${src}/cache/download $out
                  '') sources}
                  lndir -silent ${final.modGraph} $out
                ''
              ) { };
            }
          ) (lockFile.workspace or { });

          # The go.mod files Go reads to resolve the workspace graph, including
          # versions MVS doesn't select (see graph.go in the generator). One
          # fixed-output derivation, without the sources.
          modGraph = final.callPackage (
            {
              stdenvNoCC,
              curl,
              cacert,
            }:
            stdenvNoCC.mkDerivation {
              name = "go-mod-graph";
              nativeBuildInputs = [ curl ];
              SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
              impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "GOPROXY" ];
              mods = lockFile.graph.mods or [ ];
              buildCommand = ''
                proxy="''${GOPROXY:-https://proxy.golang.org}"
                proxy="''${proxy%%,*}"
                export proxy out
                for mod in $mods; do echo "$mod"; done \
                  | xargs -P 16 -I '{}' sh -c \
                      'mkdir -p "$out/$(dirname "$1")" && curl -fsSL --retry 3 "$proxy/$1" -o "$out/$1"' _ '{}'
              '';
              outputHashMode = "recursive";
              outputHashAlgo = null;
              outputHash = lockFile.graph.hash or lib.fakeHash;
            }
          ) { };
        }
        //
          # Create a package per Go _module_
          mapAttrs (
            goPackagePath: locked:
            cyclePkgs.${goPackagePath} or (final.callPackage (
              {
                stdenv,
                fetchers,
                hooks,
              }:
              stdenv.mkDerivation (
              {
                name = goPackagePath;
                inherit (locked) version;

                src = fetchers.fetchModuleProxy {
                  inherit goPackagePath;
                  inherit (locked) version hash;
                };

                passthru = {
                  inherit cycles;
                  inherit cyclePkgs;
                };

                # A workspace lock records which packages are imported from
                # each module: build only those instead of `<module>/...`. A
                # module nothing imports is only needed for its go.mod.
              }
              // lib.optionalAttrs (locked ? packages || lockFile ? workspace) (
                if (locked.packages or [ ]) == [ ] then
                  { dontUseGoBuild = true; }
                else
                  { env.goBuildPackages = builtins.concatStringsSep " " locked.packages; }
              )
              // {

                nativeBuildInputs = [
                  hooks.goModuleHook
                ];

                propagatedBuildInputs = map (depGoPackagePath: final.${depGoPackagePath} or null) (
                  locked.require or [ ]
                );

              })
            ) { })
          ) lockFile.locked
        //
          # Create a package per local Go _package_
          mapAttrs (
            goPackagePath: locked:
            let
              # Resolve local package requirements
              require = genericClosure {
                startSet = [ { key = goPackagePath; } ];
                operator =
                  item:
                  concatMap (
                    goPackagePath: if !lockFile.package ? ${goPackagePath} then [ ] else [ { key = goPackagePath; } ]
                  ) (lockFile.package.${item.key}.require or [ ]);
              };

              # Local package directories to include
              dirs = map (item: lockFile.package.${item.key}.dir) require;

            in
            overridePackage (
              final.callPackage (
                {
                  stdenv,
                  hooks,
                }:
                stdenv.mkDerivation {
                  name = goPackagePath;

                  # Create a union of all required local sources
                  src = lib.sources.sourceByGlobs rootDir ([
                    "go.mod"
                    "go.work.sum"
                  ] ++ map (dir: "${dir}/**") dirs);

                  # Only build the current Go package
                  env.goBuildPackages = goPackagePath + "/...";

                  nativeBuildInputs = [
                    hooks.goPackageHook
                  ];

                  passthru = {
                    inherit goPackagePath;
                  };

                  propagatedBuildInputs =
                    final.require ++ map (depGoPackagePath: final.${depGoPackagePath} or null) (locked.require or [ ]);
                }
              ) { }
            )
          ) (lockFile.package or { });

    in
    (callPackage ./nix { inherit go; }).overrideScope overlay';
}
