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
  - With no network, nothing on the host can reach the database over TCP, including `--network=host`
    containers. Access is controlled by the socket directory (`0770 dauntless-db`), so there are no database
    passwords or keyfiles to manage.
  - It uses Podman and the bridge-network "smallest blast radius" pattern.
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

## D12 — No domain: a remote player reaches the server over WireGuard (2026-11-13)
- **Context:** there is no owned domain. Upstream's model is a public DNS name, publicly trusted TLS on 443, 80 open
  for the pong page, and a public UDP game range.
- **Finding:** the runtime reads `MYSTICPARADOX_BACKEND_URL` (`ParadoxRuntime/BackendUrl.h`): `http` or `https`, a DNS
  name or an IPv4/IPv6 literal, with an optional port. It replaces the compiled-in `https://MP_PUBLIC_HOST` for API
  calls and chat. A client can therefore be pointed at an address with no DNS at all. The launcher is ours to build
  (phase 3), so its trust store is ours to choose too.
- **Options:**
  1. A free dynamic-DNS name plus Let's Encrypt, with 80, 443 and UDP public. This depends on a third-party DNS
     provider at run time and exposes the most.
  2. A public IP and a self-signed certificate, with 80, 443 and UDP public. This breaks whenever the home IP
     changes, and still exposes everything.
  3. The remote player as a peer on the existing router WireGuard server. Stock firmware gives a peer all or nothing
     of the LAN.
  4. A dedicated WireGuard interface on the server, used only by players.
- **Chosen:** option 4. The server module gains an opt-in `wg-dauntless` interface. Its firewall allows only the
  backend (80/443) and game UDP on that interface. The only public exposure is one forwarded UDP port (a human step at
  the router). LAN players connect directly. Clients get the server address through `MYSTICPARADOX_BACKEND_URL`.
- **Why:** no domain and no third-party DNS; less exposure than upstream's model; the remote player can reach only
  the game ports, not the LAN.
- **Open:** whether the game's HTTP client accepts a self-signed certificate (otherwise plain HTTP, which inside the
  tunnel is encrypted by WireGuard and on the LAN is local only), to be decided in phase 3. If the home IP is dynamic,
  the peer's `Endpoint` needs updating when it changes.

## D13 — RuntimeLoader (`winmm.dll`) is cross-built with MinGW (2026-11-13)
- **Chosen:** `nix/pkgs/runtime-loader.nix` builds `tools/RuntimeLoader` for `x86_64-pc-windows-gnu`
  (`pkgsCross.mingwW64.rustPlatform`, stable Rust, `+crt-static`) instead of upstream's 2026-03 nightly MSVC build.
- **Checked:**
  - Its imports are only system DLLs (kernel32, ntdll, msvcrt, bcryptprimitives, api-ms-win-core-synch).
  - It exports 198 functions, including all four the game imports from winmm.
  - Under the pinned Proton with `WINEDLLOVERRIDES=winmm=n,b`, the game loads it as native from the game folder, it
    forwards to the builtin winmm, and it loads DLLs listed in `mystic_loader.ini`. This was verified inside the real
    1.14.7 process with a probe DLL that writes a marker file.
- **Why:** the crate is pure Rust plus winapi, with no MSVC-specific link steps, so it needs neither the MSVC
  toolchain nor the Windows SDK.
- **Consequence:** `mystic_loader.ini` gives a way to inject Dumper-7 and CatalogExporter under Proton without a
  separate injector.
- **Gotcha:** Proton writes no log, and ignores `WINEDEBUG`, unless `SteamGameId` is set. The wrapper now defaults
  it to `dauntless-nix`.

## D14 — C++ toolchain: clang-cl + lld-link + MSVC CRT/Windows SDK (ACCEPTED 2026-11-13)
- **Needs:** MSVC-dialect C++. The runtime uses `__try`/`__except` 70 times, MSVC intrinsics, `/MT` and `.vcxproj`
  builds, and is linked against an SDK whose layout must match the MSVC-compiled game exactly.
- **Options:**
  1. clang-cl + lld-link (LLVM 21) with the MSVC CRT/STL and Windows SDK fetched by `xwin`.
  2. clang or GCC for MinGW-w64 (open source, but the Itanium C++ ABI, case-shim includes and more porting).
  3. MSVC under Wine.
- **Chosen:** option 1. The operator accepted Microsoft's license terms for the xwin download on 2026-11-13.
  - nixpkgs' own `windows.sdk` (xwin, pinned VS 17.14 manifest and hash; CRT 14.44, SDK 10.0.26100) is used, gated
    by `config.microsoftVisualStudioLicenseAccepted`.
  - **This flake never accepts the license for anyone.** CLI builds opt in per command
    (`DAUNTLESS_NIX_ACCEPT_MSVC_LICENSE=1 nix build --impure ...`); modules and downstream flakes call
    `lib.msvcPackages { acceptMicrosoftVisualStudioLicense = true; }` from their own config.
  - Microsoft's files are never committed or redistributed. The pre-commit hook blocks `*.lib` and xwin caches.
- **Toolchain (`nix/pkgs/msvc-toolchain.nix`):** a CMake toolchain file with `-fms-compatibility-version=19.44`,
  `/Brepro`, static CRT, an `llvm-rc` wrapper (it needs `clang` on PATH to preprocess), and two MSVC-compatibility
  switches: `-Wno-invalid-constexpr` and `-Wno-c++11-narrowing` (Dumper-7 emits `enum : uint8 { X_MAX = 256 }`, which
  MSVC truncates with a warning).
