# NixOS module: a dedicated WireGuard interface for remote players (DECISIONS D12).
#
# Remote players get exactly the game: HTTPS/pong (80, 443) and the game UDP range on the server's tunnel address.
# A guard rule placed before the NixOS firewall's own accepts drops everything else arriving on this interface,
# so ports the host opens globally or on other interfaces are NOT reachable through the tunnel.
# The only public exposure is listenPort/udp (forward it on the router; that step is the operator's).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dauntless-nix;
  wcfg = cfg.wireguard;
  inherit (lib) mkOption mkEnableOption mkIf types;
  iface = wcfg.interface;
  udpRange = "${toString cfg.director.portRange.from}:${toString cfg.director.portRange.to}";
  nftUdpRange = "${toString cfg.director.portRange.from}-${toString cfg.director.portRange.to}";
in
{
  options.services.dauntless-nix.wireguard = {
    enable = mkEnableOption "a WireGuard interface for remote players";
    interface = mkOption { type = types.str; default = "wg-dauntless"; };
    address = mkOption {
      type = types.str;
      default = "10.77.0.1/24";
      description = "Server address on the tunnel (CIDR). Use its IP as publicHost / director.publicAddress.";
    };
    listenPort = mkOption { type = types.port; default = 51821; };
    privateKeyFile = mkOption {
      type = types.str;
      default = "${cfg.stateDir}/secrets/wireguard.key";
      defaultText = lib.literalExpression ''"''${stateDir}/secrets/wireguard.key"'';
      description = "Generated on first start if missing. Print the public key with: wg pubkey < <file>.";
    };
    peers = mkOption {
      default = [ ];
      description = "Remote players.";
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { type = types.str; description = "Label (comment only)."; };
          publicKey = mkOption { type = types.str; };
          address = mkOption { type = types.str; example = "10.77.0.2/32"; description = "The peer's tunnel address."; };
        };
      });
    };
  };

  config = mkIf (cfg.enable && wcfg.enable) {
    networking.wireguard.interfaces.${iface} = {
      ips = [ wcfg.address ];
      inherit (wcfg) listenPort privateKeyFile;
      generatePrivateKeyFile = true;
      peers = map (p: { inherit (p) publicKey; allowedIPs = [ p.address ]; }) wcfg.peers;
    };

    networking.firewall = {
      allowedUDPPorts = [ wcfg.listenPort ];
      interfaces.${iface} = {
        allowedTCPPorts = [ 80 443 ];
        allowedUDPPortRanges = lib.optional cfg.director.enable { inherit (cfg.director.portRange) from to; };
      };
    }
    # Guard: on the tunnel, anything not listed is refused even if the host opens it elsewhere, and nothing from the
    # tunnel is ever forwarded (hosts running containers usually have ip_forward on): peers cannot reach the LAN.
    // (if config.networking.nftables.enable then {
      extraInputRules = ''
        iifname "${iface}" tcp dport { 80, 443 } accept
        ${lib.optionalString cfg.director.enable ''iifname "${iface}" udp dport ${nftUdpRange} accept''}
        iifname "${iface}" drop
      '';
    } else {
      extraCommands = ''
        for ipt in iptables ip6tables; do
          $ipt -N dauntless-wg-guard 2>/dev/null || $ipt -F dauntless-wg-guard
          $ipt -A dauntless-wg-guard -p tcp -m multiport --dports 80,443 -j RETURN
          ${lib.optionalString cfg.director.enable ''$ipt -A dauntless-wg-guard -p udp --dport ${udpRange} -j RETURN''}
          $ipt -A dauntless-wg-guard -j nixos-fw-refuse
          $ipt -D nixos-fw -i ${iface} -j dauntless-wg-guard 2>/dev/null || true
          $ipt -I nixos-fw 1 -i ${iface} -j dauntless-wg-guard
          $ipt -D FORWARD -i ${iface} -j DROP 2>/dev/null || true
          $ipt -I FORWARD 1 -i ${iface} -j DROP
        done
      '';
      extraStopCommands = ''
        for ipt in iptables ip6tables; do
          $ipt -D nixos-fw -i ${iface} -j dauntless-wg-guard 2>/dev/null || true
          $ipt -D FORWARD -i ${iface} -j DROP 2>/dev/null || true
          $ipt -F dauntless-wg-guard 2>/dev/null || true
          $ipt -X dauntless-wg-guard 2>/dev/null || true
        done
      '';
    });

    networking.nftables.tables = mkIf config.networking.nftables.enable {
      dauntless-wg-forward = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority -10; policy accept;
            iifname "${iface}" drop
          }
        '';
      };
    };

    environment.systemPackages = [ pkgs.wireguard-tools ];
  };
}
