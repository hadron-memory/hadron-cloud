# Postgres backups on alpha

**Hourly** `pg_dump -Fc` of each database in `DATABASES` (currently
`hadron`) plus `pg_dumpall --globals-only` (roles), written to
`/root/backup/` with the `<db>-alpha-YYYY-MM-DD-HHMM` UTC naming
convention, then uploaded offsite to **Hetzner Object Storage**.

This is the platform's **baseline backup** today. The hourly logical dump
is portable and has a documented restore procedure; a full restore test
remains to be done. Dumps were about 360 MiB each on 2026-09-29, so local
retention and disk headroom need monitoring. pgBackRest **streaming** backups
(spec `001-pgbackrest-doppler` in `baragaun-cloud`) remain the planned
*upgrade* for sub-hour RPO and point-in-time recovery.
The two are complementary (PITR + portable logical dumps), not either/or.

## Retention

| Copy | Location | Retention | Pruned by |
|---|---|---|---|
| Local | `/root/backup/` | 7 days | `find -mmin +10080` in `pg-backup.sh` |
| Offsite | `hetzner:hadron-internal/alpha/` | 90 days | `rclone delete --min-age 90d` in `pg-backup.sh` |

The script writes dumps and globals to hidden `.partial` files in the backup
directory. It publishes their final names only after both producers succeed
and each dump passes `pg_restore -l`. The upload filters exclude leftover
`.partial` files if a run is interrupted; ordinary failures remove them. A
second run in the same minute refuses to overwrite completed files.
After a hard kill or power loss, a hidden `.partial` file may remain; it is
excluded from upload and can be removed after confirming no backup is running.

The script then uploads the local set and only then prunes local files beyond
the rolling seven-day window. An upload failure
leaves the local files in place and fails the systemd unit. The offsite
copy uses `rclone copy`, so shortening local retention does not delete
older offsite backups before their separate 90-day cutoff.

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

Before installing a change, run `bash hosts/alpha/backup/test-pg-backup.sh`
locally. It stubs the Postgres and rclone commands in a temporary directory;
it does not contact alpha or Object Storage.

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
- **Disk headroom.** On 2026-09-29, the seven-day local set occupied 51 GB
  and root disk was 68% used with 48 GB free. Monitor both as the DB grows;
  the earlier 5 GB estimate for local dumps is obsolete.
- **MongoDB is not yet covered** (no `mongodump` timer).
- **Host config** (Komodo/Traefik/certs under `/root/komodo/`) is not yet
  in any backup — easy add: tar it into the same job.
