# Pacemaker migration service cutover

This is a **master2-only** NFS migration service. Independent power fencing is
not an implementation requirement. The tradeoff is deliberate: there is no
automatic failover, switchover, or promotion on slave1. Pacemaker must never
mount an HA filesystem or start the new NFS group there. Both cluster votes
are required for quorum; loss of either node or the Corosync link stops the
service when master2 can still run its stop actions. If master2 itself hangs,
there is no automatic way to prove it stopped. Verify it is off and its HA
filesystems are unmounted before any manual storage recovery.

The old NFS service on slave1 stays independent while stacks move. See
[gradual migration](gradual-migration.md) for per-stack data copying and the
final legacy-service retirement. Automatic two-host HA is outside this
configuration. Removing the five migration restrictions or changing quorum to
one vote is not a supported operation.

## September 27 handoff

The operator reports that bootstrap and gradual PVC migration are complete.
Use [final consumer cutover and legacy mount retirement](legacy-nfs-retirement.md)
for the reviewed execution stages and remaining work. Do not rerun initial
submission or copy/rebind completed claims. That plan documents the
`legacy_service_state=retired` record for stop/activate after legacy retirement.
It requires all five retirement gates and an evidence note instead of the
preserved-service assertion; initial submission still requires preservation. Retirement retains the master2-only availability boundary above.

## 1. Collect fresh evidence

Run from the repository root on the control-plane host:

~~~bash
./nfs-ha/scripts/nfs-ha-collect.sh nfs-ha/staging/preflight-YYYYMMDD-HHMM
~~~

The private output includes both hosts' DRBD readiness, service inventory,
agent metadata, exports, active NFS connections, Kubernetes storage/client
objects, and maintenance dry runs. A missing restore state file makes that
dry run fail until a controlled shutdown has recorded replica counts. Review
the client inventory: Kubernetes nodes mount PVCs through the NFS StorageClasses.
A prior inventory saw server connections from ubuntu-slave2, ubuntu-mini and
ubuntu-master2; the 23:42 UTC snapshot showed an established connection from
ubuntu-mini. The operator asserts that ubuntu-mini and ubuntu-slave1 have no
client NFS mounts and that independent mount verification on those two hosts
is not required. The operator also confirms ubuntu-slave2 is not an NFS
client. An established NFS TCP connection observed from ubuntu-mini does not
by itself establish that a filesystem is mounted. Review Jobs, CronJobs, direct
NFS volumes and unmanaged Pods to ensure the client set has not changed before
the outage.
Do not overwrite an existing replica-count state file with zeroes.

The selected VIP and NFS scope are 192.168.1.240 in the component-local
.env. Authoritative DNS for nfs-ha.koeppster.lan currently returns .240.
The operator confirmed .240 is excluded from DHCP; DHCP exclusion is no longer
an open verification gate. No firewalls are in place. Validate NFS access from
the Kubernetes nodes after service activation. ARP probes on both hosts
returned no duplicate response. The address is outside
the observed MetalLB .243-.254 pool and the checked-in
macvlan .241-.254 range.

Both enp2s0 links fell together at 19:59 and 20:01 UTC on 2026-09-26,
disconnecting all four DRBD replicas. The operator confirmed these drops
were caused by unrelated network maintenance; that investigation is closed.
Slave1's recorded RX/alignment counters are historical observations, not
proof of a continuing fault. After maintenance, verify both links are up
and all four replicas are Connected and UpToDate/UpToDate on both hosts
before cutover. The [current status](status-2026-09-26.md) records the
latest evidence.

