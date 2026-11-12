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
- **Chosen:** option 1. The repo owner accepted Microsoft's license terms for the xwin download on 2026-11-13.
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
