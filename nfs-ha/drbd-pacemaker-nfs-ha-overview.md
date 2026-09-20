# DRBD + Pacemaker Active/Passive NFS HA Overview

## Purpose and scope

This design keeps the existing NFS-based PersistentVolume workflow in the Ubuntu 24.04 / MicroK8s environment while removing the single-NFS-server maintenance outage. It provides one active NFS server at a time, a stable virtual IP (VIP) for Kubernetes clients, and synchronous replication of the exported filesystems to a second NFS node.

The primary goal is planned maintenance: move NFS to the peer, update or reboot the original node, then return it to service without first identifying or shutting down every application that uses a PVC. Unplanned failover is also supported when proper fencing is configured. A brief client I/O pause during failover is expected; NFSv4 hard mounts normally wait and retry rather than immediately failing the mount.

This is a two-node active/passive NFS design, not an active/active NFS cluster and not a substitute for a separate backup strategy.

The hosts are **`ubuntu-slave1.koeppster.lan`** (existing NFS server) and **`ubuntu-master2.koeppster.lan`** (new HA peer). No additional server is planned. This is a development and demo environment: planned outages are acceptable. Prefer a straightforward, operator-reviewed migration over elaborate arrangements to keep every stack online.

The selected approach is a **data-copy migration into new DRBD-backed filesystems**, followed by stack-by-stack cutovers over multiple maintenance windows or weekends. Allocate the new backing LVs from existing free extents and do not convert the original filesystems to DRBD in place. Read-only inspection on 2026-09-20 confirmed that `ubuntu-slave1` does not need an initial filesystem/LV shrink for the planned sizes. See [`ubuntu-slave1` storage preparation](ubuntu-slave1-storage-preparation.md) and [new node implementation](new_node_implementation.md) for host-specific preparation.

## Current storage inventory

The current NFS host, `ubuntu-slave1.koeppster.lan`, has four separate local ext4 filesystems on LVM logical volumes. Preserve their separation in four new DRBD data resources and exports. The inventory below is a planning baseline; recheck usage and free extents before allocating the new LVs.

| Existing mount/export | Current backing LV | Provisioned size | Observed use | Target DRBD backing LV |
|---|---|---:|---:|---:|
| `/srv/nfs-lv` | `nfs-vg/nfs-lv` | 500G | ~1.3G | **100G** |
| `/srv/kube-lv` | `kube-vg/kube-lv` | 500G | ~3.2G | **200G** |
| `/srv/kube-grafana` | `kube-vg/kube-grafana` | 20G | ~51M | **5G** |
| `/srv/kube-postgres` | `kube-vg/kube-postgres` | 100G | ~222M | **50G** |

Add a **1 GiB** backing LV named `drbd-nfs-state`, with DRBD resource `nfs-state`, mounted at `/var/lib/nfs-ha`, for private NFS recovery state. It is never exported. Total new backing allocation is **356 GiB per node**: four data resources plus one state resource. These are backing-device sizes; internal DRBD metadata and ext4 overhead reduce usable capacity. Leave additional VG reserve.

As verified on 2026-09-20, `nfs-vg` has 897.26 GiB free and `kube-vg` has 311.51 GiB free. After allocating the planned 101 GiB and 255 GiB respectively, they retain about 796.26 GiB and 56.51 GiB. Budget the VGs separately; their combined free space is not one allocation pool. Recheck immediately before creation and monitor the smaller `kube-vg` reserve.

The export roots themselves are `65534:65534` and mode `0777`; the meaningful differences are their NFS export options and the ownership within their PVC directories.

## Configuration names

Use these planned names consistently in scripts, templates, and migration records. They describe the target configuration, not resources already deployed. Existing source LVs retain their original names.

