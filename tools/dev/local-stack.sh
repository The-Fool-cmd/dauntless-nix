# dauntless-nix local development stack: the whole server as unprivileged user processes on one machine.
# No root, no system changes, nothing listens beyond 127.0.0.1. Production uses nixosModules.server instead.
#
#   local-stack up      MongoDB (single-node replica set), backend, signed runtime feed, Director + Wine game servers
#   local-stack down    stop everything started by `up`
#   local-stack status  what is running
#   local-stack launcher-config   write a launcher config for this stack and print its path
#
# Environment:
#   DN_DEV_DIR      state directory (default ~/.local/state/dauntless-nix-dev)
#   DN_RUNTIME      directory with MysticParadox.dll + winmm.dll (required for `up`)
#   DN_SERVER_GAME  game copy the servers run from (holds Archon/; Win64 must be writable)
#   DN_CLIENT_GAME  pristine client install;  DN_CLIENT_INSTANCE  client working copy
set -euo pipefail

D=${DN_DEV_DIR:-$HOME/.local/state/dauntless-nix-dev}
BACKEND_PORT=3000
DIRECTOR_PORT=3011
MONGO_PORT=27717
mkdir -p "$D"/{db,logs,secrets,game-data/raw,hunt-data,updates,launcher-logs,backend,debug,director/run,director/logs,director/prefixes,pids}
chmod 0700 "$D/secrets"

pidof_svc() { [ -s "$D/pids/$1" ] && kill -0 "$(cat "$D/pids/$1")" 2>/dev/null && cat "$D/pids/$1"; }
start_bg() {  # name, command...
  local name=$1; shift
  if pidof_svc "$name" >/dev/null; then echo "$name already running"; return; fi
  setsid "$@" >>"$D/logs/$name.log" 2>&1 < /dev/null &
  echo $! > "$D/pids/$name"
  echo "started $name (pid $!), log: $D/logs/$name.log"
}
wait_for() {  # description, command...
  local what=$1; shift
  for _ in $(seq 1 120); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "timed out waiting for $what" >&2; return 1
}

secrets() {
  local f=$D/secrets/backend.env
  touch "$f"; chmod 0600 "$f"
  has() { grep -q "^$1=." "$f"; }
  if ! has AUTH_SIGNING_PRIVKEY_B64; then
    local keys; keys=$(node "$DN_SRC/scripts/generate-selfhost-rsa-key.mjs")
    echo "AUTH_SIGNING_PRIVKEY_B64=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).privateKeyB64)' "$keys")" >> "$f"
    echo "AUTH_SIGNING_PUBKEY_B64=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).publicKeyB64)' "$keys")" >> "$f"
  fi
  for k in GAMESERVER_API_KEYS API_KEY_HASH_SECRET MYSTICPARADOX_METRICS_TOKEN; do has $k || echo "$k=$(openssl rand -hex 32)" >> "$f"; done
}

