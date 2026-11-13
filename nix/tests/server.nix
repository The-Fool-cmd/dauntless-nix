# Acceptance in VMs: run with `nix flake check` or `nix build .#checks.x86_64-linux.server -L`.
#   vlan 1 = "internet", vlan 2 = home LAN
#   server: backend + MongoDB + nginx + Director (stub game server) + WireGuard; firewall scoped to its LAN (eth2);
#           ip_forward on, as on a host running containers
#   lan:    a LAN player, also running an unrelated LAN service
#   remote: a remote player on the internet side, reaching the server only through WireGuard
{ self, pkgs }:
let lib = pkgs.lib; in
let
  wgServerIp = "10.77.0.1";
  host = wgServerIp;   # no domain (D12): players use the tunnel address everywhere
  # Throwaway key pairs, generated at build time (no private keys in the repo).
  wgKeys = pkgs.runCommand "dauntless-test-wg-keys" { nativeBuildInputs = [ pkgs.wireguard-tools ]; } ''
    mkdir $out
    for n in server remote; do wg genkey > $out/$n.key; wg pubkey < $out/$n.key | tr -d '\n' > $out/$n.pub; done
  '';
  pub = n: builtins.readFile "${wgKeys}/${n}.pub";
  # A stand-in game install and runtime: the real ones are game-derived and never part of a test.
  fakeGame = pkgs.runCommand "fake-dauntless" { } ''
    mkdir -p $out/Archon/Binaries/Win64
    echo "not Dauntless: dauntless-nix test fixture" > $out/Archon/Binaries/Win64/Dauntless-Win64-Shipping.exe
    echo "dauntless_rel-1.14.7_Shipping_test_647472" > $out/Version.txt
  '';
  fakeExeSha256 = builtins.hashFile "sha256" "${fakeGame}/Archon/Binaries/Win64/Dauntless-Win64-Shipping.exe";
  fakeRuntime = pkgs.runCommand "fake-runtime" { } ''
    mkdir $out; echo "fake MysticParadox.dll" > $out/MysticParadox.dll; echo "fake winmm.dll" > $out/winmm.dll
  '';
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
      autoStart = false;                  # like the server: only `dauntless up` starts it
      operators = [ "op" ];
      plainHttpPort = 3080;
      firewall.interfaces = [ "eth2" ];
      runtime = fakeRuntime;
      approvedExecutableSha256 = fakeExeSha256;
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
    users.users.op = { isNormalUser = true; };
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
    imports = [ self.nixosModules.client ];
    virtualisation.vlans = [ 2 ];
    services.dauntless-nix-client = {
      enable = true;
      serverAddress = wgServerIp;
      runtimePublicKey = "unused-in-this-node";
      lanRoute = { enable = true; via = serverLanIp nodes; };
    };
    # The test also needs a return path to tunnel peers on this LAN host (for the forward-guard check).
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
    imports = [ self.nixosModules.client ];
    virtualisation.vlans = [ 1 ];
    services.dauntless-nix-client = {
      enable = true;
      serverAddress = wgServerIp;
      runtimePublicKey = "set-at-test-time";
      gameDir = "${fakeGame}";
      wireguard = {
        enable = true;
        address = "10.77.0.2/32";
        privateKeyFile = "${wgKeys}/remote.key";
        serverPublicKey = pub "server";
        endpoint = "${serverInetIp nodes}:51821";
      };
    };
    # A hostile variant of the peer also routes the home LAN into the tunnel; the server must not forward it.
    networking.wireguard.interfaces.wg-dauntless.peers = lib.mkForce [ {
      publicKey = pub "server";
      allowedIPs = [ "${wgServerIp}/32" "192.168.2.0/24" ];
      endpoint = "${serverInetIp nodes}:51821";
      persistentKeepalive = 5;
    } ];
    users.users.alice = { isNormalUser = true; };
    environment.systemPackages = [ pkgs.curl pkgs.netcat-openbsd pkgs.jq ];
  };

  testScript = { nodes, ... }: let serverLan = serverLanIp nodes; lanHost = ipOn 1 nodes.lan; in ''
    import json
    start_all()

    with subtest("Nothing starts at boot; an operator brings it up without sudo"):
        server.wait_for_unit("multi-user.target")
        server.fail("systemctl is-active dauntless-backend.service podman-dauntless-mongodb.service")
        server.fail("su - op -c 'systemctl stop nginx.service'")          # polkit grants dauntless units only
        server.succeed("su - op -c 'dauntless up' >&2", timeout=600)

    server.wait_for_unit("dauntless-mongodb-rs-init.service", timeout=300)
    server.wait_for_unit("dauntless-backend.service")
    server.wait_until_succeeds("curl -sf http://127.0.0.1:3000/", timeout=120)
    server.wait_for_unit("nginx.service")
    server.wait_for_unit("dauntless-director.service")

    with subtest("Director brings up Ramsgate and the Training Grounds via the game-server binary"):
        server.wait_until_succeeds("journalctl -u dauntless-director -b | grep -q 'ready on ${wgServerIp}:8790'", timeout=180)
        server.wait_until_succeeds("journalctl -u dauntless-director -b | grep -q 'ready on ${wgServerIp}:8789'", timeout=180)
        # Bound to the public address, so LAN players routed to it get replies from it (not from the LAN address).
        server.succeed("pgrep -af stub-gameserver | grep -q -- '-MULTIHOME=${wgServerIp}'")

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

    with subtest("Plain-HTTP backend port on the LAN and the tunnel"):
        for node in (lan, remote):
            status = json.loads(node.succeed("curl -sf http://${host}:3080/launcher/v1/status"))
            assert str(status.get("supportedBuildChangelist")) == "647472", status

    with subtest("Operator switches the Hunt Pass season at run time"):
        def assert_season(want):
            # Read the running backend's environment (just after a restart the new process may not have exec'd yet).
            server.wait_until_succeeds("tr '\\0' '\\n' < /proc/$(systemctl show -P MainPID dauntless-backend.service)/environ"
                                       f" | grep -qx GAMESERVER_HUNTPASS_ID={want}", timeout=60)
            # Ready before the next switch: a restart during startup aborts it (a logged "Fatal startup error").
            server.wait_until_succeeds("curl -s -o /dev/null http://127.0.0.1:3000/", timeout=120)
        assert_season("season43")
        server.fail("su - op -c 'dauntless season season99'")
        server.succeed("su - op -c 'dauntless season season44' >&2")
        assert_season("season44")
        assert "season44" in server.succeed("su - op -c 'dauntless status'")
        server.succeed("su - op -c 'dauntless season default' >&2")
        assert_season("season43")
        server.wait_until_succeeds("curl -sf http://127.0.0.1:3000/", timeout=120)
        server.wait_for_unit("dauntless-director.service")

    with subtest("Remote player over WireGuard: nothing else, even ports open on the LAN"):
        for port in (8080, 22, 3000, 3011, 27017):
            remote.fail(f"nc -z -w 3 ${host} {port}")

    with subtest("Remote player: no forwarding into the home LAN, no other ports on the server's LAN address"):
        lan.succeed("nc -z -w 3 ${serverLan} 8080")   # the LAN service exists
        remote.fail("nc -z -w 3 ${lanHost} 9999")      # another LAN host via the server
        remote.fail("nc -z -w 3 ${serverLan} 8080")    # the server's own LAN-only service via its LAN address

    with subtest("Remote player cannot reach the server at all outside the tunnel"):
        remote.fail("nc -z -w 3 ${serverInetIp nodes} 443")

    with subtest("Login-screen status line is ours, never the official Mystic Paradox text"):
        st = json.loads(remote.succeed("curl -skf https://${host}/dauntless-status"))
        assert st["en"] == "Private server (dauntless-nix)", st

    with subtest("Server signed and published the runtime feed"):
        server.wait_for_unit("dauntless-runtime-publish.service")
        key = server.succeed("cat /var/lib/dauntless-nix/updates/runtime-public-key.b64").strip()
        cert = server.succeed("cat /var/lib/dauntless-nix-tls/fullchain.pem")
        # Every boot re-runs the publish with the same bytes: it must stay a no-op, not fail.
        server.succeed("systemctl restart dauntless-runtime-publish.service")
        server.succeed("systemctl restart dauntless-runtime-publish.service")
        manifest = json.loads(remote.succeed("curl -skf https://${host}/launcher/v1/runtime/stable/windows-x86_64"))
        assert manifest["targetChangelist"] == 647472 and {e["name"] for e in manifest["extraFiles"]} == {"winmm.dll"}, manifest

    with subtest("Launcher on the remote player: register, login, signed runtime sync, game session"):
        remote.succeed("cat > /tmp/server.pem <<'EOF'\n" + cert + "EOF\n")
        cfg = json.loads(remote.succeed("cat /etc/dauntless-nix/config.json"))
        cfg.update({"runtimePublicKey": key, "caCertFile": "/tmp/server.pem", "approvedExeSha256": "${fakeExeSha256}",
                    "instanceDir": "/home/alice/game/instance", "protonPrefix": "/home/alice/game/prefix"})
        remote.succeed("cat > /tmp/launcher.json <<'EOF'\n" + json.dumps(cfg) + "\nEOF\n")
        run = "sudo -u alice env DAUNTLESS_NIX_CONFIG=/tmp/launcher.json DAUNTLESS_NIX_PASSWORD=correct-horse-battery-9 dauntless-nix-launcher"
        print(remote.succeed(f"{run} status"))
        print(remote.succeed(f"{run} register --email alice@example.test --name AliceSlayer"))
        print(remote.succeed(f"{run} login --email alice@example.test"))
        remote.succeed("test \"$(stat -c %a /home/alice/.local/state/dauntless-nix/session.json)\" = 600")
        print(remote.succeed(f"{run} sync"))
        remote.succeed("cmp /home/alice/game/instance/Archon/Binaries/Win64/MysticParadox.dll ${fakeRuntime}/MysticParadox.dll")
        remote.succeed("cmp /home/alice/game/instance/Archon/Binaries/Win64/winmm.dll ${fakeRuntime}/winmm.dll")
        remote.succeed("test -e /home/alice/game/instance/Archon/Binaries/Win64/DISABLE_LOGIN_BRANDING.flag")
        out = json.loads(remote.succeed(f"{run} play --dry-run").strip().splitlines()[-1])
        print(out)
        assert out["exchangeCodeIssued"] and out["backendUrl"] == "https://${host}", out
        assert "-AUTH_TYPE=exchangecode" in out["args"] and "-NoEAC" in out["args"], out

    with subtest("Launcher refuses a runtime whose signature does not verify"):
        bad = dict(cfg); bad["runtimePublicKey"] = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
        bad["instanceDir"] = "/home/alice/game/instance2"
        remote.succeed("cat > /tmp/bad.json <<'EOF'\n" + json.dumps(bad) + "\nEOF\n")
        err = remote.fail("sudo -u alice env DAUNTLESS_NIX_CONFIG=/tmp/bad.json dauntless-nix-launcher sync 2>&1")
        assert "signature does not verify" in err, err

    with subtest("LAN player reaches the tunnel address through the client module's route"):
        lan.wait_for_unit("dauntless-nix-lan-route.service")
        lan.succeed("ip route get ${wgServerIp} | grep -q 'via ${serverLanIp nodes}'")

    with subtest("Stopping the Director stops its game servers"):
        server.succeed("systemctl stop dauntless-director.service")
        server.fail("pgrep -f stub-gameserver")

    with subtest("dauntless down stops everything"):
        server.succeed("su - op -c 'dauntless down' >&2")
        server.fail("systemctl is-active dauntless-backend.service dauntless-director.service podman-dauntless-mongodb.service")

    with subtest("no startup errors in the backend log"):
        server.fail("journalctl -u dauntless-backend.service -b --no-pager | grep -E 'ERROR|Fatal'")

    with subtest("secrets are private"):
        server.succeed("test \"$(stat -c %a:%U /var/lib/dauntless-nix/secrets/backend.env)\" = 600:dauntless")
        server.succeed("test \"$(stat -c %a:%U /var/lib/dauntless-nix/director/director.env)\" = 600:dauntless-director")
  '';
}
