# alpha

Production host for Hadron Memory. Hetzner ccx23 (4 dedicated vCPU,
16 GB, 160 GB), Debian 13, location `hil` (us-west), instance
`123035399`, IP `5.78.186.49`. `ssh root@alpha`.

The operational runbook lives on the host (`/root/CLAUDE.md`); the
Komodo deployment workflow is in `/root/komodo/setup.md` (a copy is in
baragaun-cloud `hosts/alpha/`). This directory holds the config
artifacts this repo manages on alpha.

## Bare-metal services

| Service | Port | Bind | Source |
|---|---|---|---|
| PostgreSQL 17 | 5432 | localhost + 172.17.0.1 + 172.18.0.1 | Debian |
| MongoDB 8.0 | 27017 | 0.0.0.0 (Hetzner firewall blocks external) | repo.mongodb.org |
| Redis | 6379 | localhost + 172.17.0.1 + 172.18.0.1 | packages.redis.io |
| NATS 2.10 | 4222 | 0.0.0.0 (Hetzner firewall blocks external) | Debian |

Containers reach all of these via `host.docker.internal` (added per
deployment with `--add-host=host.docker.internal:host-gateway`).

**Boot ordering:** every service binding a Docker gateway IP has a
`wait-for-docker.conf` systemd drop-in (After/Wants `docker.service`).
Without it the service starts before the Docker bridges exist, logs
only a WARNING, and comes up localhost-only.

**Redis auth:** currently none (`protected-mode no`, no `requirepass`).
Any container on the host can use it. Adding `requirepass` requires
coordinating a password into the apps' Doppler configs first.

**NATS auth:** currently none, same trust model as Redis. Monitoring
endpoint on `127.0.0.1:8222`.

## Subdirectories

- `nats/` — `/etc/nats/nats-server.conf` + systemd drop-in
- `redis/` — systemd drop-in + the managed `bind` line
- `backup/` — nightly Postgres dump script, service, timer

## Apps (Docker, via Komodo)

`hadron-server` (:10300), `hadron-portal` (:10400), `hadron-cms`,
plus Market Railz apps that must stay: `kcu`, `mrserver`, `tapco`.
Traefik terminates TLS (Cloudflare full/strict) and routes by hostname.
