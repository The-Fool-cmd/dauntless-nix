# Status

Goal: self-hosted Dauntless 1.14.7 on NixOS (server and two clients), with no Windows machines and no third-party
servers at run time. Phases are listed in order; each one gates the next.

| Phase | State |
|---|---|
| 0. Feasibility: 1.14.7 client under Proton | ✅ Done 2026-11-12 |
| 1. Backend + MongoDB + TLS on NixOS | ✅ Done in VM test 2026-11-13; deployed with phase 5 |
| 2. Game-server topology (Director+Wine vs realms+coturn) | ✅ Decided 2026-11-13: dedicated hubs/hunts under Wine (D17) |
| 3. Linux client path (launcher) | ✅ Minimal launcher (D21); real client logs in off-screen (D23) |
| 4. Runtime DLLs without Windows | ✅ Built in Nix (D13–D16); loaded by real client and servers |
| 5. End to end, two players over the internet | ⏭ In progress: deployed, play-testing |
| 6. Package and harden | Not started |

## What works
- `nix run .#legendary`: Legendary 0.21.1, pinned.
- 1.14.7 installed from Epic's CDN with the archived manifest (download took 164 s). Every documented check passes:
  - `legendary verify` reports `1.14.7.647472`, "Verification finished successfully";
  - `Dauntless-Win64-Shipping.exe` SHA-256 is `f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b`;
  - `Version.txt` is `dauntless_rel-1.14.7_Shipping_2024-04-01_14-59-21_647472`;
  - there are 611 files.
- `nix build .#proton-run`: `dauntless-proton <prefix> <exe> [args]` runs the exe under the pinned GE-Proton11-1.
- Client boot, on a desktop PC (NVIDIA, Wayland):
  `Dauntless-Win64-Shipping.exe -NoEAC -DisableEOS -EpicPortal -windowed` renders through DXVK/D3D11, plays the
  intro and reaches the front-end screen, which shows "An error occurred while communicating with the game servers"
  (expected with no backend).
- Pre-commit hook: blocks game files, credentials and secrets (gitleaks).
- Phase 1: `nixosModules.server` (backend, MongoDB, nginx, firewall). `nix build .#checks.x86_64-linux.server`
  passes with synthetic data: pong on 80; HTTPS `/`, `/QoS` and launcher status `647472`; only 80 and 443
  reachable; MongoDB socket-only; secrets `0600`; clean log; survives a restart.

- Phase 2 and 4 work (details in DECISIONS D12–D18):
  - `winmm.dll` is cross-built with MinGW and verified loading DLLs inside the 1.14.7 process under Proton.
  - Dumper-7 is built with clang-cl and the MSVC SDK, injected through `mystic_loader.ini`; the SDK dumped in 14 s.
  - `MysticParadox.dll` builds with 0 errors, and all ~225k SDK layout `static_assert`s pass under clang-cl.
  - A headless Ramsgate or Training Grounds server under Wine prints `MYSTICPARADOX_GAMESERVER_READY`.
  - `dauntless-gameserver` (the Director's `GAMESERVER_BINARY_PATH`) has a ready → SIGTERM → clean-exit cycle.

- Phase 3 (D21–D23):
  - `nixosModules.client` with `dauntless-nix-launcher`; the signed runtime feed on the server.
  - The VM test covers register, login, signed sync, exchange code and bad-signature refusal over WireGuard.
  - On real hardware: the 1.14.7 client logs in to our backend off-screen and shows "Logged in as".
- Director and WireGuard modules (D20): game ports only through the tunnel, no forwarding into the LAN
  (negative-controlled), Director API on loopback.
- Network containment (D38): opt-in `allowedNetworks` confines the backend and game servers to localhost and the
  tunnel; `wireguard.firewallInterfaces` scopes the WireGuard port to the forwarded interface.

- Game data (D24): CatalogExporter is built in Nix and ran off-screen against our own install. `progression_config`
  is assembled for all 23 non-Hunt-Pass XP tracks (player, weapons, mastery, reforge) and accepted by upstream's
  generator; the backend loads it with no warnings.

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
- Epic can remove the 1.14.7 chunks from its CDN at any time. A local pristine copy exists; an off-disk backup is
  still to do.

## Next
First real play-test 2026-11-13: login and Ramsgate work on the deployed server (D25–D27).
1. Hunts: tables exported and deployed (D28): 154 of 161 player hunts resolve and a hunt server boots its map on
   the server. The 7 Expedition islands have no matchmaker rows in 1.14.7 (removed content, D39). Empty hunt
   servers exit on their own (60 s after the last player, 5 min if nobody joined; D39).
   A hunt was play-tested on 2026-11-13: it loaded quickly, ran smoothly and paid rewards.
2. D33: Hunt Pass XP rules and an annual event calendar are served; Trials leaderboards wait for the result path.
   Game data is real (D29): Hunt Passes season43..50, weapon prestige and reforge Aetherhearts, Slayer's Path,
   mastery objectives, Reward Cache, Lady Luck, platinum store. Still to do: play-test it in game. (Heroic Escalation
   tuning only checks saves from player-hosted servers; not needed with dedicated servers, D39.)
   D30: every account gets all premium passes, VIP (`ent_boost_vip`), `cc_premium` and 500 Platinum once; the 40
   cosmetic passes (vaults, event and Reward Cache passes) are served. Still to check in game: whether the client
   lists the cosmetic passes and how it switches the selected pass. In game: listed, selectable, elite visible (D30);
   the selection is now saved (D31).
   D40: the event schedule no longer serves the items the capture had switched off (among them
   `Ramsgate_HuntPass_Starts`, parked in 3020), the likely reason passes showed as inactive; to confirm in game.
   New characters start with 10 Rare Cell Cores (`starterItems`).
3. Operations: MongoDB backups done (D32); `dauntless collect-logs` and `deploy-runtime` done (D39). Still to do:
   check that progression persists across a restart. The fountain coin toss needs `fountain_daily_bundle.json` in
   the game data (D39).
4. Remote player onboarding over WireGuard; play-test a party and a hunt together.
5. Report the Dumper-7 Blueprint-lookup bug upstream (D27).

Player guide: docs/LINUX_PLAYER.md.
