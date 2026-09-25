#!/usr/bin/env bash
# Validate and optionally install the five static DRBD 8.4 resource files.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd -- "$SCRIPT_DIR/../templates/drbd" && pwd)"
readonly TEMPLATE_DIR
readonly TARGET_DIR=/etc/drbd.d

apply=false

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-drbd-config.sh [--apply]

The default validates the local backing LVs, resource syntax, addresses, ports,
and proposed file changes. --apply installs only the five resource files. It
does not create metadata, bring resources up, format filesystems, or start a
service.
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
for command_name in blockdev cmp diff drbdadm findmnt hostname ip lsblk ss; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

host="$(hostname -s)"
case "$host" in
    ubuntu-slave1)
        expected_node_name=ubuntu-slave1.koeppster.lan
        local_address=192.168.1.235
        backing=(
            /dev/nfs-vg/drbd-nfs
            /dev/kube-vg/drbd-kube
            /dev/kube-vg/drbd-grafana
            /dev/kube-vg/drbd-postgres
            /dev/nfs-vg/drbd-nfs-state
        )
        ;;
    ubuntu-master2)
        expected_node_name=ubuntu-master2.koeppster.lan
        local_address=192.168.1.194
        backing=(
            /dev/ubuntu-vg/drbd-nfs
            /dev/ubuntu-vg/drbd-kube
            /dev/ubuntu-vg/drbd-grafana
            /dev/ubuntu-vg/drbd-postgres
            /dev/ubuntu-vg/drbd-nfs-state
        )
        ;;
    *) echo "Refusing to run on $host; expected an NFS HA node." >&2; exit 1 ;;
esac

[[ "$(uname -n)" == "$expected_node_name" ]] || {
    echo "Kernel node name is $(uname -n); DRBD configuration expects $expected_node_name." >&2
    exit 1
}

resources=(nfs kube grafana postgres nfs-state)
devices=(/dev/drbd0 /dev/drbd1 /dev/drbd2 /dev/drbd3 /dev/drbd4)
ports=(7788 7789 7790 7791 7792)
sizes_gib=(100 200 5 50 1)

ip -o address show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$local_address" || {
    echo "Expected local address is not configured: $local_address" >&2
    exit 1
}

for i in "${!resources[@]}"; do
    resource="${resources[$i]}"
    path="${backing[$i]}"
    expected_bytes="$((sizes_gib[i] * 1024 * 1024 * 1024))"
    [[ -b "$path" ]] || { echo "Backing device is missing: $path" >&2; exit 1; }
    actual_bytes="$(blockdev --getsize64 "$path")"
    [[ "$actual_bytes" == "$expected_bytes" ]] || {
        echo "$path has $actual_bytes bytes; expected $expected_bytes." >&2
        exit 1
    }
    [[ -z "$(findmnt -rn -S "$path" -o TARGET)" ]] || {
        echo "Backing device is mounted: $path" >&2
        exit 1
    }
    [[ -z "$(lsblk -dnro FSTYPE "$path")" ]] || {
        echo "Backing device already has a recognized signature: $path" >&2
        exit 1
    }
    if ss -Hln "sport = :${ports[$i]}" | grep -q .; then
        echo "Replication port is already listening: ${ports[$i]}" >&2
        exit 1
    fi
    drbdadm -c "$TEMPLATE_DIR/$resource.res" dump "$resource" >/dev/null
done

printf 'Validated %s (%s).\n\n' "$(hostname -f)" "$local_address"
for i in "${!resources[@]}"; do
    source_file="$TEMPLATE_DIR/${resources[$i]}.res"
    target_file="$TARGET_DIR/${resources[$i]}.res"
    printf '%-10s %-12s %-32s -> %s\n' \
        "${resources[$i]}" "${devices[$i]}" "${backing[$i]}" "$target_file"
    if [[ -e "$target_file" ]] && ! cmp -s "$source_file" "$target_file"; then
        diff -u "$target_file" "$source_file" || true
        if [[ "$apply" == true ]]; then
            echo "Refusing to overwrite differing configuration: $target_file" >&2
            exit 1
        fi
    fi
done

if [[ "$apply" == false ]]; then
    echo
    echo 'Preview only; no configuration was installed.'
    exit 0
fi

install -d -m 0755 "$TARGET_DIR"
for resource in "${resources[@]}"; do
    source_file="$TEMPLATE_DIR/$resource.res"
    target_file="$TARGET_DIR/$resource.res"
    if [[ ! -e "$target_file" ]]; then
        install -o root -g root -m 0644 "$source_file" "$target_file"
    fi
done

drbdadm dump all >/dev/null
echo
echo 'Installed and parsed all five resource files; DRBD remains uninitialized and down.'
