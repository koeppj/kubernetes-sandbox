# NFS HA Project

This folder contains all the resources needed to set up a high availability NFS for this project.

Not a "stack" in the traditional sense, but a collection of documentation that describes the
desired end-state, the plans to get there, and any scripts and tooling needed to implement the setup.

## Resources

**Note to AGENTS**: Update this document as you make changes to the NFS setup.

The current target design uses `ubuntu-slave1` and `ubuntu-master2`, new `drbd-*`
LVs, and `/srv/ha/...` exports with phased stack migration. See the
[overview naming table](drbd-pacemaker-nfs-ha-overview.md#configuration-names)
and [implementation naming reference](new_node_implementation.md#configuration-naming-reference)
for exact LV paths, DRBD mappings, Pacemaker IDs, configuration artifacts,
and Kubernetes names. Source-host capacity and allocation steps are in
[`ubuntu-slave1` storage preparation](ubuntu-slave1-storage-preparation.md).

The commands below describe the existing preparation tooling. In particular,
the Python-backed configuration helper still emits the old mount paths in
`preparation.json`; it is not an implementation of the revised HA design.
Align the renderer with the naming reference before activation. Future work
favors small shell scripts and human-reviewed QA; the existing Python helpers
and optional tests below have not been rewritten by these documentation changes.

## Steps 1 and 2: local preparation

Run the entrypoints from this directory with `sudo`. LV creation uses five direct
`lvcreate` commands in a standalone shell script for manual QA and execution.
The other entrypoints use Python 3's standard library for inventory, validation,
logging, locking, and installation-policy recovery. No `.env` values are required.

```bash
sudo ./scripts/nfs-ha-preflight.sh
sudo ./scripts/nfs-ha-packages.sh                 # simulation, no apt update
sudo ./scripts/nfs-ha-packages.sh --apply         # guarded update + install
# Review scripts/nfs-ha-lvm.sh and live storage before executing:
sudo ./scripts/nfs-ha-lvm.sh                      # creates all five LVs immediately
sudo ./scripts/nfs-ha-config.sh --output /var/lib/nfs-ha-preparation/staging-UNIQUE
```

On `ubuntu-slave1`, preview and then create its five backing LVs from existing
free extents. The existing filesystems and LVs do not need resizing:

```bash
sudo ./scripts/nfs-ha-peer-lvm.sh
sudo ./scripts/nfs-ha-peer-lvm.sh --apply
```

Run the repository's Kubernetes workload shutdown/restore helpers from a
MicroK8s control-plane host. This worker's local `microk8s kubectl` does not
enumerate the cluster and must not be used to conclude that there are no NFS
consumers.

Preflight and package simulation do not mutate storage, packages, or services.
The Python-backed entrypoints write private timestamped logs and a lock under
`/var/lib/nfs-ha-preparation` (root-only). Package installation saves before/after
inventory, Kubernetes health, NFS mounts, service states, and listening ports.
Existing unhealthy pods are recorded; new unhealthy pods fail the post-check.
Package simulations reject upgrades, removals, and kernel/DKMS additions.

The installer preserves the existing `policy-rc.d` object by rename and restores
it on normal exit, exceptions, SIGINT, SIGTERM, and SIGHUP. `needrestart` is
suppressed for the install process. Persistent masks keep NFS server, HA, pcsd,
and SMART services inactive across reboot. NFS client units remain available.
The masks are intentional preparation controls; future activation needs a
separate reviewed procedure. SMART monitoring is not enabled, including the
package's default `DEVICESCAN` configuration.

A power failure or SIGKILL cannot execute cleanup handlers. If
`/usr/sbin/policy-rc.d.nfs-ha-original` exists, investigate the interrupted package
operation and restore that original object before retrying. The installer
refuses to overwrite a stale policy backup. If no original policy existed, the
temporary policy is recognizable by its `NFS HA preparation boundary` comment.

### Manual LV creation

Review `scripts/nfs-ha-lvm.sh`, run the read-only preflight, and manually confirm
the host, VG/PV identities, root LV, free space, and absence of the five target
LV names before running it. The planned 356 GiB allocation leaves approximately
2336.52 GiB free; retain at least 512 GiB. The script itself does not enforce
host/UUID/capacity checks, lock execution, or keep a private ledger.

The script uses the approved Linux PV's stable `/dev/disk/by-id/` path explicitly
in each command. It creates ordinary linear LVs with zeroing and signature
wiping disabled. It does not format filesystems or initialize DRBD.

**Running `sudo ./scripts/nfs-ha-lvm.sh` creates the LVs immediately.** There are
no `plan`, `create`, `grow`, or `--apply` modes; arguments are rejected to avoid
accidentally treating an old dry-run invocation as an execution request.

An existing target LV makes `lvcreate` fail. The script stops there and leaves
prior allocations intact. After a partial failure, inspect `lvs` and manually
run only the remaining commands after review. Do not remove completed LVs to
make the script rerunnable. Its final `lvs` command prints sizes, UUIDs, types,
and backing devices for manual verification and recordkeeping.

Off-host metadata backup and disposable-VM test evidence are no longer
prerequisites for local LV creation, per the revised manual QA workflow. A
`vgcfgbackup` and off-host copy remain optional precautions; LVM metadata is not
an application-data backup. There is no automated backup or evidence gate.

Growth is a separate manual operation. For configured DRBD resources, follow the
coordinated two-node growth procedure in the implementation plan: extend both
backing LVs, resize DRBD, then grow ext4 through the active DRBD device. Never
use `lvextend -r` on a backing LV or shrink it.

### Configuration boundary

`nfs-ha-config.sh` stages and round-trip validates the five-volume preparation
layout as JSON, with activation explicitly blocked. It cannot write into `/etc`
or submit a CIB. DRBD/NFS/Pacemaker templates and resource-agent/CRM validation
are step 3 and are not implemented by this steps 1–2 change. Peer identity,
network/VIP, exports, quorum, fencing, and recovery evidence remain unresolved.

### Validation

```bash
python3 -m unittest discover -s tests -v
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
```

Mock tests cover preflight identities and capacity, manually created LV layout
validation, package simulation and policy restoration, and activation exclusion.
The direct LV creation commands are reviewed and executed manually by the
operator. No Kubernetes workload, PVC, or StorageClass specifications change.

See [the 2026-09-13 validation record](validation-2026-09-13.md) for actual host
changes and the revised workflow. LV creation remains pending manual QA and
execution by the operator.
