#!/usr/bin/env bash
# One-node step: create DRBD metadata and bring up each new resource.
# Run on both nodes, reviewing the preview first on each node.
set -euo pipefail

apply=false

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-drbd-metadata.sh [--apply]

The default verifies that all five configured backing devices are unused and
prints the metadata/up commands. --apply runs create-md and up for each resource
on this node. Run it on both nodes before selecting the initialization source.
EOF
}

case "${1:-}" in
    '') ;;
    --apply) apply=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }
(( EUID == 0 )) || { echo 'Run this script with sudo.' >&2; exit 1; }

host="$(hostname -s)"
case "$host" in ubuntu-slave1|ubuntu-master2) ;; *) echo "Unexpected host: $host" >&2; exit 1 ;; esac
for command_name in drbdadm findmnt hostname lsblk; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

resources=(nfs kube grafana postgres nfs-state)
for resource in "${resources[@]}"; do
    backing="$(drbdadm sh-ll-dev "$resource")"
    device="$(drbdadm sh-dev "$resource")"
    [[ -b "$backing" ]] || { echo "Backing device is missing: $backing" >&2; exit 1; }
    [[ -z "$(findmnt -rn -S "$backing" -o TARGET)" ]] || {
        echo "Backing device is mounted: $backing" >&2
        exit 1
    }
    [[ -z "$(lsblk -dnro FSTYPE "$backing")" ]] || {
        echo "Backing device has a recognized signature: $backing" >&2
        exit 1
    }
    if drbdadm dump-md "$resource" >/dev/null 2>&1; then
        echo "DRBD metadata already exists for $resource; inspect it manually." >&2
        exit 1
    fi
    [[ ! -b "$device" ]] || {
        echo "DRBD device already exists for $resource: $device" >&2
        exit 1
    }
done

printf 'Host: %s\n\n' "$(hostname -f)"
for resource in "${resources[@]}"; do
    printf 'drbdadm create-md %q\n' "$resource"
    printf 'drbdadm up %q\n' "$resource"
done

if [[ "$apply" == false ]]; then
    echo
    echo 'Preview only; no DRBD metadata or devices were created.'
    exit 0
fi

for resource in "${resources[@]}"; do
    drbdadm create-md "$resource"
    drbdadm up "$resource"
done

echo
echo 'Local resources are up. Run this step on the peer, then inspect both nodes.'
drbdadm status 2>/dev/null || cat /proc/drbd
