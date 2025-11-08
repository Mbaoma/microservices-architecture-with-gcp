locals {
  name_prefix = "iac"
}

# ------------------------------
# Enable required APIs
# ------------------------------
resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "redis.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com"
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# ------------------------------
# VPC + Subnets
# ------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "public" {
  name                     = "${local.name_prefix}-public-${var.region}"
  ip_cidr_range            = var.public_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "private" {
  name                     = "${local.name_prefix}-private-${var.region}"
  ip_cidr_range            = var.private_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${local.name_prefix}-pods" # iac-pods
    ip_cidr_range = "10.20.0.0/14"              # K8S Pods
  }

  # CORRECT SYNTAX for the GKE Services CIDR
  secondary_ip_range {
    range_name    = "${local.name_prefix}-services" # iac-services
    ip_cidr_range = "10.24.0.0/20"                  # K8S Services
  }
}

# ------------------------------
# Cloud Router + Cloud NAT (egress for private subnets)
# ------------------------------
resource "google_compute_router" "router" {
  name    = "${local.name_prefix}-cr"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.name
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ------------------------------
# GKE - Private cluster (regional)
# ------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = "${local.name_prefix}-gke-nodes"
  display_name = "GKE node pool service account"
}

resource "google_project_iam_member" "gke_nodes_logwriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
resource "google_project_iam_member" "gke_nodes_metricwriter" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}
resource "google_project_iam_member" "gke_nodes_artifactreader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "gke" {
  name       = "${local.name_prefix}-gke"
  location   = var.region
  network    = google_compute_network.vpc.self_link
  subnetwork = google_compute_subnetwork.private.self_link

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.gke_release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "${local.name_prefix}-pods"
    services_secondary_range_name = "${local.name_prefix}-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.admin_cidr
      display_name = "admin"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  depends_on = [google_project_service.services]
}

resource "google_container_node_pool" "default" {
  name     = "default-pool"
  location = var.region
  cluster  = google_container_cluster.gke.name

  node_count = var.gke_desired_nodes

  autoscaling {
    min_node_count = var.gke_min_nodes
    max_node_count = var.gke_max_nodes
  }

  management {
    auto_upgrade = true
    auto_repair  = true
  }

  node_config {
    preemptible     = false
    machine_type    = var.gke_machine_type
    service_account = google_service_account.gke_nodes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    tags = ["gke-nodes"]
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    labels = {
      role = "general"
    }
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  depends_on = [google_container_cluster.gke]
}

# ------------------------------
# Private Service Access for Cloud SQL
# ------------------------------
resource "google_compute_global_address" "private_service_range" {
  name          = "${local.name_prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

# ------------------------------
# Cloud SQL for Postgres (Private IP)
# ------------------------------
resource "random_password" "db_master_password" {
  length  = 24
  special = true
}

resource "google_secret_manager_secret" "db_master" {
  secret_id = "${local.name_prefix}-db-master-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "db_master_version" {
  secret      = google_secret_manager_secret.db_master.id
  secret_data = random_password.db_master_password.result
}

resource "google_sql_database_instance" "postgres" {
  name             = "${local.name_prefix}-pg"
  region           = var.region
  database_version = var.db_version

  settings {
    tier              = var.db_tier
    availability_type = var.db_availability_type
    disk_size         = var.db_disk_size_gb
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.self_link
      enable_private_path_for_google_cloud_services = true
    }

    maintenance_window {
      day  = 7
      hour = 3
    }

    backup_configuration {
      enabled                        = true
      transaction_log_retention_days = 7
    }

    insights_config {
      query_insights_enabled = true
    }
  }

  deletion_protection = false

  depends_on = [google_service_networking_connection.psa, google_project_service.services]
}

resource "google_sql_user" "app" {
  instance = google_sql_database_instance.postgres.name
  name     = "appuser"
  password = random_password.db_master_password.result
}

resource "google_sql_database" "appdb" {
  name     = "appdb"
  instance = google_sql_database_instance.postgres.name
}

# ------------------------------
# Memorystore for Redis (STANDARD_HA)
# ------------------------------
resource "google_redis_instance" "redis" {
  name                    = "${local.name_prefix}-redis"
  tier                    = "STANDARD_HA"
  region                  = var.region
  memory_size_gb          = var.redis_size_gb
  redis_version           = "REDIS_7_0"
  transit_encryption_mode = "SERVER_AUTHENTICATION"
  authorized_network      = google_compute_network.vpc.self_link

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 3
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
    # depends_on = [google_project_service.services]
  }
}

# ------------------------------
# Pub/Sub (Managed Kafka alternative)
# ------------------------------
resource "google_pubsub_topic" "events" {
  name                       = "${local.name_prefix}-events"
  message_retention_duration = "604800s"
  labels                     = var.tags
}

resource "google_pubsub_subscription" "events_sub" {
  name                  = "${local.name_prefix}-events-sub"
  topic                 = google_pubsub_topic.events.name
  ack_deadline_seconds  = 20
  retain_acked_messages = false
}

# ------------------------------
# Firewall: harden egress from nodes
# ------------------------------
resource "google_compute_firewall" "egress_deny_all" {
  name        = "${local.name_prefix}-egress-deny-all"
  network     = google_compute_network.vpc.name
  direction   = "EGRESS"
  priority    = 65534
  target_tags = ["gke-nodes"]
  deny { protocol = "all" }
}

resource "google_compute_firewall" "egress_allow_db" {
  name               = "${local.name_prefix}-egress-allow-db"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 1000
  target_tags        = ["gke-nodes"]
  destination_ranges = [var.service_peering_cidr]
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  depends_on = [google_compute_firewall.egress_deny_all]
}

resource "google_compute_firewall" "egress_allow_redis" {
  name               = "${local.name_prefix}-egress-allow-redis"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 1000
  target_tags        = ["gke-nodes"]
  destination_ranges = [var.private_subnet_cidr]
  allow {
    protocol = "tcp"
    ports    = ["6379"]
  }
  depends_on = [google_compute_firewall.egress_deny_all]
}

resource "google_compute_firewall" "egress_allow_apis" {
  name               = "${local.name_prefix}-egress-allow-apis"
  network            = google_compute_network.vpc.name
  direction          = "EGRESS"
  priority           = 1000
  target_tags        = ["gke-nodes"]
  destination_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  depends_on = [google_compute_firewall.egress_deny_all]
}

# ------------------------------
# Outputs
# ------------------------------
output "network" { value = google_compute_network.vpc.name }
output "subnet_private" { value = google_compute_subnetwork.private.name }
output "subnet_public" { value = google_compute_subnetwork.public.name }

output "gke_cluster_name" { value = google_container_cluster.gke.name }
output "gke_endpoint" { value = google_container_cluster.gke.endpoint }
output "gke_workload_pool" { value = google_container_cluster.gke.workload_identity_config[0].workload_pool }

output "cloudsql_connection_name" { value = google_sql_database_instance.postgres.connection_name }
output "db_secret_name" { value = google_secret_manager_secret.db_master.secret_id }

output "redis_host" { value = google_redis_instance.redis.host }
output "redis_port" { value = google_redis_instance.redis.port }

output "pubsub_topic" { value = google_pubsub_topic.events.name }
