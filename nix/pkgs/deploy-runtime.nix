# deploy-runtime: put a runtime built on one machine (MysticParadox.dll + winmm.dll; MSVC licence accepted there)
# into a server's Nix store, where the host config pins it with
#   runtime = pkgs.requireFile { name = "dauntless-nix-runtime"; hashMode = "recursive"; hash = "<NAR hash>"; ... };
# An unprivileged SSH user suffices: `nix store add` makes a content-addressed path, no signature or trust needed.
#
#   deploy-runtime <ssh-target> <runtime-dir> [host-module.nix]
#
# With a host module, the hash after `name = "dauntless-nix-runtime";` in it is updated. Rebuilding the server
# (and restarting the game) remains the operator's step.
{ writeShellApplication, coreutils, gawk, nix, openssh }:
writeShellApplication {
  name = "deploy-runtime";
  runtimeInputs = [ coreutils gawk nix openssh ];
  text = ''
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
      echo "usage: deploy-runtime <ssh-target> <runtime-dir> [host-module.nix]" >&2; exit 2
    fi
    target=$1; src=$2; module=''${3:-}
    for f in MysticParadox.dll winmm.dll; do [ -f "$src/$f" ] || { echo "missing $src/$f" >&2; exit 1; }; done
    extra=$(find "$src" -mindepth 1 ! -name MysticParadox.dll ! -name winmm.dll | head -n 1)
    [ -z "$extra" ] || { echo "$src holds more than the two DLLs ($extra); the hash would not match" >&2; exit 1; }

    # The same NAR the server will make: two non-executable files.
    stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
    install -m 0644 "$src/MysticParadox.dll" "$src/winmm.dll" "$stage/"
    hash=$(nix --extra-experimental-features nix-command hash path --type sha256 --sri "$stage")
    echo "runtime NAR hash: $hash"

    remote=dauntless-runtime-upload
    # shellcheck disable=SC2029  # $remote is expanded here on purpose
    ssh "$target" "rm -rf ~/$remote && mkdir -m 0700 ~/$remote"
    scp -q "$stage/MysticParadox.dll" "$stage/winmm.dll" "$target:$remote/"
    # shellcheck disable=SC2029
    added=$(ssh "$target" "chmod 0644 ~/$remote/*.dll && nix --extra-experimental-features nix-command store add --mode nar --name dauntless-nix-runtime ~/$remote && rm -rf ~/$remote")
    # shellcheck disable=SC2029
    remote_hash=$(ssh "$target" "nix --extra-experimental-features nix-command hash path --type sha256 --sri '$added'")
    if [ "$remote_hash" != "$hash" ]; then
      echo "hash mismatch: local $hash, server $remote_hash ($added)" >&2; exit 1
    fi
    echo "on $target: $added"

    if [ -n "$module" ]; then
      awk -v h="$hash" '
        /name = "dauntless-nix-runtime";/ { want = 4 }
        want > 0 && /hash = "sha256-[^"]*";/ { sub(/sha256-[^"]*/, h); want = 0; done = 1 }
        want > 0 { want-- }
        { print }
        END { if (!done) exit 3 }
      ' "$module" > "$module.tmp" || { rm -f "$module.tmp"; echo "no runtime hash found in $module" >&2; exit 1; }
      cat "$module.tmp" > "$module"; rm -f "$module.tmp"
      echo "updated $module; rebuild the server, then restart the game server"
    else
      echo "set the runtime's requireFile hash to $hash, rebuild the server, then restart the game server"
    fi
  '';
}
