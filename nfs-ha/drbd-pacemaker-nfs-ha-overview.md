# DRBD + Pacemaker master2-only NFS migration for MicroK8s

## Purpose and current boundary

The target is a **master2-only** NFS migration service for the three MicroK8s
exports. A stable virtual IP (VIP) gives migrated clients one endpoint, but
does not move to `ubuntu-slave1.koeppster.lan`. DRBD Protocol C replicates
each exported filesystem and private NFS recovery state. Pacemaker owns
promotion, mounts, NFS, exports, and the VIP on master2 only. There is no
automatic failover or independent power-fencing requirement.

This is a data-copy migration to new DRBD filesystems, followed by
stack-by-stack Kubernetes PV rebinding. Existing StorageClass names and PVC
names remain stable. The old endpoint stays active for unmigrated stacks.
The HA service is **not active**. The [cutover runbook](pacemaker-cutover.md)
and supporting scripts implement offline staging and gated Pacemaker operations. The [2026-09-26 status](status-2026-09-26.md)
records a disk I/O incident on `ubuntu-slave1`; the
[retirement runbook](retire-legacy-nfs-lv.md) describes removal of the unused
legacy export and obsolete DRBD resource before HA activation.

## Four-resource target layout

| DRBD resource | `ubuntu-slave1` backing LV | `ubuntu-master2` backing LV | DRBD device / port | HA mount | MicroK8s class |
|---|---|---|---|---|---|
| `kube` | `kube-vg/drbd-kube` | `ubuntu-vg/drbd-kube` | `/dev/drbd1` / 7789 | `/srv/ha/kube-lv` | `kube-nfs` |
| `grafana` | `kube-vg/drbd-grafana` | `ubuntu-vg/drbd-grafana` | `/dev/drbd2` / 7790 | `/srv/ha/kube-grafana` | `kube-grafana` |
| `postgres` | `kube-vg/drbd-postgres` | `ubuntu-vg/drbd-postgres` | `/dev/drbd3` / 7791 | `/srv/ha/kube-postgres` | `kube-postgres` |
| `nfs-state` | **new** `kube-vg/drbd-nfs-state` | existing `ubuntu-vg/drbd-nfs-state` | `/dev/drbd4` / 7792 | `/var/lib/nfs-ha` (private) | None |

The data backing sizes are 200, 5, and 50 GiB; the private state backing is
1 GiB. Total target allocation is **256 GiB per host**, with all four peer
resources on `kube-vg` on `ubuntu-slave1`. The 255 GiB of data LVs and the
1 GiB state LV on `ubuntu-master2` already exist. The peer state resource was relocated to a new 1 GiB `kube-vg` LV on
2026-09-26; the installed configuration now uses that path and both replicas
are UpToDate. The unused old `nfs-vg` LV remains untouched.
The last observed `kube-vg` free space was 56.51 GiB, leaving about 55.51 GiB
after a 1 GiB allocation if unchanged. Recheck the live VG and PV identity.

The previous five-resource initialization also created an obsolete `nfs`
resource on DRBD minor 0 and port 7788. It is not part of the target. Keep
minor 0 and port 7788 retired; do not remap the existing resources. Retire
the installed resource and unused LVs as described in the
[retirement runbook](retire-legacy-nfs-lv.md). Historical preparation scripts
are disabled so they cannot recreate the old layout.

DRBD sits above LVM and below ext4:

```text
physical disk -> LVM PV/VG -> backing LV -> DRBD -> ext4 -> NFS export
```

Only one node may be Primary and mount ext4. Do not format a backing LV,
mount a DRBD filesystem through `fstab`, or run an independent NFS service
against the HA VIP. The private `nfs-state` filesystem is not exported; its
`/var/lib/nfs-ha/state` directory holds clustered NFS recovery information.

## NFS exports and service ownership

The HA server exports only `/srv/ha/kube-lv`, `/srv/ha/kube-grafana`, and
`/srv/ha/kube-postgres`. Preserve the verified legacy client networks and
options. Grafana needs `root_squash,anonuid=472,anongid=472`; PostgreSQL
needs `root_squash,anonuid=999,anongid=999`. The general `kube` export keeps
normal `root_squash`. Preserve numeric ownership, modes, ACLs, and xattrs in
PVC directories when copying. Continue NFSv4 over TCP with hard client mounts.

