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