- **Verified:**
  - Dumper-7 builds (`.#dumper7`).
  - The 1.14.7 SDK dumped under Proton through `mystic_loader.ini`.
  - `MysticParadox.dll` builds with 0 errors, importing only KERNEL32, USER32, SHELL32, ADVAPI32 and WS2_32.
  - All ~225,000 Dumper-7 `static_assert`s on sizes, alignments and offsets pass under clang-cl. `SDK.hpp` includes
    every header, and each expands its assertions, so every type's layout matches the live game's.
- **Rejected:** option 2's ABI risk and porting cost; option 3's fragility.

## D15 — Dumper-7: pinned, built locally, never redistributed (2026-11-13)
- Commit `2c1eae30` (2026-10-26) is fetched from GitHub by hash. Upstream has no license file, so it is treated as
  all rights reserved: built locally only, marked unfree, and allowed by name.
- Two build fixes are applied in `postPatch`, both upstream CMake bugs: `cmake/common.cmake` vs `Common.cmake`
  casing, and the CMake files pinning C++20 while the code (and upstream's `.vcxproj`) needs C++23.
- It is injected through the loader's `mystic_loader.ini` with a `Dumper-7.ini` beside the exe (`SleepTimeout=45`,
  `ShouldAutoUnload=1`, output outside the repo). The dump took 14 s and identified
  `4.26.2-647472+++dauntless+rel-1.14.7`. It produced 3,704 headers and 1,266 `*_functions.cpp`.

## D16 — CMake build for the runtime (2026-11-13)
- `ParadoxRuntime/CMakeLists.txt` mirrors the Release|x64 `.vcxproj`: the same sources, the same nine SDK
  translation units, the same P2P/anti-cheat conditions, `/MT`, C++23 and the same defines. `MP_SDK_DIR` points at
  a Dumper-7 dump anywhere on disk. `MP_PUBLIC_HOST` generates `deployment_config.generated.h` in the build tree.
  The `.vcxproj` stays the reference, so Windows users are unaffected.
- Two portable one-line source fixes, both upstream candidates: `#include "networking.h"` changed to
  `"Networking.h"`, and the `.rc` asset path changed from `assets\x.png` to `assets/x.png` (accepted by both
  `rc.exe` and `llvm-rc`).

## D17 — Game-server topology: dedicated hubs and hunts on the server under Wine (2026-11-13)
- **Options:**
  - (a) ParadoxDirector on the server, starting Ramsgate, the Training Grounds and hunts as headless Wine
    processes;
  - (b) Paradox realms, where a player's PC hosts hubs and hunts over ICE/TURN (coturn).
- **Prototype results for (a)**, on a desktop PC with no display (`DISPLAY`/`WAYLAND_DISPLAY` unset), using the
  runtime built in D14/D16 and the MinGW loader from D13:
  - Ramsgate and the Training Grounds boot with `-server -nullrhi`. The runtime logs `Networking::Listen returned
    true`, UDP 8790 or 8789 opens, and the exact `MYSTICPARADOX_GAMESERVER_READY launchId=<id> port=<port>` line
    reaches stdout.
  - Through the wrapper (D18), a server is ready in 14 s including first-time prefix creation and uses about
    1.4 GB RSS (Training Grounds). It stops cleanly within 2 s of SIGTERM.
  - Launched through Proton's `waitforexitandrun` instead, the server also boots, but the ready line never reaches
    stdout, because Proton's `steam.exe` shim does not pass Unix stdio through. That is why the wrapper uses Proton's
    `wine` directly.
- **Against (b):**
  - In the public code, player-hosted hunts earn no rewards: the backend logs `[AntiCheat] module not present;
    player-hosted hunts are unmonitored and earn no rewards`, because the anti-cheat module is not published. That
    fails the "progression saved" goal.
  - Realm hosting lives in the Windows-only Tauri launcher plus the ParadoxTransport DLL, which would all need
    porting.
  - Latency: with one player on the server's LAN and one remote, hosting on either player's PC is no better than
    hosting on the server.
- **Chosen:** (a). The ParadoxDirector code needs no changes: it already starts `GAMESERVER_BINARY_PATH`, reads its
  stdout, stops it with a signal and probes `kill(pid, 0)`. Its only Windows-only path (`tasklist.exe`, in the runtime
  self-updater) is already skipped on non-Windows and off by default.
- **Capacity:** about 1.4–2 GB per server. Two hubs plus `MAX_CONCURRENT_HUNT_SERVERS` hunts, sized to the host's
  RAM.

## D18 — `dauntless-gameserver` wrapper (2026-11-13)
- `nix/pkgs/gameserver-wine.nix` is the Director's `GAMESERVER_BINARY_PATH`. It runs the exe with the pinned
  GE-Proton's own `wine` inside `steam-run`, with:
  - `WINEDLLPATH=<proton>/lib/vkd3d:<proton>/lib/wine`, because the exe statically imports d3d11/dxgi even with
    `-nullrhi`;
  - `winmm=n,b`;
  - the display unset.
- It keeps **one prefix per port**, created on first use. Each server then has its own wineserver, so the Director's
  SIGTERM stops exactly that server through `wineserver -k`. Killing `wine` alone can leave the Windows process
  running.
