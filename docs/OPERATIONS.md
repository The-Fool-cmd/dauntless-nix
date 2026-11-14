# Operations (dauntless-nix)

Day-to-day tasks for the operator of a server running `nixosModules.server`. Players follow
[LINUX_PLAYER.md](LINUX_PLAYER.md).

## Commands

Over SSH on the server: `dauntless up` (start), `down`, `restart`, `status`, `logs [-f]` (`LINES_BACK=n` for more
lines; extra arguments go to `journalctl`, e.g. `--since today`), and `season [ID|default]` (the default Hunt Pass).
It starts at boot unless `services.dauntless-nix.autoStart = false` (then only `dauntless up` starts it).

`dauntless collect-logs` (D39) gathers the last two days of logs that only root can read (Director, every game
server's output and DLL log, backend debug, launcher uploads) plus the journal into
`/var/lib/dauntless-nix-logs/dauntless-logs-<UTC time>.tar.gz`, readable by `dauntless-operators` only, and prints
its path. The five newest archives are kept. They hold account names and ids: share them with care.

### Players and grants (D41)

- `dauntless who`: every game client heard from in the last minute (name, menu/Ramsgate/hunt, map, ping), from the
  heartbeat each client sends every 20 s, and the game servers the Director runs.
- `dauntless grant ACCOUNT ITEM QUANTITY [ITEM QUANTITY ...]`: pays stacked items or currencies at once to the
  account's character (ACCOUNT is the launcher name or the user id; `platinum` is short for
  `CURRENCY_PLATINUM_UNIV`). Only ids the 1.14.7 storage policy lists as stacked are accepted, so weapons and armour
  cannot be granted this way. The game shows the grant after its next inventory refresh; a relog always does. The
  log line is `[Operator] grant <user> (<name>): ...`. Example: `dauntless grant Slayer CONTAINER_CORE_GOLD_CELLCORE 5`.
- `dauntless reload`: copies changed files from `gameDataDir` into the server now and lists them.
  `account_grants.json`, `seasonal_event_schedule.json` and `huntpass_xp_config.json` take effect at once; every
  other file is read once per start and needs `dauntless restart`.

Both commands use a loopback-only operator API (`/operator/v1`, token in
`/var/lib/dauntless-nix-settings/operator.token`, readable by `dauntless-operators`). The backend refuses any request
that came through nginx, and nginx refuses the path as well.

### Idle auto-stop (D41)

With `idleStop.minutes` (default 30; `null` turns it off), the server stops itself, backup included, once no game
client has sent a heartbeat and no hunt server has run for that long. The journal says
`nobody online for N min, stopping the server`. It never starts the server. Nothing in the game runs on a server-side
timer: cooldowns, daily and weekly resets and the Hunt Pass are stored as times and computed when asked, so a
stopped server loses nothing.

## Updating the runtime (D39)

The runtime DLLs are built where the MSVC licence was accepted, then pinned in the host config with
`pkgs.requireFile { name = "dauntless-nix-runtime"; hashMode = "recursive"; hash = ...; }`. From the build machine:

```bash
nix run .#deploy-runtime -- <user>@<server> <runtime build output> [path/to/host-module.nix]
```

It copies the two DLLs, adds them to the server's Nix store as that (unprivileged) user, checks that the server's
NAR hash matches the local one, and, given the host module, rewrites the pinned hash. Then rebuild the server and
`dauntless restart`.

## Backups (D32)

`services.dauntless-nix.backup` (on by default) dumps MongoDB with `mongodump --archive --gzip`:

- when the stack starts (`dauntless up`), before the backend: `mongodb-<UTC time>-start.archive.gz`;
- when it stops (`dauntless down`, `dauntless restart`), after the backend has stopped: `…-stop.archive.gz`.

Nothing writes to the database while either dump runs. The files are root-only in `backup.dir`
(default `/var/lib/dauntless-nix-backups`, listable by `dauntless-operators`: `dauntless backups`). The newest
`backup.keep` (default 30) are kept, and the oldest go first while all of them together are over
`backup.maxTotalMiB` (default 2048; the newest two always stay). A failed backup does
not stop the backend from starting; check `dauntless logs` for `backup:`. Copy them off the host now and then.

### Restore

`dauntless restore NAME` (no root; NAME from `dauntless backups`) asks for confirmation, stops the stack (its stop
backup is the safety copy), checks the archive with `--dryRun`, restores it with `--drop`, and leaves the server
down: start it with `dauntless up`. By hand, as root:

```sh
dauntless down
systemctl start podman-dauntless-mongodb.service dauntless-mongodb-rs-init.service
f=/var/lib/dauntless-nix-backups/mongodb-<time>-stop.archive.gz
podman exec -i dauntless-mongodb mongorestore --dryRun --archive --gzip < "$f"   # check first
podman exec -i dauntless-mongodb mongorestore --drop --archive --gzip < "$f"
dauntless up
```

`--drop` replaces every collection that the archive holds with the archived one. The game-data files are not
in the database; they come from `gameDataDir` on every start.

## Setting a player's password (forgotten password)

Passwords are stored only as Argon2id hashes (`passwordHash` in `dauntless.accounts`). A password cannot be
recovered; it can be replaced. Over SSH on the server, with the stack up:

```sh
B=$(systemctl show -p ExecStart --value dauntless-backend | grep -o '/nix/store/[^ ;]*-dauntless-nix-backend-[^ ;/]*' | head -1)
NODE=$(grep -o '/nix/store/[^ ]*/bin/node' "$B/bin/dauntless-nix-backend" | head -1)
read -rsp 'New password: ' P; echo
H=$(cd "$B/lib/backend" && "$NODE" -e 'require("@node-rs/argon2").hash(process.argv[1]).then(console.log)' "$P"); unset P
sudo podman exec -e E='player@example.com' -e H="$H" dauntless-mongodb mongosh --quiet dauntless \
  --eval 'printjson(db.accounts.updateOne({ email: process.env.E }, { $set: { passwordHash: process.env.H } }))'
```

`matchedCount: 1` means it was set (the email is stored in lower case). The player signs in with the new password.

## Crediting a player (D35)

Add an entry to `credits` in `account_grants.json` in the server's game-data directory (no root needed):

```json
"credits": [{ "id": "credit_1", "userId": "<account uuid>", "currency": { "CURRENCY_PLATINUM_UNIV": 150 } }]
```

For a one-off credit, `dauntless grant` (above) is quicker. A file credit is paid once, at that player's next launcher login (D41: after `dauntless reload`, no restart needed); the log shows
`[AccountGrants] <user> credit <id>`. Keep the entry: its id is what stops a second payment. Use a new id for a new
credit.
