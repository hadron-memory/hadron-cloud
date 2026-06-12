# Hadron Cloud

Infrastructure artifacts for the Hadron Memory platform
(`hadronmemory.com`, `srv.hadronmemory.com`).

## Layout

| Path | What |
|---|---|
| `tofu/hadron-host/` | [OpenTofu](https://opentofu.org/) project that stands up a Hadron host on Hetzner Cloud (server, firewall, Cloudflare DNS, cloud-init bootstrap). |
| `hosts/alpha/` | Artifacts and runbook for the existing production host `alpha` (Hetzner ccx23, Debian 13, `5.78.186.49`). |
| `hosts/alpha/nats/` | NATS server config + systemd drop-in (bare metal, apt). |
| `hosts/alpha/redis/` | Redis config notes + systemd drop-in (bare metal, apt). |
| `hosts/alpha/backup/` | Nightly Postgres backup script + systemd timer. |

## The alpha host

`ssh root@alpha`. The host carries:

- **Hadron**: `hadron-server`, `hadron-portal`, `hadron-cms` (Docker, deployed by Komodo)
- **Other apps that must stay**: `kcu`, `mrserver`, `tapco` (Market Railz)
- **Komodo** + **Traefik**: deployment manager and reverse proxy
- **Bare metal services**: PostgreSQL 17, MongoDB, Redis, NATS

Bare-metal services bind `127.0.0.1` plus the Docker gateway IPs
(`172.17.0.1` bridge, `172.18.0.1` komodo_default) so containers reach
them via `host.docker.internal`. Each bare-metal service that binds a
Docker gateway IP needs a systemd drop-in ordering it after
`docker.service` — otherwise it boots before the bridge interfaces
exist and silently falls back to localhost-only.

The Hetzner firewall blocks the database ports externally; access goes
through SSH.

See the on-host runbook (`/root/CLAUDE.md` on alpha) for operational
guidance, and `~/komodo/setup.md` there for the Komodo deployment
workflow.

## Architecture decisions

- **Single host for now.** A ccx23 (4 vCPU, 16 GB, 160 GB, ~$40/mo) is
  sized right; Redis and NATS add negligible load at pilot scale.
- **Postgres, MongoDB, Redis, NATS run bare metal**; apps run in Docker
  via Komodo. Bare metal keeps the data services easy to maintain.
- **MicroMentor stays on alpha for now.** If/when they need their own
  host, the likely path is moving to AWS entirely (RDS, ElastiCache)
  rather than running split-brain across two Hadron accounts/MCP servers.
- **Embeddings stay on AWS SageMaker.**
- **Secrets** live in Doppler, injected at container start (`doppler run --`).

## Standing up a new host

See [tofu/hadron-host/README.md](tofu/hadron-host/README.md).
