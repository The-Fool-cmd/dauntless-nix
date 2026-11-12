# ParadoxBackend, built from this repo. Game data, .env and TLS material are NOT part of the package;
# the NixOS module points the service at a state directory for those.
{ lib, buildNpmPackage, nodejs_22, autoPatchelfHook, stdenv }:
buildNpmPackage {
  pname = "dauntless-nix-backend";
  version = "0-unstable";
  # The backend imports ../shared/hunt-manifest, so the source is the repo root, narrowed to those two folders.
  src = let r = ../..; b = ../../ParadoxBackend; in lib.fileset.toSource {
    root = r;
    fileset = lib.fileset.unions [
      ../../shared/hunt-manifest
      # Synthetic hunt tables (examples only) for smoke tests; real tables live in the state dir.
      (lib.fileset.fileFilter (f: lib.hasSuffix ".example.json" f.name) ../../ParadoxDirector/game-data)
      (lib.fileset.difference b (lib.fileset.unions [
        (lib.fileset.maybeMissing (b + "/node_modules"))
        (lib.fileset.maybeMissing (b + "/build"))
        (lib.fileset.maybeMissing (b + "/.env"))
        (lib.fileset.maybeMissing (b + "/game-data/raw"))
        # Real (non-example) game data must never land in the world-readable Nix store.
        (lib.fileset.fileFilter (f: f.hasExt "json" && !(lib.hasSuffix ".example.json" f.name)) (b + "/game-data"))
      ]))
    ];
  };
  sourceRoot = "source/ParadoxBackend";
  nodejs = nodejs_22;
  npmDepsHash = "sha256-DYsAr3Uzhk2IchpyWTZoFwAHO0KThUowxan/qcz2YX8=";

  # @node-rs/argon2 ships a prebuilt glibc .node; patch its rpath for NixOS.
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];

  # Upstream `npm run build` = clean + tsc.
  npmBuildScript = "build";
  dontNpmPrune = false;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/backend $out/lib/shared
    cp -r ../shared/hunt-manifest $out/lib/shared/   # build/p2p/huntManifest/*.js -> ../../../../shared
    cp -r build scripts package.json package-lock.json $out/lib/backend/
    mkdir -p $out/lib/backend/game-data
    cp game-data/*.example.json $out/lib/backend/game-data/
    mkdir -p $out/lib/hunt-data-examples
    cp ../ParadoxDirector/game-data/*.example.json $out/lib/hunt-data-examples/
    npm prune --omit=dev --no-audit --no-fund
    cp -r node_modules $out/lib/backend/
    mkdir -p $out/bin
    cat > $out/bin/dauntless-nix-backend <<SH
    #!${stdenv.shell}
    exec ${nodejs_22}/bin/node $out/lib/backend/build/server.js "\$@"
    SH
    chmod +x $out/bin/dauntless-nix-backend
    runHook postInstall
  '';

  meta = {
    description = "Account/metagame backend for self-hosted Dauntless 1.14.7 (modified Mystic Paradox)";
    license = lib.licenses.agpl3Only;
    mainProgram = "dauntless-nix-backend";
  };
}
