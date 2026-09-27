#!/bin/bash
set -euo pipefail
# First check if aliases are used
if [ -f ~/.bash_aliases ]; then
    shopt -s expand_aliases
    source ~/.bash_aliases
fi
#
# Get project root.
#
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source $SCRIPT_DIR/../.env
export manifests_dir=$SCRIPT_DIR/../manifests
export values_dir=$SCRIPT_DIR/../values
export secrets_dir=$SCRIPT_DIR/../secrets

[[ "${nfs_server_ip:-}" == "192.168.1.240" ]] || {
  echo 'nfs_server_ip must be 192.168.1.240 before Grafana/Loki deployment.' >&2
  exit 1
}
pvc_states="$(python3 "$SCRIPT_DIR/../../nfs-ha/scripts/verify-migrated-claims.py" grafana \
  grafana-pv-claim loki-pv-claim box-collector-pv-claim)"

microk8s helm repo add grafana https://grafana.github.io/helm-charts
envsubst < $manifests_dir/grafana-storage-class.yaml | microk8s kubectl apply -f -
microk8s kubectl apply -f $manifests_dir/grafana-namespace.yaml
if grep -qx 'loki-pv-claim NEW' <<< "$pvc_states"; then
  microk8s kubectl apply -f "$manifests_dir/loki-pvc.yaml"
else
  echo 'Preserving verified grafana/loki-pv-claim binding.'
fi
if grep -qx 'grafana-pv-claim NEW' <<< "$pvc_states"; then
  microk8s kubectl apply -f "$manifests_dir/grafana-pvc.yaml"
else
  echo 'Preserving verified grafana/grafana-pv-claim binding.'
fi
microk8s helm upgrade --install loki grafana/loki-stack --version 2.10.2 -n grafana -f $values_dir/loki-values.yaml
microk8s helm upgrade --install grafana grafana/grafana --version 9.4.5 -n grafana -f $values_dir/grafana-values.yaml
microk8s kubectl apply -f $manifests_dir/grafana-httproute.yaml
microk8s kubectl apply -f $manifests_dir/loki-httproute.yaml
microk8s kubectl -n grafana create secret generic box-jwt \
  --from-file=box-config.json=$secrets_dir/sandbox.json \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
if grep -qx 'box-collector-pv-claim NEW' <<< "$pvc_states"; then
  microk8s kubectl apply -f "$manifests_dir/box-collector-pv-claim.yaml"
else
  echo 'Preserving verified grafana/box-collector-pv-claim binding.'
fi
microk8s kubectl apply -f $manifests_dir/box-collector-deployment.yaml
