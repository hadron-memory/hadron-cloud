# Agent ops guide — hadron-cloud

**hadron-cloud** holds the **infrastructure artifacts** for the Hadron Memory platform
(`hadronmemory.com`, `srv.hadronmemory.com`): the OpenTofu project that stands up a host, plus
the runbooks and service config for the live production host **alpha**. This is an **ops repo,
not an application** — there's no build/test step; changes here touch real infrastructure.

> ⚠️ **Production.** `alpha` is the live host (Hadron server/portal/cms + MicroMentor and other
> apps). Treat `tofu apply` and any change against `alpha` as hard-to-reverse: confirm intent,
> review the plan output, and prefer the documented runbooks over ad-hoc changes.

## Layout

- `tofu/hadron-host/` — OpenTofu project: Hetzner Cloud server + firewall, Cloudflare DNS,
  cloud-init bootstrap. Stand up a new host per
  [tofu/hadron-host/README.md](tofu/hadron-host/README.md) (`tofu plan` before `tofu apply`).
- `hosts/alpha/` — runbook + artifacts for the prod host (Hetzner ccx23, Debian 13).
  `nats/`, `redis/`, `backup/` — bare-metal service config, systemd drop-ins, nightly Postgres backup.

## The alpha host (read the README first)

`ssh root@alpha`. Apps (hadron-server, hadron-portal, hadron-cms, plus kcu / mrserver / tapco)
run in **Docker via Komodo** behind **Traefik**; **PostgreSQL 17, MongoDB, Redis, and NATS run
bare metal**. The on-host runbook lives at `/root/CLAUDE.md` on alpha, and the Komodo deploy
workflow at `~/komodo/setup.md` there — consult those for live operations.

## Use of Hadron

No cloud-specific memory yet; operational knowledge lives in the shared `::dev` memory:

- `hrn:memory:hadronmemory.com::dev` — findings, conventions, and especially the **`ops`
  branch** (incidents + runbooks, e.g. `ops:alpha:*`); start at `…::dev::preflight`.
- `hrn:memory:hadronmemory.com::hadron-server` — the app this infra runs (deploy flow, env vars).

Query Hadron before changing infra: `hadron_find_nodes` for the service/symptom, then
`hadron_get_node`; cite `loc`. Capture a new incident or runbook immediately
(`hadron_create_node`, under the `ops` branch). The **Hadron CLI is a superset of the MCP tools.**

## Gotchas worth knowing

- **Bare-metal services that bind Docker gateway IPs need a systemd drop-in ordering them after
  `docker.service`** — otherwise they boot before the bridge interfaces exist and silently fall
  back to localhost-only (containers then can't reach them via `host.docker.internal`).
- **Secrets live in Doppler**, injected at container start (`doppler run --`) — never in the repo.
- DB ports are firewalled externally (Hetzner); access is via SSH. Embeddings run on AWS SageMaker.
- **Single host for now** is a deliberate decision, and MicroMentor stays on alpha for now —
  read the README "Architecture decisions" before proposing a split or a new host.
