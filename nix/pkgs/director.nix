# ParadoxDirector (DeployServer): starts and supervises Ramsgate, the Training Grounds and hunts.
# On Linux its GAMESERVER_BINARY_PATH is the dauntless-gameserver Wine wrapper (nix/pkgs/gameserver-wine.nix).
{ lib, buildNpmPackage, nodejs_22, stdenv }:
buildNpmPackage {
  pname = "dauntless-nix-director";
  version = "0-unstable";
  # Imports ../../../shared/hunt-manifest (from dist/controllers), so the source is the repo root, narrowed.
  src = let d = ../../ParadoxDirector; in lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../shared/hunt-manifest
      (lib.fileset.difference d (lib.fileset.unions [
        (lib.fileset.maybeMissing (d + "/node_modules"))
        (lib.fileset.maybeMissing (d + "/dist"))
        (lib.fileset.maybeMissing (d + "/.env"))
        (lib.fileset.maybeMissing (d + "/game-data/raw"))
        # Real hunt tables are game data: never in the Nix store.
        (lib.fileset.fileFilter (f: f.hasExt "json" && !(lib.hasSuffix ".example.json" f.name)) (d + "/game-data"))
      ]))
    ];
  };
  sourceRoot = "source/ParadoxDirector";
  nodejs = nodejs_22;
  npmDepsHash = "sha256-dmYyKtZLtTKFuCZaXTZadRpyu9RUBLv1ZiSbstYirSw=";
  npmBuildScript = "build";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/director $out/lib/shared $out/bin
    cp -r ../shared/hunt-manifest $out/lib/shared/      # dist/controllers/*.js -> ../../../shared
    cp -r dist scripts package.json package-lock.json $out/lib/director/
    mkdir -p $out/lib/director/game-data
    cp game-data/*.example.json $out/lib/director/game-data/
    npm prune --omit=dev --no-audit --no-fund
    cp -r node_modules $out/lib/director/
    cat > $out/bin/dauntless-nix-director <<SH
    #!${stdenv.shell}
    exec ${nodejs_22}/bin/node $out/lib/director/dist/server.js "\$@"
    SH
    chmod +x $out/bin/dauntless-nix-director
    runHook postInstall
  '';
  meta = {
    description = "Game-server director for self-hosted Dauntless 1.14.7 (modified Mystic Paradox)";
    license = lib.licenses.agpl3Only;
    mainProgram = "dauntless-nix-director";
  };
}
