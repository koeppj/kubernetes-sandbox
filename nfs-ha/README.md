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

The current tooling consists of small, preview-first shell scripts. LV creation
is complete on both nodes. The next implemented stage installs packages,
installs the five DRBD resource definitions, creates metadata on each peer, and
performs the one-time source initialization and ext4 creation. See
[`drbd-initialization.md`](drbd-initialization.md) for the ordered runbook.

## Completed storage preparation

The five new, unformatted backing LVs have been created on both hosts. The
storage scripts remain available as the reviewed record of that work:

```bash
# Review scripts/nfs-ha-lvm.sh and live storage before executing:
sudo ./scripts/nfs-ha-lvm.sh                      # creates all five LVs immediately
```

On `ubuntu-slave1`, preview and then create its five backing LVs from existing
free extents. The existing filesystems and LVs do not need resizing:

```bash
sudo ./scripts/nfs-ha-peer-lvm.sh
sudo ./scripts/nfs-ha-peer-lvm.sh --apply
```

Do not rerun either LV creation script now that its targets exist.

## Next stage: DRBD installation and initialization

Run each preview before its matching `--apply` invocation, following the full
two-node checkpoints in [`drbd-initialization.md`](drbd-initialization.md):

```bash
# Each node: package simulation/install and static resource configuration.
sudo ./scripts/nfs-ha-packages.sh
sudo ./scripts/nfs-ha-packages.sh --apply
sudo ./scripts/nfs-ha-drbd-config.sh
sudo ./scripts/nfs-ha-drbd-config.sh --apply

# Each node: create internal metadata and connect the five resources.
sudo ./scripts/nfs-ha-drbd-metadata.sh
sudo ./scripts/nfs-ha-drbd-metadata.sh --apply

# ubuntu-master2 only, after both peers are Connected and Secondary.
sudo ./scripts/nfs-ha-drbd-init.sh --source ubuntu-master2
sudo ./scripts/nfs-ha-drbd-init.sh --source ubuntu-master2 --apply
```

The package installer preserves and restores an existing `policy-rc.d` while
suppressing package-triggered starts. If the host loses power or the process is
killed before cleanup and `/usr/sbin/policy-rc.d.nfs-ha-original` remains,
inspect and restore it before retrying. The existing NFS service on
`ubuntu-slave1` is not disabled or stopped.

The DRBD scripts do not mount filesystems or activate NFS, Corosync, Pacemaker,
exports, or a VIP. Run Kubernetes workload discovery and any later shutdown
from a MicroK8s control-plane host; this worker's local `microk8s kubectl` must
not be used to conclude that there are no NFS consumers.

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

The five DRBD resource templates now implement the fixed backing-device,
address, port, protocol C, internal metadata, and split-brain-disconnect choices
from the design. Pacemaker/NFS templates and activation remain unimplemented.
Peer fencing, the VIP, authoritative export clients, quorum behavior, legacy NFS
service ownership, and recovery testing must be resolved before that stage.

### Validation

```bash
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
```

Use the scripts' previews, live state output, and DRBD's native parser as the
primary QA. No Kubernetes workload, PVC, or StorageClass specification changes
in this stage.

See [the 2026-09-13 validation record](validation-2026-09-13.md) for the earlier
new-node inspection and preparation history.
