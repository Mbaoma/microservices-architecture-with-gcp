# microservices-architecture-with-gcp
Using Google Cloud Provider (GCP), setup a microservices architecture, using Infrastructure as Code (IAC). The application to be deployed, consists of several microservices, each with its own data storage requirements.

## Run the project

- [Authenticate](https://docs.cloud.google.com/docs/authentication/set-up-adc-local-dev-environment) to ADC

```
gcloud auth application-default login
./run.sh
```

## Notes

I chose Google Cloud Platform (GCP) because it provides managed services that map very cleanly to the scenario:

- GKE is one of the most mature managed Kubernetes offerings, with:
    - Native Workload Identity (tight, least-privilege IAM integration).
    - First-class support for private clusters and IP aliasing.

- Cloud SQL for PostgreSQL gives a fully managed, HA relational database with:
    - Built-in backups, PITR, and query insights.
    - Easy private IP connectivity via Private Service Access.

- Memorystore for Redis removes the operational burden of managing Redis clusters.

- Pub/Sub is the recommended “managed Kafka alternative” on GCP:
    - Fully managed, horizontally scalable, exactly what the original requirement hints at (“e.g., Pub/Sub on GCP”).

- GCP networking features (VPCs, Cloud NAT, Cloud Router) make it straightforward to keep workloads private while still allowing controlled outbound internet access.

Overall, GCP lets us satisfy the requirements using managed building blocks and keep the Terraform code focused on security rather than operating stateful clusters ourselves.

### Architecture

At a high level, the Terraform creates:

- A custom VPC with:

    - One public subnetwork (for future ingress/Bastion/LB if needed).
    - One private subnetwork (GKE nodes, internal services).
    - Secondary IP ranges for pods and services (IP aliasing).
    - Cloud Router + Cloud NAT so private workloads can reach the internet without public IPs.

- A regional private GKE cluster:

    - Nodes only have private IPs in the private subnet.
    - The control plane is public but restricted via master authorized networks.

- Cloud SQL for PostgreSQL with:
    - Private IP only (no public endpoint).
    - Regional high availability (HA) and automatic backups.

- Memorystore for Redis:

    - Connected to the same VPC, reachable from the GKE node subnet.
    - Pub/Sub topic + subscription for asynchronous communication between microservices.

- Security posture:
    - Egress-deny firewall on GKE nodes, with narrow allow rules to DB, Redis, and Google APIs.
    - Secrets (DB credentials) stored in Secret Manager.
    - Minimal IAM for node service accounts (logWriter / metricWriter / artifactregistry.reader).

```
+---------------- INTERNET ----------------+
|   User/Engineer                          |
+--------------------+---------------------+
                     |  HTTPS
                     v
             +------------------+
             |  GCLB / Ingress |
             +--------+---------+
                      |
+==================== VPC ====================+
|  Cloud Router + Cloud NAT (egress)          |
|                                             |
|  +---------+        +--------------------+  |
|  | Public  |        |    Private Subnet  |  |
|  | Subnet  |        |  +---------------+ |  |
|  | (GCLB)  |        |  | GKE Nodes     | |  |
|  +---------+        |  +-------+-------+ |  |
|                     |          |          |
|                     |   +------v------+   |
|                     |   | Cloud SQL   |   |
|                     |   +-------------+   |
|                     |   +-------------+   |
|                     |   | Redis       |   |
|                     |   +-------------+   |
|                     |   +-------------+   |
|                     |   | Pub/Sub     |   |
|                     |   +-------------+   |
+============================================+
```

## Design Choices

### Cloud platform

* **GCP** chosen to leverage:

  * **GKE** for managed Kubernetes.
  * **Cloud SQL (Postgres)**, **Memorystore (Redis)**, and **Pub/Sub** as fully managed data/async services.
  * Strong **VPC + Cloud NAT + Private Service Access** story for private networking.

### Networking

* **Custom VPC**, no auto-subnets → full control of IP ranges.
* Two subnets:

  * **Public**: reserved for future ingress/bastion/load balancers.
  * **Private**: GKE nodes and internal services.
* **Cloud Router + Cloud NAT** for outbound internet from private nodes without public IPs.
* **Private Service Access /16** reserved to give **Cloud SQL** a private IP inside the VPC.

### Compute (GKE)

* **Regional private GKE cluster**:

  * Private nodes (no public IPs), IP aliasing for pods/services.
  * Control plane public but restricted via **master authorized networks** (`admin_cidr`).
* **Managed node pool** with autoscaling (min/desired/max configurable).
* **Workload Identity** enabled for secure GCP IAM integration from pods.
* Node service account with **minimal IAM**: logging, monitoring, Artifact Registry read.

### Data layer

* **Cloud SQL for PostgreSQL 16**:

  * **REGIONAL** (HA) by default; private IP only, no public endpoint.
  * Disk autoresize, backups + WAL retention, Query Insights enabled.
  * DB password generated by Terraform and stored in **Secret Manager** (not in code).
* **Memorystore Redis 7 STANDARD_HA**:

  * Private IP in the VPC; used as cache/session store.
  * HA tier for automatic failover.

### Messaging / “Managed Kafka”

* **Pub/Sub** topic + subscription:

  * Used as the managed Kafka-equivalent for async microservice communication.
  * Chosen over self-managed Kafka to avoid operating brokers.

### Security

* **Egress-deny firewall** for nodes, then narrow **allow** rules:

  * Allow TCP 5432 only to PSA CIDR (Cloud SQL).
  * Allow TCP 6379 only to private subnet CIDR (Redis).
  * Allow HTTPS 443 to the internet for Google APIs and image pulls.
* **Private-only** access for DB and Redis.
* Credentials stored in **Secret Manager**; cluster prepared for **Workload Identity** for app-level IAM.

### Operational posture

* Defaults tuned for a **prod-ish baseline** but configurable via variables:

  * Region/zones, node sizes, DB tier, Redis size, autoscaling bounds.
* **GKE release channel (REGULAR)** instead of hard-coded versions for smoother upgrades.
* Labels/tags for basic ownership/management metadata.

This boils down to: **private-by-default networking**, **managed services wherever possible**, and **least-privilege security** with a clear path to scale and harden further.

## Assumptions

To keep the solution focused and within scope, I made a few assumptions:

- Single environment / project
- Terraform manages resources in a single GCP project and region.
- No multi-project separation (e.g., shared VPC, separate networking project) in this first cut.
- Ingress and DNS are out of scope
- The cluster networking is ready for ingress (subnets, NAT), but:
- No HTTP(S) Load Balancer / Gateway / Ingress resource is created.
- No managed certificate / DNS records are configured.

This matches the requirement, which focuses on infrastructure, compute, and data.

Application-level concerns are separate. Terraform doesn’t deploy the microservice workloads themselves (Deployments, Services, HPA), those would be managed via Helm/Kustomize/ArgoCD once the cluster exists.

### Basic observability setup

- GKE logging/monitoring is enabled at the cluster level (Cloud Logging / Monitoring).
- A full observability stack inside the cluster (Prometheus Operator, Grafana, etc.) is not included.
- No strict compliance/KMS requirements
- Using Google-managed encryption keys (CMEK optional).

If compliance requires customer-managed keys, additional KMS resources and key references would need to be wired into Cloud SQL / disks / Redis / Pub/Sub.

### Admin access via IP / VPN

- `admin_cidr` is assumed to be a trusted corporate IP/VPN range.
In more advanced setups, I'd typically front this with Cloud VPN / Cloud Interconnect and tighter ranges.

