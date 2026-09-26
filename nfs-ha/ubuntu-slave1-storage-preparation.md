# `ubuntu-slave1` storage preparation: completed history and new state LV

The earlier five-resource LV preparation has already run. Its script is
retired and must not be rerun. The current four-resource target and the
retirement sequence are in the [overview](drbd-pacemaker-nfs-ha-overview.md)
and [retirement runbook](retire-legacy-nfs-lv.md).

The three MicroK8s data DRBD backing LVs already exist in `kube-vg`:
`drbd-kube` (200 GiB), `drbd-grafana` (5 GiB), and `drbd-postgres`
(50 GiB). The remaining local allocation is a **new 1 GiB**
`kube-vg/drbd-nfs-state` LV for private NFS recovery state. Do not create
another data LV and do not allocate HA storage from `nfs-vg`, whose physical
path logged I/O errors during initial synchronization.

The last read-only inspection showed 56.51 GiB free in `kube-vg`. A 1 GiB
allocation would leave about 55.51 GiB, above the earlier 50 GiB reserve,
but the live free extent count and PV identity must be checked again before
any `lvcreate`. The expected `kube-vg` UUID is
`yACJPE-IOuf-9bRI-B3ez-x0D1-NqpX-GzfGp2`, and its sole PV UUID is
`ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf`. Use the stable PV path
`/dev/disk/by-id/lvm-pv-uuid-ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf`.
Disk letters are observations, not identities.

This allocation is part of the [state relocation](retire-legacy-nfs-lv.md),
not a standalone instruction to run now. The existing
`nfs-vg/drbd-nfs-state` is already configured and synchronized; placing a
new LV in `kube-vg` requires a coordinated, resource-specific DRBD procedure
that keeps `ubuntu-master2` authoritative. Never format the backing LV.
The existing legacy `nfs-vg/nfs-lv` remains mounted and exported until its
clients and data have been reviewed and the export is retired in a separate
maintenance window.
