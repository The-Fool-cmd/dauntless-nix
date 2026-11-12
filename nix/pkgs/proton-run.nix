# Runs a Windows executable under the flake-pinned GE-Proton, outside Steam.
# Usage: dauntless-proton <prefix-dir> <exe> [args...]
# umu-launcher was rejected: it downloads the Steam Runtime at run time (unpinned). See DECISIONS.md.
{ writeShellApplication, steam-run, proton-ge-bin }:
let proton = proton-ge-bin.steamcompattool;
in writeShellApplication {
  name = "dauntless-proton";
  runtimeInputs = [ steam-run ];
  text = ''
    if [ "$#" -lt 2 ]; then
      echo "usage: dauntless-proton <prefix-dir> <exe> [args...]" >&2; exit 64
    fi
    prefix=$(realpath -m "$1"); shift
    mkdir -p "$prefix/client"
    export STEAM_COMPAT_DATA_PATH="$prefix"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$prefix/client"   # no Steam client needed
    export PROTONFIXES_DISABLE=1      # no protonfixes/winetricks downloads at run time
    # Proton only writes its log (and only honours WINEDEBUG) when SteamGameId is set: $PROTON_LOG_DIR/steam-<id>.log
    export SteamGameId="''${SteamGameId:-dauntless-nix}"
    export PROTON_LOG="''${PROTON_LOG:-1}"
    export PROTON_LOG_DIR="''${PROTON_LOG_DIR:-$prefix/logs}"
    mkdir -p "$PROTON_LOG_DIR"
    echo "dauntless-proton: $(cat ${proton}/version)" >&2
    exec steam-run ${proton}/proton waitforexitandrun "$@"
  '';
}