- It changes into the game folder before calling `steam-run`, because the sandbox re-enters the caller's working
  directory, which may not exist inside it (seen with `/etc/nixos`).

## D19 — Real progression data: export the XP curves from the client, Hunt Pass from the wiki (2026-11-13)
- **Why it matters:** `progression_config.json` holds every track's rank curve: weapon and player levels,
  mastery, the Hunt Pass, and prestige. The backend refuses XP grants for any track without a curve (`"no rank
  curve in progression_config.json"`), so the synthetic example would save no progression at all. Upstream calls
  this file a captured live-service response that the client does not contain.
- **Finding:** the downstream fork HyjinnxDev/dauntless-revamped (AGPL-3.0, versions/1.14.7, commit `874ad303`) has:
  - `tools/CatalogExporter/ProgressionExporter.cpp`, which exports `player_experience_track_table`,
    `weapon_experience_track_table`, `experience_track_table`, `mastery_track_table` and
    `progression_track_table` from the running client, with full per-rank XP costs and rewards;
  - `scripts/generate_progression_config.cjs`, which assembles `progression_config` from that export;
  - `scripts/fetch_hunt_passes.cjs`, which rebuilds the five 1.10–1.14 Hunt Pass reward tracks from the Dauntless
    wiki (one-time fetch; the tier rewards really are not in the client);
  - Lady Luck store generators.
- **Chosen:** cherry-pick those pieces with attribution in NOTICE.md. Build CatalogExporter with the D14 toolchain
  and inject it through `mystic_loader.ini` (as with Dumper-7) into our own 1.14.7 client. Generate the real
  backend and Director data on the server's state directory, never in the repo.
