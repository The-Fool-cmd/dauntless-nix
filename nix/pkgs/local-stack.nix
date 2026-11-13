# `nix run .#local-stack -- up|down|status|launcher-config`: the server as user processes (tools/dev/local-stack.sh).
{ lib, writeShellApplication, writeShellScript, mongodb-ce, mongosh, nodejs_22, openssl, curl, coreutils, gnugrep,
  util-linux, steam-run, proton-ge-bin, backend, director, gameserver-wine, proton-run }:
let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [ ../../scripts/generate-selfhost-rsa-key.mjs ../../ParadoxLauncher/scripts ];
  };
  wineserver = writeShellScript "dn-wineserver" ''exec ${steam-run}/bin/steam-run ${proton-ge-bin.steamcompattool}/files/bin/wineserver "$@"'';
in writeShellApplication {
  name = "local-stack";
  # Variables assigned between `set -a` / `set +a` are exported to the services; shellcheck cannot see that.
  excludeShellChecks = [ "SC2034" ];
  runtimeInputs = [ mongodb-ce mongosh nodejs_22 openssl curl coreutils gnugrep util-linux ];
  runtimeEnv = {
    DN_SRC = "${src}";
    DN_BACKEND = "${backend}";
    DN_DIRECTOR = "${director}";
    DN_GAMESERVER = lib.getExe gameserver-wine;
    DN_WINESERVER = "${wineserver}";
    DN_PROTON_RUN = lib.getExe proton-run;
  };
  text = builtins.readFile ../../tools/dev/local-stack.sh;
}
