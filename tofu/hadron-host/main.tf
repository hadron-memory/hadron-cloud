provider "hcloud" {
  token = var.HCLOUD_TOKEN
}

provider "cloudflare" {
  api_token = var.CLOUDFLARE_API_TOKEN
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = trimspace(file(pathexpand(var.ssh_public_key)))
}

resource "hcloud_firewall" "main" {
  name = "${var.server_name}-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = length(var.ssh_admin_ips) > 0 ? var.ssh_admin_ips : ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Postgres / MongoDB: only whitelisted admin IPs, if any. Redis and
  # NATS are never exposed — they bind localhost + Docker gateways only.
  dynamic "rule" {
    for_each = length(var.db_admin_ips) > 0 ? ["5432", "27017"] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = var.db_admin_ips
    }
  }
}

resource "hcloud_server" "main" {
  name         = var.server_name
  server_type  = var.server_type
  location     = var.location
  image        = var.image
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.main.id]
  backups      = true
  user_data    = file("${path.module}/cloud-init.yaml")

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}

# Host record, NOT proxied — direct SSH/admin access.
resource "cloudflare_record" "host" {
  zone_id = var.CLOUDFLARE_ZONE_ID
  name    = var.server_name
  content = hcloud_server.main.ipv4_address
  type    = "A"
  proxied = false
  comment = "${var.server_name} host (direct, for SSH/admin)"
}

# Proxied records for public-facing services (Traefik routes by hostname).
resource "cloudflare_record" "service" {
  for_each = toset(var.service_subdomains)

  zone_id = var.CLOUDFLARE_ZONE_ID
  name    = each.value
  content = hcloud_server.main.ipv4_address
  type    = "A"
  proxied = true
  comment = "service on ${var.server_name}"
}