- **Ordering:**
  - Some exports (hunts, store, Slayer's Path) need the client in Ramsgate, which needs the backend, the Director
    and a working client session. Those come from phase 3 running first on synthetic data.
  - The XP-track tables load at the front end, so they can be exported earlier.

## D20 — Director module, per-interface firewall, WireGuard guard (2026-11-13)
- **`nix/pkgs/director.nix`** builds ParadoxDirector with `shared/hunt-manifest`; real hunt tables are kept out of
  the store.
- **Upstream-friendly patch:** an optional `BIND_HOST` for the Director, the same key the backend uses. The Director
  API has **no authentication** and listened on all interfaces. Unset keeps the old behaviour; the module sets
  `127.0.0.1`.
- **`nix/modules/director.nix`** (`services.dauntless-nix.director`):
  - a setup one-shot checks the server's pristine `gameDir` exe against the approved SHA-256, hard-links (or copies)
    it to `<stateDir>/director/game`, installs `MysticParadox.dll` and `winmm.dll` from the `runtime` package,
    removes any `mystic_loader.ini`, and writes `METAGAME_API_KEY` (= the backend's `GAMESERVER_API_KEYS`) to a
    `0600` env file;
  - the service runs as its own user with `KillMode=control-group`, so stopping it stops every game server;
  - game servers get `MYSTICPARADOX_BACKEND_URL=http://127.0.0.1:<backend>`, the loopback backend instead of the
    public name;
  - the hunt limit defaults to 2 (two players).
  - **Port:** the default is 3001; a host where another service already publishes 3001 overrides it (e.g. 3011).
- **Firewall scoping:** `services.dauntless-nix.firewall.interfaces` opens 80/443 and the game UDP range only on the
  listed interfaces. On a host with several network segments, a global open would leak onto the others.
- **`nix/modules/wireguard.nix`** (`wg-dauntless`, UDP 51821): the peer list carries public keys, and the server key
  is generated on the host. A guard runs before the NixOS firewall's accepts, for both the iptables and nftables
  backends:
  - on the tunnel, only 80/443 and the game UDP range are accepted, even if the host opens other ports elsewhere;
  - nothing arriving from the tunnel is forwarded. A host with `ip_forward` on (e.g. for Podman) without this
    rule a peer that routes the LAN into the tunnel reaches other LAN hosts. The negative control proved it: with
    the rule removed, the test reached a LAN host's port 9999.
- **One address everywhere:** players use the tunnel address (e.g. `10.77.0.1`) for HTTPS and game UDP. LAN players
  reach it through a static route via the server's LAN IP (client module), so `MY_IP` and the client
  `MYSTICPARADOX_BACKEND_URL` are the same for both players. The self-signed certificate gets an `IP:` SAN when
  `publicHost` is an address.
- **VM test (`checks.server`), three VMs** (server, LAN player, remote player), with VLANs for "internet" and the
  home LAN. It checks:
  - Ramsgate and the Training Grounds come up through a stub game server;
  - the Director API is loopback-only;
  - a LAN player gets pong, HTTPS and launcher status through the tunnel address;
  - a remote player over WireGuard reaches the game ports only, not 8080, 22, 3000, 3011 or 27017, nor the LAN
    service through the server's LAN IP or another LAN host, nor anything outside the tunnel;
  - stopping the Director kills its servers;
  - the secrets files are `0600`.

## D21 — Linux client: a minimal launcher of our own (2026-11-13)
- **Options:**
  1. Port the Tauri launcher: about 29k lines of Rust with heavy Win32 use (job objects, WinTrust, secure store,
     process reparenting) plus realm hosting.
  2. Run the Tauri launcher under Wine: needs WebView2 under Wine; fragile.
  3. A minimal Linux launcher that speaks the same protocol.
- **Chosen:** option 3, `tools/linux-launcher/launcher.mjs`: one Node file, stdlib only, packaged as `.#launcher`
  (`dauntless-nix-launcher`). It handles `register`, `login`, `logout`, `status`, `sync` and `play [--dry-run]`:
  - **Auth:** `/launcher/v1/auth/{register,login,refresh}`. The refresh token is stored in
    `$XDG_STATE_HOME/dauntless-nix/session.json` (`0600`). The server's TLS certificate can be pinned
    (`caCertFile`).
  - **Runtime:** it downloads the signed manifest and files from our own server only. It checks each file's size,
    SHA-256 and Ed25519 signature against the pinned `runtimePublicKey`, which is the same scheme as upstream's
    launcher, then installs into a hard-linked working copy. It removes before writing, so nothing is ever written
    through a hard link into the pristine install. It also writes the three `DISABLE_*_BRANDING.flag` files and
    removes any `mystic_loader.ini`.
  - **Play:** it checks the exe hash, requests `/launcher/v1/game-sessions` with exactly the fields
    `RequestGameExchangeCode` checks, and starts the game under `dauntless-proton` with upstream's 13 arguments,
    `MYSTICPARADOX_BACKEND_URL`, `MYSTICPARADOX_RUNTIME_PROFILE=production` and `WINEDLLOVERRIDES=winmm=n,b`. Any
    other inherited `MYSTICPARADOX_*` variable is dropped, as upstream does.
  - **Not ported:** Launcher Guard (observe-only upstream), Discord login, realm hosting and launcher self-update.
    None is needed for two players on dedicated servers.
- **Server side:** `dauntless-runtime-publish` generates an Ed25519 runtime signing key on first start (upstream's
  `generate-runtime-key.mjs`). It publishes the Nix-built runtime with upstream's `publish-runtime-update.mjs`,
  versioned `1.0.0-nix.<dll sha prefix>` (unchanged bytes keep their signature), and exposes the public key at
  `<stateDir>/updates/runtime-public-key.b64`. The remote player therefore needs neither the SDK nor the MSVC
  toolchain.
- **Client module (`nixosModules.client`):** installs the launcher, Proton runner and Legendary; writes
  `/etc/dauntless-nix/config.json` and the pinned certificate; adds a LAN route (`lanRoute`) or a WireGuard peer
  whose `allowedIPs` is the server's /32 only.
- **Verified in the VM test** (the remote player over WireGuard, a fake exe and a fake runtime published through the
  real feed): register, login, sync with signature check, an exchange code issued, and a wrong runtime key refused.

## D22 — No upstream consent or branding on a private server (2026-11-13)
- `MYSTICPARADOX_CONSENT_REQUIRED=off`, `MYSTICPARADOX_CONSENT_ENFORCE=off` and `MYSTICPARADOX_EMAIL_VERIFICATION=off`.
  Upstream's Terms of Use and Privacy Policy belong to the official Mystic Paradox service; upstream itself defaults
  consent off for "a local server, whose operator sets its own rules". It only defaulted on here because the
  persistence is MongoDB.
- The runtime's Mystic Paradox login background, credits and press-start branding are disabled on both servers and
  clients with upstream's own flag files.
- **Why:** ADDITIONAL_TERMS §2–4. A modified build must not look like, or be presented as, an official Mystic
  Paradox release or service.

## D23 — Real-client verification on Linux, off-screen; game traffic over plain HTTP (2026-11-13)
- **Local stack:** `nix run .#local-stack -- up|down|status|launcher-config` runs the whole server as unprivileged
  user processes on 127.0.0.1: MongoDB 8 as a single-node replica set, the backend, the signed runtime feed, and the
  Director with **real** Wine game servers. It is for development; production is `nixosModules.server`.
  `mongodb-ce` is allowed as unfree for this app only.
- **Off-screen client:** the real 1.14.7 client runs under `gamescope --backend headless`: GPU rendering with no
  window on the desktop. `gamescopectl screenshot` captures frames, and `xdotool` on gamescope's Xwayland sends
  input.
- **Verified on a desktop PC:**
  - The Director starts Ramsgate and the Training Grounds under Wine, ready in about 12 s each. The game servers
    use `[BackendAddress] source=env api=http://127.0.0.1:3000`.
  - The launcher registers, logs in, syncs the signed runtime and gets an exchange code. The game logs in with it
    through the runtime's redirect (`oauth/token → 200`, "Logging in a user via a launcher exchange code";
    `LoginToEpicProxy` and `TryEpicAutomaticLoginProxy` succeed), and the screen shows "Logged in as: DevSlayer".
  - The game is happy with **plain HTTP** to the backend, which settles the TLS question from D12: no certificate
    trust inside the game is needed. Game traffic still travels inside WireGuard (remote) or the LAN (local).
- **Stopped at the game's own Phoenix Labs Terms of Service dialog.** Accepting a third party's terms is the operator's
  decision, so automation does not click through it.
- **Branding found and fixed:** the backend's `/dauntless-status` hard-coded "Welcome to Mystic Paradox!" on the
  login screen. It now comes from `src/statusMessage.ts` with `MYSTICPARADOX_STATUS_MESSAGE` (unset = official
  text, `off` hides it; upstream-friendly). The module sets `services.dauntless-nix.statusMessage` (default
  "Private server (dauntless-nix)"). Covered by a unit test and the VM test.
- **Upstream test suites now run in every package build:** backend 1,681 tests (1,611 pass, 0 fail, 70 skipped
  that need real game data); Director 35/35.

## D24 — Real progression data from our own install (2026-11-13)
- **`tools/CatalogExporter/CMakeLists.txt` + `nix/pkgs/catalog-exporter.nix`** (`lib.msvcPackages … .catalog-exporter
  { sdk; }`): this mirrors the Release `.vcxproj` and built on the first try with the D14 toolchain. It reads
  `export_flags.txt` from, and writes `Items_Analysis\` to, the game's working directory, so no machine paths are
  compiled in.
- **Export run:** the off-screen client (headless gamescope), injected through `mystic_loader.ini`, with no login and
  nothing accepted in the client. It took about 12 s: `ALL DONE general=6170 equipment=1608 progression=139
  currencyNames=53`. Output was moved to `~/Games/dauntless-1.14.7/generated/` and is never committed.
- **New `ParadoxBackend/scripts/assemble_progression_config.cjs`:** neither upstream nor revamped has the step from
  the export to `progression_config.source.json`. It builds a path for every track in
  `APPROVED_XP_PROGRESSION_TRACK_IDS` except the Hunt Pass:
  - player level (20 ranks, 141,020 XP), 7 weapon tracks (20 ranks each) and 9 mastery tracks with their per-rank
    rewards, all from the export;
  - 7 `PrestigeTrack_Weapon_*` (reforge) tracks, synthesised exactly as upstream's `progression.ts` describes them
    (one 0-XP requirement, `prestige.xp_per_level 1`).

  Upstream's `generate_progression_config.cjs` validated the result and wrote it: 24 paths, 239 reward tiers. The
  backend starts with no progression warnings.
- **Still open:** the Hunt Pass (`season43`). Its tier costs and rewards are not in the client (the season table rows
  are empty), so it comes from revamped's wiki-based `fetch_hunt_passes.cjs`, converted to a `season43` path. Lady Luck
  store: also open. Neither blocks weapon, player or mastery XP or reforge.
- **Upstream bug fixed (production-relevant):** `publish-runtime-update.mjs` copies an unchanged artifact onto
  itself, and a read-only source (a Nix store path) leaves a read-only copy. So the module's publish service would
  have failed on **every boot after the first**. A `publishCopy` helper now skips same-path copies and writes
  `0644`. The VM test now restarts the publish service twice.

## D25 — On-demand server, operator command, run-time Hunt Pass, plain-HTTP game port (2026-11-13)
- **Context:** the server host runs other services; the game server should run only when someone plays, and be
  controlled over SSH without root. The live service rotated Hunt Passes; the 1.14.7 client enables `season43`…
  `season50`. The game's backend address in production was open (D23: plain HTTP is what we verified).
- **Decision:**
  - Every unit (init, runtime publish, MongoDB, replica-set init, backend, Director) is part of `dauntless.target`.
    `autoStart = false` keeps the target out of `multi-user.target`. nginx and WireGuard stay up (502 while down).
  - `dauntless up|down|restart|status|logs|season` is installed system-wide. A polkit rule lets members of
    `dauntless-operators` (`services.dauntless-nix.operators`) start, stop and restart only the dauntless units.
  - `huntPass.season` (default `season43`) sets `GAMESERVER_HUNTPASS_ID`. `dauntless season <id>|default` runs the
    root template `dauntless-huntpass@<id>`, which accepts only `huntPass.seasons`, writes
    `/var/lib/dauntless-nix-settings/huntpass.env` (the backend's last EnvironmentFile, so it wins) and try-restarts
    the backend and Director. Progress is stored per track id, so a new season starts at rank 0 and switching back
    resumes. Tier rewards are still the cloned `season43` path for every season (data still open).
  - `plainHttpPort` adds an nginx plain-HTTP vhost (HTTP + WebSocket) opened only where 80/443 are: the firewall
    interfaces and the tunnel. Players use `gameBackendUrl = http://<publicHost>:<port>`, the transport D23 verified.
  - `gameDataDir` installs host-side real game data (not in the store: it derives from the game) on every start.
- **Verified:** the VM test boots with nothing running, an unprivileged operator runs `dauntless up`, cannot touch
  other units, switches `season44` and back, reaches the plain-HTTP port from the LAN and the tunnel, and
  `dauntless down` stops everything.

## D26 — Game servers bind to their public address (-MULTIHOME) (2026-11-13)
- **Context:** first LAN play-test: the client reached the backend and was matched to Ramsgate at 10.77.0.1:8790, then
  "The server network connection timed out" with nothing ever received. The servers bound 0.0.0.0, so replies to a
  LAN player (routed to the tunnel address over the LAN) left with the host's LAN address as the source and the
  client dropped them. Tunnel peers were unaffected, which is why the VM test passed.
- **Decision:** the Director passes `-MULTIHOME=<MY_IP>` to every game server (`GAMESERVER_MULTIHOME=off` disables
  it, another value overrides it). The VM test checks the argument.
- **Correction (same day, measured on the server):** Wine implements a bind to a specific address as
  `0.0.0.0` + SO_BINDTODEVICE on the interface owning it (`ss` shows `0.0.0.0%wg-dauntless:8790`), so the servers
  only accept packets that arrive on the tunnel. It does not help a LAN player; it does confine game UDP to the
  tunnel. **Every player, LAN included, joins the WireGuard tunnel** (a LAN player uses the server's LAN address as
  the endpoint). The static LAN route to the tunnel address is not used.

## D27 — Fix Dumper-7's Blueprint-event lookups in the SDK (2026-11-13)
- **Context:** the first real join crashed the Ramsgate server: `Fatal error: Failed to find function
  BP_PlayerCharacter_C in BP_PlayerCharacter_C ...`, raised from the runtime's per-connection `TickStamina` call.
  Our Dumper-7 build (`CppGenerator.cpp`, the dynamic-lookup branch) passes the outer class name to
  `FindFunctionChecked` for every BlueprintEvent wrapper: 11,999 wrappers in our 1.14.7 SDK.
- **Decision:** `tools/sdk-fixups/fix-bp-function-names.py` rewrites each lookup to the function's own name (from the
  `// Function Pkg.Class.Name` comment above it). The flake applies it to the SDK for both the runtime and the
  CatalogExporter, so the SDK store path stays the untouched dump.

