# NixOS module for a player's PC: the launcher, Legendary, the pinned Proton runner, the launcher config, and the
# network path to the server (a LAN route, or a WireGuard tunnel for remote players). DECISIONS D12, D21.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dauntless-nix-client;
  inherit (lib) mkOption mkEnableOption mkIf types;
  launcherConfig = {
    server = cfg.server;
    gameBackendUrl = cfg.gameBackendUrl;
    runtimePublicKey = cfg.runtimePublicKey;
    inherit (cfg) gameDir instanceDir protonPrefix extraGameArgs;
    protonRun = lib.getExe cfg.protonRunPackage;
  } // lib.optionalAttrs (cfg.serverCertificate != null) {
    caCertFile = "/etc/dauntless-nix/server.pem";
  };
in
{
  options.services.dauntless-nix-client = {
    enable = mkEnableOption "the dauntless-nix player setup";
    launcherPackage = mkOption { type = types.package; };
    protonRunPackage = mkOption { type = types.package; };
    legendaryPackage = mkOption { type = types.package; };

    serverAddress = mkOption { type = types.str; example = "10.77.0.1"; description = "The server's tunnel address (one address for every player)."; };
    server = mkOption {
      type = types.str;
      default = "https://${cfg.serverAddress}";
      defaultText = lib.literalExpression ''"https://''${serverAddress}"'';
      description = "Launcher API base.";
    };
    gameBackendUrl = mkOption {
      type = types.str;
      default = cfg.server;
      defaultText = lib.literalExpression "server";
      description = "MYSTICPARADOX_BACKEND_URL handed to the game.";
    };
    serverCertificate = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "PEM of the server's TLS certificate, pinned by the launcher (self-signed setups). Public, not secret.";
    };
    runtimePublicKey = mkOption {
      type = types.str;
      description = "Base64 raw Ed25519 key of the server's runtime feed (<stateDir>/updates/runtime-public-key.b64 on the server).";
    };
    gameDir = mkOption { type = types.str; default = "~/Games/dauntless-1.14.7/Dauntless"; description = "Pristine 1.14.7 install (never modified)."; };
    instanceDir = mkOption { type = types.str; default = "~/Games/dauntless-1.14.7/instance/Dauntless"; };
    protonPrefix = mkOption { type = types.str; default = "~/Games/dauntless-1.14.7/prefixes/client"; };
    extraGameArgs = mkOption { type = types.listOf types.str; default = [ ]; example = [ "-windowed" ]; };

    lanRoute = {
      enable = mkEnableOption "a route to the server's tunnel address via its LAN address (players on the server's LAN)";
      via = mkOption { type = types.str; example = "192.168.50.10"; description = "The server's LAN address."; };
    };

    wireguard = {
      enable = mkEnableOption "the WireGuard tunnel to the server (remote players)";
      interface = mkOption { type = types.str; default = "wg-dauntless"; };
      address = mkOption { type = types.str; example = "10.77.0.2/32"; };
      privateKeyFile = mkOption {
        type = types.str;
        default = "/var/lib/dauntless-nix-client/wireguard.key";
        description = "Generated on first start if missing; send `wg pubkey < file` to the server operator.";
      };
      serverPublicKey = mkOption { type = types.str; };
      endpoint = mkOption { type = types.str; example = "203.0.113.7:51821"; description = "The server's public address:port."; };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.launcherPackage cfg.protonRunPackage cfg.legendaryPackage ];
    environment.etc."dauntless-nix/config.json".text = builtins.toJSON launcherConfig;
    environment.etc."dauntless-nix/server.pem" = mkIf (cfg.serverCertificate != null) { text = cfg.serverCertificate; };

    systemd.services.dauntless-nix-lan-route = mkIf cfg.lanRoute.enable {
      description = "dauntless-nix: route to the game server's tunnel address via its LAN address";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 10; };
      script = "ip route replace ${cfg.serverAddress}/32 via ${cfg.lanRoute.via}";
      preStop = "ip route del ${cfg.serverAddress}/32 via ${cfg.lanRoute.via} || true";
    };

    networking.wireguard.interfaces.${cfg.wireguard.interface} = mkIf cfg.wireguard.enable {
      ips = [ cfg.wireguard.address ];
      inherit (cfg.wireguard) privateKeyFile;
      generatePrivateKeyFile = true;
      peers = [ {
        publicKey = cfg.wireguard.serverPublicKey;
        allowedIPs = [ "${cfg.serverAddress}/32" ];   # only the server, nothing else of its network
        inherit (cfg.wireguard) endpoint;
        persistentKeepalive = 25;
      } ];
    };
  };
}
