#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
#
# Environment Variable Setups.  
#
source $SCRIPT_DIR/../.env
export manifests_dir=$SCRIPT_DIR/../manifests
export values_dir=$SCRIPT_DIR/../values
export secrets_dir=$SCRIPT_DIR/../secrets

microk8s kubectl -n grafana delete deployment box-event-collector
microk8s kubectl -n grafana delete pvc box-collector-pv-claim
microk8s helm uninstall loki -n grafana
microk8s kubectl -n delete pvc loki-pc-claim
microk8s kubectl apply -f $manifests_dir/loki-pvc.yaml
microk8s kubectl apply -f $manifests_dir/box-collector-pv-claim.yaml
microk8s helm upgrade --install loki grafana/loki-stack -n grafana -f $values_dir/loki-values.yaml
microk8s kubectl apply -f $manifests_dir/box-collector-deployment.yaml
