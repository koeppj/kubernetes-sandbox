# HA implementation validation — 2026-09-26

This document records historical offline validation of the earlier
fencing-based design. The current [master2-only status](status-2026-09-26.md)
and [cutover guide](pacemaker-cutover.md) supersede its activation plan.

This is the 17:03–17:09 UTC offline validation snapshot. The later
[19:47 UTC status](status-2026-09-26.md#pacemaker-migration-checkpoint--1947-utc)
records a DRBD network interruption, successful reconnection, and the current
Pacemaker migration blockers. Use that checkpoint for live readiness.

Read-only live checks were run at approximately 17:03–17:09 UTC from
`ubuntu-master2`. Raw output is private under
`nfs-ha/staging/validation-20260926-implementation/`; that directory is ignored
by Git. No service was started/stopped, no CIB was submitted, no filesystem was
mounted, and no storage endpoint was changed.

| Check | Observed result |
|---|---|
| Four retained DRBD resources | Both peers passed readiness; Connected, UpToDate/UpToDate |
| Roles | master2 Primary; slave1 Secondary, for all four |
| Retirement | Obsolete resource/minor absent; peer private state on kube-vg |
| Filesystems | Source ext4 signatures/labels correct; no HA mounts |
| Legacy NFS | Three kube exports active only on slave1; no general legacy export |
| Clients/options | Both verified IPv4 CIDRs; root squash; Grafana 472:472; PostgreSQL 999:999 |
| Export identity | No explicit fsid in active/static listings or etab; proposed 102–104 not reserved |
| NFS lease | 90 seconds on legacy host |
| Network | Both enp2s0, /24; MetalLB pool .243–.254 |
| Packages | Pacemaker 2.1.6, pcs 0.11.7, Corosync 3.1.7, agents 4.13.0; DRBD kernel 8.4.11 |
| Agents | DRBD, Filesystem, NFS server, exportfs, IPaddr2 hashes identical across hosts |
| Unit ownership | master2 relevant units masked/inactive; slave1 legacy NFS enabled/active, cluster/DRBD disabled/inactive |
| Kubernetes | 19 NFS PVs, 10 bound NFS PVCs; nine detected Deployment/StatefulSet targets at zero replicas |
| Other Kubernetes writers | Three NFS-related Jobs/Pods completed; no active NFS writer found in collected Pod/Job/CronJob specs |
| Restore helper | Existing state retains original counts; dry run passed without restoring workloads |
| External client | Established TCP/2049 connection from ubuntu-mini (.162); mount/use unresolved |

The Kubernetes inventory includes direct NFS volumes and PVC references. It
cannot prove external clients are idle. SSH to ubuntu-mini failed host-key
verification; the trust check was not bypassed. No active `/proc/fs/nfsd/clients`
entry was returned, despite the TCP connection; neither observation identifies
its export or proves that there are no consumers.

Installed NFS agent behavior was read locally: shared state bind mount at
`/var/lib/nfs`, explicit server scope via systemd UTS namespace overrides,
and systemd service management. Export metadata requires one primitive per
client specification and warns against unlocking a filesystem exported by
another resource. The candidate therefore uses six export primitives, with
shared fsid per directory, no per-resource unlock, and NFSv4 lease waits.

The new offline tests validate rejection of invalid VIPs/IDs, stopped default
roles, dependency structure, private state exclusion, root squash, rejection
of non-fencing base resources, and plan-only operation without cluster access.
Native `crm_verify` and `crm_simulate` are exercised with a synthetic fencing
fixture. That fixture has documentation-only device addresses and is never
submitted or used to call a fencing device. Synthetic promotion scores exist
only in simulation copies because `crm_simulate` does not execute DRBD agents.

Corosync syntax was checked with `corosync -t` using an ephemeral private test
key; no membership service started. The no-fencing draft fails Pacemaker
validation as expected. A final real-device CIB cannot be validated until the
fencing selection and parameters exist. The scripts check local metadata
parameter names, not live start/stop behavior of agents.

The operator later confirmed the VIP is excluded from DHCP, so that check is
closed. Remaining requirements in this historical fencing-based plan were to
verify VIP/DNS, identify external clients, verify fsids, select/install/test
independent fencing for both hosts,
validate quorum/partition and DRBD fencing behavior, complete legacy NFS
ownership handoff, then exercise real NFSv4 lock recovery and controlled
switchover. The old disk fault and remaining LVM cleanup are separate work.

Validation commands: `shellcheck` and `bash -n` passed for all three new shell
scripts; `git diff --check` passed. The six new `test_cutover.py` tests pass,
including native stage rendering, schema checks, both-node/survivor scheduling,
and rejection of unresolved execution gates and synthetic production scores.
Full test discovery additionally hits a pre-existing failure: `test_safety.py`
imports the absent retired `scripts/nfs_ha.py`. That historical initialization
test was not changed or silently skipped.

## Gradual migration follow-up

The revised renderer defaults to `migration`. Native scheduler tests cover
both phases, verify no service-group actions on slave1 during migration and no
promotion/VIP startup with only slave1 available. Finalization tests verify that
only the five migration restrictions are removed, both phase and stopped-role
guards hold, and changed live/configuration snapshots are rejected. The stack
planner tests preserve claim names, explicit binding and ownership settings,
and reject unsafe paths or stale PV/PVC identities. Seven focused tests pass;
shell syntax/lint and whitespace checks also pass. These are offline checks;
no migration, service cutover or Kubernetes binding change was executed.
The historical `test_safety.py` missing-module issue described above remains.
