# Drop-in GAMESERVER_BINARY_PATH for ParadoxDirector on Linux: runs Dauntless-Win64-Shipping.exe headless under the
# flake-pinned GE-Proton's own `wine` (no Steam shim, no DXVK: -nullrhi renders nothing), passing the Director's
# arguments through unchanged. stdout reaches the Director, so it sees MYSTICPARADOX_GAMESERVER_READY.
#
# One Wine prefix per game port (cloned from a template on first use), so each server has its own wineserver
# and SIGTERM from the Director stops exactly that server (`wineserver -k` for its prefix).
#
# Environment (set by the NixOS module):
#   DAUNTLESS_GAME_DIR     game root containing Archon/Binaries/Win64 (with MysticParadox.dll + winmm.dll)
#   DAUNTLESS_PREFIX_ROOT  directory holding the per-port prefixes
{ writeShellApplication, steam-run, proton-ge-bin, coreutils }:
let
  files = "${proton-ge-bin.steamcompattool}/files";
  wine = "${files}/bin";
in writeShellApplication {
  name = "dauntless-gameserver";
  runtimeInputs = [ steam-run coreutils ];
  text = ''
    : "''${DAUNTLESS_GAME_DIR:?}" "''${DAUNTLESS_PREFIX_ROOT:?}"
    port=''${2:?"usage: <api-key> <port> <map> ... (ParadoxDirector argument order)"}
    case "$port" in (*[!0-9]*|"") echo "bad port: $port" >&2; exit 64;; esac

    export WINEPREFIX="$DAUNTLESS_PREFIX_ROOT/port-$port"
    export WINEDLLOVERRIDES="winmm=n,b"   # load the runtime loader from the game folder
    export WINEDEBUG="''${WINEDEBUG:--all}"
    # What Proton's script would set: the exe statically imports d3d11/dxgi, and wined3d needs vkd3d's DLLs.
    export WINEDLLPATH="${files}/lib/vkd3d:${files}/lib/wine"
    unset DISPLAY WAYLAND_DISPLAY          # headless; -nullrhi
    # steam-run's sandbox re-enters the caller's cwd, which may not exist inside it (e.g. under /etc): move first.
    cd "$DAUNTLESS_GAME_DIR/Archon/Binaries/Win64"

    if [ ! -d "$WINEPREFIX/drive_c" ]; then
      mkdir -p "$WINEPREFIX"
      steam-run ${wine}/wine wineboot --init >/dev/null 2>&1 || true
      steam-run ${wine}/wineserver -w
    fi

    stop() { steam-run ${wine}/wineserver -k 2>/dev/null || true; }
    trap 'stop; exit 143' TERM INT

    steam-run ${wine}/wine Dauntless-Win64-Shipping.exe "$@" &
    child=$!
    rc=0; wait "$child" || rc=$?
    [ "$rc" -eq 0 ] || echo "dauntless-gameserver: game exited with $rc (port $port)" >&2
    stop
    exit "$rc"
  '';
}
