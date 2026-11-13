# Runs a Windows executable under the flake-pinned GE-Proton, outside Steam.
# Usage: dauntless-proton <prefix-dir> <exe> [args...]
# umu-launcher was rejected: it downloads the Steam Runtime at run time (unpinned). See DECISIONS.md.
{ writeShellApplication, steam, proton-ge-bin, SDL2, sdl3 }:
let
  proton = proton-ge-bin.steamcompattool;
  # Wine's winebus only presents a controller to the game as an XInput pad when it can load SDL2 (D36); plain
  # steam-run lacks it, so non-Xbox pads (e.g. HID-mode GameSir) were invisible. nixpkgs' SDL2 is sdl2-compat over
  # SDL3, and Proton's LD_LIBRARY_PATH puts its own older libxkbcommon first, which a full SDL3 refuses. winebus
  # needs only joysticks, so this SDL3 is built without video, audio and input-method backends.
  sdl3-joystick = sdl3.override {
    x11Support = false; waylandSupport = false; libdecorSupport = false; ibusSupport = false; traySupport = false;
    openglSupport = false; vulkanSupport = false; drmSupport = false;
    alsaSupport = false; jackSupport = false; pipewireSupport = false; pulseaudioSupport = false;
  };
  sdl2-joystick = SDL2.override { sdl3 = sdl3-joystick; };
  steam-run = (steam.override { extraPkgs = _: [ sdl2-joystick sdl3-joystick ]; }).run;
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
    # Proton's default channels include +seh, which grew one play session's log to 5 GB (D36): keep DLL loads,
    # thread names and errors only.
    export WINEDEBUG="''${WINEDEBUG:-+timestamp,+pid,+tid,+loaddll,+threadname,err+all,fixme-all}"
    echo "dauntless-proton: $(cat ${proton}/version)" >&2
    exec steam-run ${proton}/proton waitforexitandrun "$@"
  '';
}
