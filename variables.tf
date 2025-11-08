variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for regional resources"
  type        = string
  default     = "europe-west1"
}

variable "zones" {
  description = "List of zones for the regional GKE node pool"
  type        = list(string)
  default     = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]
}

variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "iac-vpc"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnetwork"
  type        = string
  default     = "10.10.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnetwork (GKE nodes here)"
  type        = string
  default     = "10.10.10.0/24"
}

variable "service_peering_cidr" {
  description = "CIDR /16 reserved for Private Service Access (Cloud SQL)"
  type        = string
  default     = "10.50.0.0/16"
}

variable "gke_release_channel" {
  description = "GKE release channel (RAPID, REGULAR, STABLE)"
  type        = string
  default     = "REGULAR"
}

variable "gke_version" {
  description = "Optional exact GKE version (leave empty to use release channel)"
  type        = string
  default     = ""
}

variable "gke_machine_type" {
  description = "Node machine type for default pool"
  type        = string
  default     = "e2-standard-4"
}

variable "gke_min_nodes" {
  type    = number
  default = 1
}

variable "gke_desired_nodes" {
  type    = number
  default = 3
}

variable "gke_max_nodes" {
  type    = number
  default = 6
}

variable "db_version" {
  description = "Cloud SQL machine type"
  type        = string
  default     = "POSTGRES_17"
}

variable "db_tier" {
  description = "Cloud SQL machine type"
  type        = string
  default     = "db-perf-optimized-N-2"
}

variable "db_disk_size_gb" {
  type    = number
  default = 40
}

variable "db_availability_type" {
  description = "REGIONAL (HA) or ZONAL"
  type        = string
  default     = "REGIONAL"
}

variable "redis_size_gb" {
  description = "Redis memory size in GB"
  type        = number
  default     = 2
}

variable "admin_cidr" {
  description = "CIDR allowed to call the GKE control-plane public endpoint"
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = "Common labels for resources"
  type        = map(string)
  default = {
    owner      = "platform-team"
    managed-by = "terraform"
  }
}
