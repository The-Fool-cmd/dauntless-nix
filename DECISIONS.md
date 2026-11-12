# Decisions

One entry per decision: options considered, what was chosen, why. Newest last.

## D1 — Fork name and form (2026-11-12)
- **Options:** fresh repo with imported history; GitHub fork renamed.
- **Chosen:** a real GitHub fork of `pranav158/Mystic-Paradox`, named `dauntless-nix`.
- **Why:** a fork keeps upstream PRs and rebases cheap. That matters because Linux support is meant to sit behind
  switches that could go upstream. The name avoids "Mystic Paradox", "MysticFox" and "Paradox"
  (ADDITIONAL_TERMS §3–4). LICENSE, NOTICE and ADDITIONAL_TERMS are kept unchanged. NOTICE and README mark the fork
  as modified (§2).

## D2 — Source of the 1.14.7 manifest (2026-11-12)
- **Options:** `api.mysticfox.dev` (upstream's copy); the community Dauntless Manifest Archive on GitHub.
- **Chosen:** the archive, pinned to commit `26ec6249b6350d8f59f537642445c9bccb29babd`,
  `manifests/Windows/Dauntless_1.14.7.647472.manifest`. SHA-1 checked against the documented
  `aa70748e4c0a776a991f2bac10ad342adaa31476`. A local copy is kept beside the install, outside the repo.
- **Why:** no dependency on someone else's server; same bytes as the upstream doc's copy.

## D3 — Legendary version (2026-11-12)
- **Options:** nixpkgs `legendary-gl` (0.20.34); upstream 0.21.1.
- **Chosen:** 0.21.1, packaged in `nix/pkgs/legendary.nix` and pinned by tag commit and hash.
- **Why:** `INSTALLING_DAUNTLESS.md` requires 0.21.1 or newer. The `uv_build` version bound is relaxed to the one
  in nixpkgs (0.10), which builds it fine.

## D4 — How the game runs on Linux clients (2026-11-12)
- **Options:**
  - nixpkgs `wineWow64Packages` plus separately pinned DXVK/VKD3D;
  - GE-Proton through `umu-launcher`;
  - GE-Proton directly under `steam-run`.
- **Chosen:** nixpkgs `proton-ge-bin` (GE-Proton11-1) started by its `proton` script inside `steam-run`
  (`nix/pkgs/proton-run.nix`). `PROTONFIXES_DISABLE=1` is set.
- **Why:** Proton bundles matching DXVK, VKD3D-Proton and nvapi. Its version is fixed by this flake's own
  `flake.lock`, which does not follow any host's system nixpkgs. umu was rejected because it downloads the Steam
  Runtime at run time, which is unpinned and an outside dependency. protonfixes is disabled for the same reason
  (winetricks downloads).
- **Revisit:** the server side (phase 2) may prefer plain Wine for headless `-server -nullrhi`.

## D5 — Pristine game copy (2026-11-12)
- **Chosen:**
  - `~/Games/dauntless-1.14.7/Dauntless` is the Legendary install, made read-only after verification.
  - The game runs from `instance/Dauntless`, a hard-linked copy whose `Win64` directory is writable for the runtime
    DLLs.
- **Why:** the shared inodes are read-only, so nothing that runs the game can modify the verified files, and the
  working copy costs no extra 16 GB. To repair, run `chmod -R u+w` on the pristine tree first, then
  `legendary repair` with the 1.14.7 manifest (never `--repair-and-update`).

## D6 — Leak prevention (2026-11-12)
- **Chosen:** `nix/git-hooks/pre-commit`, enabled with `git config core.hooksPath nix/git-hooks`. It does two
  things:
  - refuses staged game files, Epic manifests, SDK output, exported data, Proton prefixes, Legendary state and
    `.env` files, by path pattern;
  - runs gitleaks pinned by the flake, with upstream's `.gitleaks.toml`, the same config CI uses.
- **Why:** CI alone catches leaks only after a push. Game files and credentials live outside the repo by design
  (under `~/Games/dauntless-1.14.7` and `~/.config/legendary`); the hook is the second line of defence.

## D7 — Backend packaging (2026-11-13)
- **Chosen:** `nix/pkgs/backend.nix`, built with `buildNpmPackage` on Node 22 and pinned by `npmDepsHash`.
- **Source contents:** the source is narrowed to `ParadoxBackend/`, `shared/hunt-manifest/` (the backend imports it
  from `../../../../shared`, so it is installed as `lib/shared` next to `lib/backend`) and the `*.example.json` hunt
  tables. Real game data is filtered out, so it can never reach the world-readable Nix store.
- **Native module:** `@node-rs/argon2`'s prebuilt `.node` file is patched with `autoPatchelfHook`.

## D8 — MongoDB: socket-only container, single-node replica set (2026-11-13)
- **Options:**
  - nixpkgs `mongodb`: source build, unfree (SSPL), very long compile;
  - Podman container on loopback TCP with auth and a replica-set keyfile;
  - Podman container with `--network=none` and a Unix socket.
- **Chosen:** the last option. The `mongo:7.0.48-jammy` image is pinned by digest through
  `dockerTools.pullImage` and loaded offline. The container runs with `--network=none` as a fixed uid/gid
  (`services.dauntless-nix.mongodb.uid`, default 27017). It is a single-node replica set `rs0`, initiated by an
  idempotent one-shot service. The backend connects with `mongodb://<socket>/?directConnection=true`.
- **Why:**
  - The backend refuses to start without a replica-set primary (`MONGODB_PRODUCTION_REPLICA_SET_PRIMARY_REQUIRED`).
  - With no network, nothing on the host can reach the database over TCP, including the server's `--network=host`
    containers. Access is controlled by the socket directory (`0770 dauntless-db`), so there are no database
    passwords or keyfiles to manage.
  - This follows the user's Podman preference and the bridge-network "smallest blast radius" pattern already used on
    the server.
- **Gotcha:** systemd expands `%` in `Environment=`, so the percent-encoded socket URI is escaped as `%%`.

## D9 — TLS at nginx (2026-11-13)
- **Chosen:** nginx terminates TLS, as in upstream's "Linux behind nginx" notes. The backend runs with
  `MYSTICPARADOX_TLS_TERMINATED_BY_PROXY=on` on `127.0.0.1:3000`. Port 80 always serves the exact pong page (the game's
  region check). The TLS mode is one option with three values:
  - `self-signed`: for phase 1 and testing;
  - `acme`: Let's Encrypt over HTTP-01 on the pong vhost; needs DNS and a public port 80, which is a human step;
  - `files`.
- **Why:** this is the documented upstream path, and NixOS covers nginx and ACME declaratively. The self-signed
  material lives in `/var/lib/dauntless-nix-tls`, not inside the state directory, so nginx never needs access to the
  directory that holds secrets.
- **Open:** SECURITY.md says the launcher trusts only WebPKI roots. Real play will very likely need `acme` mode (a
  real domain); phase 3 will confirm.

## D10 — Secrets generated on the host (2026-11-13)
- **Chosen:** the `dauntless-nix-init` one-shot service adds each missing secret on its own to
  `/var/lib/dauntless-nix/secrets/backend.env` (`0600 dauntless`):
  - the RSA-4096 JWT key pair, from upstream's own `scripts/generate-selfhost-rsa-key.mjs`;
  - `GAMESERVER_API_KEYS`, `API_KEY_HASH_SECRET` and `MYSTICPARADOX_METRICS_TOKEN`, from `openssl rand`.

  Non-secret settings are module options, mirroring `configure-selfhost.ps1`, with `MYSTICPARADOX_SERVICE_ROLE=api`.
  Extra secrets (SMTP, TURN) go in through `backend.extraEnvironmentFiles`.
- **Why:** nothing secret enters the Nix store or the repo. Generating keys one at a time means a key added later
  reaches existing installs without rotating the old ones.

## D11 — Phase gates are NixOS VM tests (2026-11-13)
- **Chosen:** `checks.x86_64-linux.server`, a server VM plus a client VM, run with `nix flake check`. It checks:
  - the exact pong body on port 80;
  - HTTPS `/`, `/QoS`, and `/launcher/v1/status` reporting `647472`;
  - that ports 3000, 3001 and 27017 are unreachable from the client;
  - that MongoDB has no TCP listener and its socket is unreadable by `nobody`;
  - that the secrets file is `0600`;
  - that the backend log has no errors and the backend survives a restart.
- **Why:** this tests the declarative config without touching any real machine.
