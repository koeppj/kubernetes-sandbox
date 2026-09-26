# After DRBD initialization: readiness and HA service design

This starts after the completed [one-time initialization](drbd-initialization.md).
The 2026-09-26 inspection found a disk I/O incident on `ubuntu-slave1`;
retire the unused resource and move private state off that disk before
proceeding with the HA service design. This runbook does not
activate a second NFS server, mount new filesystems, submit a CIB, or change
Kubernetes storage endpoints. The current status is recorded in
[status-2026-09-26.md](status-2026-09-26.md).

## 1. Resolve the storage incident

The obsolete `nfs` resource is Diskless on `ubuntu-slave1` after ATA write
errors on the physical disk that also backs the live legacy general export.
Fresh read errors were observed on that disk. Treat this as an active storage
incident, not a routine DRBD resync pause. Avoid repeated probing or any
attempt to reattach the obsolete resource. Follow the
[retirement runbook](retire-legacy-nfs-lv.md) to protect legacy data, retire
its export and DRBD resource, and move private `nfs-state` to `kube-vg`.
The [DRBD 8.4 guide](https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/)
describes automatic transition to Diskless after lower-layer I/O errors.

The physical disk identity observed at failure was serial
`WD-WMAVU1286378`. Protect needed data and resolve the disk/cable/controller
fault before changing its LVM metadata. The HA target does not require any
data from the obsolete `nfs` DRBD resource. Require the **four retained**
resources to reach `UpToDate/UpToDate` on both hosts before activation.

## 2. Finish the DRBD checkpoint

Wait until all four retained resources are `Connected` and `UpToDate/UpToDate`,
with the obsolete resource gone and private state using `kube-vg`. On
**each host**, from this directory when available:

```bash
sudo ./scripts/nfs-ha-drbd-readiness.sh
sudo drbdadm status
```

The readiness script checks the planned role split (`ubuntu-master2` Primary,
`ubuntu-slave1` Secondary), four DRBD devices, ext4 labels on the source, and
absence of HA mounts. Save the dated output privately for the maintenance
record. Stop if any resource disconnects, becomes Diskless, shows an unexpected
role, or fails to reach `UpToDate/UpToDate`; inspect it before changing state.
Do not rerun the one-time initializer or `mkfs`.

The new scripts are not installed in the repository checkout on
`ubuntu-slave1`. Until the checkout is updated there, run the local copy of
the read-only script over the now-working SSH connection from
`ubuntu-master2`:

```bash
ssh -T ubuntu-slave1.koeppster.lan 'sudo -n bash -s' < scripts/nfs-ha-drbd-readiness.sh
```

## 3. Collect service and client facts on both hosts

Run locally on each peer:

```bash
sudo ./scripts/nfs-ha-service-inventory.sh
```

The script reads IPs, service states, mount ownership, `exportfs -v`, static
exports, and installed resource-agent files. Treat the live `exportfs -v`
output on `ubuntu-slave1` as the starting authority for client networks and
options. The three MicroK8s exports currently permit `192.168.1.0/24` and
`10.0.0.0/24`. The legacy general export also has an IPv6 client network;
that entry is part of its separate retirement, not an HA export. Compare with
`/etc/exports*` at implementation time; record any dynamic or conflicting
entries. Copy only verified clients into the future Pacemaker `exportfs`
resources. Preserve `root_squash` and the Grafana `472:472` and PostgreSQL
`999:999` anonymous identities. No explicit fsid appeared in the active
export listing; check fsid behavior and conflicts before adopting 102–104.
Do not put private host keys or credentials in Git.

To run the inventory using the current local checkout over SSH:

```bash
ssh -T ubuntu-slave1.koeppster.lan 'sudo -n bash -s' < scripts/nfs-ha-service-inventory.sh
```

From a MicroK8s **control-plane** host, collect the NFS PVC/PV and client
inventory and review `./bin/shutdown-nfs-workloads.sh --dry-run`. Inventory
Jobs, CronJobs, unmanaged Pods, and non-Kubernetes NFS clients separately.
No workload shutdown is needed for these read-only checks.

