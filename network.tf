resource "google_compute_network" "this" {
  name                            = "${local.prefix}-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "data" {
  name                     = "${local.prefix}-data"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.25
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Dataflow workers must talk to each other on 12345-12346 (shuffle/streaming).
resource "google_compute_firewall" "dataflow_internal" {
  name      = "${local.prefix}-dataflow-internal"
  network   = google_compute_network.this.name
  direction = "INGRESS"
  priority  = 1000

  source_tags = ["dataflow"]
  target_tags = ["dataflow"]

  allow {
    protocol = "tcp"
    ports    = ["12345-12346"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "deny_all_ingress" {
  name      = "${local.prefix}-deny-all-ingress"
  network   = google_compute_network.this.name
  direction = "INGRESS"
  priority  = 65000

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

# Composer 3 (private) needs egress to PyPI; Dataflow workers have no public IPs.
resource "google_compute_router" "this" {
  name    = "${local.prefix}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${local.prefix}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.data.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
