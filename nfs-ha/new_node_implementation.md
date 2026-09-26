# NFS HA implementation reference

The [overview](drbd-pacemaker-nfs-ha-overview.md) is the current design and
the [next-stage runbook](nfs-ha-next-stage.md) is the current sequence. The
earlier five-resource preparation is complete and its one-time scripts are
retired. This reference retains the current four-resource names and safety
boundaries for the remaining implementation.

## Host and storage identities

| Item | Current value or requirement |
|---|---|
| HA hosts | `ubuntu-slave1.koeppster.lan` (`192.168.1.235`) and `ubuntu-master2.koeppster.lan` (`192.168.1.194`) |
| Existing NFS server | `ubuntu-slave1`; keep its three MicroK8s exports online until a reviewed ownership handoff |
| `ubuntu-slave1` HA storage | `kube-vg` on the disk with PV UUID `ctmQ3z-B6pJ-MBgM-Zdw7-1Xrn-2Tnq-5q4swf` |
| `ubuntu-master2` HA storage | `ubuntu-vg` on the approved Linux PV; exclude the Windows disk and root LV |
| Fencing | Independent device/agent for both hosts, selected and tested before automatic failover |
| VIP | TBD; neither physical node IP is the VIP |

Do not use a `/dev/sd*` letter as a storage identity. On `ubuntu-slave1`,
`nfs-vg` resides on the suspect physical I/O path described in
[status-2026-09-26.md](status-2026-09-26.md). No target HA resource may use
that VG. The old `nfs-vg/drbd-nfs-state` peer backing LV must move to a new
1 GiB LV in `kube-vg` after live capacity and PV identity checks. The current
`kube-vg` free-space observation was 56.51 GiB; the 1 GiB addition would
leave about 55.51 GiB if nothing else changes. The source copy on
`ubuntu-master2` remains authoritative for the private state resource.

## Configuration naming reference

| Resource | `ubuntu-slave1` backing device | `ubuntu-master2` backing device | DRBD device | TCP port | File on both hosts |
|---|---|---|---|---:|---|
| `kube` | `/dev/kube-vg/drbd-kube` | `/dev/ubuntu-vg/drbd-kube` | `/dev/drbd1` | 7789 | `/etc/drbd.d/kube.res` |
| `grafana` | `/dev/kube-vg/drbd-grafana` | `/dev/ubuntu-vg/drbd-grafana` | `/dev/drbd2` | 7790 | `/etc/drbd.d/grafana.res` |
| `postgres` | `/dev/kube-vg/drbd-postgres` | `/dev/ubuntu-vg/drbd-postgres` | `/dev/drbd3` | 7791 | `/etc/drbd.d/postgres.res` |
| `nfs-state` | `/dev/kube-vg/drbd-nfs-state` (new) | `/dev/ubuntu-vg/drbd-nfs-state` | `/dev/drbd4` | 7792 | `/etc/drbd.d/nfs-state.res` |

The `nfs-state` filesystem is mounted at `/var/lib/nfs-ha` and holds
`/var/lib/nfs-ha/state`; it is never exported. Keep existing DRBD device
numbers and ports. The old resource on `/dev/drbd0` and port 7788 must be
retired on both hosts; do not assign it another purpose during this migration.
The repo's `nfs-state.res` template now has the target peer path, but the
installed file still has the old backing path and must be changed only during
the reviewed state-relocation window.

| Pacemaker item | Target name |
|---|---|
| Cluster | `nfs-ha` |
| DRBD primitives | `p-drbd-kube`, `p-drbd-grafana`, `p-drbd-postgres`, `p-drbd-nfs-state` |
| Promotable clones | `cl-drbd-kube`, `cl-drbd-grafana`, `cl-drbd-postgres`, `cl-drbd-nfs-state` |
| Filesystem primitives | `p-fs-kube`, `p-fs-grafana`, `p-fs-postgres`, `p-fs-nfs-state` |
| NFS server and VIP | `p-nfs-server`, `p-nfs-vip` |
| Service group | `g-nfs-ha`: four mounts, server, three export sets, VIP |
| Export IDs | `p-export-kube-<client-id>`, `p-export-grafana-<client-id>`, `p-export-postgres-<client-id>` |
| Candidate fsids | 102, 103, 104 respectively; verify against the active export set |

Use `nfs-ha.koeppster.lan` as a proposed service DNS name only after a free
VIP is reserved. For future live configuration, keep component-local `.env`
values and placeholder-only `.env.sample` files. The consuming components
already use `nfs_server_ip`; change it to the VIP during their cutover, not
during storage retirement.

## Script interfaces and validation

`scripts/nfs-ha-drbd-readiness.sh` and
`scripts/nfs-ha-service-inventory.sh` are read-only local checks. The earlier
LV, DRBD configuration, metadata, and ext4 initialization scripts are
retired and exit before taking action; they document the completed
five-resource initialization but must not be run for the new layout.
Packages already installed by `nfs-ha-packages.sh` remain available.

Before activating HA, verify all four resources are Connected and
`UpToDate/UpToDate` on both hosts, with only one Primary, correct backing
paths, and no obsolete resource. Validate the installed agent metadata,
Corosync configuration, staged Pacemaker CIB, ordering/colocation, NFSv4
scope and recovery directory, exact clients/options, and fencing. Use
`crm_verify` and `crm_simulate` on the staged CIB. No activation script or
rendered CIB exists yet.

Keep `kube-nfs`, `kube-grafana`, and `kube-postgres` StorageClass names.
Their current repository manifests are
`infrastruture/create-storage-class.yaml`,
`grafana+loki/manifests/grafana-storage-class.yaml`, and
`infrastruture/postgres-storage-class.yaml`. Recreate those classes under
the same names with the VIP and new `/srv/ha/kube-*` shares only after the
HA service is validated. Existing PVs retain immutable endpoints and need
per-stack data copy and explicit rebinding. Preserve application PVC names,
set old PVs to `Retain` before removing storage objects, and never let old
and new copies of one stack accept concurrent writes.
