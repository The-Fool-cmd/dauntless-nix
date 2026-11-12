# Acceptance in VMs: run with `nix flake check` or `nix build .#checks.x86_64-linux.server -L`.
#   vlan 1 = "internet", vlan 2 = home LAN
#   server: backend + MongoDB + nginx + Director (stub game server) + WireGuard; firewall scoped to its LAN (eth2);
#           ip_forward on, as on a host running containers
#   lan:    a LAN player, also running an unrelated LAN service
#   remote: a remote player on the internet side, reaching the server only through WireGuard
{ self, pkgs }:
let
  wgServerIp = "10.77.0.1";
  host = wgServerIp;   # no domain (D12): players use the tunnel address everywhere
  # Throwaway key pairs, generated at build time (no private keys in the repo).
  wgKeys = pkgs.runCommand "dauntless-test-wg-keys" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    mkdir $out
    for n in server remote; do wg genkey > $out/$n.key; wg pubkey < $out/$n.key | tr -d '\n' > $out/$n.pub; done
  '';
  pub = n: builtins.readFile "${wgKeys}/${n}.pub";
  # Stands in for Dauntless under Wine: prints the runtime's ready marker for the port it is given, then idles.
  stubGameServer = pkgs.writeShellScript "stub-gameserver" ''
    echo "stub game server: map=$3 port=$2"
    echo "MYSTICPARADOX_GAMESERVER_READY launchId=$MYSTICPARADOX_GAMESERVER_LAUNCH_ID port=$2"
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
  ipOn = vlan: node: (builtins.head node.networking.interfaces."eth${toString vlan}".ipv4.addresses).address;
  serverInetIp = nodes: ipOn 1 nodes.server;
  serverLanIp = nodes: ipOn 2 nodes.server;
in pkgs.testers.runNixOSTest {
  name = "dauntless-nix-server";

  nodes.server = { ... }: {
    imports = [ self.nixosModules.server ];
    virtualisation.vlans = [ 1 2 ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    services.dauntless-nix = {
      enable = true;
      publicHost = host;
      syntheticGameData = true;
      firewall.interfaces = [ "eth2" ];
      director = {
        enable = true;
        port = 3011;                      # 3001 is taken on the real server (Uptime Kuma)
        publicAddress = wgServerIp;
        gameserverBinary = "${stubGameServer}";
      };
      wireguard = {
        enable = true;
        privateKeyFile = "${wgKeys}/server.key";
        peers = [ { name = "remote"; publicKey = pub "remote"; address = "10.77.0.2/32"; } ];
      };
    };
    # Something else the host serves on its LAN (like Open WebUI/Kuma on the server): must stay off the tunnel.
    networking.firewall.interfaces.eth2.allowedTCPPorts = [ 8080 ];
    systemd.services.other-lan-service = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
    };
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 8192;
  };

  nodes.lan = { nodes, pkgs, ... }: {
    virtualisation.vlans = [ 2 ];
    # LAN players reach the tunnel address through the server's LAN address (a static route in the client module).
    # /24 (not just the server /32) so a reply path to tunnel peers exists: only the forward guard can stop them.
    networking.interfaces.eth1.ipv4.routes = [ { address = "10.77.0.0"; prefixLength = 24; via = serverLanIp nodes; } ];
    # An unrelated service elsewhere on the home LAN: must not be reachable from the tunnel.
    networking.firewall.allowedTCPPorts = [ 9999 ];
    systemd.services.lan-only = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 9999";
    };
    environment.systemPackages = [ pkgs.curl pkgs.netcat-openbsd ];
  };

  nodes.remote = { nodes, pkgs, ... }: {
    virtualisation.vlans = [ 1 ];
    networking.wireguard.interfaces.wg0 = {
      ips = [ "10.77.0.2/32" ];
      privateKeyFile = "${wgKeys}/remote.key";
      peers = [ {
        publicKey = pub "server";
        # A hostile peer also routes the home LAN into the tunnel; the server must not forward it.
        allowedIPs = [ "${wgServerIp}/32" "192.168.2.0/24" ];
        endpoint = "${serverInetIp nodes}:51821";
        persistentKeepalive = 5;
      } ];
    };
    environment.systemPackages = [ pkgs.curl pkgs.netcat-openbsd ];
  };

  testScript = { nodes, ... }: let serverLan = serverLanIp nodes; lanHost = ipOn 1 nodes.lan; in ''
    import json
    start_all()

    server.wait_for_unit("dauntless-mongodb-rs-init.service", timeout=300)
    server.wait_for_unit("dauntless-backend.service")
    server.wait_until_succeeds("curl -sf http://127.0.0.1:3000/", timeout=120)
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("dauntless-director.service")

    with subtest("Director brings up Ramsgate and the Training Grounds via the game-server binary"):
        server.wait_until_succeeds("journalctl -u dauntless-director -b | grep -q 'ready on ${wgServerIp}:8790'", timeout=180)
        server.wait_until_succeeds("journalctl -u dauntless-director -b | grep -q 'ready on ${wgServerIp}:8789'", timeout=180)

    with subtest("Director API is loopback-only"):
        server.succeed("ss -ltnH 'sport = :3011' | grep -q '127.0.0.1:3011'")
        server.fail("ss -ltnH 'sport = :3011' | grep -v '127.0.0.1:3011' | grep -q .")

    with subtest("LAN player: pong, HTTPS, launcher status via the tunnel address"):
        body = lan.succeed("curl -s http://${host}/x")
        assert body == "<!DOCTYPE html><html><body>pong</body></html>", repr(body)
        status = json.loads(lan.succeed("curl -skf https://${host}/launcher/v1/status"))
        assert str(status.get("supportedBuildChangelist")) == "647472", status

    with subtest("LAN: only 80/443 (+ the host's own LAN services) reachable; internals closed"):
        for port in (3000, 3011, 27017):
            lan.fail(f"nc -z -w 3 ${serverLan} {port}")
        lan.succeed("nc -z -w 3 ${serverLan} 8080")

    with subtest("Remote player over WireGuard: game ports yes"):
        remote.wait_until_succeeds("curl -skf https://${host}/launcher/v1/status", timeout=60)
        body = remote.succeed("curl -s http://${host}/x")
        assert "pong" in body, body

    with subtest("Remote player over WireGuard: nothing else, even ports open on the LAN"):
        for port in (8080, 22, 3000, 3011, 27017):
            remote.fail(f"nc -z -w 3 ${host} {port}")

    with subtest("Remote player: no forwarding into the home LAN, no other ports on the server's LAN address"):
        lan.succeed("nc -z -w 3 ${serverLan} 8080")   # the LAN service exists
        remote.fail("nc -z -w 3 ${lanHost} 9999")      # another LAN host via the server
        remote.fail("nc -z -w 3 ${serverLan} 8080")    # the server's own LAN-only service via its LAN address

    with subtest("Remote player cannot reach the server at all outside the tunnel"):
        remote.fail("nc -z -w 3 ${serverInetIp nodes} 443")

    with subtest("Stopping the Director stops its game servers"):
        server.succeed("systemctl stop dauntless-director.service")
        server.fail("pgrep -f stub-gameserver")

    with subtest("no startup errors in the backend log"):
        server.fail("journalctl -u dauntless-backend.service -b --no-pager | grep -E 'ERROR|Fatal'")

    with subtest("secrets are private"):
        server.succeed("test \"$(stat -c %a:%U /var/lib/dauntless-nix/secrets/backend.env)\" = 600:dauntless")
        server.succeed("test \"$(stat -c %a:%U /var/lib/dauntless-nix/director/director.env)\" = 600:dauntless-director")
  '';
}
