#!/usr/bin/env bash
# Read-only, local post-initialization checkpoint. Run separately on both peers.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-drbd-readiness.sh

Checks the four retained DRBD resources, their roles, replication state, ext4 signatures
on the initial source, and absence of HA mounts. Makes no changes. A nonzero
exit means the next stage is not ready; synchronization in progress is expected
to produce a nonzero exit until it finishes.
EOF
}

case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }
(( EUID == 0 )) || { echo 'Run with sudo.' >&2; exit 1; }

for command_name in blkid drbdadm findmnt hostname; do
    command -v "$command_name" >/dev/null || { echo "Missing $command_name" >&2; exit 1; }
done

case "$(hostname -s)" in
    ubuntu-master2) local_role=Primary; peer_role=Secondary ;;
    ubuntu-slave1) local_role=Secondary; peer_role=Primary ;;
    *) echo 'Unexpected host; expected ubuntu-master2 or ubuntu-slave1.' >&2; exit 1 ;;
esac

resources=(kube grafana postgres nfs-state)
devices=(/dev/drbd1 /dev/drbd2 /dev/drbd3 /dev/drbd4)
labels=(ha-kube ha-grafana ha-postgres ha-nfs-state)
mounts=(/srv/ha/kube-lv /srv/ha/kube-grafana /srv/ha/kube-postgres /var/lib/nfs-ha)
failures=0

if drbdadm status nfs >/dev/null 2>&1 || [[ -b /dev/drbd0 ]]; then
    echo 'Obsolete nfs DRBD resource is still configured or active; retire it before HA activation.' >&2
    (( failures += 1 ))
fi
if [[ "$(hostname -s)" == ubuntu-slave1 ]]; then
    state_backing="$(drbdadm sh-ll-dev nfs-state)"
    if [[ "$state_backing" != /dev/kube-vg/drbd-nfs-state ]]; then
        echo "Private NFS state still uses $state_backing; move it off nfs-vg." >&2
        (( failures += 1 ))
    fi
fi

printf 'Host: %s\nTime: %s\n' "$(hostname -f)" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
printf '%-12s %-19s %-13s %-25s %-9s\n' Resource Role Connection Data Filesystem

for i in "${!resources[@]}"; do
    resource="${resources[$i]}"
    device="${devices[$i]}"
    role="$(drbdadm role "$resource")"
    connection="$(drbdadm cstate "$resource")"
    data="$(drbdadm dstate "$resource")"
    filesystem='peer check'
    if [[ "$local_role" == Primary ]]; then
        filesystem="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"
        label="$(blkid -s LABEL -o value "$device" 2>/dev/null || true)"
        [[ "$filesystem" == ext4 && "$label" == "${labels[$i]}" ]] || {
            filesystem="INVALID:${filesystem:-missing}/${label:-missing}"
            (( failures += 1 ))
        }
    fi
    printf '%-12s %-19s %-13s %-25s %-9s\n' "$resource" "$role" "$connection" "$data" "$filesystem"
    [[ "$role" == "$local_role/$peer_role" ]] || (( failures += 1 ))
    [[ "$connection" == Connected ]] || (( failures += 1 ))
    [[ "$data" == UpToDate/UpToDate ]] || (( failures += 1 ))
    [[ -b "$device" ]] || (( failures += 1 ))
    if findmnt -rn -S "$device" >/dev/null || findmnt -rn -M "${mounts[$i]}" >/dev/null; then
        echo "Unexpected HA mount: $device or ${mounts[$i]}" >&2
        (( failures += 1 ))
    fi
done

if (( failures > 0 )); then
    printf 'NOT READY: %d failed checks. Do not mount, promote, or activate HA services.\n' "$failures" >&2
    exit 1
fi
echo 'Four-resource DRBD checkpoint ready on this host. Run the same check on the other peer.'
