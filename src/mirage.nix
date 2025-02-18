{ pkgs, lib, flake-utils, opam-nix, opam2json, nix-filter, opam-repository, opam-overlays, ... }:

let
  inherit (opam-nix) queryToScope buildOpamMonorepo buildOpamProject;
  inherit (pkgs.lib.attrsets) mapAttrsToList mapAttrs' nameValuePair;
in rec {
  # run `mirage configure` on source,
  # with mirage, dune, and ocaml from `opam-nix`
  configureSrcFor = configureSrcFor' (queryToScope { } { "mirage" = "*"; });

  configureSrcFor' = configureScope: unikernelName: mirageDir: src: target:
    # Get mirage tool and dependancies from opam.
    # We could also get them from nixpkgs but they may not be up to date.
    pkgs.stdenv.mkDerivation {
      name = "configured-src";
      # only copy these files and only rebuild when they change
      src = with nix-filter.lib;
      filter {
        root = src;
        exclude = [
        (inDirectory "_build")
        (inDirectory "dist")
        (inDirectory "duniverse")
        (inDirectory "${mirageDir}/mirage")
        "dune"
        "dune.build"
        "dune.config"
        "dune-project"
        "dune-workspace"
        "Makefile"
        "flake.nix"
        "flake.lock"
        ];
      };
      buildInputs = with configureScope; [ mirage ];
      nativeBuildInputs = with configureScope; [ dune ocaml ];
      phases = [ "unpackPhase" "configurePhase" "installPhase" "fixupPhase" ];
      configurePhase = ''
        mirage configure -f ${mirageDir}/config.ml -t ${target}
        # Rename the opam file for package name consistency
        # And move to root so a recursive search for opam files isn't required
        cp ${mirageDir}/mirage/${unikernelName}-${target}.opam ${unikernelName}.opam
      '';
      installPhase = "cp -R . $out";
    };

  # collect all dependancy sources in a scope
  mkScopeMonorepo = monorepoQuery: src: buildOpamMonorepo { } src monorepoQuery;

  # read all the opam files from the configured source and build the ${unikernelName} package
  mkScopeOpam = unikernelName: mirageDir: libexts: depexts: monorepoQuery: src:
    let
      scope = buildOpamProject { } unikernelName src { "ocaml" = "4.14.1"; };
      overlay = mkScopeOverlay unikernelName mirageDir libexts depexts monorepoQuery src;
    in scope.overrideScope' overlay;

  mkScopeOverlay = unikernelName: mirageDir: libexts: depexts: monorepoQuery: src:
    mkScopeOverlay' (mkScopeMonorepo monorepoQuery src) unikernelName mirageDir libexts depexts;

  mkScopeOverlay' = monorepoScope: unikernelName: mirageDir: libexts: depexts:
    final: prev: {
        "${unikernelName}" = prev.${unikernelName}.overrideAttrs (_ : {
            phases = [ "unpackPhase" "preBuild" "buildPhase" "installPhase" ];
            # TODO pick depexts of deps in monorepo
            buildInputs = prev.${unikernelName}.buildInputs ++ libexts;
            nativeBuildInputs = depexts;

            # find solo5 toolchain
            OCAMLFIND_CONF = if final ? ocaml-solo5
                             then "${final.ocaml-solo5}/lib/findlib.conf"
                             else "";
            preBuild = let
              # TODO get dune build to pick up symlinks
              createDep = name: path: "cp -r ${path} duniverse/${name}";
              createDeps = mapAttrsToList createDep monorepoScope;
              createDuniverse = builtins.concatStringsSep "\n" createDeps;
            in ''
              # create duniverse
              mkdir duniverse
              echo '(vendored_dirs *)' > duniverse/dune
              ${createDuniverse}
            '';
            buildPhase = ''
              # don't fail on warnings
              dune build ${mirageDir} --profile release
            '';
            installPhase = ''
              mkdir $out
              cp -L ${mirageDir}/dist/${unikernelName}* $out/
            '';
          }
        );
      };

  mkUnikernelPackages = { unikernelName, mirageDir ? ".", libexts ? with pkgs; [ ], depexts ? with pkgs; [ ], monorepoQuery ? { } }:
    src: let
      targets = [ "xen" "qubes" "unix" "macosx" "virtio" "hvt" "spt" "muen" "genode" ];
      mapTargets = mkScope:
      let
        pipeTarget = target: lib.pipe target [
          (configureSrcFor unikernelName mirageDir src)
          mkScope
        ];
        mappedTargets = builtins.map (target: nameValuePair target (pipeTarget target)) targets;
      in builtins.listToAttrs mappedTargets;
        targetUnikernels = mapAttrs'
          (target: scope: nameValuePair target scope.${unikernelName})
          (mapTargets (mkScopeOpam unikernelName mirageDir libexts depexts monorepoQuery));
        targetScopes = mapAttrs'
          (target: scope: nameValuePair "${target}-scope" scope)
          (mapTargets (mkScopeOpam unikernelName mirageDir libexts depexts monorepoQuery));
        targetMonorepoScopes = mapAttrs'
          (target: scope: nameValuePair "${target}-monorepo" scope)
          (mapTargets (mkScopeMonorepo monorepoQuery));
    in targetUnikernels // targetScopes // targetMonorepoScopes;
}
