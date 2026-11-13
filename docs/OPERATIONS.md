# Operations (dauntless-nix)

## Backups (D32)

`services.dauntless-nix.backup` (on by default) dumps MongoDB with `mongodump --archive --gzip`:

- when the stack starts (`dauntless up`), before the backend: `mongodb-<UTC time>-start.archive.gz`;
- when it stops (`dauntless down`, `dauntless restart`), after the backend has stopped: `…-stop.archive.gz`.

Nothing writes to the database while either dump runs. The files are root-only in `backup.dir`
(default `/var/lib/dauntless-nix-backups`), and the newest `backup.keep` (default 30) are kept. A failed backup does
not stop the backend from starting; check `dauntless logs` for `backup:`. Copy them off the host now and then.

### Restore (as root)

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
