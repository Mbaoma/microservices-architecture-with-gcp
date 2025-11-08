#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:?Cluster name required}"
REGION="${2:-${REGION:-europe-west1}}"
PROJECT_ID="${3:-${GOOGLE_CLOUD_PROJECT:-}}"

echo "Updating kubeconfig for cluster: $CLUSTER_NAME in region: $REGION"
if [[ -n "$PROJECT_ID" ]]; then
  gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT_ID"
else
  gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION"
fi

kubectl get nodes -o wide
