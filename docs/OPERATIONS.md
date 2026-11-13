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
