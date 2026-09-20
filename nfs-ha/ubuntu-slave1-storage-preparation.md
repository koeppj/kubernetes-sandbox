# `ubuntu-slave1` storage preparation

## Decision

Do **not** shrink the existing NFS filesystems or logical volumes for the current
DRBD plan. Read-only inspection on 2026-09-20 found enough free extents in each
existing volume group to create all five DRBD backing LVs alongside the legacy
LVs.

| Volume group | Current free space | New allocation | Free after allocation |
|---|---:|---:|---:|
| `nfs-vg` | 897.26 GiB | 101 GiB | 796.26 GiB |
| `kube-vg` | 311.51 GiB | 255 GiB | 56.51 GiB |

The existing 500 GiB, 500 GiB, 20 GiB, and 100 GiB ext4 filesystems stay at
their current sizes and remain mounted. No partition table, PV, filesystem, or
existing LV needs to change. This avoids an unnecessary all-client outage and
the irreversible risk of an offline ext4/LV shrink.

The script checks a 50 GiB minimum remaining reserve in each VG. At the current
layout, `kube-vg` is the limiting pool. Re-run the preview immediately before
allocation because later LV creation can invalidate this decision.

## Verified storage identities

The preparation script is intentionally host-specific and rejects identity
changes.

| Item | Verified identity |
|---|---|
| Host | `ubuntu-slave1.koeppster.lan` |
| `nfs-vg` UUID | `ciyhk9-3ztT-N0Tl-Fc0A-RaiX-9HQB-UdDRS8` |
| `nfs-vg` PV UUID | `eZJSdB-L0oG-Gyb0-ORS5-u1pA-yFmv-tOCROr` |
| `nfs-vg` stable PV path | `/dev/disk/by-id/lvm-pv-uuid-eZJSdB-L0oG-Gyb0-ORS5-u1pA-yFmv-tOCROr` |
| `kube-vg` UUID | `yACJPE-IOuf-9bRI-B3ez-x0D1-NqpX-GzfGp2` |
| `kube-vg` PV UUID | `ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf` |
| `kube-vg` stable PV path | `/dev/disk/by-id/lvm-pv-uuid-ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf` |

Each VG currently has exactly one PV. Device letters `/dev/sdb` and `/dev/sdc`
are observations only and are not used as durable identifiers by the script.

## Procedure

1. Run the read-only preview on `ubuntu-slave1`:

   ```bash
   cd /home/koeppj/projects/kubernetes-sandbox/nfs-ha
   sudo ./scripts/nfs-ha-peer-lvm.sh
   ```

2. Review the host, VG and PV UUIDs, free-space report, five target names, and
   exact `lvcreate` commands. The preview must report that no storage changed.

3. Confirm the five `drbd-*` targets do not exist and that the projected reserve
   still meets the operational requirement. The script enforces 50 GiB per VG;
   choose a larger reserve before execution if expected legacy growth requires
   it.

4. Create only the new backing LVs:

   ```bash
   sudo ./scripts/nfs-ha-peer-lvm.sh --apply
   ```

   The script saves current LVM metadata with `vgcfgbackup`, then creates five
   linear, unformatted LVs. It does not stop NFS, unmount filesystems, initialize
   DRBD, or format anything.

5. Inspect the resulting allocation:

   ```bash
   sudo lvs nfs-vg kube-vg \
     -o lv_name,lv_uuid,vg_name,lv_size,segtype,devices
   sudo vgs nfs-vg kube-vg -o vg_name,vg_size,vg_free,pv_count,lv_count
   findmnt /srv/nfs-lv /srv/kube-lv /srv/kube-grafana /srv/kube-postgres
   sudo exportfs -v
   ```

6. Stop here. DRBD metadata creation, DRBD promotion, filesystem creation, and
   Pacemaker activation belong to later coordinated procedures. Never run
   `mkfs` against `/dev/*-vg/drbd-*`; the filesystems will be created once through
   the corresponding `/dev/drbd*` devices.

LV creation from free extents can occur while the legacy exports remain online.
The later DRBD/NFS activation and data cutover still require maintenance windows.
Run Kubernetes workload discovery and shutdown from a MicroK8s control-plane
host. On 2026-09-20 this worker's local `microk8s kubectl` could not query the
cluster, while active NFS client sessions were present, so a local empty result
must not be treated as proof that no consumers exist.

## If capacity changes before execution

Do not automatically fall back to shrinking. If either VG fails the allocation
plus reserve check, stop and choose among reducing the proposed DRBD capacity,
adding storage, or designing a separately reviewed offline shrink. An offline
shrink requires verified file backups, a complete writer/client outage, export
shutdown, unmount, `e2fsck`, `resize2fs` to an explicitly chosen filesystem
size, a second `e2fsck`, and only then `lvreduce` to a size no smaller than the
filesystem. That decision needs fresh minimum-size and growth evidence for every
affected filesystem; the current inventory does not justify it.
