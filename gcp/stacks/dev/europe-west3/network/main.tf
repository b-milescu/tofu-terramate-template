locals {
  vpc_cidr = "10.10.0.0/16"
}

# The project and the region of the subnetwork come from the generated provider block.
resource "google_compute_network" "main" {
  #checkov:skip=CKV2_GCP_18:GCP's implied deny-all ingress rule covers this stack; workload stacks add their own firewall rules.
  name                    = "main"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "private" {
  name                     = "private"
  network                  = google_compute_network.main.id
  ip_cidr_range            = cidrsubnet(local.vpc_cidr, 4, 0)
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}
