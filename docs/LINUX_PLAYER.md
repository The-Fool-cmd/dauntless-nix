# Playing on a dauntless-nix server from Linux

This guide is for a player joining a self-hosted dauntless-nix server from a Linux PC (written for NixOS with flakes;
other distributions need Nix installed). dauntless-nix is a modified version of Mystic Paradox (see NOTICE.md); it
is not the official Mystic Paradox service.

You need:
- Dauntless in your own Epic Games library (added before it left the store in May 2025);
- about 17 GB free disk space;
- from the server operator: the server address (e.g. `10.77.0.1`), the server's WireGuard public key and public
  endpoint, the server's TLS certificate (`server.pem`) and its runtime public key.

The game files come from Epic's own servers with your own account. Nobody else can give them to you.

## 1. Install Dauntless 1.14.7

All commands use the tools pinned by this repository. Nothing is installed system-wide.

    R=github:The-Fool-cmd/dauntless-nix
    mkdir -p ~/Games/dauntless-1.14.7/manifest && cd ~/Games/dauntless-1.14.7

**Sign in to Epic.** A browser opens. After signing in, the page shows a short JSON text with an
`authorizationCode`. Paste that code into the terminal only, and never share it:

    nix run $R#legendary -- auth --disable-webview
    nix run $R#legendary -- info Jackal        # must print details about Dauntless

**Get the archived 1.14.7 manifest** and check it. The SHA-1 must be
`aa70748e4c0a776a991f2bac10ad342adaa31476`:

    curl -fLo manifest/Dauntless_1.14.7.647472.manifest \
      https://raw.githubusercontent.com/addison2k/DauntlessManifestArchive/26ec6249b6350d8f59f537642445c9bccb29babd/manifests/Windows/Dauntless_1.14.7.647472.manifest
    sha1sum manifest/Dauntless_1.14.7.647472.manifest

**Download about 15 GB from Epic's CDN:**

    nix run $R#legendary -- -y install Jackal \
      --manifest ~/Games/dauntless-1.14.7/manifest/Dauntless_1.14.7.647472.manifest \
      --base-url "https://egs-cloudfront-chunks.epicgamescdn.com/Builds/Org/o-krlzxj88qrtb69fredeuaf887bl5az/Jackal/default" \
      --base-path ~/Games/dauntless-1.14.7 --skip-sdl

**Check the result.** `verify` must report version `1.14.7.647472` and "Verification finished successfully", and
the SHA-256 must be `f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b`:

    nix run $R#legendary -- verify Jackal
    sha256sum Dauntless/Archon/Binaries/Win64/Dauntless-Win64-Shipping.exe

**Keep this copy pristine.** The launcher plays from a hard-linked working copy and never changes it:

    chmod -R a-w ~/Games/dauntless-1.14.7/Dauntless

Never run `legendary update Jackal`, never install without `--manifest`, and never let Heroic or the Epic launcher
touch this folder. Any of those replaces 1.14.7 with 2.1.1.

## 2. Connect to the server (WireGuard)

Every player reaches the server through a WireGuard tunnel that only carries the game (players on the server's own
LAN too: use the server's LAN address as `Endpoint`). Make a key pair and send
the **public** key to the operator. The private key stays on your PC:

    nix shell nixpkgs#wireguard-tools -c sh -c 'umask 077; wg genkey > ~/.config/dauntless-wg.key; wg pubkey < ~/.config/dauntless-wg.key'

**Without changing your system config (NetworkManager):** write `dauntless.conf`, filling in the operator's values
and your own private key:

    [Interface]
    PrivateKey = <contents of ~/.config/dauntless-wg.key>
    Address = <your tunnel address from the operator, e.g. 10.77.0.2/32>

    [Peer]
    PublicKey = <server WireGuard public key>
    Endpoint = <server public address>:51821
    AllowedIPs = <server address>/32
    PersistentKeepalive = 25

    nmcli connection import type wireguard file dauntless.conf
    nmcli connection up dauntless      # `down` when you are done playing

`AllowedIPs` is only the server's address, so nothing else of yours goes through the tunnel.

**Or declaratively (NixOS):** import `nixosModules.client` from this flake and set
`services.dauntless-nix-client.wireguard` (see `nix/modules/client.nix`).

## 3. Configure the launcher

Save the operator's `server.pem` as `~/.config/dauntless-nix/server.pem`, then write
`~/.config/dauntless-nix/config.json`:

    {
      "server": "https://<server address>",
      "caCertFile": "~/.config/dauntless-nix/server.pem",
      "gameBackendUrl": "http://<server address>:3080",
      "runtimePublicKey": "<runtime public key from the operator>",
      "gameDir": "~/Games/dauntless-1.14.7/Dauntless",
      "instanceDir": "~/Games/dauntless-1.14.7/instance/Dauntless",
      "protonRun": "<output of: nix build --print-out-paths github:The-Fool-cmd/dauntless-nix#proton-run>/bin/dauntless-proton",
      "protonPrefix": "~/Games/dauntless-1.14.7/prefixes/client"
    }

`gameBackendUrl` is the address the game itself uses (`MYSTICPARADOX_BACKEND_URL`): plain HTTP on the server's
`plainHttpPort`, e.g. `http://10.77.0.1:3080`. It is not the same as `server`. It is unencrypted only inside the
WireGuard tunnel or your LAN.

## 4. Play

    nix run $R#launcher -- register        # once: email, display name, password
    nix run $R#launcher -- login
    nix run $R#launcher -- play

`play` checks your game files, downloads the game runtime from the server and verifies its signature, then starts
Dauntless under Proton. The first time, the game shows Phoenix Labs' Terms of Service. Accepting them is your own
decision.

## Troubleshooting

| Problem | What to do |
|---|---|
| `cannot read config` | Check the path and the JSON syntax of `~/.config/dauntless-nix/config.json`. |
| `POST … HTTP 000` / timeout | Is the tunnel up (`nmcli connection show --active`)? Can you `ping <server address>`? |
| `is not Dauntless 1.14.7` | The game was changed or updated: run the install command of step 1 again, which repairs it. |
| `signature does not verify` | `runtimePublicKey` does not match the server; ask the operator for the current key. |
| Game shows "error communicating with the game servers" | Check `gameBackendUrl` and that the server is up (`nix run $R#launcher -- status`). |