| DRBD resource | New LV on `ubuntu-slave1` | New LV on `ubuntu-master2` | HA mount/export | Kubernetes StorageClass |
|---|---|---|---|---|
| `nfs` | `nfs-vg/drbd-nfs` | `ubuntu-vg/drbd-nfs` | `/srv/ha/nfs-lv` | None currently mapped; inventory external consumers |
| `kube` | `kube-vg/drbd-kube` | `ubuntu-vg/drbd-kube` | `/srv/ha/kube-lv` | `kube-nfs` |
| `grafana` | `kube-vg/drbd-grafana` | `ubuntu-vg/drbd-grafana` | `/srv/ha/kube-grafana` | `kube-grafana` |
| `postgres` | `kube-vg/drbd-postgres` | `ubuntu-vg/drbd-postgres` | `/srv/ha/kube-postgres` | `kube-postgres` |
| `nfs-state` | `nfs-vg/drbd-nfs-state` | `ubuntu-vg/drbd-nfs-state` | `/var/lib/nfs-ha` (private, not exported) | None |

This assigns **101 GiB** of new backing LVs to `nfs-vg` and **255 GiB** to `kube-vg` on `ubuntu-slave1`, subject to live capacity verification before allocation. `/dev/<VG>/<LV>` is the backing-device path, not the filesystem mount source; mount through DRBD.

Name the Corosync/Pacemaker cluster `nfs-ha`, its service group `g-nfs-ha`, the NFS primitive `p-nfs-server`, and the VIP primitive `p-nfs-vip`. Use `nfs-ha.koeppster.lan` as the proposed service DNS name after DNS configuration, with a separately reserved VIP; neither host's physical IP becomes the VIP. Keep the existing `nfs_server_ip` component variable and set it to that VIP during cutover. Do not assume the proposed DNS name already resolves.

