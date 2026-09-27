# Retire the unused legacy NFS LV from the MicroK8s HA design

The target HA service has **three exported data resources** (`kube`,
`grafana`, `postgres`) and one private `nfs-state` resource. It has no
`nfs` DRBD resource and no HA export for `/srv/nfs-lv`. The existing data
resources keep DRBD minors 1–3 and ports 7789–7791; `nfs-state` keeps minor 4
and port 7792. Minor 0 and port 7788 are retired, not reassigned.

## Execution status — 2026-09-26

Steps 1–6 are complete. The user confirmed steps 1–3 complete; steps 4–6
were performed and verified on both hosts. Step 7 remains pending and is a
separate storage operation. The suspect `nfs-vg` disk has not been repaired,
replaced, or decommissioned, and no LVs or VGs have been removed.

- The legacy `/srv/nfs-lv` export and boot mount were retired. The three
  `/srv/kube-*` exports remain active on `ubuntu-slave1`.
- DRBD resource `nfs` was demoted, taken down on both hosts, and its installed
  `/etc/drbd.d/nfs.res` removed after backups were saved under
  `/var/backups/drbd-retired/`. `/dev/drbd0` is absent on both hosts.
- `ubuntu-slave1` now backs `nfs-state` with the 1 GiB
  `kube-vg/drbd-nfs-state` LV (LV UUID
  `36uqnM-HwHB-VhvI-LWfx-cim8-pW98-vbDZTt`) on the verified `kube-vg` PV.
  Its prior `nfs-state.res` was backed up under
  `/var/backups/drbd-retired/`; the new LV metadata was initialized and
  synchronized from the still-authoritative `ubuntu-master2` copy. The old
  `nfs-vg/drbd-nfs-state` LV remains present and unused.
- At 15:01 UTC, `nfs-ha-drbd-readiness.sh` passed on both hosts. All four
  retained resources were Connected and `UpToDate/UpToDate`, with the planned
  Primary/Secondary roles. The service inventory confirmed only the three
  expected exports on `ubuntu-slave1`; Pacemaker is inactive on both hosts.

The DRBD checkpoint is ready. HA activation and removal of any remaining
`nfs-vg` storage are not part of these completed steps.

## Initial observations before retirement

The live MicroK8s API showed no StorageClass or PV using `/srv/nfs-lv`.
`kube-nfs`, `kube-grafana`, and `kube-postgres` and their bound PVs use
`/srv/kube-lv`, `/srv/kube-grafana`, and `/srv/kube-postgres` on the separate
`kube-vg` disk. A bound claim is not proof of an active mount; at the inspection
no running Pod referenced an NFS PVC.
The repository NFS shutdown dry run reported all discovered NFS-backed
Deployments and StatefulSets at zero replicas; it does not inventory external
clients or one-off Jobs. The [NFS CSI driver parameters](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md)
describe the server/share fields used by these PVs and StorageClasses.

At that inspection, on `ubuntu-slave1`, `/srv/nfs-lv` was mounted from
`nfs-vg/nfs-lv` and exported. `/etc/exports` had **three entries** for it:
`192.168.1.0/24`, `10.0.0.0/24`, and
`[2601:84:8800:9a50::0]/64`. `/etc/fstab` had a separate boot-mount entry
for `/srv/nfs-lv`. The active NFSv4 client from `ubuntu-mini` does not prove
which export it uses. Check non-Kubernetes clients and preserve any data they
need before removing this export. The `nfs-vg` disk has logged I/O errors;
avoid repeated reads and do not assume its 1.3 GiB of observed data is safe.

The previous five-resource preparation created `nfs` DRBD and `nfs-state` on
`nfs-vg` on `ubuntu-slave1`, with corresponding LVs on `ubuntu-master2`.
Those installed paths have since been retired or updated as recorded above.

## Maintenance sequence

