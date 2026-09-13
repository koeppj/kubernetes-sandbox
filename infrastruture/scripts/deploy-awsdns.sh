#!/usr/bin/env bash

# Apply the updater after its image has been imported onto every cluster node.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
infrastructure_dir=$(cd -- "$SCRIPT_DIR/.." && pwd)
kube_host_ip=$(curl --fail --silent --show-error --max-time 30 -4 https://icanhazip.com)
if [[ ! "$kube_host_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Public IP discovery did not return an IPv4 address." >&2
    exit 1
fi
IFS=. read -r -a ip_octets <<< "$kube_host_ip"
for octet in "${ip_octets[@]}"; do
    if ((10#$octet > 255)); then
        echo "Public IP discovery returned an invalid IPv4 address." >&2
        exit 1
    fi
done
export kube_host_ip

rendered_manifest=$(mktemp -t awsdns-manifest.XXXXXXXX)
trap 'rm -f -- "$rendered_manifest"' EXIT
envsubst '${kube_host_ip}' < "$infrastructure_dir/create-awsdns-updater.yaml" > "$rendered_manifest"
microk8s kubectl apply --dry-run=server -f "$rendered_manifest"
# A Deployment does not replace a standalone Pod. Stop the legacy worker first.
microk8s kubectl -n infrastructure delete pod awsdns --ignore-not-found --wait=true --timeout=2m
microk8s kubectl apply -f "$rendered_manifest"
microk8s kubectl -n infrastructure rollout status deployment/awsdns --timeout=5m