The [implementation naming reference](new_node_implementation.md#configuration-naming-reference) defines DRBD devices/ports, Pacemaker IDs, configuration files, and migration artifact names. The [script interfaces](new_node_implementation.md#script-interfaces) distinguish existing entrypoints from proposed scripts. `nfs-ha-peer-lvm.sh` now previews and creates the source-host backing LVs without resizing existing storage. DRBD initialization, activation, migration, and rollback scripts remain planned.

## Target architecture

```text
MicroK8s workers / NFS CSI
            |
            | NFSv4.x over TCP, hard mounts
            v
     NFS virtual IP (VIP)
            |
  +---------+---------+
  |                   |
ubuntu-slave1       ubuntu-master2
active or standby   standby or active
  |                   |
  +-- DRBD Protocol C-+
       (five resources)
```

Use free space in the existing `ubuntu-vg` on `ubuntu-master2` and the existing free extents in `nfs-vg` and `kube-vg` on `ubuntu-slave1`. No spare dedicated disk or new VG is required. Both nodes create corresponding backing LVs for all five resources. Match backing sizes and configure explicit node-specific paths; VG/LV names need not match between nodes.

```text
existing local disk
  -> existing LVM PV/VG -> new backing LV
  -> DRBD resource (/dev/drbd/by-res/<resource>)
  -> ext4
  -> /srv/ha/... mount point (or private NFS state mount)
  -> Pacemaker-managed NFS export
```

DRBD uses **Protocol C**: while connected and replicating, writes are acknowledged after local and peer disk completion. Whether writes continue without a peer depends on the configured failure policy; Protocol C alone does not prevent split brain. Only one node may be DRBD Primary and mount/export the filesystems. Pacemaker and Corosync manage the promoted DRBD role, filesystems, NFS service/exports, and the VIP as one ordered, colocated service.

Required resource order:

```text
fence failed peer (when required)
  -> promote all DRBD resources on one node
  -> mount all five filesystems, including private NFS recovery state
  -> start/manage clustered NFS service and exports
  -> assign VIP
```

The reverse order applies during shutdown/failback. The VIP must never advertise an NFS server that does not own the promoted DRBD resources and mounted filesystems.

## Why DRBD is above LVM

LVM supplies the local block device that DRBD replicates; the filesystem is created on the DRBD device, not directly on the LV.

```text
physical disk -> LVM PV/VG -> LV -> DRBD -> ext4 -> NFS export
```

For example, `kube-vg/drbd-postgres` on `ubuntu-slave1` and `ubuntu-vg/drbd-postgres` on `ubuntu-master2` back DRBD resource `postgres`. Its ext4 filesystem is created on `/dev/drbd3` and mounted only on the active node at `/srv/ha/kube-postgres`.

This lets both nodes have ordinary local disks while DRBD handles synchronous block replication. The replicated ext4 contents include the PVC files, numeric ownership, modes, ACLs, and PostgreSQL data/WAL; they are not copied or reconstructed separately on the standby node.

## Why use LVM rather than raw partitions

DRBD works with either an LV or a normal disk partition. LVM has no intrinsic HA advantage, but is the better fit here because the current layout already uses LVM and the target contains multiple volumes of different sizes.

- It creates precisely sized backing devices without partition-table changes.
- It keeps unallocated capacity available for later extension.
- It makes expansion simpler and more controlled than repartitioning a disk.
- It supports the four distinct exports without combining their operational roles.

The important limitation applies to both designs: a DRBD-backed filesystem should be treated as **grow-oriented**. Raw partitions do not avoid DRBD shrink complexity; they replace `lvreduce` with partition-table surgery.

## NFS export semantics to preserve

Configure the same NFS export definitions/options on both NFS nodes, but have Pacemaker activate the exports only with the active filesystem/service. Retain the existing allowed client networks and IPv6 scope where currently used.

In particular, preserve these exact special mappings:

| Original export | New HA export | Required identity behavior |
|---|---|---|
| `/srv/kube-grafana` | `/srv/ha/kube-grafana` | `root_squash,anonuid=472,anongid=472` |
| `/srv/kube-postgres` | `/srv/ha/kube-postgres` | `root_squash,anonuid=999,anongid=999` |

Numeric IDs matter; local account names on the standby host do not. Grafana content uses `472:472`; PostgreSQL content uses `999:999`, including restrictive database directory/file modes. The general exports retain their current normal `root_squash` behavior.

Map the general exports to `/srv/ha/nfs-lv` and `/srv/ha/kube-lv`. Keep these distinct paths permanently so old and new filesystems can coexist during migration without mounting over the originals. Configure shared recovery state at `/var/lib/nfs-ha/state`, consistent NFS server scope, and stable export filesystem IDs across the HA pair.

Continue using NFSv4 over TCP with **hard** client mounts. Keep the StorageClasses/client configuration pointed at the single VIP (or a DNS name resolving only to that VIP), not either node’s fixed address. Validate NFSv4 recovery/stable-state handling in the selected Pacemaker NFS resource design so client state is coordinated across failover; do not merely run two unrelated `nfs-kernel-server` instances against the same VIP.

## Cluster safety: Corosync, Pacemaker, and fencing

Corosync provides cluster membership/messaging; Pacemaker is the service manager. In a two-node cluster, a broken inter-node network can look like a peer failure to both servers. Without protection, both could promote DRBD and corrupt the filesystem (split brain).

Use a working STONITH/fencing mechanism before treating automatic failover as safe—for example IPMI, iDRAC, iLO, managed PDU, or hypervisor fencing. Pacemaker must be able to power off or otherwise prove the former active peer is no longer using storage before it promotes the standby after an ambiguous failure.

Do not leave `stonith-enabled=false` as the finished configuration. A quorum/witness strategy appropriate to the environment should also be selected and tested, but it does not replace fencing for protecting a single-writer replicated filesystem.

## Migration on the existing two hosts

### Prepare capacity and the HA service

1. Review live storage identities, usage, backups, and the per-VG allocation plan. Create the five new backing LVs on `ubuntu-master2` using its existing Linux PV; exclude its Windows disk and root LV.
2. On `ubuntu-slave1`, run `sudo ./nfs-ha/scripts/nfs-ha-peer-lvm.sh` from the repository root and review its identity, capacity, reserve, and exact-command output. The current plan uses already-free extents and leaves all four legacy filesystems mounted and unchanged.
3. Run the same script with `--apply` to save LVM metadata and create the five unformatted backing LVs. Inspect their sizes and backing PVs. Do not format the LVs directly or initialize DRBD in this step.
4. Schedule a shared outage for DRBD initialization, NFS ownership changes, and failover testing. Run workload discovery and shutdown from a MicroK8s control-plane host; the local worker `microk8s kubectl` cannot enumerate this cluster. Separately stop Jobs, CronJob writers, unmanaged Pods, and non-Kubernetes clients that use the affected exports.
5. Configure all five DRBD resources, explicitly designate the initialization source, create ext4 once on each **new DRBD device**, and complete synchronization. Use the separate HA mount paths and private state mount.
6. Configure Pacemaker/Corosync, NFS recovery, exports, fencing, and the new VIP. Validate startup/stop ordering and controlled failover during an outage before moving stacks. Resolve NFS service ownership on `ubuntu-slave1`; legacy service startup must not compete with Pacemaker.
7. Restore the original service for unmigrated stacks and review `./bin/restore-nfs-workloads.sh --dry-run` on the control-plane host before restoring recorded replicas. Account separately for writers not covered by the helpers.

For normal operation between migration windows, prefer `ubuntu-master2` as the HA active node while legacy exports remain on `ubuntu-slave1`. This preference is not isolation: failover onto `ubuntu-slave1`, fencing either host, and shared NFS configuration changes can require a shared outage. Fencing also stops any Kubernetes workloads/control-plane services on the fenced host. Do not promise uninterrupted legacy exports or run two competing host NFS service managers. Finalize and human-review the transitional service ownership procedure before activation; outages are acceptable when switching ownership for tests or recovery.

### Move one stack per maintenance window

The migration unit is an application's PVC directories, not an entire LV. For example, n8n and Keycloak both use the general and PostgreSQL exports, while Grafana/Loki spans the Grafana and general exports.

1. Record the stack's workloads, replica counts, PVC/PV bindings, exact source/destination directories, ownership, and rollback definitions. Include database and background writers.
2. Copy only those directories with privileged `rsync -aHAX --numeric-ids` over authenticated SSH or between local mounts on the active host. Avoid copying through root-squashed NFS mounts when that would lose metadata. An initial live copy is optional; for this environment, stopping the stack before the whole copy is acceptable.
3. Stop all stack writers and cleanly shut down PostgreSQL before the final file synchronization. Review a dry run and account for files deleted since an initial copy. Scope any deletion strictly to that stack's destination directories.
4. Protect old PVs with `Retain`, then perform the controlled Kubernetes rebinding described below. Release old client mounts and mount through the VIP; new filesystems have new inode/file-handle identities.
5. Human-review file metadata, PVC access, database startup, and application read/write behavior before reopening normal use. Retain the old directories as the rollback copy for that stack.

Never repeat a whole-export old-to-new synchronization after a stack has moved: it could overwrite newer data belonging to migrated stacks. Keep a simple per-stack record of which endpoint is authoritative. Retire the legacy exports only after all consumers, including non-Kubernetes clients, have moved.

### Kubernetes endpoint transition without renaming StorageClasses

Keep `kube-nfs`, `kube-postgres`, and `kube-grafana`. Once HA is ready, pause new provisioning and recreate the StorageClass objects under the same names with the VIP (or a name resolving only to it) and new `/srv/ha/...` shares; their server/share parameters cannot be changed in place. Update component configuration and manifests so future deploys retain the new endpoint. Recreating a StorageClass does not migrate existing PVs.

Existing PVs hold their own endpoint and have immutable volume sources. Save their definitions and set the **existing PVs** to `Retain` before removing any PV/PVC objects; changing only a class's reclaim policy does not protect existing volumes. During each stack outage, recreate/rebind the necessary PV/PVC objects to its copied directories, retaining application-facing PVC names. Explicit prebinding must prevent accidental provisioning of empty directories; review CSI server/share/subdirectory and volume-handle values together. Account for StatefulSet-generated claim names and controllers that might recreate claims during the operation.

Old and new PVs can temporarily share StorageClass names. Track each PV's actual endpoint and path rather than inferring migration status from its class. Review both NFS maintenance helpers and run the shutdown dry run against each deployed result; newly bound claims must remain discoverable. See [Kubernetes persistent volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

## Implementation and QA approach

Use small Bash scripts under `nfs-ha/scripts/` for repeatable inventory, rendering, package installation, copying, and cluster operations. Prefer direct standard commands over complex Python orchestration or a new automation framework. Keep new LV creation, HA activation, and individual stack migrations separate and reviewable. Resolve paths from `BASH_SOURCE`, keep live values in component-local `.env` with placeholder-only `.env.sample` updates, and apply `envsubst` selectively.

Human review is the primary QA method: inspect live inventory and proposed commands, review dry-run output and rendered configuration, execute a bounded step, then inspect actual storage, cluster, and application behavior. Use `bash -n`, ShellCheck, package simulations, and native configuration validators where useful. Do not require extensive mocked tests, disposable-VM suites, or automated evidence/approval frameworks. Preserve basic error handling and stop on unexpected state; manual review does not replace backups or working fencing before automatic failover.

## Routine operations

### Planned update or reboot

1. Confirm DRBD is fully synchronized and cluster resources are healthy.
2. Put the current active node into Pacemaker standby; allow the complete service stack and VIP to move to the peer.
3. Confirm clients reach NFS through the VIP and that the maintenance node owns no DRBD primary/mount/NFS/VIP resources.
4. Patch/reboot/maintain the standby node.
5. Confirm it rejoins and DRBD resynchronizes. Keep the peer active unless there is a reason to fail back.

### Capacity management

Growing is the normal path. Extend the matching backing LV on **both** nodes, make DRBD recognize the larger backing size, then grow ext4 on the active DRBD device. Validate each resource’s current DRBD version/configuration and peer state before executing a resize runbook.

Avoid shrinking established DRBD resources in place. It requires an offline, top-down contraction—filesystem, then DRBD, then backing LV—on both peers, and errors can destroy data. For a later major reduction, create a new smaller DRBD resource/filesystem, copy, cut over, and retain the former resource until rollback is no longer needed.

## Cutover validation and rollback

Before declaring the migration complete, test a controlled failover while monitoring a non-critical NFS client: DRBD should be promoted on one node only, all filesystems and exports should follow it, and the VIP should move after the service is ready. Confirm Grafana still writes as `472:472` and PostgreSQL as `999:999`.

The original LVs and filesystems remain unchanged during storage preparation. Retain them and each stack's old directories through cutover and validation; unmigrated stacks may continue writing their own directories. They are rollback copies for phased migration, but they do not replace independent backups.

Before new writes, roll back a failed stack by stopping its consumers, restoring its saved PV/PVC bindings to the old endpoint/directories, and obtaining fresh client mounts. Do not stop the entire HA service merely to roll back one stack if other migrated stacks depend on it. Once the stack has written to the new storage, stop writers and deliberately reconcile or restore its data before reverting. Never allow the old and new copies of the same stack to accept independent writes. Retaining the old copy for several weekends does not make it current after cutover.

## Caveats

- DRBD replication is synchronous, so write latency depends on the network and disks of both NFS nodes. Use reliable, low-latency networking and monitor replication health.
- DRBD protects against the loss of one node/disk, not accidental deletion, data corruption, ransomware, or operator error. Keep tested backups.
- A two-node design has less fault tolerance than a multi-node distributed storage system. Fencing, tested failure procedures, and backups are essential.
- Exact resource-agent names/parameters and DRBD configuration must be finalized against the Ubuntu 24.04 package versions and the available fencing method before implementation. This document defines the architecture and sequence rather than serving as a copy/paste command runbook.
