#!/usr/bin/env bash
# Read-only local inventory for planning the NFS/Pacemaker handoff.
set -euo pipefail

if (( $# != 0 )); then
    echo 'Usage: sudo ./nfs-ha-service-inventory.sh' >&2
    exit 2
fi
(( EUID == 0 )) || { echo 'Run with sudo.' >&2; exit 1; }

for command_name in exportfs findmnt hostname ip systemctl; do
    command -v "$command_name" >/dev/null || { echo "Missing $command_name" >&2; exit 1; }
done

case "$(hostname -s)" in
    ubuntu-master2|ubuntu-slave1) ;;
    *) echo 'Unexpected host; expected an NFS HA peer.' >&2; exit 1 ;;
esac

printf 'Host: %s\nTime: %s\n' "$(hostname -f)" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
printf '\nIPv4 addresses:\n'
ip -4 -brief address show
printf '\nRelevant service states (enabled / active):\n'
for unit in drbd.service corosync.service pacemaker.service pcsd.service nfs-server.service nfs-kernel-server.service; do
    printf '%-26s %-12s %s\n' "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null || true)" "$(systemctl is-active "$unit" 2>/dev/null || true)"
done
printf '\nMounted source and target paths:\n'
for mountpoint in /srv/nfs-lv /srv/kube-lv /srv/kube-grafana /srv/kube-postgres /srv/ha/kube-lv /srv/ha/kube-grafana /srv/ha/kube-postgres /var/lib/nfs-ha; do
    findmnt -rn -M "$mountpoint" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
done
printf '\nActive exports (authoritative on the legacy host):\n'
exportfs -v
printf '\nStatic export entries, if any:\n'
if [[ -f /etc/exports ]]; then
    cat /etc/exports
fi
if [[ -d /etc/exports.d ]]; then
    for file in /etc/exports.d/*.exports; do
        [[ -f "$file" ]] || continue
        printf '%s\n' "$file"
        cat "$file"
    done
fi
printf '\nResource agent files:\n'
for agent in /usr/lib/ocf/resource.d/linbit/drbd /usr/lib/ocf/resource.d/heartbeat/Filesystem /usr/lib/ocf/resource.d/heartbeat/nfsserver /usr/lib/ocf/resource.d/heartbeat/exportfs /usr/lib/ocf/resource.d/heartbeat/IPaddr2; do
    if [[ -f "$agent" ]]; then echo "present $agent"; else echo "missing $agent"; fi
done
