output "server_ipv4" {
  value       = hcloud_server.main.ipv4_address
  description = "Public IPv4 address of the host."
}

output "server_ipv6" {
  value       = hcloud_server.main.ipv6_address
  description = "Public IPv6 address of the host."
}

output "server_name" {
  value = hcloud_server.main.name
}

output "host_fqdn" {
  value       = "${var.server_name}.${var.domain}"
  description = "FQDN for SSH/admin access (not Cloudflare-proxied)."
}

output "service_fqdns" {
  value       = [for s in var.service_subdomains : "${s}.${var.domain}"]
  description = "Cloudflare-proxied service FQDNs."
}