## D28 — Hunt tables from our own export, installed host-side (2026-11-13)
- **Context:** the Director still ran the example tables, so no hunt could start (backlog item 1). The guide said
  the export needs a client in Ramsgate.
- **Finding:** 1.14.7 loads every hunt table at the main menu. The D24 off-screen client (no login, nothing
  accepted), injected with `EXPORT_HUNTS=1` only, wrote 1,378 rows in seconds: 161 player hunts, 614 matchmaker rows
  over 6 tables, and the region, escalation, modifier, activity, unlock and schedule tables. Wine loads our
  `winmm.dll` only with `WINEDLLOVERRIDES=winmm=n,b`; without it nothing is injected and nothing says so.
  `mapAssetName` is empty in every row, but `mapAssetPath` (the soft-pointer path) is set, and the importer uses it.
- **Decision:** upstream's `import_hunt_tables.cjs --apply`, run with `PARADOX_GAME_DATA_DIR` pointing to an empty
  directory outside the repository, so no example rows are kept: 7 tables, no rejected rows. The tables go to
  `<gameDataDir>/hunt-data/` on the host, which the module already installs on every start (D25). The
  output is game data, never committed.
- **Verified:** the Director's audit reports `problems=0`, with `resolvable=154/161` (7 CR19 Expedition islands are
  unsupported upstream) and 39 maps. A `ISLAND` matchmaking request for `CR19_PlayerHunt_Pursuit_Electroquill`
  booted `dia_arid_rose` with the Electroquill, ready in 12 s on a desktop PC and 6 s on the server.
