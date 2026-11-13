# NixOS module: self-hosted Dauntless 1.14.7 backend (phase 1).
#
#   internet ──80/tcp──▶ nginx "pong" (region measurement, exact body, never redirected)
#            ──443/tcp─▶ nginx TLS ──▶ 127.0.0.1:<backend.port> ParadoxBackend (HTTP + XMPP WebSocket)
#                                         │ unix socket only (group-restricted directory)
#                                         ▼
#                                      MongoDB 7 container, --network=none, single-node replica set
#
# Secrets are generated once on the host into ${stateDir}/secrets and never enter the Nix store.
# See DECISIONS.md D7–D10.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dauntless-nix;
  inherit (lib) mkOption mkEnableOption mkIf types;

  mongoSockDir = "/run/dauntless-nix/mongodb";
  # The socket mongod creates for --port 27017 with --unixSocketPrefix ${mongoSockDir}.
  mongoUri = "mongodb://${lib.escapeURL "${mongoSockDir}/mongodb-27017.sock"}/?directConnection=true";

  # Own directory: nginx must not be able to traverse into stateDir (secrets live there).
  tlsDir = "/var/lib/dauntless-nix-tls";
  certFile = if cfg.tls.mode == "files" then cfg.tls.certFile else "${tlsDir}/fullchain.pem";
  keyFile = if cfg.tls.mode == "files" then cfg.tls.keyFile else "${tlsDir}/privkey.pem";

  mongoImage = pkgs.dockerTools.pullImage {
    imageName = "mongo";
    imageDigest = "sha256:fb8e0773cddc25d3450171301e3fa0e7398c3e6b02afc3dc6e2780196b62726a";
    hash = "sha256-UvnooRoJSExnUZMW7hBQ0T8RYjmdsiWnBNmBb/oFGrw=";
    finalImageName = "mongo";
    finalImageTag = "7.0.48-jammy";
  };

  # Non-secret backend settings. Mirrors scripts/configure-selfhost.ps1 plus the "Linux behind nginx" notes.
  backendEnv = {
    NODE_ENV = "production";
    MYSTICPARADOX_SERVICE_ROLE = "api";
    PORT = toString cfg.backend.port;
    BIND_HOST = "127.0.0.1";
    MYSTICPARADOX_TLS_TERMINATED_BY_PROXY = "on";
    QOS_PORT = "off";
    AUTH_MODE = "LAUNCHER";
    ALLOW_NO_AUTH_DEV_MODE = "false";
    MONGODB_URI = mongoUri;
    MONGODB_DB = "dauntless";
    MONGODB_APP_NAME = "dauntless-nix-backend";
    MONGODB_CONNECT_TIMEOUT_MS = "5000";
    MONGODB_SERVER_SELECTION_TIMEOUT_MS = "5000";
    MONGODB_MAX_POOL_SIZE = "20";
    MONGODB_MAX_IDLE_TIME_MS = "60000";
    TARGET_CHANGELIST = "647472";
    QOS_TARGET_URL = "https://${cfg.publicHost}/QoS";
    MATCHMAKING_MODE = "DEPLOYSERVER";
    DEPLOYSERVER_URL = "127.0.0.1:${toString cfg.director.port}";
    LAUNCHER_ALLOWED_ORIGINS = "https://${cfg.publicHost}";
    APPROVED_EXECUTABLE_SHA256 = cfg.approvedExecutableSha256;
    UPDATE_PUBLIC_BASE_URL = "https://${cfg.publicHost}";
    LAUNCHER_UPDATE_ROOT = "${cfg.stateDir}/updates";
    LAUNCHER_LOG_STORAGE_DIR = "${cfg.stateDir}/launcher-logs";
    PARADOX_GAME_DATA_DIR = "${cfg.stateDir}/game-data";
    PARADOX_GAME_DATA_RAW_DIR = "${cfg.stateDir}/game-data/raw";
    # Hunt tables (CatalogExporter EXPORT_HUNTS); shared with the Director once it exists.
    PARADOX_HUNT_DATA_DIR = "${cfg.stateDir}/hunt-data";
    REALTIME_XMPP_ENABLED = "true";
    REALTIME_XMPP_CAPTURE = "false";
    REALTIME_XMPP_ALLOWED_HOSTS = cfg.publicHost;
    REALTIME_XMPP_DEV_CITY_MUC = "false";
    MYSTICPARADOX_ADMIN_API = "off";
    # Upstream's Terms/Privacy consent belongs to the official Mystic Paradox service; a private server's operator sets
    # its own rules (upstream's own default for local servers). Not asking players to accept Mystic Paradox's documents
    # also avoids implying this server is theirs (ADDITIONAL_TERMS 2-4).
    MYSTICPARADOX_CONSENT_REQUIRED = "off";
    MYSTICPARADOX_CONSENT_ENFORCE = "off";
    MYSTICPARADOX_EMAIL_VERIFICATION = "off";    # no SMTP; accounts are created by the operator's own players
    # Login-screen status line: never the official "Welcome to Mystic Paradox!" on this server (ADDITIONAL_TERMS 2-4).
    MYSTICPARADOX_STATUS_MESSAGE = cfg.statusMessage;
    GAMESERVER_HUNTPASS_ID = cfg.huntPass.season;
    LOG_LEVEL = "info";
  } // cfg.backend.extraEnvironment;

  # systemd expands %-specifiers in Environment=; the socket URI is percent-encoded, so double every %.
  systemdEnv = lib.mapAttrs (_: v: lib.replaceStrings [ "%" ] [ "%%" ] v) backendEnv;

  backendLocation = {
    proxyPass = "http://127.0.0.1:${toString cfg.backend.port}";
    extraConfig = ''
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $dauntless_connection_upgrade;
      proxy_read_timeout 3600s;
    '';
  };

  # Every dauntless unit is part of dauntless.target: `dauntless up` starts it, `dauntless down` stops all of it.
  target = "dauntless.target";
  inTarget = { wantedBy = [ target ]; partOf = [ target ]; };
  backupScript = pkgs.writeShellScript "dauntless-mongodb-backup" ''
    set -euo pipefail
    umask 077
    dir=${lib.escapeShellArg cfg.backup.dir}
    mkdir -p "$dir"; chmod 0700 "$dir"
    out="$dir/mongodb-$(date -u +%Y%m%dT%H%M%SZ)-$1.archive.gz"
    podman exec dauntless-mongodb mongodump --quiet --uri 'mongodb://127.0.0.1:27017/?directConnection=true' \
      --archive --gzip > "$out.tmp"
    [ -s "$out.tmp" ] || { echo "empty dump" >&2; rm -f "$out.tmp"; exit 1; }
    mv "$out.tmp" "$out"
    echo "backup: $out ($(stat -c %s "$out") bytes)"
    ls -1t "$dir"/mongodb-*.archive.gz | tail -n +$((${toString cfg.backup.keep} + 1)) | xargs -r rm -f --
  '';
  # Operator-visible settings (no secrets): the runtime Hunt Pass override lives here, outside the 0750 stateDir.
  settingsDir = "/var/lib/dauntless-nix-settings";
  huntPassFile = "${settingsDir}/huntpass.env";
  operatorUnits = [ target "dauntless-backend.service" "dauntless-director.service" "podman-dauntless-mongodb.service" ];
  # `dauntless collect-logs`: root gathers the 0750 log dirs into an archive only operators can read.
  logArchiveDir = "/var/lib/dauntless-nix-logs";

  cli = pkgs.writeShellApplication {
    name = "dauntless";
    runtimeInputs = [ pkgs.systemd pkgs.curl pkgs.coreutils pkgs.gnugrep ];
    text = ''
      units=(${lib.concatStringsSep " " operatorUnits})
      seasons="${lib.concatStringsSep " " cfg.huntPass.seasons}"
      current_season() {
        if [ -r ${huntPassFile} ] && grep -q '^GAMESERVER_HUNTPASS_ID=' ${huntPassFile}; then
          grep -m1 '^GAMESERVER_HUNTPASS_ID=' ${huntPassFile} | cut -d= -f2-
        else echo "${cfg.huntPass.season} (default)"; fi
      }
      wait_backend() {
        for _ in $(seq 1 90); do
          # Any HTTP answer (even 404) means the backend listens.
          if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:${toString cfg.backend.port}/)" != 000 ]; then return 0; fi
          sleep 1
        done
        return 1
      }
      case "''${1:-status}" in
        up|start)
          systemctl start ${target}
          if wait_backend; then echo "dauntless: up (Hunt Pass: $(current_season))"
          else echo "dauntless: backend did not answer within 90 s; see: dauntless logs" >&2; exit 1; fi ;;
        # Name every unit: stopping only the target would return before its PartOf units have stopped.
        down|stop) systemctl stop "''${units[@]}"; echo "dauntless: down" ;;
        restart) systemctl stop "''${units[@]}"; exec "$0" up ;;
        status)
          systemctl list-units --all --no-pager --plain --no-legend "''${units[@]}" 'dauntless-*' | cut -c1-100
          echo "Hunt Pass: $(current_season)" ;;
        collect-logs)
          systemctl start dauntless-collect-logs.service
          archives=(${logArchiveDir}/dauntless-logs-*.tar.gz)   # UTC timestamps: the glob sorts oldest first
          echo "dauntless: ''${archives[-1]}" ;;
        logs) shift; exec journalctl --no-pager -n "''${LINES_BACK:-200}" -u 'dauntless-*' -u podman-dauntless-mongodb.service "$@" ;;
        season)
          if [ $# -lt 2 ]; then echo "Hunt Pass: $(current_season)"; echo "available: $seasons (or: default)"; exit 0; fi
          case " $seasons default " in *" $2 "*) ;; *) echo "unknown season '$2'; available: $seasons default" >&2; exit 2 ;; esac
          systemctl start "dauntless-huntpass@$2.service"
          echo "Hunt Pass: $(current_season) (running servers were restarted; players log in again)" ;;
        *) echo "usage: dauntless up|down|restart|status|logs [-f]|collect-logs|season [ID|default]" >&2; exit 2 ;;
      esac
    '';
  };
