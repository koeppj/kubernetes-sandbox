#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "${SCRIPT_DIR}/common.sh"
if [[ "${1:-}" == --render ]]; then
  # Preview deliberately excludes Secret data. Real credentials are not required.
  export ntfy_config_checksum=preview ntfy_secret_checksum=preview
  for manifest in namespace.yaml ntfy-configmap.yaml ntfy-pvc.yaml ntfy-service.yaml ntfy-statefulset.yaml ntfy-gateway.yaml; do
    printf '%s\n' '---'
    render_manifest "$manifest"
  done
  exit 0
fi
if (($#)); then
  echo "Usage: $0 [--render]" >&2
  exit 2
fi
microk8s kubectl -n ntfy rollout status statefulset/ntfy --timeout=5m
microk8s kubectl -n ntfy get statefulset,pods,services,pvc,httproute
microk8s kubectl -n ntfy get secret ntfy
microk8s kubectl -n ntfy logs statefulset/ntfy --tail=100
"${SCRIPT_DIR}/../../bin/shutdown-nfs-workloads.sh" --dry-run
