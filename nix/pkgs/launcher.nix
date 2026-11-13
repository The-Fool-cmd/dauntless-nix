# The minimal Linux launcher (tools/linux-launcher/launcher.mjs): Node stdlib only.
{ lib, writeShellApplication, nodejs_22, coreutils }:
writeShellApplication {
  name = "dauntless-nix-launcher";
  runtimeInputs = [ nodejs_22 coreutils ];   # cp for the hard-linked working copy
  text = ''exec node ${../../tools/linux-launcher/launcher.mjs} "$@"'';
  meta.license = lib.licenses.agpl3Only;
}
