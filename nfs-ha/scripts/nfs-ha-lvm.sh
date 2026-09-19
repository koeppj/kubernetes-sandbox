#!/usr/bin/env bash
# Review manually, then run with sudo on ubuntu-master2.koeppster.lan.
# Creates five unformatted backing LVs (356 GiB total). No DRBD initialization.
# This script executes immediately; it has no plan/create/grow or --apply modes.
# If a command fails, earlier allocations remain. Inspect with lvs before retrying;
# existing LV names cause lvcreate to fail rather than being skipped or replaced.
set -euo pipefail

if (( $# != 0 )); then
    echo 'Usage: sudo ./nfs-ha-lvm.sh (creates LVs immediately; review script first)' >&2
    exit 2
fi

PV=/dev/disk/by-id/ata-WDC_WD30EZRX-00D8PB0_WD-WMC4N0H7PM9A-part3

lvcreate --type linear --size 100G --name drbd-nfs       --zero n --wipesignatures n ubuntu-vg "$PV"
lvcreate --type linear --size 200G --name drbd-kube      --zero n --wipesignatures n ubuntu-vg "$PV"
lvcreate --type linear --size   5G --name drbd-grafana   --zero n --wipesignatures n ubuntu-vg "$PV"
lvcreate --type linear --size  50G --name drbd-postgres  --zero n --wipesignatures n ubuntu-vg "$PV"
lvcreate --type linear --size   1G --name drbd-nfs-state --zero n --wipesignatures n ubuntu-vg "$PV"

lvs ubuntu-vg -o lv_name,lv_uuid,lv_size,segtype,devices