in
{
  options.services.dauntless-nix = {
    enable = mkEnableOption "self-hosted Dauntless 1.14.7 backend (dauntless-nix)";

    package = mkOption {
      type = types.package;
      description = "The dauntless-nix backend package.";
    };

    publicHost = mkOption {
      type = types.str;
      example = "dauntless.example.net";
      description = ''
        Exact hostname players reach. Must match the TLS certificate, the hostname compiled into the runtime
        (MP_PUBLIC_HOST) and the launcher. Changing it later means rebuilding those.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/dauntless-nix";
      description = "Persistent state: secrets, TLS (self-signed mode), game data, MongoDB data, update feed.";
    };

    approvedExecutableSha256 = mkOption {
      type = types.str;
      default = "f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b";
      description = "SHA-256 of the only accepted Dauntless-Win64-Shipping.exe (1.14.7, CL 647472).";
    };

    statusMessage = mkOption {
      type = types.str;
      default = "Private server (dauntless-nix)";
      description = "Status line on the game's login screen; \"off\" hides it.";
    };

    syntheticGameData = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Seed missing game-data files from the upstream *.example.json fixtures. Startup/smoke tests only:
        synthetic data is NOT playable. Real files you place in ''${stateDir}/game-data are never overwritten.
      '';
    };

    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Start the server at boot. When false, nothing runs until an operator types `dauntless up` (dauntless.target);
        nginx and the WireGuard interface stay up either way.
      '';
    };

    operators = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "alice" ];
      description = "Users allowed to run `dauntless up/down/restart/season` without sudo (polkit, dauntless units only).";
    };

    huntPass = {
      season = mkOption {
        type = types.str;
        default = "season43";
        description = "The Hunt Pass the server runs (GET /huntpass). `dauntless season <id>` overrides it at run time.";
      };
      seasons = mkOption {
        type = types.listOf types.str;
        # The rows the 1.14.7 client's HuntPassSeasonDataTable enables (routes/system.ts DEFAULT_RECENT_SEASONS).
        default = [ "season43" "season44" "season45" "season46" "season47" "season48" "season49" "season50" ];
        description = "Seasons an operator may switch to. Progress is kept per season, so switching back resumes it.";
      };
    };

    gameDataDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/srv/dauntless/game-data";
      description = ''
        Host directory (not the Nix store: this data comes from the game) with real game-data JSON files, e.g. the
        assembled progression_config.json, and an optional hunt-data/ subdirectory. Installed into the state
        directory on every start when changed, over the synthetic examples.
      '';
    };

    plainHttpPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      example = 3080;
      description = ''
        Also serve the backend (HTTP + WebSocket) over plain HTTP on this port, opened only where 80/443 are (the
        firewall interfaces and the tunnel). For clients pointed at http://<publicHost>:<port>.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open TCP 80 (pong) and 443 (HTTPS + XMPP WebSocket), plus the game UDP range when the Director is on.";
    };

    firewall.interfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "enp10s0" ];
      description = ''
        Interfaces to open the player-facing ports on (the WireGuard interface, when enabled, is added on its own).
        Empty = all interfaces (networking.firewall.allowed*). Hosts that scope their firewall per interface should
        list their LAN interface here so nothing is opened on other segments (e.g. an IoT VLAN).
      '';
    };

    allowedNetworks = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [ "10.77.0.0/24" ];
      description = ''
        When set, the backend and the Director (with its game servers) may exchange IP traffic only with localhost and
        these networks (systemd IPAddressAllow, IPAddressDeny=any). Every player, and publicHost, must be inside them.
        A game server taken over by a player then cannot reach the home LAN or the internet. null = no restriction.
      '';
    };

    backend = {
      port = mkOption { type = types.port; default = 3000; description = "Loopback-only backend HTTP port."; };
      extraEnvironment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra non-secret backend settings (see ParadoxBackend/.env.example).";
      };
      extraEnvironmentFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Extra env files with secrets (SMTP, Discord, TURN...). Kept outside the Nix store.";
      };
    };

    tls = {
      mode = mkOption {
        type = types.enum [ "self-signed" "acme" "files" ];
        default = "self-signed";
        description = ''
          self-signed: generate a certificate for publicHost once (LAN/testing; the launcher and game will not
          trust it without extra steps). acme: Let's Encrypt via security.acme (needs DNS + public port 80).
          files: use certFile/keyFile.
        '';
      };
      certFile = mkOption { type = types.nullOr types.path; default = null; };
      keyFile = mkOption { type = types.nullOr types.path; default = null; };
    };

    runtime = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = ''
        Package with MysticParadox.dll + winmm.dll (flake: lib.msvcPackages { ... }.runtime { sdk; publicHost; }).
        Published, signed with this server's runtime key, to the backend's runtime feed for clients, and installed
        beside the Director's game servers.
      '';
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Dump MongoDB (mongodump --archive --gzip) when the stack starts, before the backend, and when it stops, after
          the backend has stopped. Root-only files in `backup.dir`; the newest `backup.keep` are kept. Restore: see
          docs/OPERATIONS.md.
        '';
      };
      dir = mkOption { type = types.str; default = "/var/lib/dauntless-nix-backups"; };
      keep = mkOption { type = types.ints.positive; default = 30; };
    };

    mongodb.uid = mkOption {
      type = types.int;
      default = 27017;
      description = "Fixed uid/gid the MongoDB container runs as (owns its data and socket). Pick one free on the host.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.tls.mode != "files" || (cfg.tls.certFile != null && cfg.tls.keyFile != null);
        message = "services.dauntless-nix.tls.mode = \"files\" needs certFile and keyFile."; }
      { assertion = lib.elem cfg.huntPass.season cfg.huntPass.seasons;
        message = "services.dauntless-nix.huntPass.season must be one of huntPass.seasons."; }
    ];

    systemd.targets.dauntless = {
      description = "dauntless-nix: the whole server (dauntless up / down)";
      wantedBy = lib.optional cfg.autoStart "multi-user.target";
    };

    environment.systemPackages = [ cli ];
    users.groups.dauntless-operators.members = cfg.operators;
    security.polkit.enable = lib.mkDefault true;
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" && subject.isInGroup("dauntless-operators")) {
          var unit = action.lookup("unit"), verb = action.lookup("verb");
          var units = ${builtins.toJSON operatorUnits};
          if ((units.indexOf(unit) >= 0 || unit == "dauntless-collect-logs.service" || /^dauntless-huntpass@[A-Za-z0-9_]+\.service$/.test(unit)) &&
              ["start", "stop", "restart", "try-restart"].indexOf(verb) >= 0) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    # `dauntless season <id>`: validated, written to huntpass.env, then running servers pick it up.
    systemd.services."dauntless-huntpass@" = {
      description = "dauntless-nix: switch the Hunt Pass to %i";
      path = [ pkgs.coreutils pkgs.systemd ];
      scriptArgs = "%i";
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        case "$1" in
          default) rm -f ${huntPassFile} ;;
          ${lib.concatStringsSep "|" cfg.huntPass.seasons})
            install -d -m 0755 ${settingsDir}
            echo "GAMESERVER_HUNTPASS_ID=$1" > ${huntPassFile}.tmp
            chmod 0644 ${huntPassFile}.tmp; mv ${huntPassFile}.tmp ${huntPassFile} ;;
          *) echo "unknown season: $1" >&2; exit 2 ;;
        esac
        systemctl try-restart dauntless-backend.service dauntless-director.service
      '';
    };

    # Game-server, Director and backend logs from the last two days, plus the journal. Root reads the 0750
    # dirs; the archive is group-readable by dauntless-operators only (it holds account names and ids).
    systemd.services.dauntless-collect-logs = {
      description = "dauntless-nix: collect server logs for operators";
      path = [ pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.gzip pkgs.systemd ];
      serviceConfig = { Type = "oneshot"; UMask = "0027"; };
      script = ''
        set -euo pipefail
        install -d -m 0750 -o root -g dauntless-operators ${logArchiveDir}
        work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
        out=dauntless-logs-$(date -u +%Y%m%dT%H%M%SZ)
        mkdir "$work/$out"
        journalctl --no-pager --since -2d -u 'dauntless-*' -u podman-dauntless-mongodb.service \
          > "$work/$out/journal.txt" || true
        cd /
        # Relative paths keep the layout readable: var/lib/dauntless-nix/director/logs/port8780_hunt.log, ...
        find ${lib.removePrefix "/" cfg.stateDir}/director/logs ${lib.removePrefix "/" cfg.stateDir}/director/debug \
             ${lib.removePrefix "/" cfg.stateDir}/director/game/Archon/Binaries/Win64 \
             ${lib.removePrefix "/" cfg.stateDir}/debug ${lib.removePrefix "/" cfg.stateDir}/launcher-logs \
             -maxdepth 4 -type f \( -name '*.log' -o -name '*.txt' -o -name '*.json' \) -mtime -2 \
             2>/dev/null > "$work/files" || true
        xargs -r -d '\n' cp --parents -t "$work/$out" < "$work/files" || true
        tar -C "$work" -czf "${logArchiveDir}/$out.tar.gz.tmp" "$out"
        chgrp dauntless-operators "${logArchiveDir}/$out.tar.gz.tmp"; chmod 0640 "${logArchiveDir}/$out.tar.gz.tmp"
        mv "${logArchiveDir}/$out.tar.gz.tmp" "${logArchiveDir}/$out.tar.gz"
        ls -1t ${logArchiveDir}/dauntless-logs-*.tar.gz | tail -n +6 | xargs -r rm -f --
      '';
    };

    users.users.dauntless = { isSystemUser = true; group = "dauntless"; extraGroups = [ "dauntless-db" ]; };
    users.groups.dauntless = { };
    users.users.dauntless-db = { isSystemUser = true; uid = cfg.mongodb.uid; group = "dauntless-db"; };
    users.groups.dauntless-db.gid = cfg.mongodb.uid;

    systemd.tmpfiles.settings."10-dauntless-nix" = {
      "${cfg.stateDir}".d = { user = "root"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/secrets".d = { user = "dauntless"; group = "dauntless"; mode = "0700"; };
      "${cfg.stateDir}/game-data".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/hunt-data".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/game-data/raw".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/updates".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/launcher-logs".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/backend".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/debug".d = { user = "dauntless"; group = "dauntless"; mode = "0750"; };
      "${cfg.stateDir}/mongodb".d = { user = "dauntless-db"; group = "dauntless-db"; mode = "0700"; };
      "${tlsDir}".d = { user = "root"; group = "nginx"; mode = "0750"; };
      "/run/dauntless-nix".d = { user = "root"; group = "root"; mode = "0755"; };
      "${mongoSockDir}".d = { user = "dauntless-db"; group = "dauntless-db"; mode = "0770"; };
    };

    # ---- one-time secret + state initialisation (idempotent) ----
    systemd.services.dauntless-nix-init = {
      description = "dauntless-nix: generate backend secrets, TLS and seed data (first run only)";
      inherit (inTarget) wantedBy partOf;
      after = [ "systemd-tmpfiles-setup.service" ];
      path = [ pkgs.openssl pkgs.coreutils pkgs.diffutils pkgs.nodejs_22 ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
      script = ''
        set -euo pipefail
        secrets=${cfg.stateDir}/secrets/backend.env
        touch "$secrets"; chown dauntless:dauntless "$secrets"; chmod 0600 "$secrets"
        has() { grep -q "^$1=." "$secrets"; }
        add() { echo "$1=$2" >> "$secrets"; echo "generated $1"; }   # never logs the value

        # Each key is generated once, independently, so new keys reach existing installs without rotating old ones.
        if ! has AUTH_SIGNING_PRIVKEY_B64 || ! has AUTH_SIGNING_PUBKEY_B64; then
          sed -i '/^AUTH_SIGNING_P\(RIV\|UB\)KEY_B64=/d' "$secrets"
          # Same generator upstream's configure-selfhost.ps1 uses (pure node:crypto, RSA-4096).
          keys=$(node ${../../scripts/generate-selfhost-rsa-key.mjs})
          add AUTH_SIGNING_PRIVKEY_B64 "$(printf '%s' "$keys" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).privateKeyB64))')"
          add AUTH_SIGNING_PUBKEY_B64  "$(printf '%s' "$keys" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).publicKeyB64))')"
        fi
        has GAMESERVER_API_KEYS         || add GAMESERVER_API_KEYS "$(openssl rand -hex 32)"
        has API_KEY_HASH_SECRET         || add API_KEY_HASH_SECRET "$(openssl rand -hex 32)"
        has MYSTICPARADOX_METRICS_TOKEN || add MYSTICPARADOX_METRICS_TOKEN "$(openssl rand -hex 32)"

        ${lib.optionalString (cfg.tls.mode == "self-signed") ''
          if [ ! -s ${tlsDir}/privkey.pem ]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
              -subj "/CN=${cfg.publicHost}" -addext "subjectAltName=${if builtins.match "[0-9.]+" cfg.publicHost != null then "IP" else "DNS"}:${cfg.publicHost}" \
              -keyout ${tlsDir}/privkey.pem -out ${tlsDir}/fullchain.pem
            chown root:nginx ${tlsDir}/privkey.pem ${tlsDir}/fullchain.pem
            chmod 0640 ${tlsDir}/privkey.pem; chmod 0644 ${tlsDir}/fullchain.pem
            echo "generated self-signed certificate for ${cfg.publicHost}"
          fi
        ''}

        ${lib.optionalString cfg.syntheticGameData ''
          for f in ${cfg.package}/lib/backend/game-data/*.example.json; do
            dest=${cfg.stateDir}/game-data/$(basename "$f" .example.json).json
            if [ ! -e "$dest" ]; then install -o dauntless -g dauntless -m 0640 "$f" "$dest"; fi
          done
          for f in ${cfg.package}/lib/hunt-data-examples/*.example.json; do
            dest=${cfg.stateDir}/hunt-data/$(basename "$f" .example.json).json
            if [ ! -e "$dest" ]; then install -o dauntless -g dauntless -m 0640 "$f" "$dest"; fi
          done
        ''}

        ${lib.optionalString (cfg.gameDataDir != null) ''
          src=${lib.escapeShellArg cfg.gameDataDir}
          for sub in "" hunt-data/; do
            dir=game-data; [ -n "$sub" ] && dir=hunt-data
            for f in "$src/$sub"*.json; do
              [ -e "$f" ] || continue
              dest=${cfg.stateDir}/$dir/$(basename "$f")
              if ! cmp -s "$f" "$dest"; then install -o dauntless -g dauntless -m 0640 "$f" "$dest"; echo "installed $dir/$(basename "$f")"; fi
            done
          done
        ''}
      '';
    };

    # ---- runtime feed: sign + publish the Nix-built runtime for clients (upstream publish-runtime-update.mjs) ----
    systemd.services.dauntless-runtime-publish = mkIf (cfg.runtime != null) {
      description = "dauntless-nix: sign and publish the client runtime to the update feed";
      inherit (inTarget) wantedBy partOf;
      before = [ "dauntless-backend.service" ];
      after = [ "dauntless-nix-init.service" ];
      requires = [ "dauntless-nix-init.service" ];
      path = [ pkgs.nodejs_22 pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; User = "dauntless"; Group = "dauntless"; UMask = "0077"; };
      script = ''
        set -euo pipefail
        key=${cfg.stateDir}/secrets/runtime-signing
        if [ ! -s "$key.private.pem" ]; then
          node ${../../ParadoxLauncher/scripts/generate-runtime-key.mjs} "$key"
        fi
        # Clients pin this (services.dauntless-nix-client.runtimePublicKey). Not secret.
        install -m 0644 "$key.public.raw.b64" ${cfg.stateDir}/updates/runtime-public-key.b64
        echo "runtime signing public key: $(cat "$key.public.raw.b64")"
        sha=$(sha256sum ${cfg.runtime}/MysticParadox.dll | cut -c1-12)
        node ${../../ParadoxLauncher/scripts/publish-runtime-update.mjs} \
          --dll ${cfg.runtime}/MysticParadox.dll --extra ${cfg.runtime}/winmm.dll \
          --target client --version "1.0.0-nix.$sha" --changelist 647472 --channel stable \
          --output ${cfg.stateDir}/updates --base-url https://${cfg.publicHost} --key "$key.private.pem"
      '';
    };

    # ---- MongoDB: no network, unix socket only, single-node replica set ----
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.dauntless-mongodb = {
      image = "mongo:7.0.48-jammy";
      imageFile = mongoImage;
      user = "${toString cfg.mongodb.uid}:${toString cfg.mongodb.uid}";
      volumes = [ "${cfg.stateDir}/mongodb:/data/db" "${mongoSockDir}:${mongoSockDir}" ];
      cmd = [
        "mongod" "--replSet" "rs0" "--bind_ip" "127.0.0.1" "--port" "27017"
        "--unixSocketPrefix" mongoSockDir "--filePermissions" "0770"
      ];
      extraOptions = [ "--network=none" ];
      autoStart = false;   # dauntless.target starts it
    };
    systemd.services.podman-dauntless-mongodb = inTarget;

    systemd.services.dauntless-mongodb-rs-init = {
      description = "dauntless-nix: initiate the single-node MongoDB replica set (idempotent)";
      after = [ "podman-dauntless-mongodb.service" ];
      requires = [ "podman-dauntless-mongodb.service" ];
      inherit (inTarget) wantedBy partOf;
      path = [ config.virtualisation.podman.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        for i in $(seq 1 60); do
          if podman exec dauntless-mongodb mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; then break; fi
          sleep 1
        done
        podman exec dauntless-mongodb mongosh --quiet --eval '
          try { rs.status().ok } catch (e) {
            rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "127.0.0.1:27017" }] });
          }
          for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
          if (!db.hello().isWritablePrimary) quit(1);
        '
      '';
    };

    # ---- backups: a quiet dump at every start (before the backend) and stop (after it) ----
    systemd.services.dauntless-mongodb-backup = mkIf cfg.backup.enable {
      description = "dauntless-nix: MongoDB backup at start and stop";
      after = [ "dauntless-mongodb-rs-init.service" ];
      requires = [ "dauntless-mongodb-rs-init.service" ];
      before = [ "dauntless-backend.service" ];
      inherit (inTarget) wantedBy partOf;
      path = [ config.virtualisation.podman.package pkgs.coreutils pkgs.findutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${backupScript} start";
        ExecStop = "${backupScript} stop";
        TimeoutSec = 600;
      };
    };

    # ---- backend ----
    systemd.services.dauntless-backend = {
      description = "dauntless-nix backend (ParadoxBackend)";
      inherit (inTarget) wantedBy partOf;
      after = [ "network.target" "dauntless-nix-init.service" "dauntless-mongodb-rs-init.service" "dauntless-mongodb-backup.service" ];
      requires = [ "dauntless-nix-init.service" "dauntless-mongodb-rs-init.service" ];
      environment = systemdEnv;
      serviceConfig = {
        User = "dauntless";
        Group = "dauntless";
        SupplementaryGroups = [ "dauntless-db" ];
        # logger.ts writes ../debug/metagame relative to cwd, so cwd is ${stateDir}/backend.
        WorkingDirectory = "${cfg.stateDir}/backend";
        # The run-time Hunt Pass override (`dauntless season`) wins over the configured default.
        EnvironmentFile = [ "${cfg.stateDir}/secrets/backend.env" "-${huntPassFile}" ] ++ cfg.backend.extraEnvironmentFiles;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        # hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      } // lib.optionalAttrs (cfg.allowedNetworks != null) {
        IPAddressAllow = [ "localhost" ] ++ cfg.allowedNetworks;
        IPAddressDeny = "any";
      };
    };

    # ---- nginx: pong on 80, TLS + proxy on 443 ----
    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      appendHttpConfig = ''
        map $http_upgrade $dauntless_connection_upgrade { default upgrade; ''' close; }
      '';
      virtualHosts."${cfg.publicHost}-pong" = {
        serverName = cfg.publicHost;
        default = true;
        listen = [ { addr = "0.0.0.0"; port = 80; } { addr = "[::]"; port = 80; } ];
        # The game measures regions with a plain GET on port 80 and expects this exact body. Never redirect it.
        locations."/".extraConfig = ''
          default_type text/html;
          return 200 "<!DOCTYPE html><html><body>pong</body></html>";
        '';
        # ACME http-01 needs this path on port 80 too.
        locations."/.well-known/acme-challenge/" = mkIf (cfg.tls.mode == "acme") {
          root = "/var/lib/acme/acme-challenge";
        };
      };
      virtualHosts."${cfg.publicHost}-plain" = mkIf (cfg.plainHttpPort != null) {
        serverName = cfg.publicHost;
        listen = [ { addr = "0.0.0.0"; port = cfg.plainHttpPort; } { addr = "[::]"; port = cfg.plainHttpPort; } ];
        extraConfig = "client_max_body_size 64m;";
        locations."/" = backendLocation;
      };
      virtualHosts."${cfg.publicHost}" = {
        listen = [ { addr = "0.0.0.0"; port = 443; ssl = true; } { addr = "[::]"; port = 443; ssl = true; } ];
        onlySSL = true;
        http2 = true;
        useACMEHost = mkIf (cfg.tls.mode == "acme") cfg.publicHost;
        sslCertificate = mkIf (cfg.tls.mode != "acme") certFile;
        sslCertificateKey = mkIf (cfg.tls.mode != "acme") keyFile;
        extraConfig = "client_max_body_size 64m;";
        locations."/" = backendLocation;
      };
    };
    systemd.services.nginx = {
      after = [ "dauntless-nix-init.service" ];
      wants = [ "dauntless-nix-init.service" ];
    };
    security.acme.certs = mkIf (cfg.tls.mode == "acme") {
      "${cfg.publicHost}" = { webroot = "/var/lib/acme/acme-challenge"; group = "nginx"; };
    };

    networking.firewall = mkIf cfg.openFirewall (
      if cfg.firewall.interfaces == [ ] then { allowedTCPPorts = [ 80 443 ] ++ lib.optional (cfg.plainHttpPort != null) cfg.plainHttpPort; }
      else { interfaces = lib.genAttrs cfg.firewall.interfaces (_: { allowedTCPPorts = [ 80 443 ] ++ lib.optional (cfg.plainHttpPort != null) cfg.plainHttpPort; }); });
  };
}