## 4. Close the activation design before writing live configuration

Record the following concrete values and checks in a private maintenance
record, and review them against both hosts:

1. Select independent fencing hardware/agent credentials for **both** nodes.
   Verify each device can cut power to the intended host and that fencing a
   MicroK8s node is acceptable during the scheduled outage. Keep STONITH on.
2. Select and test two-node Corosync quorum behavior and DRBD fencing
   integration. A network partition must not allow both peers to mount ext4.
3. Reserve an unused VIP distinct from `192.168.1.235` and `192.168.1.194`.
   Verify the interface and prefix on each host, DHCP/MetalLB conflicts, DNS,
   and client reachability. The name `nfs-ha.koeppster.lan` is only proposed.
4. Map each verified client specification and exact options to its new
   `/srv/ha/...` path. Reserve stable fsids only after checking the legacy
   server. Keep `/var/lib/nfs-ha` private and never export it.
5. Inspect the **installed** `ocf:heartbeat:nfsserver`, `exportfs`, and
   `Filesystem` agent metadata and behavior. Confirm how `nfs_shared_infodir`
   is bind-mounted onto `/var/lib/nfs`, the scope value used for NFSv4 recovery,
   and safe stop timeouts. The state filesystem must be mounted before NFS.
6. Define a service-ownership handoff for `ubuntu-slave1`. Its legacy exports
   and the HA exports share one kernel NFS server; do not let systemd and
   Pacemaker independently manage that server. Account for unmigrated clients
   whenever the service is stopped, moved, or the host is fenced.
7. Review the unit masks and enablement on both hosts. On `ubuntu-master2`,
   Corosync, Pacemaker, DRBD's unit, and NFS server units were masked at the
   status checkpoint. On `ubuntu-slave1`, the legacy NFS server is active and
   enabled; cluster services are disabled. Resolve only the units required by
   the reviewed Pacemaker/NFS design during activation, with DRBD and NFS
   ownership clear.

The proposed Pacemaker group is `g-nfs-ha`: all four filesystem mounts,
`p-nfs-server`, verified export resources, then `p-nfs-vip`. Each mount must be
colocated and ordered after its promoted DRBD resource; the group/VIP must be
ordered after **all four** promoted resources. Configure each DRBD resource as
a single-promoted-instance clone. Check every resource/constraint against the
installed agent metadata and use `crm_verify` and `crm_simulate` on a staged
CIB before submission. Agent parameters in the overview are design intent,
not validated commands for this Ubuntu build.

## 5. First activation window, once the design is complete

Take a shared maintenance window. Review the live NFS workload set, stop all
writers (including Jobs and external clients), and preserve backups. Stage
Corosync, fencing, Pacemaker resources, mounts, exports, and VIP as separate
reviewable artifacts. Validate syntax and simulation before starting services.
Handoff legacy NFS ownership deliberately; promote/mount via Pacemaker only,
then start the NFS/export resources, and assign the VIP last. Confirm the old
unmigrated endpoint's availability before restoring its clients.

Exercise controlled switchover and a non-critical NFSv4 client recovery test.
Check single Primary ownership, mounts, exports, fsids, scope, and VIP after
each transition. Test the fencing path and network-partition behavior during
the scheduled outage before relying on automatic failover. Keep Kubernetes
StorageClasses and existing PVs at their current endpoint until this service
passes validation; [the overview](drbd-pacemaker-nfs-ha-overview.md#per-stack-kubernetes-migration)
describes the later per-stack data and binding migration.

For reference, the installed ClusterLabs [NFS server agent](https://github.com/ClusterLabs/resource-agents/blob/main/heartbeat/nfsserver)
documents shared information storage and NFSv4 server scope; the
[export agent](https://github.com/ClusterLabs/resource-agents/blob/main/heartbeat/exportfs)
defines client specification and fsid handling. Verify the local package's
version and metadata before rendering commands.
