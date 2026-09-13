#!/bin/bash

set -euo pipefail

#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source "$SCRIPT_DIR/../.env"
export manifests_dir="$SCRIPT_DIR/../manifests"

encode() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

export postgres_user_encoded="$(encode "$POSTGRES_USER")"
export postgres_password_encoded="$(encode "$POSTGRES_PASSWORD")"
export postgres_db_encoded="$(encode "$POSTGRES_DB")"
export postgres_non_root_user_encoded="$(encode "$POSTGRES_NON_ROOT_USER")"
export postgres_non_root_password_encoded="$(encode "$POSTGRES_NON_ROOT_PASSWORD")"

microk8s kubectl apply -f "$manifests_dir/namespace.yaml"
envsubst < "$manifests_dir/postgres-secret.yaml" | microk8s kubectl apply -f -

if [[ -n "${N8N_ENCRYPTION_KEY:-}" ]]; then
  export n8n_encryption_key_encoded="$(encode "$N8N_ENCRYPTION_KEY")"
  envsubst < "$manifests_dir/n8n-secret.yaml" | microk8s kubectl apply -f -
elif ! microk8s kubectl -n n8n get secret n8n-secret >/dev/null 2>&1; then
  echo "N8N_ENCRYPTION_KEY is unset and the n8n-secret does not exist." >&2
  exit 1
fi

# Do not envsubst these manifests; their shell variables must expand in the pods.
microk8s kubectl apply -f "$manifests_dir/postgres-configmap.yaml"
microk8s kubectl apply -f "$manifests_dir/postgres-statefulset.yaml"
microk8s kubectl -n n8n rollout status statefulset/postgres-n8n-v17 --timeout=5m

microk8s kubectl apply -f "$manifests_dir/n8n-persistent-volume-claim.yaml"
microk8s kubectl apply -f "$manifests_dir/n8n-deployment.yaml"
microk8s kubectl apply -f "$manifests_dir/jenkins-deployer-rbac.yaml"
microk8s kubectl apply -f "$manifests_dir/n8n-service.yaml"
microk8s kubectl apply -f "$manifests_dir/n8n-gateway.yaml"

if [[ -n "${BOX_CLIENT_ID:-}" && -n "${BOX_CLIENT_SECRET:-}" && -n "${BOX_SUBJECT_TYPE:-}" && -n "${BOX_SUBJECT_ID:-}" ]]; then
  export box_client_id_secret_encoded="$(encode "$BOX_CLIENT_ID")"
  export box_client_secret_encoded="$(encode "$BOX_CLIENT_SECRET")"
  export box_subject_type_encoded="$(encode "$BOX_SUBJECT_TYPE")"
  export box_subject_id_encoded="$(encode "$BOX_SUBJECT_ID")"
  envsubst < "$manifests_dir/box-mcp-server-secret-.yaml" | microk8s kubectl apply -f -
elif ! microk8s kubectl -n n8n get secret box-mcp-server >/dev/null 2>&1; then
  echo "Box variables are incomplete and the box-mcp-server Secret does not exist." >&2
  exit 1
fi

microk8s kubectl apply -f "$manifests_dir/box-mcp-server-deployment.yaml"
microk8s kubectl apply -f "$manifests_dir/box-mcp-server-service.yaml"

microk8s kubectl -n n8n rollout status deployment/n8n --timeout=5m
microk8s kubectl -n n8n rollout status deployment/box-mcp-server --timeout=5m
