variable "HCLOUD_TOKEN" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Set via Doppler as TF_VAR_HCLOUD_TOKEN."
}

variable "CLOUDFLARE_API_TOKEN" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:DNS:Edit on the target zone. Set via Doppler as TF_VAR_CLOUDFLARE_API_TOKEN."
}

variable "CLOUDFLARE_ZONE_ID" {
  type        = string
  description = "Cloudflare Zone ID for the domain (e.g. hadronmemory.com). Set via Doppler as TF_VAR_CLOUDFLARE_ZONE_ID."
}

variable "ssh_public_key" {
  type        = string
  description = "Path to SSH public key used for initial root access to the host."
  default     = "~/.ssh/id_rsa.pub"
}

variable "domain" {
  type        = string
  description = "Apex domain managed in Cloudflare."
  default     = "hadronmemory.com"
}

variable "server_name" {
  type        = string
  description = "Host name. Also used as the non-proxied DNS record for SSH/admin access, e.g. 'beta' produces beta.hadronmemory.com."
  default     = "beta"
}

variable "service_subdomains" {
  type        = list(string)
  description = "Cloudflare-proxied A records pointing at this host, one per public-facing service (e.g. ['srv', 'www']). Traefik routes by hostname behind these."
  default     = []
}

variable "server_type" {
  type        = string
  description = "Hetzner Cloud server type. ccx23 = 4 dedicated vCPU, 16 GB RAM, 160 GB disk (~$40/mo) — same as alpha."
  default     = "ccx23"
}

variable "location" {
  type        = string
  description = "Hetzner Cloud location. hil = Hillsboro, OR (us-west) — same as alpha. Alternatives: ash (us-east), fsn1/nbg1/hel1 (EU)."
  default     = "hil"
}

variable "image" {
  type    = string
  default = "debian-13"
}

variable "ssh_admin_ips" {
  type        = list(string)
  description = "IPv4/IPv6 CIDRs allowed to reach SSH. Empty list = open to the world."
  default     = []
}

variable "db_admin_ips" {
  type        = list(string)
  description = "IPv4/IPv6 CIDRs allowed to reach Postgres (5432) and MongoDB (27017) directly. Empty list = no external DB access (SSH tunnel only) — alpha whitelists a few IPs here."
  default     = []
}
