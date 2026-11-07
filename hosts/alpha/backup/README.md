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
| Local | `/root/backup/` | **12 hours** (`RETENTION_HOURS=12`, since 2026-11-07) | `prune_local` in `pg-backup.sh`, on every exit |
| Offsite hourly | `hetzner:baragaun-alpha-backups/hourly/` | 3 days | bucket lifecycle rule |
| Offsite daily | `hetzner:baragaun-alpha-backups/daily/` | 30 days | bucket lifecycle rule |
| Offsite weekly | `hetzner:baragaun-alpha-backups/weekly/` | 90 days | bucket lifecycle rule |

- **Local prune guard.** A local dump or globals file older than `RETENTION_HOURS` is deleted only when the `hourly/` listing has an object of the same name and size. If the listing fails, every aged file is kept. Empty files are removed. The prune runs from the EXIT trap, so it also runs after a failed dump or upload.
- **Off-site.** The script never deletes off-site objects; the bucket's lifecycle rules expire them. Each run uploads with `rclone copy --max-age 3h`, so a missed upload heals on the next run, but an old local file is never re-uploaded. The first run of each UTC day copies that run's files server-side to `daily/`, and on Sundays to `weekly/`.
- **Why 12 hours.** On 2026-11-07 dumps were 1.4 GB each and two days of hourly dumps held 59 GB. The off-site tiers are the longer history, so local copies only cover the most recent half day (Holger, 2026-11-07).
- **Operator flags.** `PG_BACKUP_PRUNE_ONLY=1` skips the dump and upload; `PG_BACKUP_PRUNE_DRY=1` prints `would-prune:` instead of deleting. `PG_BACKUP_DIR` overrides `/root/backup`.

> **Not staged (finding, 2026-11-07).** The live script writes each dump and the globals file **directly to its final name**. The `.partial` staging, the publish-by-hard-link and the same-minute overwrite refusal from #8 are not in the script running on alpha, so a dump that fails or is interrupted leaves a truncated file under a final name, and the next run's `rclone copy` may upload it. `pg_restore -l` still checks each dump, and a failure fails the unit. `test-pg-backup.sh` encodes #8's behavior and fails against this script; it is the acceptance test for restoring the staging.

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

Bucket `baragaun-alpha-backups` must exist (created in the Hetzner console, 2026-10-28) with lifecycle rules expiring `hourly/` after 3 days, `daily/` after 30 and `weekly/` after 90. The old bucket `hadron-internal/alpha/` is no longer written.

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
ssh root@alpha 'rclone ls hetzner:baragaun-alpha-backups/hourly/ | tail'   # offsite contents
ssh root@alpha PG_BACKUP_PRUNE_ONLY=1 PG_BACKUP_PRUNE_DRY=1 /usr/local/sbin/pg-backup.sh   # what the local prune would delete
```

## Restore

Dumps are Postgres custom format (`-Fc`), restored with `pg_restore`. `/root`
is `0700`, so the `postgres` user cannot open files there directly — feed every
file via shell redirection (`<`) so the root shell opens it before privileges
drop to `postgres` (same trick the backup script uses).

```bash
# If restoring from offsite, pull the dump into /root/backup first:
ssh root@alpha 'rclone copy hetzner:baragaun-alpha-backups/hourly/hadron-alpha-<TS>.dump /root/backup/'   # or daily/, weekly/

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
- **Existing final-named files need an operator audit before installation.**
  This change cannot identify or repair a partial file written by the old
  script. The next `rclone copy` still considers all matching final names.
  Inspect existing dumps with `pg_restore -l` and investigate missing or
  suspicious globals; quarantine suspect files before a new upload. The TOC
  check is not a full restore test. No such audit is performed by this PR.
- **Disk headroom.** On 2026-11-07, two days of hourly dumps (1.4 GB each) held 59 GB with the root disk at 80%. That prompted the 12-hour local retention. The local set now grows only with dump size, about 12 × the dump size. The host manager's prod-health tick reports above 85%.
- **MongoDB is not yet covered** (no `mongodump` timer).
- **Host config** (Komodo/Traefik/certs under `/root/komodo/`) is not yet
  in any backup — easy add: tar it into the same job.
