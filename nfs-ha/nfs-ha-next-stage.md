# After DRBD initialization: master2-only service readiness

This starts after the completed [one-time initialization](drbd-initialization.md).
The legacy export/obsolete resource retirement and private-state relocation
completed on 2026-09-26. Both hosts passed the four-resource readiness check
again during [implementation validation](validation-2026-09-26.md). The old
physical disk fault remains unresolved and its storage must not be modified
as part of HA activation.

The concrete [Pacemaker cutover runbook](pacemaker-cutover.md) now describes
staging, bootstrap, ownership handoff, activation and rollback for the
master2-only migration service. Its scripts produce private offline candidates
and default to printing cutover plans. The operator confirmed the VIP's DHCP
exclusion. No firewalls are in place. Kubernetes nodes are the NFS clients,
mounting PVC-backed volumes through the NFS StorageClasses; test those mounts
after activation. Quorum-loss tests remain activation gates. This demo/dev
system has no required cluster, configuration, recovery-state or application
backups.
No HA service or Kubernetes endpoint was changed.

## 1. Confirm completed isolation of the storage incident

At the initial incident, the obsolete `nfs` resource became Diskless on `ubuntu-slave1` after ATA write
errors on the physical disk that also backs the live legacy general export.
Fresh read errors were observed on that disk. The subsequent retirement
removed this resource and moved private state to `kube-vg`; disk repair and
legacy LVM cleanup remain separate incident work. Avoid repeated probing or any
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
inventory and review `./bin/shutdown-nfs-workloads.sh --dry-run`. Kubernetes
nodes mount NFS-backed claims through the NFS StorageClasses. Review Jobs,
CronJobs, unmanaged Pods and direct NFS volumes, and confirm this remains the
complete client set. No workload shutdown is needed for these read-only checks.

## 4. Close the master2-only activation design

Record the following in a private maintenance record and review on both hosts:

1. Confirm both Corosync votes are required: expected_votes: 2,
   two_node: 0, wait_for_all: 1 and no-quorum-policy=stop. Test that either
   isolated singleton is inquorate. Node fencing is disabled only because
   the service and DRBD promotion are permanently banned on slave1; there
   is no automatic takeover.
2. The operator attributed the repeated enp2s0 link drops to unrelated
   network maintenance, so that investigation is closed. Confirm both links
   are up and replication is Connected, UpToDate/UpToDate before cutting
   over. If master2 hangs, verify it is off before manual storage recovery.
3. The operator confirmed VIP 192.168.1.240 is excluded from DHCP; no further
   DHCP verification is required. No firewalls are in place. Authoritative
   DNS for nfs-ha.koeppster.lan points there; validate PVC-backed NFS access
   from Kubernetes nodes after activation.
4. Map each verified client network and export option to its new
   /srv/ha path; confirm fsids 102-104 do not conflict with live exports.
   Keep /var/lib/nfs-ha private.
5. Inspect the installed NFS server, exportfs, Filesystem and DRBD agents.
   Confirm the shared NFSv4 recovery-state bind, scope and lease-aware stop
   timeouts. DRBD resource-only peer-fencing handlers constrain promotion
   but do not power off a node.
6. Keep slave1's legacy NFS instance systemd-owned while unmigrated stacks
   use it. Only master2 runs the new Pacemaker NFS instance. Confirm no
   workload writes to both copies of a claim.

The group is g-nfs-ha: four filesystem mounts, NFS server, six export
primitives and VIP. It starts only after all four DRBD resources are
promoted on master2. Review ordering, colocation, placement bans and
quorum-loss stop ordering in the offline scheduler graphs.

## 5. First activation window

Use a shared maintenance window. Stop writers (including Jobs and any clients
outside the Kubernetes-node set), preserve their replica counts,
then bootstrap both Corosync members with an empty application CIB.
Confirm both votes are present and a controlled peer stop removes quorum.
Submit only the stopped candidate; install the reviewed DRBD handler
configuration after its clones exist; then activate explicitly. Follow
[Pacemaker cutover](pacemaker-cutover.md) for commands and state checks.

Test the new endpoint with a noncritical NFSv4.1 client, including file
ownership, root squash, fsync and locks. A controlled quorum-loss test must
stop the VIP and exports on master2. Do not move the group to slave1 or
remove its five permanent restrictions. Leave the existing StorageClasses
and PVs at the legacy endpoint until the new endpoint passes validation;
then follow [gradual migration](gradual-migration.md) stack by stack.

The installed ClusterLabs
[NFS server agent](https://github.com/ClusterLabs/resource-agents/blob/main/heartbeat/nfsserver)
documents shared information storage and NFSv4 scope; the
[export agent](https://github.com/ClusterLabs/resource-agents/blob/main/heartbeat/exportfs)
defines client specification and fsid handling. Verify local metadata
before executing an operation.