- **Open:** the Director has no timeout for a hunt server that no player joins; it holds a slot until restart.

## D29 — The rest of the game data: main-menu exports plus a public live-service capture (2026-11-13)
- **Context:** after D28 the backend still served synthetic Slayer's Path, mastery, Reward Cache, Lady Luck and
  platinum data, and Hunt Passes without rewards. The client does not hold Hunt Pass rewards or Lady Luck offers.
- **Exports:** the main menu is enough again, with the same off-screen run as D28 (no login). One run exported
  Slayer's Path (509 nodes), mastery (258 cards, 46 achievements, already the backend's `mastery_objectives.json`
  format) and a catalog of 7,318 items (6,170 in D24's run). A second run exported 3,168 `store_item_images` rows.
  Upstream's generators then built a Slayer's Path of 509 nodes with 459 definitions, a Reward Cache of
  178 SKUs and a platinum store of 353 SKUs (154 prices reconstructed).
- **Live-service capture:** EisigesEis/DauntlessEndpointDocumentation (public; commit c0b5355, used locally and never
  vendored) holds the live `Progression/Config.json` and `ladyluckstore.json`. Upstream's `ladyluck:enrich`
  serves 38 of its 43 offers; the five gold cell cores are not in the 1.14.7 catalog.
- **Cross-check:** every weapon and mastery track that D24 built from the client matches the capture exactly
  (requirements and rewards). Two things differ:
  - the player level: the capture has 12 ranks, the 1.14.7 client has 20. The capture includes a December 2024
    season, so it comes from a later build; we keep the client's curve.
  - the `prestige` blocks: the capture's weapon tracks have an XP rate per prestige level, and its reforge tracks
    pay one Aetherheart (`CURRENCY_PJM_PRESTIGE_FILLED`) per level. Ours had neither, so a reforge paid no
    Aetherheart.
- **Decision:** `tools/data/progression-from-capture.py` copies captured passes onto the ids the client enables:
  `season43..45 = season25..27` and `season46..50 = season20..24`. season25 ran from 2024-04-11, the pass of this
  build. Each target keeps its own id, `<id>_premium` gate and dates. The script also copies the prestige blocks
  onto tracks whose requirements match. Every reward id must exist in the catalog (all 8 × 162 do). The files go
  to `gameDataDir` on the host (previous versions are kept in `previous/`).
- **Verified:** upstream's backend tests with the real data: 1,796 pass, 3 fail. The 3 assume upstream's own dataset
  (an override naming `season19` must find a path; `CURRENCY_PRESTIGE` as a prestige reward). Ours serves only
  the season ids the client enables and the real prestige rewards. On the dev stack the backend served the config
  to a real client with no warnings, and season44..50 resolve without clones. The hub was not reached: the dev
  account stops at the game's EULA, which only the account holder accepts.

## D30 — Operator account grants; cosmetic passes served (2026-11-13)
- **Context:** the operator wants every player to start with 500 Platinum and to have every paid feature: premium
  passes, VIP and the rest. The 1.14.7 client lists 40 cosmetic passes in its season table (17 Hunt Pass vaults, 10
  event passes, 4 Reward Cache passes, plus 9 vault and duplicate rows); the backend served none of them.
- **What exists in 1.14.7:** the binary names the VIP entitlement `ent_boost_vip` (`VIPAccessEntitlement`, with a
  membership countdown), `cc_premium` and the pass gates. It has no "Slayer's Club" string. The Middleman appears
  only as a cell store and objectives, not as a subscription.
- **Decision:**
  - `account_grants.json` (optional, host-side game data) is applied at every launcher login in a transaction:
    the listed entitlements are granted if missing, and `starterCurrency` is credited once per account (the marker
    entitlement `dauntless_nix_starter_<id>`). It never blocks a login and never revokes. The deployed file: the
    `season43..50_premium` gates, the 40 cosmetic pass gates, `ent_boost_vip`, `cc_premium`, and 500
    `CURRENCY_PLATINUM_UNIV` (the bucket rewards already use).
  - `progression-from-capture.py` copies a pass under its own id with its captured gate and an open window. Every
    reward of the 40 passes is in the catalog. The backend no longer clamps their windows and accepts XP for them
    (`IsCosmeticPassId`; test passes excluded).
- **Verified:** tsc clean; the backend tests: 1,798 pass and the same 3 dataset failures as D29. On the dev stack, a
  real client's login granted the 50 entitlements and +500 once; a second login granted nothing.
- **Open:** the game grants pass XP only to the track `GET /huntpass` names as selected, and no capture shows how
  the client switches tracks. Whether the client lists the cosmetic passes at all (the comment in
  `routes/system.ts` says only season43..50 are enabled) is checked in game next.

## D31 — The selected pass is saved per account (2026-11-13)
- **Context:** in game a player can select any pass, including the cosmetic passes (D30), but the hub reports the
  choice with `POST progression/huntpass/<userId>` (gameserver key). There was no such route, so it got a 404, and
  `GET /huntpass` kept naming season43. The game grants pass XP to the track that GET names, so a switch never
  took effect.
- **Decision:** a `huntPassSelections` store (Mongo and SQLite, `_id` = userId; included in account deletion).
  `POST /huntpass/:userId` (a gameserver, or the player for themselves) saves the selection if it is a served
  selectable pass: `season43..50` or a cosmetic pass with a curve in the config. `GET` returns the saved
  selection while it is still served, and otherwise the default pass. The XP grant route approves the same set. The 1.14.7
  POST body was not captured, so the handler takes the id from `huntpass_id`/`season`/`progression_id`/... or a bare
  string; it logs the body, and answers 400 with the body in the log when it cannot read it.
- **Verified:** tsc clean; the backend tests: 1,799 pass and the same 3 dataset failures; on the dev stack
  GET → season43, POST season10a_vault → saved and returned by GET, a test pass → 400, no key → 401.

## D32 — MongoDB backups at every start and stop (2026-11-13)
- **Context:** before changing anything that touches saves, the server's MongoDB needs backups. The stack runs on
  demand, so a fixed-time timer would usually find it stopped.
- **Decision:** `dauntless-mongodb-backup.service`, part of `dauntless.target`, ordered after the replica-set init
  and before the backend. Its `ExecStart` dumps at every start and its `ExecStop` dumps at every stop. Stop runs in
  reverse order, after the backend has stopped, so both dumps are quiet. `mongodump --archive --gzip` runs inside the
  container, writing to a root-only directory, and the newest 30 are kept. The backend only `wants` the backup, so a
  failed dump never blocks play. The restore procedure is in docs/OPERATIONS.md.
- **Verified (VM test):** a `-start` dump exists after `dauntless up`, the directory is `0700`, the archive passes
  `mongorestore --dryRun`, and a `-stop` dump exists after `dauntless down`.

## D33 — Hunt Pass XP rules, the annual event calendar, a Trials probe; the Recycle Cell (2026-11-13)
- **Hunt Pass XP:** `GET game_tuning/huntpass_xp_config` was an empty stub. It now serves `huntpass_xp_config.json`
  (host game data) when present. `tools/data/tuning-from-capture.py` writes that file from the live capture,
  turning its decimal commas back into points. The rules are Heroic Pursuits 20, bounties bronze 20 / silver 40 /
  gold 100, and at most 200 per award.
- **Events:** `seasonal_event_schedule` served nothing. It now serves the captured 65 items (events and rumours)
  from `seasonal_event_schedule.json`. The capture had the six seasonal events parked in 2099 or past. The file's
  `annual` calendar ("MM-DD" windows, UTC) moves each one to its open or next window at run time:
  - Saintsbond 02-06..02-27, Springtide 04-01..04-22, Anniversary 05-19..06-09;
  - Dark Harvest 10-14..11-04, Ramsgiving 11-18..12-09, Frostfall (with its snowball fight and public events)
    12-11..01-08.
  `alwaysOn` forces any item on. The client's `seasonal_event_ui_table` has 6 events. Whether each event's content
  (hunts, stores, decor) works in 1.14.7 is checked in game when one runs.
- **Trials:** the game only ever read `trials/leaderboards/*` (stubbed empty). No route that submits a result was
  ever called, and the binary contains none. Telemetry (`POST /event`, previously dropped unread) now logs each
  batch's event names, and any trial-like payload, so the next trial run shows where results go.
- **Gauntlet cells:** the drop-table export (main menu, `EXPORT_DROP_TABLES`) shows that the Recycle Cell
  (`CELL_SAME_PART_DMG_UP_UC`, "+1 Recycle Cell") is already in `DT_CELL_CORE_00`, the 73-cell uniform pool every
  cell core rolls on. The +2 and +3 tiers are in no drop table. The captured Gauntlet store is from a later build,
  and its exclusive gold cores are not in 1.14.7. No change.
- **Verified:** tsc clean; the backend tests: 1,801 pass and the same 3 dataset failures; on the dev stack the
  XP config, the calendar (2026-11-13: Ramsgiving 2026-11-18..12-09) and the telemetry log answer as described.

## D35 — Elite reward claims; Hunt Pass level skips; one-time account credits (2026-11-13)
- **Bugs:** `POST /progression/<user>/<track>/<rank>/confirm/premium` had no route, so Elite reward claims were not
  saved and stayed claimable. `selected_huntpass` (used by level-skip SKUs and by the hub's progress refresh after a
  purchase) resolved to a fixed season or not at all, so a level skip did not show in game.
- **Decision:**
  - `confirm/premium` uses the `confirm/public` handler and records `confirmedPremiumRank` (`$max`, same XP check
    against the track's curve). Repositories gain `setConfirmedPremiumRank`.
  - `selected_huntpass` resolves to the account's selected pass (D31), for the level-skip purchase and for the
    single-track GET, which answers with the real track id.
  - `account_grants.json` gains `credits`: `[{ id, userId, currency }]`, each credited once to that account at its
    next launcher login (marker entitlement `dauntless_nix_credit_<id>`).
- **Verified:** backend build and tests pass (1,617, 0 failures), including new tests for the premium claim and
  credit parsing.

## D36 — Controllers: SDL2 in the client's steam-run sandbox (2026-11-13)
- **Problem:** the game reads controllers through XInput only. Wine's winebus turns a pad into an XInput device when
  SDL2 recognises it as a game controller, but plain `steam-run` ships no `libSDL2`, so pads that the kernel drives
  as generic HID (e.g. a GameSir G7 Pro in HID mode) never reached the game. Steam Input does not help either: it
  applies only to games that Steam itself starts.
- **Chosen:** `nix/pkgs/proton-run.nix` adds SDL2 (sdl2-compat) and SDL3 to the client's `steam-run` (64-bit,
  `extraPkgs`). SDL3 is built without X11, Wayland, OpenGL, Vulkan, audio and input-method backends: Proton's
  `LD_LIBRARY_PATH` puts its own older `libxkbcommon` first, so a full SDL3 fails to load ("version `V_1.10.0' not
  found", seen by sdl2-compat as "Failed loading SDL3 library.") and winebus silently falls back. Servers keep plain
  `steam-run`.
- **Also:** the wrapper's default `WINEDEBUG` drops Proton's `+seh` channel, which grew one session's log to 5 GB;
  `+loaddll`, `+threadname` and `err` stay (they found this bug). Setting `WINEDEBUG` still overrides it.
- **Verified:** inside the new sandbox, with the `LD_LIBRARY_PATH` and `SDL_*` environment taken from a running
  winedevice, SDL2 initialises and reports the HID-mode GameSir as a game controller (`SDL_IsGameController` = 1).
  Confirmed in game with the GameSir G7 Pro.
- **Gotcha:** a relaunch while the game still runs joins the old wineserver, so a fix is only tested after every
  game process has exited.

## D37 — The client wrapper stops Wine after the game exits (2026-11-13)
- **Problem:** Proton's `waitforexitandrun` returns only when every process in the prefix has exited. After the game
  quit, a hung Wine helper (services.exe, explorer.exe, ...) could keep the session, `play`, and the open Proton log
  alive for hours; one such log, already deleted but still held open, grew to 224 GB and filled the disk.
- **Chosen:** `dauntless-proton` runs Proton in the background and watches for the program it started (matched by
  executable name among the processes whose `WINEPREFIX` is this prefix; Proton's `steam.exe` shim is ignored).
  Once that program has exited, Wine gets a grace period (`DAUNTLESS_PROTON_EXIT_GRACE`, default 20 s); if the
  prefix is still running after it, its processes get SIGTERM (the wineserver saves the registry), then SIGKILL after
  3 s. `wineserver -k` did not stop a hung session.
- **Verified:** a `cmd.exe` that leaves a `ping.exe` running: the prefix is stopped 10 s after `cmd.exe` exits and
  no process is left; a program that exits cleanly returns at once, untouched; the prefix starts normally afterwards.
- **Gotcha:** an agent shell with a private `/tmp` cannot reach a Wine session whose prefix is under `/tmp` (the
  wineserver socket lives in `/tmp/.wine-<uid>`); test prefixes belong outside `/tmp`.