backend_env() {
  set -a
  # shellcheck disable=SC1091
  . "$D/secrets/backend.env"
  NODE_ENV=production MYSTICPARADOX_SERVICE_ROLE=api PORT=$BACKEND_PORT BIND_HOST=127.0.0.1
  MYSTICPARADOX_TLS_TERMINATED_BY_PROXY=on QOS_PORT=off AUTH_MODE=LAUNCHER ALLOW_NO_AUTH_DEV_MODE=false
  MONGODB_URI="mongodb://127.0.0.1:$MONGO_PORT/?directConnection=true" MONGODB_DB=dauntless MONGODB_APP_NAME=dauntless-dev
  TARGET_CHANGELIST=647472 QOS_TARGET_URL="http://127.0.0.1:$BACKEND_PORT/QoS"
  MATCHMAKING_MODE=DEPLOYSERVER DEPLOYSERVER_URL="127.0.0.1:$DIRECTOR_PORT"
  LAUNCHER_ALLOWED_ORIGINS="http://127.0.0.1:$BACKEND_PORT"
  APPROVED_EXECUTABLE_SHA256=f3f95fbf22709ef077a11632ed95d675b7209b7e0172d9ecb9ba7d02a1fbb66b
  UPDATE_PUBLIC_BASE_URL="http://127.0.0.1:$BACKEND_PORT" LAUNCHER_UPDATE_ROOT="$D/updates"
  LAUNCHER_LOG_STORAGE_DIR="$D/launcher-logs" PARADOX_GAME_DATA_DIR="$D/game-data"
  PARADOX_GAME_DATA_RAW_DIR="$D/game-data/raw" PARADOX_HUNT_DATA_DIR="$D/hunt-data"
  REALTIME_XMPP_ENABLED=true REALTIME_XMPP_CAPTURE=false REALTIME_XMPP_ALLOWED_HOSTS=127.0.0.1 REALTIME_XMPP_DEV_CITY_MUC=false
  MYSTICPARADOX_ADMIN_API=off MYSTICPARADOX_CONSENT_REQUIRED=off MYSTICPARADOX_CONSENT_ENFORCE=off
  MYSTICPARADOX_EMAIL_VERIFICATION=off MYSTICPARADOX_STATUS_MESSAGE="Private server (dauntless-nix dev)" LOG_LEVEL=info
  set +a
}

