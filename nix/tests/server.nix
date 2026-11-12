# Phase 1 acceptance in a VM pair: run with `nix flake check` or `nix build .#checks.x86_64-linux.server -L`.
{ self, pkgs }:
let host = "dauntless.test";
in pkgs.testers.runNixOSTest {
  name = "dauntless-nix-server";

  nodes.server = { ... }: {
    imports = [ self.nixosModules.server ];
    services.dauntless-nix = { enable = true; publicHost = host; syntheticGameData = true; };
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 8192;
  };

  nodes.client = { nodes, pkgs, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [ host ];
    environment.systemPackages = [ pkgs.curl pkgs.netcat-openbsd pkgs.jq ];
  };

  testScript = ''
    import json
    start_all()

    server.wait_for_unit("dauntless-mongodb-rs-init.service", timeout=300)
    server.wait_for_unit("dauntless-backend.service")
    server.wait_until_succeeds("curl -sf http://127.0.0.1:3000/", timeout=120)
    server.wait_for_unit("nginx.service")

    with subtest("port 80 answers the exact pong page, no redirect"):
        body = client.succeed("curl -s -o - -w '%{http_code}' http://${host}/anything")
        assert body == "<!DOCTYPE html><html><body>pong</body></html>200", repr(body)

    with subtest("HTTPS root, QoS and launcher status through nginx"):
        client.succeed("curl -skf https://${host}/")
        qos = client.succeed("curl -skf https://${host}/QoS")
        assert "pong" in qos.lower(), qos
        status = json.loads(client.succeed("curl -skf https://${host}/launcher/v1/status"))
        print(status)
        assert str(status.get("supportedBuildChangelist")) == "647472", status

    with subtest("only 80/443 reachable from outside"):
        for port in (3000, 3001, 27017):
            client.fail(f"nc -z -w 3 ${host} {port}")
        client.succeed("nc -z -w 3 ${host} 443")

    with subtest("MongoDB has no TCP listener on the host at all"):
        server.fail("ss -ltnH | grep -w 27017")
        server.succeed("test -S /run/dauntless-nix/mongodb/mongodb-27017.sock")
        server.fail("sudo -u nobody test -r /run/dauntless-nix/mongodb/mongodb-27017.sock")

    with subtest("secrets stay out of the store and are private"):
        server.succeed("test \"$(stat -c %a:%U /var/lib/dauntless-nix/secrets/backend.env)\" = 600:dauntless")

    with subtest("no startup errors in the backend log"):
        server.fail("journalctl -u dauntless-backend.service -b --no-pager | grep -E 'ERROR|Fatal'")

    with subtest("state survives a backend restart"):
        server.succeed("systemctl restart dauntless-backend.service")
        server.wait_until_succeeds("curl -sf http://127.0.0.1:3000/", timeout=120)
  '';
}
