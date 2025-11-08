project_id = "kubernetes-work-396809"

region = "europe-west1"
zones  = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]

network_name         = "iac-vpc"
public_subnet_cidr   = "10.10.0.0/24"
private_subnet_cidr  = "10.10.10.0/24"
service_peering_cidr = "10.50.0.0/16"

admin_cidr = "0.0.0.0/0" # replace with your public /32

gke_release_channel = "REGULAR"
gke_machine_type    = "e2-standard-4"
gke_min_nodes       = 2
gke_desired_nodes   = 3
gke_max_nodes       = 6

db_tier              = "db-custom-2-4096"
db_disk_size_gb      = 100
db_availability_type = "REGIONAL"

redis_size_gb = 5
