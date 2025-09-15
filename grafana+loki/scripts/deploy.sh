#!/bin/bash
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

microk8s helm repo add grafana https://grafana.github.io/helm-charts
envsubst < $manifests_dir/grafana-storage-class.yaml | microk8s kubectl apply -f -
microk8s kubectl apply -f $manifests_dir/grafana-namespace.yaml
microk8s kubectl apply -f $manifests_dir/loki-pvc.yaml
microk8s kubectl apply -f $manifests_dir/grafana-pvc.yaml
microk8s helm upgrade --install loki grafana/loki-stack -n grafana -f $values_dir/loki-values.yaml
microk8s helm upgrade --install grafana grafana/grafana -n grafana -f $values_dir/grafana-values.yaml
microk8s kubectl apply -f $manifests_dir/grafana-httproute.yaml
microk8s kubectl apply -f $manifests_dir/loki-httproute.yaml
microk8s kubectl -n grafana create secret generic box-jwt \
  --from-file=box-config.json=$secrets_dir/sandbox.json 
microk8s kubectl apply -f $manifests_dir/box-collector-pv-claim.yaml
microk8s kubectl apply -f $manifests_dir/box-collector-deployment.yaml
