#!/usr/bin/env bash
# Prepare the five unformatted DRBD backing LVs on ubuntu-slave1.
# Preview is the default. --apply performs only LV creation from free extents.
set -euo pipefail

readonly EXPECTED_HOST=ubuntu-slave1
readonly NFS_VG=nfs-vg
readonly NFS_VG_UUID=ciyhk9-3ztT-N0Tl-Fc0A-RaiX-9HQB-UdDRS8
readonly NFS_PV=/dev/disk/by-id/lvm-pv-uuid-eZJSdB-L0oG-Gyb0-ORS5-u1pA-yFmv-tOCROr
readonly NFS_PV_UUID=eZJSdB-L0oG-Gyb0-ORS5-u1pA-yFmv-tOCROr
readonly KUBE_VG=kube-vg
readonly KUBE_VG_UUID=yACJPE-IOuf-9bRI-B3ez-x0D1-NqpX-GzfGp2
readonly KUBE_PV=/dev/disk/by-id/lvm-pv-uuid-ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf
readonly KUBE_PV_UUID=ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf
readonly GIB=$((1024 * 1024 * 1024))
readonly MIN_RESERVE_BYTES=$((50 * GIB))

apply=false

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-peer-lvm.sh [--apply]

Without --apply, validate ubuntu-slave1's LVM identities and capacity and print
the exact LV creation plan. With --apply, create five unformatted linear LVs
from already-free extents. The script never resizes a filesystem, LV, PV, or
partition and never initializes DRBD.
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
[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || {
    echo "Refusing to run on $(hostname -s); expected $EXPECTED_HOST." >&2
    exit 1
}

for command_name in awk hostname lvs lvcreate pvs vgs vgcfgbackup; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

assert_storage_identity() {
    local vg="$1" expected_vg_uuid="$2" pv_path="$3" expected_pv_uuid="$4"
    local actual_vg_uuid actual_pv_uuid pv_count

    [[ -b "$pv_path" ]] || { echo "PV path is not a block device: $pv_path" >&2; exit 1; }
    actual_vg_uuid="$(trim "$(vgs --noheadings -o vg_uuid "$vg")")"
    [[ "$actual_vg_uuid" == "$expected_vg_uuid" ]] || {
        echo "Unexpected UUID for $vg: $actual_vg_uuid" >&2
        exit 1
    }
    actual_pv_uuid="$(trim "$(pvs --noheadings -o pv_uuid "$pv_path")")"
    [[ "$actual_pv_uuid" == "$expected_pv_uuid" ]] || {
        echo "Unexpected PV UUID for $pv_path: $actual_pv_uuid" >&2
        exit 1
    }
    pv_count="$(trim "$(vgs --noheadings -o pv_count "$vg")")"
    [[ "$pv_count" == 1 ]] || {
        echo "$vg has $pv_count PVs; expected exactly one." >&2
        exit 1
    }
}

free_bytes() {
    local vg="$1" free_extents extent_bytes
    read -r free_extents extent_bytes < <(
        vgs --noheadings --units b --nosuffix -o vg_free_count,vg_extent_size "$vg"
    )
    printf '%s' "$((free_extents * extent_bytes))"
}

assert_capacity() {
    local vg="$1" allocation_gib="$2" available required
    available="$(free_bytes "$vg")"
    required="$((allocation_gib * GIB + MIN_RESERVE_BYTES))"
    if (( available < required )); then
        printf '%s has %.2f GiB free; %.2f GiB is required for allocation plus reserve.\n' \
            "$vg" "$(awk -v b="$available" 'BEGIN {print b/1073741824}')" \
            "$(awk -v b="$required" 'BEGIN {print b/1073741824}')" >&2
        exit 1
    fi
}

assert_target_absent() {
    local vg="$1" lv="$2"
    if lvs "$vg/$lv" >/dev/null 2>&1; then
        echo "Target already exists: $vg/$lv" >&2
        echo 'Inspect the partial state and do not remove or overwrite it automatically.' >&2
        exit 1
    fi
}

assert_storage_identity "$NFS_VG" "$NFS_VG_UUID" "$NFS_PV" "$NFS_PV_UUID"
assert_storage_identity "$KUBE_VG" "$KUBE_VG_UUID" "$KUBE_PV" "$KUBE_PV_UUID"
assert_capacity "$NFS_VG" 101
assert_capacity "$KUBE_VG" 255

targets=(
    'nfs-vg drbd-nfs 100G'
    'nfs-vg drbd-nfs-state 1G'
    'kube-vg drbd-kube 200G'
    'kube-vg drbd-grafana 5G'
    'kube-vg drbd-postgres 50G'
)

for target in "${targets[@]}"; do
    read -r vg lv _ <<< "$target"
    assert_target_absent "$vg" "$lv"
done

printf 'Validated host: %s\n\n' "$(hostname -f)"
vgs "$NFS_VG" "$KUBE_VG" -o vg_name,vg_uuid,vg_size,vg_free,pv_count,lv_count
printf '\nProjected free space after allocation (minimum reserve: 50.00 GiB):\n'
printf '  %-8s %.2f GiB\n' "$NFS_VG" \
    "$(awk -v b="$(free_bytes "$NFS_VG")" 'BEGIN {print (b/1073741824)-101}')"
printf '  %-8s %.2f GiB\n' "$KUBE_VG" \
    "$(awk -v b="$(free_bytes "$KUBE_VG")" 'BEGIN {print (b/1073741824)-255}')"
printf '\nPlanned LV creation (existing filesystems remain mounted and unchanged):\n'
for target in "${targets[@]}"; do
    read -r vg lv size <<< "$target"
    if [[ "$vg" == "$NFS_VG" ]]; then pv="$NFS_PV"; else pv="$KUBE_PV"; fi
    printf '  lvcreate --type linear --size %s --name %s --zero n --wipesignatures n %s %s\n' \
        "$size" "$lv" "$vg" "$pv"
done

if [[ "$apply" == false ]]; then
    printf '\nPreview only; no storage was changed. Re-run with --apply after review.\n'
    exit 0
fi

printf '\nSaving current LVM metadata, then creating the reviewed targets...\n'
vgcfgbackup "$NFS_VG"
vgcfgbackup "$KUBE_VG"

for target in "${targets[@]}"; do
    read -r vg lv size <<< "$target"
    if [[ "$vg" == "$NFS_VG" ]]; then pv="$NFS_PV"; else pv="$KUBE_PV"; fi
    lvcreate --type linear --size "$size" --name "$lv" \
        --zero n --wipesignatures n "$vg" "$pv"
done

printf '\nCreated backing LVs; no filesystems or DRBD metadata were created:\n'
lvs "$NFS_VG" "$KUBE_VG" -o lv_name,lv_uuid,vg_name,lv_size,segtype,devices
