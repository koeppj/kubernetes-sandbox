#!/usr/bin/env bash
# Offline only; never use --live-check or --in-place here.
set -euo pipefail
[[ $# == 1 || ( $# == 2 && $2 == --cib-only ) ]] || { echo 'Usage: nfs-ha-validate-stage.sh STAGE_DIR' >&2; exit 2; }
cib_only=${2:-}
stage="$(realpath "$1")"
umask 077
failed=0
for variant in stopped start; do
    file=cib-stopped.xml
    [[ $variant == start ]] && file=simulation-start.xml
    crm_verify --xml-file "$stage/$file" --verbose > "$stage/verify-$variant.log" 2>&1 || failed=1
done
for scenario in both master2-only slave1-only; do
    args=(--xml-file "$stage/simulation-start.xml" --simulate)
    case "$scenario" in
        both) args+=(--quorum=true --node-up=ubuntu-master2.koeppster.lan --node-up=ubuntu-slave1.koeppster.lan) ;;
        master2-only) args+=(--quorum=false --node-up=ubuntu-master2.koeppster.lan --node-down=ubuntu-slave1.koeppster.lan) ;;
        slave1-only) args+=(--quorum=false --node-up=ubuntu-slave1.koeppster.lan --node-down=ubuntu-master2.koeppster.lan) ;;
    esac
    crm_simulate "${args[@]}" --save-dotfile "$stage/$scenario.dot" --save-output "$stage/$scenario.xml" > "$stage/$scenario.log" 2>&1 || failed=1
done
# A clean start requires both votes. A subsequent loss of either vote must
# schedule the already-running service to stop on master2.
if grep -Eq 'Resource action: p-nfs-vip +start on ubuntu-master2' "$stage/both.log"; then
    :
else
    failed=1
fi
for scenario in master2-only slave1-only; do
    if grep -Eq 'Resource action: p-nfs-vip +(start|promote)' "$stage/$scenario.log"; then
        failed=1
    fi
done
crm_simulate --xml-file "$stage/both.xml" --simulate --quorum=false \
    --node-down=ubuntu-slave1.koeppster.lan \
    --save-dotfile "$stage/quorum-loss.dot" --save-output "$stage/quorum-loss.xml" \
    > "$stage/quorum-loss.log" 2>&1 || failed=1
grep -Eq 'Resource action: p-nfs-vip +stop on ubuntu-master2' "$stage/quorum-loss.log" || failed=1
# Parse with an ephemeral private key, not the live /etc/corosync/authkey.
# No daemon is started. The production key must be created separately and shared.
if [[ $cib_only != --cib-only ]]; then
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
head -c 256 /dev/urandom > "$tmp/authkey"
sed "/^totem {/a\\    keyfile: $tmp/authkey" "$stage/corosync.conf" > "$tmp/corosync.conf"
corosync -t -c "$tmp/corosync.conf" > "$stage/corosync-parse.log" 2>&1 || failed=1
fi
if (( failed )); then
    echo "Offline checks failed; inspect $stage/*.log." >&2
    exit 1
fi
printf '%s\n' 'Syntax and offline scheduling finished. Review graphs; this does not test live quorum, storage, or recovery.'
