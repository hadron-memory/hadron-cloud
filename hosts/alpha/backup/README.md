# Postgres backups on alpha

Nightly `pg_dump -Fc` of each database in `DATABASES` (currently
`hadron`) plus `pg_dumpall --globals-only` (roles), written to
`/root/backup/` with the `<db>-alpha-YYYY-MM-DD-HHMM` UTC naming
convention. Retention: 14 days, pruned by the same script.

| File | Installed at |
|---|---|
| `pg-backup.sh` | `/usr/local/sbin/pg-backup.sh` (mode 0755) |
| `pg-backup.service` | `/etc/systemd/system/pg-backup.service` |
| `pg-backup.timer` | `/etc/systemd/system/pg-backup.timer` (enabled) |

## Install / update

```bash
scp hosts/alpha/backup/pg-backup.sh root@alpha:/usr/local/sbin/pg-backup.sh
scp hosts/alpha/backup/pg-backup.{service,timer} root@alpha:/etc/systemd/system/
ssh root@alpha 'chmod 755 /usr/local/sbin/pg-backup.sh && systemctl daemon-reload && systemctl enable --now pg-backup.timer'
```

## Operate

```bash
ssh root@alpha systemctl start pg-backup.service        # run now
ssh root@alpha systemctl list-timers pg-backup.timer    # next run
ssh root@alpha journalctl -u pg-backup.service -n 30    # last log
```

## Restore

```bash
# Inspect
cat /root/backup/hadron-alpha-<TS>.dump | sudo -u postgres pg_restore -l | head

# Restore into a fresh DB (never use dumps made with --clean)
sudo -u postgres createdb hadron_restore -O hadron
cat /root/backup/hadron-alpha-<TS>.dump | sudo -u postgres pg_restore -d hadron_restore
```

## Limitations / next steps

- **Same-disk only.** Hetzner's nightly server snapshots (enabled) are
  the current off-host story; they capture `/root/backup` too, but a
  disk loss between snapshot and dump loses up to a day. Next step if
  wanted: rclone the dumps to a Hetzner Storage Box or S3.
- MongoDB is not yet covered (no `mongodump` timer).