1. **[COMPLETE 2026-09-26] Protect data and identify consumers.** Inventory client mount/fstab and
   automount configurations, application owners, and any direct use of
   `/srv/nfs-lv`. Inspect recent NFS activity without repeated full-disk
   scans. Backups or recovery copies are not required for this demo/dev system.
   Resolve the physical disk/cable/controller fault first. Do not run LVM
   writes or DRBD reattach against the failing `nfs-vg` path.
2. **[COMPLETE 2026-09-26] Retire the legacy export in a client maintenance window.** Stop or move
   the identified clients. Backing up `/etc/exports` and `/etc/fstab` is
   optional in this demo/dev environment. Remove only
   the three `/srv/nfs-lv` entries from `/etc/exports`, then reload exports
   using the host's normal `exportfs -ra` procedure. Confirm `exportfs -v`
   still lists all three `kube-*` exports and no `/srv/nfs-lv` entry. Do not
   stop the NFS server while Kubernetes clients still depend on it.
3. **[COMPLETE 2026-09-26] Remove its boot mount.** Remove only the `/srv/nfs-lv` line and its stale
   comment from `/etc/fstab`, reload systemd's generated units, then unmount
   `/srv/nfs-lv` after clients have released it. Verify `findmnt` has no
   `/srv/nfs-lv` mount. If unmount or I/O blocks, stop and return to the
   storage incident procedure; do not force through it.
4. **[COMPLETE 2026-09-26] Retire the obsolete DRBD resource.** During a coordinated two-host
   storage window, confirm `/dev/drbd0` is not mounted or managed by
   Pacemaker. Demote and take down only resource `nfs` on both hosts, remove
   only `/etc/drbd.d/nfs.res` after preserving a copy, and verify it cannot
   restart. Do not reuse its filesystem or copy legacy data into it. Remove
   the now-unused `drbd-nfs` LVs only after the physical disk and LVM
   identities are healthy and the operator has reviewed the exact targets.
   No step in this runbook calls for removing `nfs-vg/nfs-lv` automatically.
5. **[COMPLETE 2026-09-26] Move private NFS recovery state off the suspect disk.** Verify
   `kube-vg` on `ubuntu-slave1` has at least 1 GiB free plus the required
   reserve (the last observed free space was 56.51 GiB). Create a new 1 GiB
   `kube-vg/drbd-nfs-state` LV only after reviewing its PV identity and
   capacity. Keep `ubuntu-master2` as the authoritative DRBD source; it
   already holds the new, empty ext4 state filesystem. In a separate reviewed
   DRBD procedure, disconnect/take down only the peer `nfs-state` resource,
   update its installed backing path to `kube-vg`, initialize metadata on
   the **new** LV, and synchronize from `ubuntu-master2`. Never format its
   backing LV or select the old `nfs-vg` copy as a source. Retire the old
   `nfs-vg/drbd-nfs-state` LV only after successful verification.
6. **[COMPLETE 2026-09-26] Verify the four-resource design.** Both hosts must show `kube`,
   `grafana`, `postgres`, and `nfs-state` Connected and
   `UpToDate/UpToDate`; `nfs` and `/dev/drbd0` must be gone. The peer
   `nfs-state` must use `kube-vg`. Run
   `scripts/nfs-ha-drbd-readiness.sh` on each host and review the three
   surviving exports. Update installed configs on both nodes as part of
   this reviewed retirement, then continue the HA runbook.
7. **[PENDING] Remove the legacy LV/VG only when safe.** After confirming no consumers,
   mounts, exports, or needed data remain, assess whether the failing disk is
   to be repaired, replaced, or decommissioned. Any `lvremove`, `vgremove`,
   or `pvremove` is a separate destructive storage operation requiring exact
   identities and a healthy I/O path; backups are not required for this
   demo/dev environment. The MicroK8s HA work does not
   require those removals to proceed once no HA resource uses `nfs-vg`.

No Kubernetes StorageClass, PV, or PVC needs changing solely to retire
`/srv/nfs-lv`. Later HA cutover changes the three existing StorageClasses and
rebinds their existing PVs to the VIP and `/srv/ha/kube-*` exports, as
described in the [overview](drbd-pacemaker-nfs-ha-overview.md).
