#!/usr/bin/env bash
# One-time source-node initialization: force initial sync and create ext4.
set -euo pipefail

readonly REQUIRED_SOURCE=ubuntu-master2
apply=false
source_node=

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-drbd-init.sh --source ubuntu-master2 [--apply]

The default validates the connected, all-Secondary DRBD resources and prints
the one-time source initialization commands. --apply promotes each resource
with --force and creates ext4 once through /dev/drbd0 through /dev/drbd4.
Run only after metadata/up completed on both nodes and the preview was reviewed.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --source)
            (( $# >= 2 )) || { usage >&2; exit 2; }
            source_node="$2"
            shift 2
            ;;
        --apply) apply=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ "$source_node" == "$REQUIRED_SOURCE" ]] || {
    echo "The reviewed initialization source is $REQUIRED_SOURCE; pass --source $REQUIRED_SOURCE." >&2
    exit 1
}
(( EUID == 0 )) || { echo 'Run this script with sudo.' >&2; exit 1; }
[[ "$(hostname -s)" == "$source_node" ]] || {
    echo "Refusing source initialization on $(hostname -s); expected $source_node." >&2
    exit 1
}

for command_name in blkid drbdadm findmnt hostname mkfs.ext4; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

resources=(nfs kube grafana postgres nfs-state)
devices=(/dev/drbd0 /dev/drbd1 /dev/drbd2 /dev/drbd3 /dev/drbd4)
labels=(ha-nfs ha-kube ha-grafana ha-postgres ha-nfs-state)

for i in "${!resources[@]}"; do
    resource="${resources[$i]}"
    device="${devices[$i]}"
    [[ "$(drbdadm role "$resource")" == Secondary/Secondary ]] || {
        echo "$resource is not Secondary/Secondary: $(drbdadm role "$resource")" >&2
        exit 1
    }
    [[ "$(drbdadm cstate "$resource")" == Connected ]] || {
        echo "$resource is not Connected: $(drbdadm cstate "$resource")" >&2
        exit 1
    }
    [[ "$(drbdadm dstate "$resource")" == Inconsistent/Inconsistent ]] || {
        echo "$resource data state is not the expected initial Inconsistent/Inconsistent: $(drbdadm dstate "$resource")" >&2
        exit 1
    }
    [[ -b "$device" ]] || { echo "DRBD device is missing: $device" >&2; exit 1; }
    [[ -z "$(findmnt -rn -S "$device" -o TARGET)" ]] || {
        echo "DRBD device is mounted: $device" >&2
        exit 1
    }
    if blkid -p "$device" >/dev/null 2>&1; then
        echo "DRBD device already has a recognized signature: $device" >&2
        exit 1
    fi
done

printf 'Initialization source: %s\n\n' "$(hostname -f)"
for i in "${!resources[@]}"; do
    printf 'drbdadm primary --force %q\n' "${resources[$i]}"
    printf 'mkfs.ext4 -L %q %q\n' "${labels[$i]}" "${devices[$i]}"
done

if [[ "$apply" == false ]]; then
    echo
    echo 'Preview only; no resource was promoted or formatted.'
    exit 0
fi

for i in "${!resources[@]}"; do
    drbdadm primary --force "${resources[$i]}"
    mkfs.ext4 -L "${labels[$i]}" "${devices[$i]}"
done

echo
echo 'Created ext4 once through the five DRBD devices. Nothing was mounted.'
drbdadm status 2>/dev/null || cat /proc/drbd
blkid "${devices[@]}"
