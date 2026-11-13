# NixOS module: ParadoxDirector + dedicated Dauntless 1.14.7 game servers under Wine (DECISIONS D17/D18).
#
#   backend ──127.0.0.1:<director.port>──▶ Director (Node, no auth: loopback only)
#                                             │ spawns, one per hub/hunt
#                                             ▼
#                    dauntless-gameserver (GE-Proton wine, headless, one prefix per port)
#                    └─ <stateDir>/director/game: hard-linked copy of `gameDir` + MysticParadox.dll + winmm.dll
#   players ──UDP <portRange>──▶ game servers
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dauntless-nix;
  dcfg = cfg.director;
  inherit (lib) mkOption mkEnableOption mkIf types;

  dir = "${cfg.stateDir}/director";
  instance = "${dir}/game";
  win64 = "${instance}/Archon/Binaries/Win64";

  directorEnv = {
    NODE_ENV = "production";
    PORT = toString dcfg.port;
    BIND_HOST = "127.0.0.1";
    MY_IP = dcfg.publicAddress;
    PORT_RANGE_BEGIN = toString dcfg.portRange.from;
    PORT_RANGE_END = toString dcfg.portRange.to;
    GAMESERVER_BINARY_PATH = dcfg.gameserverBinary;
    SECONDS_TO_WAIT_BETWEEN_GAMESERVER_STARTUP = "3";
    # First start of a port creates its Wine prefix (~10 s on a desktop); leave headroom.
    GAMESERVER_READY_TIMEOUT_MS = "120000";
    MAX_CONCURRENT_HUNT_SERVERS = toString dcfg.maxConcurrentHunts;
    PARADOX_GAME_DATA_DIR = "${cfg.stateDir}/hunt-data";   # shared with the backend (PARADOX_HUNT_DATA_DIR)
    GAMESERVER_LOG_DIR = "${dir}/logs";
    SERVER_RUNTIME_AUTO_UPDATE = "false";                   # runtime DLLs come from Nix, not a download
    SERVER_RUNTIME_UPDATE_REQUIRED = "false";
    RAMSGATE_HUB = "on";
    TRAINING_HUB = "on";
    LOG_LEVEL = "info";
    # Read by the dauntless-gameserver wrapper:
    DAUNTLESS_GAME_DIR = instance;
    DAUNTLESS_PREFIX_ROOT = "${dir}/prefixes";
  } // lib.optionalAttrs (dcfg.serverBackendUrl != null) {
    # Inherited by every game server (the Director passes its environment through): the runtime then calls the
    # backend here instead of the compiled-in https://MP_PUBLIC_HOST (ParadoxRuntime/BackendUrl.h).
    MYSTICPARADOX_BACKEND_URL = dcfg.serverBackendUrl;
  } // dcfg.extraEnvironment;
