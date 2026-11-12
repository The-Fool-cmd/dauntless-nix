# Status

Goal: self-hosted Dauntless 1.14.7 on NixOS (server and two clients), with no Windows machines and no third-party
servers at run time. Phases are listed in order; each one gates the next.

| Phase | State |
|---|---|
| 0. Feasibility: 1.14.7 client under Proton | ✅ Done 2026-11-12 |
| 1. Backend + MongoDB + TLS on NixOS | ✅ Done in VM test 2026-11-13; deploy to the server with phase 5 |
| 2. Game-server topology (Director+Wine vs realms+coturn) | ⏭ Next |
| 3. Linux client path (launcher) | Not started |
| 4. Runtime DLLs without Windows | Not started |
| 5. End to end, two players over the internet | Not started |
| 6. Package and harden | Not started |

## What works
- `nix run .#legendary`: Legendary 0.21.1, pinned.
- 1.14.7 installed from Epic's CDN with the archived manifest (download took 164 s). Every documented check passes:
  - `legendary verify` reports `1.14.7.647472`, "Verification finished successfully";
  - `Dauntless-Win64-Shipping.exe` SHA-256 is `f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b`;
  - `Version.txt` is `dauntless_rel-1.14.7_Shipping_2024-04-01_14-59-21_647472`;
  - there are 611 files.
- `nix build .#proton-run`: `dauntless-proton <prefix> <exe> [args]` runs the exe under the pinned GE-Proton11-1.
- Client boot, on a desktop PC (RTX 4080 SUPER, driver 595.71.05, Hyprland):
  `Dauntless-Win64-Shipping.exe -NoEAC -DisableEOS -EpicPortal -windowed` renders through DXVK/D3D11, plays the
  intro and reaches the front-end screen, which shows "An error occurred while communicating with the game servers"
  (expected with no backend).
- Pre-commit hook: blocks game files, credentials and secrets (gitleaks).
- Phase 1: `nixosModules.server` (backend, MongoDB, nginx, firewall). `nix build .#checks.x86_64-linux.server`
  passes with synthetic data: pong on 80; HTTPS `/`, `/QoS` and launcher status `647472`; only 80 and 443
  reachable; MongoDB socket-only; secrets `0600`; clean log; survives a restart.

## Doesn't work / not yet checked
- Only about 48 s of runtime so far; no long soak.
- The shipping build writes no Unreal log (`Archon.log` holds only open/close lines). Diagnosis will rely on the
  runtime's own logs once the DLLs are in place.
- XMPP over WebSocket through nginx is configured but not exercised by the test yet (it needs a signed-in client).
- Self-signed TLS only. The launcher trusts WebPKI roots, so real play likely needs a domain and ACME (human step).
- Upstream doc drift: SELF_HOSTING.md refers to `ParadoxBackend/.env.p2p.example`, which is not in the repo. The
  `P2P_*` keys are in `ParadoxBackend/src/p2p/config`. `P2P_FORCE_SDR=true` means relay-only ICE over *our own*
  TURN server (not Steam).

## Known risks
- `progression_config.source.json` and `ladyluck_store.source.json` must be *supplied* (captured from the live
  service). They cannot be generated from the client. They may have to be written by hand as minimal valid files.
- The SDK (Dumper-7) and game data (CatalogExporter) are produced by DLLs injected into the running client, which
  needs an MSVC-compatible C++ toolchain. The phase-4 decision therefore partly blocks real game data.
- Epic can remove the 1.14.7 chunks from its CDN at any time. A local pristine copy exists; an off-disk backup is
  still to do.

## Next
1. Phase 2: decide between dedicated hubs and hunts (Director + Wine on the server) and realms + coturn.
   - Topology: the server is the server; the user plays from a desktop PC on the same LAN, and the friend plays
     from another continent.
   - Prototype: headless `-server -nullrhi` boot under Wine/Proton (needs the runtime DLL for the readiness line).
