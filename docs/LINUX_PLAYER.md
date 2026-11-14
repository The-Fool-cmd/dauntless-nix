# Playing on a dauntless-nix server from Linux

This guide takes you from nothing to playing Dauntless 1.14.7 on a friend's self-hosted dauntless-nix server. It is
written for NixOS with flakes; other Linux distributions work too once [Nix](https://nixos.org/download) is
installed with flakes enabled. Nothing is installed system-wide: every tool comes from this repository.

dauntless-nix is a modified version of Mystic Paradox (see [NOTICE.md](../NOTICE.md)); it is not the official Mystic
Paradox service.

## Before you start

You need:
- Dauntless in your own Epic Games library (added before it left the store in May 2025). The game files come from
  Epic's servers with your own account; nobody else can give them to you;
- about 17 GB of free disk space.

You exchange with the server operator:

| You send | You get back |
|---|---|
| your WireGuard **public** key (step 2) | your tunnel address (e.g. `10.77.0.2`) |
| | the server address (e.g. `10.77.0.1`), its WireGuard public key and its endpoint (`<address>:51821`) |
| | `server.pem` (the server's TLS certificate) and the runtime public key |

Every command below uses `$R`. Set it again in each new terminal:

    R=github:The-Fool-cmd/dauntless-nix

## 1. Install Dauntless 1.14.7 (once, about 15 GB)

The guide uses `~/Games/dauntless-1.14.7` as its example folder; any folder works. If you choose another one, use
it in every command below and in `config.json` (step 3): nothing else assumes a location. Keep `instance/` on the
same disk as the game: the launcher builds it with hard links there, and makes a full ~16 GB copy otherwise.

    mkdir -p ~/Games/dauntless-1.14.7/manifest && cd ~/Games/dauntless-1.14.7

**Sign in to Epic.** A browser opens. After you sign in, the page shows a short JSON text with an
`authorizationCode`. Paste that code into the terminal only, and never share it:

    nix run $R#legendary -- auth --disable-webview
    nix run $R#legendary -- info Jackal        # must print details about Dauntless

**Get the archived 1.14.7 manifest.** The second command must print
`aa70748e4c0a776a991f2bac10ad342adaa31476`:

    curl -fLo manifest/Dauntless_1.14.7.647472.manifest \
      https://raw.githubusercontent.com/addison2k/DauntlessManifestArchive/26ec6249b6350d8f59f537642445c9bccb29babd/manifests/Windows/Dauntless_1.14.7.647472.manifest
    sha1sum manifest/Dauntless_1.14.7.647472.manifest

**Download the game from Epic's CDN:**

    nix run $R#legendary -- -y install Jackal \
      --manifest ~/Games/dauntless-1.14.7/manifest/Dauntless_1.14.7.647472.manifest \
      --base-url "https://egs-cloudfront-chunks.epicgamescdn.com/Builds/Org/o-krlzxj88qrtb69fredeuaf887bl5az/Jackal/default" \
      --base-path ~/Games/dauntless-1.14.7 --skip-sdl

**Check it.** `verify` must report version `1.14.7.647472` and "Verification finished successfully", and the
checksum must be `f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b`:

    nix run $R#legendary -- verify Jackal
    sha256sum Dauntless/Archon/Binaries/Win64/Dauntless-Win64-Shipping.exe

**Make it read-only.** The launcher plays from a hard-linked working copy and never changes this one:

    chmod -R a-w ~/Games/dauntless-1.14.7/Dauntless

> [!WARNING]
> Never run `legendary update Jackal`, never install without `--manifest`, and never let Heroic or the Epic launcher
> touch this folder. Any of those replaces 1.14.7 with 2.1.1, which cannot play here.

## 2. Connect to the server (WireGuard)

The game reaches the server through a WireGuard tunnel that carries only the game's traffic. Make a key pair; the
second command prints your **public** key, which you send to the operator. The private key never leaves your PC:

    mkdir -p ~/.config
    nix shell nixpkgs#wireguard-tools -c sh -c 'umask 077; wg genkey > ~/.config/dauntless-wg.key; wg pubkey < ~/.config/dauntless-wg.key'

When the operator has added you, write a file `dauntless.conf` with their values and your private key (the content
of `~/.config/dauntless-wg.key`):

    [Interface]
    PrivateKey = <your private key>
    Address = <your tunnel address>/32

    [Peer]
    PublicKey = <server WireGuard public key>
    Endpoint = <server endpoint>:51821
    AllowedIPs = <server address>/32
    PersistentKeepalive = 25

Import it into NetworkManager (no system config change), test it, then delete the file (it holds your private key):

    nmcli connection import type wireguard file dauntless.conf && rm dauntless.conf
    nmcli connection up dauntless
    ping -c 3 <server address>

`AllowedIPs` is only the server's address, so nothing else of yours goes through the tunnel. Bring it down with
`nmcli connection down dauntless` when you like; the app-menu entry (step 5) brings it up for you.

On NixOS you can instead declare the tunnel: import `nixosModules.client` from this flake and set
`services.dauntless-nix-client.wireguard` (see `nix/modules/client.nix`).

## 3. Configure the launcher

Save the operator's `server.pem` as `~/.config/dauntless-nix/server.pem`. Link the Proton wrapper next to the game
(the link also keeps it safe from `nix-collect-garbage`):

    nix build -o ~/Games/dauntless-1.14.7/proton-run $R#proton-run

Then write `~/.config/dauntless-nix/config.json`, filling in the two operator values:

    {
      "server": "https://<server address>",
      "caCertFile": "~/.config/dauntless-nix/server.pem",
      "gameBackendUrl": "http://<server address>:3080",
      "runtimePublicKey": "<runtime public key>",
      "gameDir": "~/Games/dauntless-1.14.7/Dauntless",
      "instanceDir": "~/Games/dauntless-1.14.7/instance/Dauntless",
      "protonRun": "~/Games/dauntless-1.14.7/proton-run/bin/dauntless-proton",
      "protonPrefix": "~/Games/dauntless-1.14.7/prefixes/client"
    }

`server` is the launcher's encrypted connection; `gameBackendUrl` is what the game itself uses (plain HTTP, which
only ever travels inside the tunnel).

## 4. Create your account and play

    nix run $R#launcher -- status          # must say online=true
    nix run $R#launcher -- register        # once: email, display name, password
    nix run $R#launcher -- play

`register` also signs you in, and the launcher stays signed in. If it ever says "not signed in", run
`nix run $R#launcher -- login`.

`play` checks your game files, downloads the game runtime from the server, verifies its signature and starts
Dauntless under Proton. The first start takes a while (Proton sets up its prefix). The first time, the game shows
Phoenix Labs' Terms of Service; accepting them is your own decision.

## 5. Optional: start it from your app menu

This adds a **Dauntless** entry to your application launcher (rofi, fuzzel, GNOME, KDE, …). It brings the tunnel up
if needed and runs `play`; its output goes to `~/.local/state/dauntless-nix/play.log`.

    mkdir -p ~/.local/share/dauntless-nix ~/.local/share/applications
    cat > ~/.local/share/dauntless-nix/play.sh <<'EOF'
    #!/usr/bin/env bash
    # Dauntless app-menu entry: tunnel up (if it is a NetworkManager connection), then the launcher's `play`.
    log="$HOME/.local/state/dauntless-nix/play.log"
    mkdir -p "${log%/*}"; exec >"$log" 2>&1
    fail() { command -v notify-send >/dev/null && notify-send "Dauntless did not start" "$1 (see $log)"; exit 1; }
    if nmcli -t -f NAME connection show | grep -qx dauntless \
       && ! nmcli -t -f NAME connection show --active | grep -qx dauntless; then
        nmcli connection up dauntless || fail "the tunnel did not come up"
    fi
    nix run github:The-Fool-cmd/dauntless-nix#launcher -- play || fail "$(tail -n 1 "$log")"
    EOF
    chmod +x ~/.local/share/dauntless-nix/play.sh
    nix shell nixpkgs#icoutils -c sh -c 'wrestool -x -t 14 ~/Games/dauntless-1.14.7/Dauntless/Dauntless.exe | icotool -x -w 256 -o ~/.local/share/dauntless-nix/icon.png -'
    cat > ~/.local/share/applications/dauntless-nix.desktop <<EOF
    [Desktop Entry]
    Type=Application
    Name=Dauntless
    Comment=Dauntless 1.14.7 on a dauntless-nix server
    Exec=$HOME/.local/share/dauntless-nix/play.sh
    Icon=$HOME/.local/share/dauntless-nix/icon.png
    Categories=Game;
    Terminal=false
    EOF

The icon is taken from your own copy of the game. If the entry does nothing, read the log.

## Updates

`nix run github:…` checks for a newer version of this repository about once an hour, so the launcher updates
itself. To pick up a fix right away, add `--refresh` once: `nix run --refresh $R#launcher -- play`. The runtime
DLLs come from the server on every `play`. Your game install never changes.

The Proton wrapper keeps the GPU driver's shader cache untrimmed, so a stutter caused by a new shader happens only
the first time that shader is seen.

## Troubleshooting

| Problem | What to do |
|---|---|
| `cannot read config` | Check the path and the JSON syntax of `~/.config/dauntless-nix/config.json`. |
| `cannot reach … is your WireGuard tunnel up?` | Bring the tunnel up (`nmcli connection show --active`, `wg show`). Does `ping <server address>` answer? |
| `the server at … is down` | The tunnel works but the game server is stopped (it stops itself after a while with nobody online): ask the operator to start it. |
| `not signed in` | `nix run $R#launcher -- login`. |
| `is not Dauntless 1.14.7` | The game was changed or updated: run the install command of step 1 again, which repairs it. |
| `signature does not verify` | `runtimePublicKey` does not match the server; ask the operator for the current key. |
| `protonRun` not found | Run the `nix build -o …/proton-run` command of step 3 again. |
| Controller ignored | Run the `nix build -o …/proton-run` command of step 3 again (older builds lacked a working SDL), and close Steam first: Steam Input does not reach games started outside Steam. |
| Game says "error communicating with the game servers" | Check `gameBackendUrl`, and `nix run $R#launcher -- status`. |
| App-menu entry does nothing | Read `~/.local/state/dauntless-nix/play.log`. |
