#!/usr/bin/env bash
# Preview or install the common DRBD/Pacemaker/NFS package set on either HA node.
# Package-triggered daemon starts are suppressed during --apply.
set -euo pipefail

readonly POLICY=/usr/sbin/policy-rc.d
readonly POLICY_BACKUP=/usr/sbin/policy-rc.d.nfs-ha-original

apply=false

usage() {
    cat <<'EOF'
Usage: sudo ./nfs-ha-packages.sh [--apply]

The default is an apt simulation. --apply refreshes package indexes, repeats
the simulation, and installs the reviewed package set without starting HA
services. On ubuntu-slave1 the existing NFS server is left enabled and running.
EOF
}

case "${1:-}" in
    '') ;;
    --apply) apply=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

host="$(hostname -s)"
case "$host" in
    ubuntu-slave1|ubuntu-master2) ;;
    *) echo "Refusing to run on $host; expected an NFS HA node." >&2; exit 1 ;;
esac

packages=(
    lvm2 drbd-utils
    pacemaker pacemaker-cli-utils corosync pcs
    resource-agents-base resource-agents-extra
    nfs-kernel-server nfs-common
    rsync acl attr smartmontools shellcheck
)

simulate() {
    local output
    output="$(LC_ALL=C apt-get --simulate --no-install-recommends install "${packages[@]}")"
    printf '%s\n' "$output"
    if grep -Eq '^[1-9][0-9]* upgraded,' <<< "$output" ||
       grep -Eq '[1-9][0-9]* to remove' <<< "$output" ||
       grep -Eq '^Inst (linux-image|linux-modules|.*dkms)' <<< "$output"; then
        echo 'Refusing a simulation containing upgrades, removals, a kernel, or DKMS.' >&2
        exit 1
    fi
}

printf 'Host: %s\n' "$(hostname -f)"
printf 'Command: apt-get --no-install-recommends install'
printf ' %q' "${packages[@]}"
printf '\n\n'
simulate

if [[ "$apply" == false ]]; then
    echo
    echo 'Preview only; no packages or services were changed.'
    exit 0
fi

(( EUID == 0 )) || { echo 'Run --apply with sudo.' >&2; exit 1; }
[[ ! -e "$POLICY_BACKUP" && ! -L "$POLICY_BACKUP" ]] || {
    echo "Stale policy backup exists: $POLICY_BACKUP" >&2
    exit 1
}

policy_moved=false
temporary_policy=false
restore_policy() {
    local status=$?
    if [[ "$temporary_policy" == true ]]; then
        rm -f "$POLICY"
    fi
    if [[ "$policy_moved" == true ]]; then
        mv "$POLICY_BACKUP" "$POLICY"
    fi
    exit "$status"
}
trap restore_policy EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ -e "$POLICY" || -L "$POLICY" ]]; then
    mv "$POLICY" "$POLICY_BACKUP"
    policy_moved=true
fi
temporary_policy=true
cat > "$POLICY" <<'EOF'
#!/bin/sh
# NFS HA preparation boundary: suppress package-triggered service actions.
exit 101
EOF
chmod 0755 "$POLICY"

apt-get update
simulate
DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
    apt-get --yes --no-install-recommends install "${packages[@]}"

systemctl disable drbd.service corosync.service pacemaker.service pcsd.service 2>/dev/null || true
if [[ "$host" == ubuntu-master2 ]]; then
    systemctl disable nfs-server.service nfs-kernel-server.service 2>/dev/null || true
fi

printf '\nInstalled versions:\n'
dpkg-query -W -f='${Package}\t${Version}\n' "${packages[@]}"
printf '\nService state (ubuntu-slave1 legacy NFS is intentionally untouched):\n'
systemctl is-enabled drbd.service corosync.service pacemaker.service pcsd.service 2>/dev/null || true
systemctl is-active drbd.service corosync.service pacemaker.service pcsd.service 2>/dev/null || true
if command -v modinfo >/dev/null 2>&1; then
    printf '\nDRBD kernel module version: '
    modinfo -F version drbd 2>/dev/null || echo 'not reported by modinfo'
fi
