# Postgres backups on alpha

**Hourly** `pg_dump -Fc` of each database in `DATABASES` (currently
`hadron`) plus `pg_dumpall --globals-only` (roles), written to
`/root/backup/` with the `<db>-alpha-YYYY-MM-DD-HHMM` UTC naming
convention, then uploaded offsite to **Hetzner Object Storage**.

This is the platform's **baseline backup** today. For a ~54 MB DB at pilot
scale an hourly full logical dump is cheap (seconds) and trivially
restorable, so it stands on its own. pgBackRest **streaming** backups
(spec `001-pgbackrest-doppler` in `baragaun-cloud`) remain the planned
*upgrade* — pursue them when the DB grows enough that full dumps get heavy,
or when a sub-hour RPO / point-in-time recovery becomes a requirement.
The two are complementary (PITR + portable logical dumps), not either/or.

## Retention

| Copy | Location | Retention | Pruned by |
|---|---|---|---|
| Local | `/root/backup/` | 14 days | `find -mtime +14` in `pg-backup.sh` |
| Offsite | `hetzner:hadron-internal/alpha/` | 90 days | `rclone delete --min-age 90d` in `pg-backup.sh` |

Hetzner's nightly **server snapshots** (enabled separately) also capture
`/root/backup` at daily granularity. The offsite leg here adds hourly
granularity and a logical, portable copy (snapshots are block-level and
won't help with logical/app-level corruption).

## Files

| File | Installed at |
|---|---|
| `pg-backup.sh` | `/usr/local/sbin/pg-backup.sh` (mode 0755) |
| `pg-backup.service` | `/etc/systemd/system/pg-backup.service` |
| `pg-backup.timer` | `/etc/systemd/system/pg-backup.timer` (enabled) — `OnCalendar=*-*-* *:15:00 UTC` |

## Offsite prerequisites (one-time)

The upload uses [rclone](https://rclone.org/) with an S3 remote named
`hetzner` pointing at Hetzner Object Storage.

```bash
ssh root@alpha 'apt-get install -y rclone'
```

`/root/.config/rclone/rclone.conf` (mode **0600**, root-only) holds the
remote. **Credentials are NOT committed to this repo** — they live only on
the host (Doppler-managed is the eventual home). The config shape:

```ini
[hetzner]
type = s3
provider = Other
access_key_id = <HETZNER_OBJECT_STORAGE_ACCESS_KEY>
secret_access_key = <HETZNER_OBJECT_STORAGE_SECRET>
endpoint = https://nbg1.your-objectstorage.com
region = nbg1
acl = private
```

Bucket `hadron-internal` must exist (created in the Hetzner console);
objects land under `alpha/`.

> **Note — same-provider offsite leg.** alpha is itself a Hetzner host, so
> Hetzner Object Storage shares the provider. That's an accepted convenience
> tradeoff for this baseline; spec 001 deliberately targets Backblaze B2 to
> satisfy the 3-2-1 "different provider" goal.

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
ssh root@alpha 'rclone ls hetzner:hadron-internal/alpha/ | tail'   # offsite contents
```

## Restore

Dumps are Postgres custom format (`-Fc`), restored with `pg_restore`. `/root`
is `0700`, so the `postgres` user cannot open files there directly — feed every
file via shell redirection (`<`) so the root shell opens it before privileges
drop to `postgres` (same trick the backup script uses).

```bash
# If restoring from offsite, pull the dump into /root/backup first:
ssh root@alpha 'rclone copy hetzner:hadron-internal/alpha/hadron-alpha-<TS>.dump /root/backup/'

# Inspect the TOC
sudo -u postgres pg_restore -l < /root/backup/hadron-alpha-<TS>.dump | head

# Restore roles first if rebuilding from scratch
sudo -u postgres psql < /root/backup/globals-alpha-<TS>.sql

# Restore into a fresh DB (dumps are made WITHOUT --clean)
sudo -u postgres createdb hadron_restore -O hadron
sudo -u postgres pg_restore -d hadron_restore < /root/backup/hadron-alpha-<TS>.dump
```

**Encrypted columns won't decrypt** unless `HADRON_ENCRYPTION_KEY` matches
the producing host — a restore elsewhere yields ciphertext for those
columns (same caveat as `hadron-server`'s `db:dev-from-prod`).

## Limitations / next steps

- **No failure alerting.** A failing run is only visible in `journalctl`.
  Cheapest fix: a healthchecks.io dead-man's-switch pinged at the end of
  `pg-backup.sh` (and `OnFailure=` on the unit).
- **Disk headroom.** The host root disk runs ~85% full; hourly × 14-day
  local retention is ~5 GB. Now that everything is mirrored offsite for
  90 days, local retention could be shortened (e.g. 2–3 days) to reclaim
  space.
- **MongoDB is not yet covered** (no `mongodump` timer).
- **Host config** (Komodo/Traefik/certs under `/root/komodo/`) is not yet
  in any backup — easy add: tar it into the same job.