cmd_up() {
  : "${DN_RUNTIME:?set DN_RUNTIME to a directory with MysticParadox.dll and winmm.dll}"
  : "${DN_SERVER_GAME:?set DN_SERVER_GAME to the game copy the servers run from}"
  # MongoDB: single-node replica set (the backend requires a writable primary)
  start_bg mongod mongod --replSet rs0 --bind_ip 127.0.0.1 --port $MONGO_PORT --dbpath "$D/db" --unixSocketPrefix "$D"
  wait_for mongod mongosh --quiet --port $MONGO_PORT --eval 'db.adminCommand({ping:1}).ok'
  mongosh --quiet --port $MONGO_PORT --eval '
    try { rs.status().ok } catch (e) { rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "127.0.0.1:'$MONGO_PORT'" }] }) }
    for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);'

  secrets
  # Synthetic data unless real files are already there (they are never overwritten).
  for f in "$DN_BACKEND"/lib/backend/game-data/*.example.json; do
    t="$D/game-data/$(basename "$f" .example.json).json"; [ -e "$t" ] || install -m 0644 "$f" "$t"; done
  for f in "$DN_BACKEND"/lib/hunt-data-examples/*.example.json; do
    t="$D/hunt-data/$(basename "$f" .example.json).json"; [ -e "$t" ] || install -m 0644 "$f" "$t"; done

  # Signed runtime feed (same scripts as the module)
  [ -s "$D/secrets/runtime-signing.private.pem" ] || node "$DN_SRC/ParadoxLauncher/scripts/generate-runtime-key.mjs" "$D/secrets/runtime-signing"
  node "$DN_SRC/ParadoxLauncher/scripts/publish-runtime-update.mjs" --dll "$DN_RUNTIME/MysticParadox.dll" \
    --extra "$DN_RUNTIME/winmm.dll" --target client --version "1.0.0-nix.$(sha256sum "$DN_RUNTIME/MysticParadox.dll" | cut -c1-12)" \
    --changelist 647472 --channel stable --output "$D/updates" --base-url "http://127.0.0.1:$BACKEND_PORT" \
    --key "$D/secrets/runtime-signing.private.pem" >/dev/null

  (cd "$D/backend" && backend_env && start_bg backend "$DN_BACKEND/bin/dauntless-nix-backend")
  wait_for backend curl -sf "http://127.0.0.1:$BACKEND_PORT/"

  # Game servers run from DN_SERVER_GAME: put this runtime + the no-branding flags beside the exe.
  W="$DN_SERVER_GAME/Archon/Binaries/Win64"
  install -m 0644 "$DN_RUNTIME/MysticParadox.dll" "$DN_RUNTIME/winmm.dll" "$W/"
  for f in LOGIN CREDITS PRESS_START; do : > "$W/DISABLE_${f}_BRANDING.flag"; done
  rm -f "$W/mystic_loader.ini"
  (
    cd "$D/director/run"
    set -a
    # shellcheck disable=SC1091
    METAGAME_API_KEY=$(grep -m1 '^GAMESERVER_API_KEYS=' "$D/secrets/backend.env" | cut -d= -f2-)
    NODE_ENV=production PORT=$DIRECTOR_PORT BIND_HOST=127.0.0.1 MY_IP=127.0.0.1 PORT_RANGE_BEGIN=8780 PORT_RANGE_END=8790
    GAMESERVER_BINARY_PATH="$DN_GAMESERVER" SECONDS_TO_WAIT_BETWEEN_GAMESERVER_STARTUP=3 GAMESERVER_READY_TIMEOUT_MS=120000
    MAX_CONCURRENT_HUNT_SERVERS=2 PARADOX_GAME_DATA_DIR="$D/hunt-data" GAMESERVER_LOG_DIR="$D/director/logs"
    SERVER_RUNTIME_AUTO_UPDATE=false SERVER_RUNTIME_UPDATE_REQUIRED=false RAMSGATE_HUB=on TRAINING_HUB=on LOG_LEVEL=info
    MYSTICPARADOX_BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"
    DAUNTLESS_GAME_DIR="$DN_SERVER_GAME" DAUNTLESS_PREFIX_ROOT="$D/director/prefixes"
    set +a
    start_bg director "$DN_DIRECTOR/bin/dauntless-nix-director"
  )
  echo "waiting for Ramsgate and the Training Grounds..."
  wait_for "Ramsgate" grep -q 'ready on 127.0.0.1:8790' "$D/logs/director.log"
  wait_for "Training Grounds" grep -q 'ready on 127.0.0.1:8789' "$D/logs/director.log"
  echo "stack up: backend http://127.0.0.1:$BACKEND_PORT, Ramsgate udp 8790"
}

cmd_down() {
  for svc in director backend mongod; do
    if pid=$(pidof_svc $svc); then kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"; echo "stopped $svc"; fi
    rm -f "$D/pids/$svc"
  done
  # Game servers: one wineserver per port prefix.
  for p in "$D"/director/prefixes/port-*; do [ -d "$p" ] && WINEPREFIX=$p "$DN_WINESERVER" -k 2>/dev/null || true; done
}

cmd_status() {
  for svc in mongod backend director; do printf '%-9s %s\n' "$svc" "$(pidof_svc $svc >/dev/null && echo running || echo stopped)"; done
  grep -hoE '(ramsgate|training_dojo|[A-Za-z_]+) ready on [0-9.:]+' "$D/logs/director.log" 2>/dev/null | tail -4 || true
}

cmd_launcher_config() {
  : "${DN_CLIENT_GAME:?}" "${DN_CLIENT_INSTANCE:?}"
  local cfg=$D/launcher.json
  node -e '
    const [cfg, key, game, inst, proton, prefix] = process.argv.slice(1);
    require("fs").writeFileSync(cfg, JSON.stringify({ server: "http://127.0.0.1:'$BACKEND_PORT'", gameBackendUrl: "http://127.0.0.1:'$BACKEND_PORT'",
      runtimePublicKey: require("fs").readFileSync(key, "utf8").trim(), gameDir: game, instanceDir: inst,
      protonRun: proton, protonPrefix: prefix }, null, 2));' \
    "$cfg" "$D/secrets/runtime-signing.public.raw.b64" "$DN_CLIENT_GAME" "$DN_CLIENT_INSTANCE" "$DN_PROTON_RUN" "$D/client-prefix"
  echo "$cfg"
}

case "${1:-}" in
  up) cmd_up ;; down) cmd_down ;; status) cmd_status ;; launcher-config) cmd_launcher_config ;;
  *) echo "usage: local-stack up|down|status|launcher-config" >&2; exit 64 ;;
esac