`ubuntu-slave1` currently runs the legacy NFS server for these Kubernetes
exports. During migration it remains systemd-owned on slave1, while the new
Pacemaker-owned NFS instance runs on master2. Never point one stack's writers
at both copies. The
VIP must come up only after all four DRBD resources are promoted, all four
filesystems are mounted, and NFS plus the three exports are ready. Shutdown
reverses that order. Validate NFSv4 server scope and shared recovery state
with the installed `ocf:heartbeat:nfsserver` agent before activation.

Use cluster name `nfs-ha`, service group `g-nfs-ha`, NFS primitive
`p-nfs-server`, and VIP primitive `p-nfs-vip`. The selected DNS name
`nfs-ha.koeppster.lan` resolves to VIP `192.168.1.240`, which the operator
confirmed is excluded from DHCP. No further DHCP verification is required;
keep it distinct from either host's physical IP. No firewalls are in place;
Kubernetes nodes connect through PVC-backed volumes using the NFS
StorageClasses. Validate those mounts after activation. Use four promotable
DRBD resources, four filesystem primitives,
three sets of export resources, and one VIP. Preserve stable export fsids,
for example 102–104 after verifying no conflict. Validate ordering and
colocation against every promoted DRBD resource and simulate the CIB before
submission.

## Cluster safety and activation

Corosync uses two expected votes without the special two-node one-vote
quorum rule. Pacemaker stops the master2-only service when quorum is lost,
provided master2 can still run stop actions. Node fencing is disabled for
this restricted design; slave1 has permanent service and promotion bans.
A hung master2 cannot be isolated automatically, so recovery requires an
operator to verify it is off before touching the DRBD data. Automatic
two-host failover is not supported by this implementation.

First resolve the storage incident, remove the obsolete DRBD resource,
relocate private state to `kube-vg`, and run the four-resource readiness check
on **both** hosts. Then finish VIP, stable cluster networking, client-network, export, NFS
recovery, and legacy service ownership design. Follow the
[next-stage runbook](nfs-ha-next-stage.md) for ordered verification. Do not
submit a CIB, mount the new filesystems, or change Kubernetes storage
endpoints while any prerequisite remains unresolved.

## Per-stack Kubernetes migration

The supported [gradual migration](gradual-migration.md) first confines the new
service and DRBD promotion to `ubuntu-master2`, with service-group probes
suppressed on `ubuntu-slave1`. Legacy NFS remains systemd-owned on slave1.
There is no automatic service failover. After all stacks and external
consumers move, retire the legacy exports while keeping the master2-only
placement and promotion bans. The restart staging helper preserves them.

Keep `kube-nfs`, `kube-postgres`, and `kube-grafana`. Pause new provisioning
while gradually rebinding existing claims to explicit static PVs at the VIP.
Leave the StorageClasses on the legacy endpoint during that phase. Once all
consumers move and the master2-only service passes validation, recreate them
under the same names with the VIP and new
root shares for future provisioning; server/share parameters are immutable.
Existing PVs retain their own endpoints throughout.

Migrate one application's PVC directories per maintenance window. Record its
PV/PVC objects, replica counts, exact old and new directories, and database
writers. Stop writers, copy with privileged `rsync -aHAX --numeric-ids`, and
review a final synchronization. Protect each **existing PV** with `Retain`
before removing any storage object. Recreate and explicitly prebind the new
PV/PVC pair to the copied directory and VIP, preserving application-facing
claim names. Use new CSI server/share/subdirectory and volume-handle values;
new file handles require fresh client mounts. Validate data, ownership,
database startup, and application I/O before reopening the stack. Keep old
directories for rollback but do not allow writes to both copies.

Review both NFS maintenance helpers after every workload/PVC change and run
the shutdown dry run against the deployed result from a MicroK8s control-plane
host. Current NFS clients are Kubernetes nodes mounting PVCs through the NFS
StorageClasses. Review Jobs, unmanaged Pods and direct NFS volumes, and confirm
this remains the complete client set before each migration window.
Retire the old Kubernetes exports only after all consumers have moved.

This demo/development environment does not require separate backups; DRBD
replication is not a backup. Monitor peer disk health, DRBD connection and
disk states, filesystem space/inodes, NFS recovery, and quorum. Routine
growth extends both backing LVs, resizes DRBD, then grows ext4 through the
active DRBD device; do not shrink an established resource in place.
