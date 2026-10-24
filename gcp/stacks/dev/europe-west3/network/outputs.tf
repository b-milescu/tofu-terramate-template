output "network_id" {
  description = "ID of the VPC network."
  value       = google_compute_network.main.id
}

output "private_subnet_id" {
  description = "ID of the private subnetwork."
  value       = google_compute_subnetwork.private.id
}