Review /etc/exports, /etc/exports.d/*.exports, exportfs -v and
/var/lib/nfs/etab together. Verify the three candidate fsids 102-104 against
all live exports and the NFSv4 pseudo root. Confirm numeric ownership, ACLs,
the two client CIDRs and the measured NFSv4 lease time before copying data.

## 2. Review the single-host safety boundary

The generated Corosync candidate uses expected_votes: 2, two_node: 0 and
wait_for_all: 1. Pacemaker uses no-quorum-policy=stop and has node fencing
disabled for this restricted migration configuration. This is safe only while
slave1 cannot promote any of the four DRBD resources and cannot discover,
adopt or start the new NFS group. The renderer adds permanent bans for all
five actions; the cutover helper rejects an altered or missing ban. It does
not offer move, clear or final HA actions.

DRBD resource-only peer fencing is separate from power fencing. The four
repository .res templates contain the crm-fence-peer and
crm-unfence-peer handlers. They must be installed only after the stopped
Pacemaker resources exist, then reviewed during controlled partition tests.
These handlers constrain DRBD promotion in the CIB; they cannot power off a
hung node. Retain allow-two-primaries=no and the split-brain disconnect rules.
Never force promotion or mount ext4 on slave1 as an outage workaround.

A two-vote cluster sacrifices availability: a clean peer shutdown or
Corosync partition makes master2 stop the VIP and exports. In a hard hang,
the stop may not complete; keep clients stopped and confirm actual ownership
before recovery. Controlled quorum-loss and link-partition tests with a
disposable client are required before production. The offline scheduler
simulation cannot prove that agents will stop on real hardware.

## 3. Render and inspect the offline candidate

From nfs-ha/:

~~~bash
# First setup only; keep the reviewed component .env.
test -e .env || cp .env.sample .env
chmod 600 .env
./scripts/nfs-ha-stage.sh staging/migration-YYYYMMDD-HHMM
./scripts/nfs-ha-validate-stage.sh staging/migration-YYYYMMDD-HHMM
~~~

No fencing-only base CIB is needed. The private stage contains
corosync.conf, cib-stopped.xml, simulation-start.xml, scheduler logs and
graphs. Never submit simulation-start.xml. The stopped CIB keeps all four
DRBD clones and the NFS group stopped. The simulation must show the VIP
starting on master2 with both votes, no startup with either node alone, and
the running VIP stopping on quorum loss. Inspect the full stop ordering and
graphs, not only command exit codes.

The group starts private NFS recovery state, three data mounts, NFS, six
client exports and then the VIP. Four promotable DRBD clones have mandatory
promotion ordering and colocation with the group. The two exports for each
filesystem share one fsid; the private state filesystem is never exported.
The NFS server agent bind-mounts the shared recovery directory under
/var/lib/nfs. The six export stops wait for the NFSv4 lease. With the measured
90-second lease, the live controlled stop took about ten minutes because the
six exports stop in order; allow the helper's full 30-minute timeout.

## 4. Bootstrap both members during the shared outage

This is a demo/development system. Copies of cluster, DRBD and NFS
configuration, NFS recovery state, and application data are not required and
are not cutover gates. Stop all writers for the shared bootstrap, suspend
relevant CronJobs/reconcilers, and release NFS mounts from the Kubernetes
nodes. Preserve any saved replica-count file. Use the repository shutdown
helper in its normal workflow; inspect both maintenance dry runs. Keep console
access for both machines.

Install the reviewed corosync.conf on both hosts with one identical private
authkey, root-owned mode 0400. Check corosync -t locally. Permit the configured
knet traffic and verify both hosts can reach each other. Unmask/start
Corosync and Pacemaker on both with an **empty** application CIB. Confirm
corosync-quorumtool -s reports two expected votes, quorum of two when both
are present, and no quorum when either is absent. Test a clean peer stop and
a controlled Corosync partition before any HA NFS resources start. Keep
DRBD's standalone systemd unit disabled; do not start pcsd unless the chosen
pcs workflow requires it.

Slave1 keeps its legacy exports, independent NFS service, local recovery
state and boot enablement. On master2, ensure no independent NFS instance
or old clients exist, unmask the NFS units the agent needs, and keep
standalone NFS boot enablement disabled. Verify all four DRBD resources are
Connected and UpToDate on both sides, with master2 Primary and slave1
Secondary. Demote the four unmounted master2 resources only during the
reviewed transfer to Pacemaker. Do not format or attach the retired disk.

Install `scripts/nfs-ha-nfsserver-control.sh` as
`/usr/local/sbin/nfs-ha-nfsserver-control` on both hosts, root-owned mode 0755.
On master2, unmask `nfs-server`, `nfs-mountd`, `nfsdcld` and
`proc-fs-nfsd.mount`, but keep
`nfs-server` disabled at boot. The reviewed NFS resource uses this wrapper in
NFSv4-only mode. Ubuntu's legacy `/etc/init.d/nfs-kernel-server` can report a
stopped server as running and can return success without starting `nfsd` when
`/etc/exports` is empty; the wrapper controls `nfs-server.service` and checks
that the daemon and its recovery service are active.

## 5. Submit stopped resources, then activate

Run the cutover helper on ubuntu-master2; it refuses execution elsewhere.
Copy templates/maintenance-record.sample.json into the private stage. Fill
every required gate with actual evidence; false is an unresolved gate.
Include an ISO UTC review time within four hours and the SHA-256 of the
candidate stopped CIB. In particular, confirm stable links, both votes and
quorum-loss behavior, DRBD peer-fencing review, master2's NFS unit
handoff, preserved legacy service, stopped writers for the new HA filesystems,
and acceptance of no automatic failover. Use `legacy_service_state=preserved`
and `legacy_service_preserved=true` for this bootstrap. After final legacy
retirement, use the retired-state record documented in the retirement runbook
for subsequent stop/activate operations. The helper refuses missing gates,
a changed hash, an existing live resource/constraint, an altered migration
ban, or a nonempty application CIB.

~~~bash
# Preview first.
./scripts/nfs-ha-cutover.py submit --stage staging/migration-YYYYMMDD-HHMM
# In the reviewed outage, after completing the record:
sudo ./scripts/nfs-ha-cutover.py submit --stage staging/migration-YYYYMMDD-HHMM --record staging/migration-YYYYMMDD-HHMM/maintenance.json --execute
~~~

Submission backs up the live CIB and pushes configuration with all HA
resources stopped. Install the reviewed DRBD resource-only handler additions
on both hosts now. Pacemaker's stop actions take the DRBD devices down, so
bring the four configured resources back up with `drbdadm up all` on slave1,
then master2. Verify Connected, UpToDate/UpToDate, Secondary/Secondary roles
and no HA mounts before activation. Keep the standalone `drbd.service`
disabled; Pacemaker will promote master2 during activation.

~~~bash
sudo ./scripts/nfs-ha-cutover.py activate --stage staging/migration-YYYYMMDD-HHMM --record staging/migration-YYYYMMDD-HHMM/maintenance.json --execute
~~~

The helper only manages Pacemaker resources. It does not copy application
data, alter PV/PVC bindings, or repair failed starts. Stop and diagnose if a
resource fails; do not force a promotion or edit away a placement ban.

## 6. Validate and operate

On both hosts inspect pcs status --full, drbdadm status, findmnt, exportfs -v
and ip -4 address show dev enp2s0. Require all four Primaries, four ext4
mounts, the NFS recovery-state bind, six new export entries and the VIP on
master2 only. Slave1 may keep its three legacy exports and local mounts but
must have four DRBD Secondaries, no HA mount, no HA state bind and no VIP.

With a disposable NFSv4.1 client, test root squash, numeric identities,
read/write/fsync, a POSIX lock, restart persistence and a controlled
stop/start. Test quorum loss with this client while the rest of the writers
are stopped. Require the VIP and exports to stop; a failed or incomplete
stop is an incident, not permission to start on slave1. If master2 fails,
migrated clients wait for manual recovery after the operator verifies
master2 cannot access the DRBD data.

For a controlled stop, use cutover stop with a fresh migration record and
wait for the group, mounts and DRBD clones to stop. Confirm actual state on
both hosts; target-role=Stopped alone is insufficient. To restart after
configuration changes, snapshot the stopped live CIB and stage a fresh
restricted candidate:

~~~bash
sudo cibadmin --query > staging/migration-restart-stopped.xml
./scripts/nfs-ha-stage-finalize.py --restart staging/migration-restart-stopped.xml staging/migration-restart-YYYYMMDD-HHMM
~~~

Review/hash the new stage and use cutover activate with its own fresh record.
Do not reuse an old CIB or remove the master2-only bans. Rollback keeps
writers stopped while checking the authoritative data copy; never restore
old PVs after new writes without reviewed reverse synchronization.

The [Corosync votequorum manual](https://manpages.debian.org/trixie/corosync/votequorum.5.en.html)
explains why two_node: 1 would make either isolated node quorate. The
[Pacemaker fencing guide](https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/pdf/Pacemaker_Explained.pdf)
explains why unrestricted automatic failover requires an isolation mechanism.
The [LINBIT DRBD 8.4 guide](https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/)
describes resource-only peer outdating and its limits.
