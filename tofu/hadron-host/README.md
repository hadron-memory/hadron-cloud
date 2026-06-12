# hadron-host (OpenTofu)

Stands up a Hadron host on Hetzner Cloud: server (ccx23, Debian 13),
firewall, Cloudflare DNS records, and a cloud-init bootstrap that
installs Docker, PostgreSQL 17 (+pgvector), MongoDB 8, Redis, and NATS
the same way alpha runs them (data services bare metal, apps in Docker).

## Usage

```bash
cd tofu/hadron-host
cp terraform.tfvars.example terraform.tfvars   # edit

# Tokens via env (or Doppler):
export TF_VAR_HCLOUD_TOKEN=...
export TF_VAR_CLOUDFLARE_API_TOKEN=...
export TF_VAR_CLOUDFLARE_ZONE_ID=...

tofu init
tofu plan
tofu apply
```

State is local and gitignored. At one-host scale that's fine; move to a
remote backend if more people start applying.

## What it creates

- `hcloud_server` — ccx23 in `hil` (us-west, same DC as alpha), Hetzner
  backups enabled, cloud-init from `cloud-init.yaml`
- `hcloud_firewall` — 22/80/443 open (SSH optionally IP-restricted);
  5432/27017 only if `db_admin_ips` is set; Redis/NATS never exposed
- `cloudflare_record.host` — `<server_name>.<domain>`, not proxied (SSH/admin)
- `cloudflare_record.service[*]` — proxied records for Traefik-routed services

## After apply

Cloud-init handles OS packages and services. The rest is manual,
following the Komodo guide (`~/komodo/setup.md` on alpha):

1. Set up Komodo + Traefik (compose files: see baragaun-cloud `hosts/alpha/komodo/`).
2. Once the `komodo_default` Docker network exists, bind Postgres/Redis/NATS
   to the Docker gateway IPs — see [hosts/alpha/README.md](../../hosts/alpha/README.md).
3. Create the `hadron` Postgres DB/user, enable pgvector.
4. Install the backup timer from `hosts/alpha/backup/`.

## Adopting alpha into state (optional, not done)

Alpha (instance `123035399`) predates this project. To manage it here,
instantiate this module/dir per host and import:

```bash
tofu import hcloud_server.main 123035399
tofu import hcloud_firewall.main <fw-id>
# cloudflare_record imports: <zone_id>/<record_id>
```

Until then, treat this project as "new hosts only".
