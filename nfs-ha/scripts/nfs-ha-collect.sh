#!/usr/bin/env bash
# Run as the SSH-capable operator on the MicroK8s control plane (not via sudo).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $# == 1 ]] || { echo 'Usage: nfs-ha-collect.sh NEW_PRIVATE_DIRECTORY' >&2; exit 2; }
umask 077
mkdir -m 700 -- "$1"
out="$(realpath "$1")"
failed=0
for host in ubuntu-master2.koeppster.lan ubuntu-slave1.koeppster.lan; do
    if [[ $(hostname -f) == "$host" ]]; then
        runner=(sudo -n bash -s)
    else
        runner=(ssh -o BatchMode=yes -o ConnectTimeout=10 -T "$host" sudo -n bash -s)
    fi
    for check in drbd-readiness service-inventory; do
        "${runner[@]}" < "$SCRIPT_DIR/nfs-ha-$check.sh" > "$out/$host-$check.txt" 2>&1 || failed=1
    done
    "${runner[@]}" > "$out/$host-agents.txt" 2>&1 <<'REMOTE' || failed=1
set -eu
hostname -f
date -u --iso-8601=seconds
dpkg-query -W resource-agents-base resource-agents-extra drbd-utils pacemaker corosync pcs
for agent in linbit/drbd heartbeat/Filesystem heartbeat/nfsserver heartbeat/exportfs heartbeat/IPaddr2; do
    path="/usr/lib/ocf/resource.d/$agent"
    sha256sum "$path"
    OCF_ROOT=/usr/lib/ocf "$path" meta-data
done
for script in /usr/lib/drbd/crm-fence-peer.sh /usr/lib/drbd/crm-unfence-peer.sh; do
    sha256sum "$script"
done
cat /proc/drbd
if [[ -r /proc/fs/nfsd/nfsv4leasetime ]]; then cat /proc/fs/nfsd/nfsv4leasetime; fi
ss -tn 'sport = :2049'
if [[ -r /var/lib/nfs/etab ]]; then cat /var/lib/nfs/etab; fi
# No disk-health scans or LVM probes against the incident disk.
REMOTE
done
microk8s kubectl get sc,pv,pvc -A -o json > "$out/storage.json" || failed=1
microk8s kubectl get pods,jobs,cronjobs -A -o json > "$out/clients.json" || failed=1
microk8s kubectl get ipaddresspools.metallb.io -A -o yaml > "$out/metallb.yaml" || failed=1
"$SCRIPT_DIR/../../bin/shutdown-nfs-workloads.sh" --dry-run > "$out/shutdown-dry-run.txt" 2>&1 || failed=1
"$SCRIPT_DIR/../../bin/restore-nfs-workloads.sh" --dry-run > "$out/restore-dry-run.txt" 2>&1 || failed=1
printf 'Private evidence: %s; failed checks: %s\n' "$out" "$failed"
exit "$failed"