in
{
  options.services.dauntless-nix.director = {
    enable = mkEnableOption "the Director and dedicated hubs/hunts under Wine";

    package = mkOption { type = types.package; description = "The dauntless-nix Director package."; };

    gameserverBinary = mkOption {
      type = types.str;
      description = "GAMESERVER_BINARY_PATH. Defaults to the dauntless-gameserver Wine wrapper (set by the flake).";
    };

    port = mkOption {
      type = types.port;
      default = 3001;
      description = "Director API port, bound to 127.0.0.1. Change it if 3001 is taken (e.g. by Uptime Kuma).";
    };

    publicAddress = mkOption {
      type = types.str;
      example = "10.77.0.1";
      description = "MY_IP: the address clients connect to for game UDP (must be reachable by every player).";
    };

    portRange = {
      from = mkOption { type = types.port; default = 8780; };
      to = mkOption { type = types.port; default = 8790; description = "Last port = Ramsgate, the one before = Training Grounds."; };
    };

    maxConcurrentHunts = mkOption { type = types.ints.positive; default = 2; };

    gameDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/srv/games/dauntless-1.14.7";
      description = ''
        A pristine Dauntless 1.14.7 install on this host (the folder holding Archon/ and Version.txt), e.g. copied
        from a player's verified Legendary install. Never modified: the servers run from a hard-linked copy (or a
        full copy across filesystems) under the state dir, after the exe's SHA-256 is checked against
        services.dauntless-nix.approvedExecutableSha256. null = skip setup (tests with a stub game server).
      '';
    };

    serverBackendUrl = mkOption {
      type = types.nullOr types.str;
      default = "http://127.0.0.1:${toString cfg.backend.port}";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString cfg.backend.port}"'';
      description = "Backend address the game servers use (loopback HTTP: they run on the same host). null = compiled-in host.";
    };

    extraEnvironment = mkOption { type = types.attrsOf types.str; default = { }; };
  };

  config = mkIf (cfg.enable && dcfg.enable) {
    assertions = [
      { assertion = dcfg.gameDir == null || cfg.runtime != null;
        message = "services.dauntless-nix.director.gameDir needs services.dauntless-nix.runtime (MysticParadox.dll + winmm.dll)."; }
      { assertion = dcfg.portRange.to - dcfg.portRange.from >= 2;
        message = "services.dauntless-nix.director.portRange needs at least three ports (hunts, Training Grounds, Ramsgate)."; }
    ];

    users.users.dauntless-director = {
      isSystemUser = true;
      group = "dauntless-director";
      extraGroups = [ "dauntless" ];      # read the shared hunt tables
      home = dir;
    };
    users.groups.dauntless-director = { };

    systemd.tmpfiles.settings."11-dauntless-nix-director" = {
      "${dir}".d = { user = "dauntless-director"; group = "dauntless-director"; mode = "0750"; };
      "${dir}/run".d = { user = "dauntless-director"; group = "dauntless-director"; mode = "0750"; };
      "${dir}/logs".d = { user = "dauntless-director"; group = "dauntless-director"; mode = "0750"; };
      "${dir}/debug".d = { user = "dauntless-director"; group = "dauntless-director"; mode = "0750"; };
      "${dir}/prefixes".d = { user = "dauntless-director"; group = "dauntless-director"; mode = "0750"; };
    };

    # Secrets + game instance. Runs as root: it reads the backend's secret file and may hard-link a root-owned install.
    systemd.services.dauntless-director-setup = {
      description = "dauntless-nix: Director secret and game-server instance";
      partOf = [ "dauntless.target" ];
      after = [ "dauntless-nix-init.service" "systemd-tmpfiles-setup.service" ];
      requires = [ "dauntless-nix-init.service" ];
      path = [ pkgs.coreutils pkgs.gnugrep ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        set -euo pipefail
        # METAGAME_API_KEY is the backend's GAMESERVER_API_KEYS (the key game servers present to the backend).
        key=$(grep -m1 '^GAMESERVER_API_KEYS=' ${cfg.stateDir}/secrets/backend.env | cut -d= -f2-)
        install -o dauntless-director -g dauntless-director -m 0600 /dev/null ${dir}/director.env
        echo "METAGAME_API_KEY=$key" > ${dir}/director.env

        ${lib.optionalString (dcfg.gameDir != null) ''
          src=${lib.escapeShellArg dcfg.gameDir}
          exe=Archon/Binaries/Win64/Dauntless-Win64-Shipping.exe
          have=$(sha256sum "$src/$exe" | cut -d' ' -f1)
          if [ "$have" != ${cfg.approvedExecutableSha256} ]; then
            echo "refusing: $src/$exe has SHA-256 $have, not the approved 1.14.7 build" >&2; exit 1
          fi
          if [ ! -e ${instance}/$exe ]; then
            rm -rf ${instance}.tmp
            # Hard links when on the same filesystem (no extra 16 GB), else a real copy.
            cp -al "$src" ${instance}.tmp 2>/dev/null || { rm -rf ${instance}.tmp; cp -a "$src" ${instance}.tmp; }
            mv ${instance}.tmp ${instance}
          fi
          # The Win64 directory itself is per-instance (hard-linked files, own directory): add the runtime there.
          chown dauntless-director:dauntless-director ${win64}
          chmod 0750 ${win64}
          for f in MysticParadox.dll winmm.dll; do
            install -o dauntless-director -g dauntless-director -m 0644 ${cfg.runtime}/$f ${win64}/$f
          done
          rm -f ${win64}/mystic_loader.ini ${win64}/MystPaxInternalServer.dll   # nothing else gets injected
          # This is a modified build, not an official Mystic Paradox release (ADDITIONAL_TERMS 2-4): stock screens.
          for f in LOGIN CREDITS PRESS_START; do
            install -o dauntless-director -g dauntless-director -m 0644 /dev/null ${win64}/DISABLE_''${f}_BRANDING.flag
          done
        ''}
      '';
    };

    systemd.services.dauntless-director = {
      description = "dauntless-nix Director (ParadoxDirector) and its game servers";
      wantedBy = [ "dauntless.target" ];
      partOf = [ "dauntless.target" ];
      after = [ "network.target" "dauntless-director-setup.service" "dauntless-backend.service" ];
      requires = [ "dauntless-director-setup.service" ];
      environment = directorEnv;
      serviceConfig = {
        User = "dauntless-director";
        Group = "dauntless-director";
        # logger.ts writes ../debug/deployserver relative to cwd -> ${dir}/debug.
        WorkingDirectory = "${dir}/run";
        EnvironmentFile = "${dir}/director.env";
        ExecStart = lib.getExe dcfg.package;
        Restart = "on-failure";
        RestartSec = 10;
        # Game servers are children: stopping the Director stops every Wine process in the unit.
        KillMode = "control-group";
        TimeoutStopSec = 30;
        # Hardening that Wine + steam-run (bubblewrap user namespaces) tolerate.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ dir ];
        ReadOnlyPaths = [ "${cfg.stateDir}/hunt-data" ];
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      };
    };

    networking.firewall = mkIf cfg.openFirewall (
      let udp = { allowedUDPPortRanges = [ { inherit (dcfg.portRange) from to; } ]; };
      in if cfg.firewall.interfaces == [ ] then udp
         else { interfaces = lib.genAttrs cfg.firewall.interfaces (_: udp); });
  };
}
