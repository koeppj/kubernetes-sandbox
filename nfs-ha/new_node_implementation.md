# New NFS node implementation

## Summary and verified host inventory

Prepare `ubuntu-master2.koeppster.lan` using free space in its existing `ubuntu-vg`, paired with the existing NFS server `ubuntu-slave1.koeppster.lan`. No third server is planned. Install the required software, provide direct LV creation commands for manual QA and execution, and stage DRBD/NFS/Pacemaker configuration. Stop before HA activation until peer storage, networking, NFS service ownership, and fencing are ready.

This plan is based on [the HA overview](drbd-pacemaker-nfs-ha-overview.md) and read-only host inspection performed on 2026-09-12. Inventory and package versions below are historical observations, not a new verification; recheck before execution. Saving this document does not execute the implementation steps below.

This is a development and demo environment. Planned outages during HA testing are acceptable. The selected sequence is: create new LVs here; create peer backing LVs from already-free extents on `ubuntu-slave1`; build/test DRBD and Pacemaker; then copy and migrate stacks one at a time over multiple weekends. This is a data-copy migration, not an in-place DRBD conversion of the original filesystems.

| Item | Verified value |
|---|---|
| Operating system | Ubuntu 24.04.5 LTS |
| Kernel | `6.8.0-139-generic` |
| Host address | `192.168.1.194/24`, interface `enp2s0` |
| Current NFS server | `ubuntu-slave1.koeppster.lan`, `192.168.1.235` |
| Existing VG | `ubuntu-vg`, approximately 2692.52 GiB free |
| Existing root LV | `ubuntu-vg/ubuntu-lv`, 100 GiB |
| Linux disk | WD 3 TB, serial `WD-WMC4N0H7PM9A`; currently `/dev/sdb` |
| Existing PV | Linux disk partition 3; currently `/dev/sdb3` |
| Windows disk—excluded | Seagate 1 TB, serial `Z4Y1FGA3`; currently `/dev/sda` |
| Network | One active 1 Gb/s Ethernet interface |
| Existing workload | Running MicroK8s applications, including NFS clients |
| HA software | DRBD utilities, Pacemaker, Corosync, pcs, and NFS server absent |
| Fencing | None identified at inspection; automatic HA activation requires working fencing |

The Linux OS, Kubernetes activity, and new NFS storage will share one physical disk. Preserve that arrangement as requested, while accounting for shared I/O load and the effect of fencing this entire machine.

## 1. Storage layout and safeguards

Use ordinary linear LVs allocated exclusively from the existing Linux PV. Do not create a PV, create another VG, change partitions, or resize the root LV.

| New LV in `ubuntu-vg` | Backing size | DRBD resource | Final mount |
|---|---:|---|---|
| `drbd-nfs` | 100 GiB | `nfs` | `/srv/ha/nfs-lv` |
| `drbd-kube` | 200 GiB | `kube` | `/srv/ha/kube-lv` |
| `drbd-grafana` | 5 GiB | `grafana` | `/srv/ha/kube-grafana` |
| `drbd-postgres` | 50 GiB | `postgres` | `/srv/ha/kube-postgres` |
| `drbd-nfs-state` | 1 GiB | `nfs-state` | `/var/lib/nfs-ha` |

Total allocation: **356 GiB**, leaving approximately **2336.52 GiB free**. These are backing-device sizes; DRBD internal metadata and ext4 overhead reduce usable filesystem capacity.

The fifth volume holds private NFS recovery information and is never exported. Both documents include it in the 356 GiB backing allocation. Keep `/srv/ha/...` as the permanent HA export paths on both nodes; the old `/srv/...` paths remain available for legacy storage during migration.

On `ubuntu-slave1`, live inspection on 2026-09-20 found 897.26 GiB free in `nfs-vg` and 311.51 GiB free in `kube-vg`. The planned allocations leave approximately 796.26 GiB and 56.51 GiB respectively, so the existing ext4 filesystems and LVs must not be shrunk. Use [`ubuntu-slave1` storage preparation](ubuntu-slave1-storage-preparation.md) and `nfs-ha-peer-lvm.sh` to revalidate identities/capacity and create new backing LVs from free extents. `nfs-ha-lvm.sh` remains specific to `ubuntu-master2`.

Before manually running the LV creation script, the operator verifies these identities (the read-only preflight also checks them):

- VG UUID: `7tSlFd-Td5w-6UIS-8Q9H-QsyJ-wAjy-AggOQz`.
- PV UUID: `hCi2Mc-JjMO-q15R-Jtb6-lR4z-lzi4-R8394T`.
- Approved PV path: `/dev/disk/by-id/ata-WDC_WD30EZRX-00D8PB0_WD-WMC4N0H7PM9A-part3`.
- Approved parent-disk serial: `WD-WMC4N0H7PM9A`.
- Root LV UUID: `2fQkbV-VOcG-xatJ-qTUs-EYsY-BszZ-HCuXz9`, which must remain unchanged.

Treat disk letters as observations, never durable identities. Reject unexpected PV membership, identity mismatches, or an allocation that would leave less than 512 GiB free.

Explicitly exclude the Windows disk and every partition or alias resolving to it. No mounting, formatting, repair, SMART tests, partition operations, or writes against that disk. Do not enable a disk-monitoring configuration using `DEVICESCAN`.

Local LV creation uses operator QA followed by direct LVM commands. An inventory, `vgcfgbackup`, and off-host metadata copy are optional precautions, not execution prerequisites. LVM metadata backups do not back up filesystem contents. No disposable-VM evidence file or automated backup gate is required for this operation.

### Configuration naming reference

These are the target implementation names. Unless explicitly marked existing, they are planned and not evidence of deployment. Use the same names in rendered configuration, shell scripts, and human-reviewed inventory.

| Resource | `ubuntu-slave1` backing device | `ubuntu-master2` backing device | DRBD device | Replication TCP port | DRBD config file on both hosts |
|---|---|---|---|---:|---|
| `nfs` | `/dev/nfs-vg/drbd-nfs` | `/dev/ubuntu-vg/drbd-nfs` | `/dev/drbd0` | 7788 | `/etc/drbd.d/nfs.res` |
| `kube` | `/dev/kube-vg/drbd-kube` | `/dev/ubuntu-vg/drbd-kube` | `/dev/drbd1` | 7789 | `/etc/drbd.d/kube.res` |
| `grafana` | `/dev/kube-vg/drbd-grafana` | `/dev/ubuntu-vg/drbd-grafana` | `/dev/drbd2` | 7790 | `/etc/drbd.d/grafana.res` |
| `postgres` | `/dev/kube-vg/drbd-postgres` | `/dev/ubuntu-vg/drbd-postgres` | `/dev/drbd3` | 7791 | `/etc/drbd.d/postgres.res` |
| `nfs-state` | `/dev/nfs-vg/drbd-nfs-state` | `/dev/ubuntu-vg/drbd-nfs-state` | `/dev/drbd4` | 7792 | `/etc/drbd.d/nfs-state.res` |

Verify minors and ports are free before adopting these mappings. On `ubuntu-slave1`, budget 101 GiB of new LVs in `nfs-vg` and 255 GiB in `kube-vg`, plus retained original LVs and reserve. No new VG is planned. Source LVs remain `nfs-vg/nfs-lv`, `kube-vg/kube-lv`, `kube-vg/kube-grafana`, and `kube-vg/kube-postgres`; never confuse them with the new `drbd-*` targets. Stable PV identities for that host are recorded in [`ubuntu-slave1` storage preparation](ubuntu-slave1-storage-preparation.md); do not use disk letters as durable identities.

| Cluster item | Planned name / convention |
|---|---|
| Corosync/Pacemaker cluster | `nfs-ha` |
| Node names in configuration | `ubuntu-slave1`, `ubuntu-master2`; verify against each host's actual cluster/uname identity |
| DRBD primitives | `p-drbd-nfs`, `p-drbd-kube`, `p-drbd-grafana`, `p-drbd-postgres`, `p-drbd-nfs-state` |
| Promotable clone IDs | `cl-drbd-nfs`, `cl-drbd-kube`, `cl-drbd-grafana`, `cl-drbd-postgres`, `cl-drbd-nfs-state` |
| Filesystem primitives | `p-fs-nfs`, `p-fs-kube`, `p-fs-grafana`, `p-fs-postgres`, `p-fs-nfs-state` |
| NFS server primitive / server scope | `p-nfs-server` / `nfs-ha` |
| Export primitive IDs | `p-export-nfs-<client-id>`, `p-export-kube-<client-id>`, `p-export-grafana-<client-id>`, `p-export-postgres-<client-id>` |
| Export filesystem IDs | Reserve 101 (`nfs`), 102 (`kube`), 103 (`grafana`), 104 (`postgres`); confirm no conflict with legacy exports |
| Ordered service group | `g-nfs-ha`: five filesystem primitives, NFS server, export primitives, then VIP |
| VIP primitive | `p-nfs-vip` |
| Fencing resource IDs | `stonith-ubuntu-slave1`, `stonith-ubuntu-master2`; actual agent/device parameters remain to be selected |
| Ordering / colocation constraints | `ord-drbd-<resource>-nfs-ha` / `col-nfs-ha-drbd-<resource>`, for each of the five resources |

Use a short stable `client-id` such as `lan-v4` or `lan-v6` for each verified export client specification; record its exact network in the rendered configuration. The label does not authorize a subnet. Multiple client specifications for one filesystem share its export filesystem ID. Validate resource IDs and agent syntax against installed versions. The NFS recovery directory is `/var/lib/nfs-ha/state` on the private `nfs-state` filesystem, not a sixth export.

Reserve the service name `nfs-ha.koeppster.lan` in DNS when a free VIP has been selected. Its IP is **TBD**, not `192.168.1.235` or `192.168.1.194`. Keep host administration/replication addresses separate from the service endpoint.

| Planned configuration/artifact | Purpose |
|---|---|
| `nfs-ha/.env`, `nfs-ha/.env.sample` | Live local settings and placeholder-only sample; currently not required by existing preparation scripts |
| `NFS_HA_CLUSTER_NAME`, `NFS_HA_SERVER_SCOPE` | Both `nfs-ha` |
| `NFS_HA_VIP`, `NFS_HA_VIP_PREFIX`, `NFS_HA_SERVICE_DNS` | Reserved IPv4 VIP, verified prefix length, and `nfs-ha.koeppster.lan` |
| `NFS_HA_SLAVE1_ADDRESS`, `NFS_HA_MASTER2_ADDRESS` | Verified node addresses for the chosen replication/membership network |
| `NFS_HA_SLAVE1_INTERFACE`, `NFS_HA_MASTER2_INTERFACE` | Verified per-node interface names; do not assume they match |
| `nfs_server_ip` | Existing variable in consuming infrastructure/app `.env` files; set to the selected VIP |
| `nfs-ha/templates/drbd/<resource>.res.template` | Five DRBD templates using the resource names above |
| `nfs-ha/templates/corosync.conf.template` | Membership template; rendered destination `/etc/corosync/corosync.conf` |
| `nfs-ha/templates/pacemaker/nfs-ha.crm.template` | Resources and constraints; stage as `pacemaker/nfs-ha.crm` for native validation before explicit CIB submission |
| `/var/lib/nfs-ha-preparation/staging-<timestamp>/` | Existing staging-root convention; future renderer stages `drbd.d/*.res`, `corosync/corosync.conf`, and `pacemaker/nfs-ha.crm` beneath it |
| `/var/lib/nfs-ha-preparation/migrations/<stack-id>/` | Planned private operator records: `inventory.tsv`, `replicas.tsv`, `old-pvs.yaml`, `old-pvcs.yaml`, `new-pvs.yaml`, `new-pvcs.yaml`, and `status.md` |

Use stable stack IDs such as `n8n`, `keyclock`, and `grafana-loki` (`keyclock` preserves the repository spelling). `inventory.tsv` records namespace, PVC, old/new PV names, old/new server/share/subdirectory, and authoritative endpoint. These are local records, not a database or automated approval ledger. Keep credentials and live snapshots out of version control. Shell renderers must explicitly load/export required values; `.env` is not automatically consumed by system services.

## 2. Software installation and management scripts

### Package installation

Use Ubuntu’s configured repositories and this package set:

```bash
sudo apt-get install --no-install-recommends \
  lvm2 drbd-utils \
  pacemaker pacemaker-cli-utils corosync pcs \
  resource-agents-base resource-agents-extra \
  nfs-kernel-server nfs-common \
  rsync acl attr smartmontools shellcheck
```

`lvm2` and `rsync` are already installed. Package simulations completed successfully for the core package set. Re-run the simulation immediately before installation, including the explicit CLI package above.

Installation procedure:

1. Record package versions, service states, current NFS mounts, and Kubernetes health.
2. Refresh package indexes and inspect the installation simulation. Stop on unexpected removals, upgrades, or service changes.
3. Temporarily suppress package-triggered service starts and automatic restarts. Preserve any existing `policy-rc.d` policy and restore it exactly on success or failure.
4. Install packages without a general system upgrade, autoremove, kernel replacement, or reboot.
5. Keep NFS server, DRBD startup, Corosync, Pacemaker, pcsd, and smartd inactive during preparation. Ensure server/socket activation cannot bypass this boundary; preserve existing NFS client operation.
6. Recheck workloads, mounts, services, and listening ports.

Install the appropriate fencing agent only after actual hardware is selected. Installing a fencing package is not evidence that fencing works.

Use the existing in-kernel **DRBD 8.4.11** as the preparation baseline. The available `drbd-utils` package is **9.22.0**; its version does not identify the running kernel driver. Verify compatibility on both hosts before initialization. Do not introduce a PPA, DKMS module, or DRBD 9-only configuration automatically. Use version-specific configuration and fencing integration from the [LINBIT DRBD 8.4 guide](https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/).

### Script interfaces

Use small, readable Bash scripts and standard tools for automated activities. Prefer direct LVM, DRBD, Pacemaker, `rsync`, and `microk8s kubectl` commands over complex Python wrappers or general orchestration frameworks. Resolve `SCRIPT_DIR` from `BASH_SOURCE`; keep live configuration in the component `.env`, synchronize placeholder-only `.env.sample` variables, and use `envsubst` only for intended templates. Keep destructive steps bounded, with explicit targets and ordinary shell error handling.

Human review is the primary QA: inspect commands, live inventory, rendered configuration, and dry-run output, then inspect the result of each step. Do not expand this effort into extensive automated testing, disposable-VM suites, or evidence/approval frameworks. Lightweight syntax/lint checks and native validators support that review. HA activation and per-stack copy/rebinding scripts should be separate from local preparation and should not silently add those actions to these entrypoints.

The preparation entrypoints live under `nfs-ha/scripts/`. Preflight, package installation, and staging currently delegate to `nfs_ha.py`; LV creation uses standalone shell scripts. The shell-first guidance above describes future implementation, not a completed rewrite. The current config script emits only `preparation.json`, still using old `/srv/...` paths; it does not yet render the HA templates or names specified here. Update that renderer before using it to prepare activation.

| Script | Interface and responsibility |
|---|---|
| `nfs-ha-preflight.sh` | Read-only inventory, storage identity checks, package/service checks, capacity report, and unresolved activation prerequisites. |
| `nfs-ha-packages.sh` | Default simulation; `--apply` performs the guarded installation procedure and restores temporary installation controls. |
| `nfs-ha-lvm.sh` | No arguments: immediately runs five explicit `lvcreate` commands, then prints `lvs` output. Operator performs QA before execution. |
| `nfs-ha-config.sh` | Existing `--output <directory>` stages `preparation.json` only. Planned extension renders the named templates and validates them; no automatic service activation or live CIB submission. |

Keep additional Bash entrypoints small and stage-specific; do not add a Python orchestrator. `nfs-ha-peer-lvm.sh` is implemented; the remaining entries are planned.

| Script | Scope / intended interface |
|---|---|
| `nfs-ha-peer-lvm.sh` | Implemented, `ubuntu-slave1` only: default identity/capacity/allocation preview; `--apply` saves LVM metadata and creates the five named new LVs in `nfs-vg`/`kube-vg` from free extents |
| `nfs-ha-drbd-init.sh` | Default initialization preview; `--apply` initializes only identified new targets, with an explicit initialization source and one-time ext4 creation |
| `nfs-ha-activate.sh` | Default review of staged configuration; `--apply` performs explicit configuration installation, service-ownership handoff, and CIB submission |
| `nfs-ha-migrate-stack.sh` | `--stack <stack-id> --phase <inventory\|copy\|rebind\|verify>`; preview by default, `--apply` executes only the selected phase |
| `nfs-ha-rollback-stack.sh` | `--stack <stack-id>` previews restoration of saved bindings; `--apply` executes the reviewed rollback after writers stop and any data reconciliation is settled |

New scripts should print their exact targets in previews and stop on unexpected state. The existing `nfs-ha-lvm.sh` remains the documented exception: no arguments creates LVs immediately. Reuse the existing repository-wide `bin/shutdown-nfs-workloads.sh` and `bin/restore-nfs-workloads.sh` for global outages; do not invent stack filtering options for them.

Required implementation behavior:

- The LV creation script uses strict shell error handling and five direct LVM commands with the sizes in the layout table.
- Each command explicitly allocates from the approved stable Linux PV path in `ubuntu-vg`, with `--type linear`, `--zero n`, and `--wipesignatures n`. Never use `%FREE`.
- There is no Python storage wrapper, UUID ledger, automated backup/evidence gate, or automatic skip/reconciliation logic.
- Before execution, the operator reviews the script and live preflight inventory, verifies identities and sufficient reserve, and confirms the five target names do not exist.
- The script rejects arguments; old `plan`, `create`, `grow`, and `--apply` interfaces are removed. Running it with no arguments creates LVs immediately.
- An existing target LV or other command failure stops the script. Keep partial allocations intact, inspect them, and manually execute only remaining commands after review. Never erase or automatically repair existing LVs.
- The final `lvs` report prints UUIDs, sizes, types, and backing devices for manual verification and recordkeeping.
- These local-preparation entrypoints provide no shrink, remove, PV-management, partition-management, filesystem-formatting, or DRBD-initialization commands. Later migration procedures cover only their explicitly reviewed stage.
- Preflight, package installation, and staging retain their shared identity checks, process lock, restrictive permissions, and timestamped logs. The direct LV creation script does not implement those controls.

Growth is a separate manually reviewed procedure, not a script mode. Use absolute target sizes for backing LVs and never `lvextend -r`, because ext4 belongs above DRBD. Configured resources require coordinated growth on both nodes, followed by DRBD resize and filesystem growth.

## 3. Staged DRBD, NFS, and cluster configuration

### DRBD and filesystem ownership

Prepare five resource templates with:

- Protocol C, one Primary per resource, internal metadata, and explicit node-specific backing LV paths.
- Fixed resource/device mapping, using minors 0–4 and TCP ports 7788–7792 after confirming availability on both hosts.
- No dual-primary mode, automatic primary promotion, or automatic split-brain discard policy.
- No filesystem created directly on an LV.
- No DRBD filesystem entries in `fstab` or independently enabled mount units.

DRBD metadata creation, initial promotion, filesystem creation, and initial synchronization belong to a later coordinated stage. Require positively identified new LVs on both nodes, compatible versions, and an explicitly designated initialization source. Create each ext4 filesystem once through its DRBD device.

The peer may use another VG name. Matching backing sizes and correct per-node paths matter; matching VG names do not.

### NFS configuration

Stage Pacemaker export resources instead of activating exports through `/etc/exports`.

Preserve the exact source client restrictions, IPv6 scopes, and options after collecting the authoritative source configuration. Do not infer export permissions from this host’s subnet.

| Original export on `ubuntu-slave1` | HA export on active node | Identity behavior |
|---|---|---|
| `/srv/nfs-lv` | `/srv/ha/nfs-lv` | Preserve existing normal root squashing |
| `/srv/kube-lv` | `/srv/ha/kube-lv` | Preserve existing normal root squashing |
| `/srv/kube-grafana` | `/srv/ha/kube-grafana` | `root_squash,anonuid=472,anongid=472` |
| `/srv/kube-postgres` | `/srv/ha/kube-postgres` | `root_squash,anonuid=999,anongid=999` |

Preserve numeric ownership, ACLs, xattrs, and restrictive application permissions. Apply `65534:65534` and `0777` only to the four mounted export roots where confirmed by the source inventory; never recursively.

Configure the clustered NFS server with:

- NFSv4 over TCP, preserving existing NFSv4.1 hard-mount behavior.
- Private recovery directory `/var/lib/nfs-ha/state`.
- Identical `nfs_server_scope` on both nodes.
- Explicit stable export filesystem IDs, consistent across nodes.
- Resource-agent stop timeouts that accommodate NFS lease handling.

The NFS agent requires shared recovery storage and a consistent server scope for recovery across failover. Verify its interaction with this machine’s existing NFS clients before activation; do not blindly enable an agent mode that masks client-related services. See the [NFS server agent](https://raw.githubusercontent.com/ClusterLabs/resource-agents/v4.13.0/heartbeat/nfsserver) and [export agent](https://raw.githubusercontent.com/ClusterLabs/resource-agents/v4.13.0/heartbeat/exportfs).

### Pacemaker resource model

Stage five promotable `ocf:linbit:drbd` resources and one ordered service group:

```text
All five DRBD resources promoted on the same node
  → five filesystem mounts
  → clustered NFS server
  → four sets of export resources
  → VIP
```

Use mandatory ordering and colocation against every promoted DRBD resource. Each promotable clone allows one promoted instance across the cluster. Shutdown reverses the service order.

Keep STONITH enabled. Planned outages are acceptable, but disabled fencing, maintenance mode, or manual promotion do not substitute for safe automatic failover.

Validate staged configuration with installed resource-agent metadata, `crm_verify`, and `crm_simulate` before applying it. Pacemaker must ultimately own promotion, mounting, exports, and the VIP; standalone service startup must not compete with it.

## 4. HA activation and phased migration

Local preparation ends with installed but inactive software, five unformatted backing LVs, staged configuration, and a validation report.

Before activating automatic HA, resolve and human-review:

- **Fencing:** independent power control for both hosts, tested in both directions during a maintenance window that accounts for Kubernetes workloads.
- **Membership safety:** an explicit Corosync quorum design and DRBD fencing integration, with partition behavior tested.
- **Networking:** stable node addresses, selected replication/membership links, and a reserved VIP checked against DHCP, DNS, and MetalLB allocations.
- **Peer storage:** adequate new target LVs alongside the unchanged originals in each VG, with at least the reviewed free-space reserve remaining.
- **Exports:** authoritative export definitions, current data usage, inode requirements, ownership, and client inventory.
- **Recovery:** verified backups and an operator-observed NFS recovery/failover exercise using a non-critical client during a scheduled outage. A separate test environment is not required.
- **Service ownership:** a reviewed procedure for legacy exports and Pacemaker-managed NFS on `ubuntu-slave1`, including stop/start ownership when HA moves there. Separate export paths do not create separate kernel NFS servers.

Do not repurpose `192.168.1.235` as a VIP without a separate network migration design: it is also the existing Kubernetes node address.

Build and test the new HA stack before moving application data. Initialize the five new DRBD resources, create their filesystems through DRBD, synchronize, and let Pacemaker manage the permanent HA paths, private recovery state, exports, and VIP. Prefer `ubuntu-master2` as the active node between migration windows while `ubuntu-slave1` serves unmigrated data. That placement is a preference, not protection from failover or fencing.

Accept a shared outage for service ownership changes and failover/fencing tests. Use the repository shutdown/restore helpers with reviewed `--dry-run` output from a MicroK8s control-plane host for all-NFS outages; they cover Deployments and StatefulSets, not Jobs, CronJobs, unmanaged Pods, or external clients. The existing helpers are global, not stack-selective. For a single-stack outage, record and stop that stack's writers explicitly using a small reviewed shell procedure. Fencing either host also stops its Kubernetes activity; account for control-plane availability and retain direct host administration access.

For each stack's maintenance window:

1. Record its workloads/replicas, PVC/PV definitions, exact directories, and old/new endpoints in a simple migration inventory. Include all related storage: n8n and Keycloak each span general and PostgreSQL exports; Grafana/Loki spans Grafana and general exports.
2. Copy only that stack's directories from the old host's local filesystems using privileged `rsync -aHAX --numeric-ids` through authenticated SSH, or local paths when both are mounted on the active host. An NFS-mounted copy may not expose all metadata correctly. Throttle if needed; it is also acceptable to stop the stack for the entire copy.
3. Stop writers and cleanly shut down PostgreSQL before the final synchronization. Review the dry run, preserve numeric ownership/ACLs/xattrs, and reconcile deletions only within that stack's target directories. Never synchronize a whole export over already migrated stacks.
4. Set the affected **existing PVs** to `Retain` before removing storage objects. Recreate/rebind the necessary PV/PVC definitions against the VIP and copied directories, preserving application-facing claim names. Use explicit prebinding to avoid fresh empty volumes and review CSI volume handles with server/share/subdirectory values. Keep controllers stopped so they cannot recreate claims unexpectedly.
5. Release old mounts and use fresh mounts through the VIP. New filesystems have new file-handle identities; this first migration is not a transparent DRBD failover. Check data, ownership, database startup, and application reads/writes, then resume normal use.
6. Mark the new endpoint authoritative for this stack and retain its original directories for fallback. Leave other stacks on the old endpoint until their window; repeat over subsequent weekends. Retire old exports only when every consumer has moved.

Keep StorageClass names `kube-nfs`, `kube-postgres`, and `kube-grafana`. Once HA is ready, recreate those class objects under the same names with the VIP and new `/srv/ha/...` shares; server/share parameters are immutable. Update repository templates and component configuration to match. Pause new provisioning during this change. It affects future provisioning only: existing PVs retain their endpoints and require the individual migration above because their volume source is immutable. Old and new PVs can share a class name, so track actual endpoint/path per PV. See [Kubernetes volume retention and reclaim rules](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

### Kubernetes object and path names

| Existing StorageClass name (retain) | Existing manifest to update at implementation | Target NFS share |
|---|---|---|
| `kube-nfs` | `infrastruture/create-storage-class.yaml` | `/srv/ha/kube-lv` |
| `kube-postgres` | `infrastruture/postgres-storage-class.yaml` | `/srv/ha/kube-postgres` |
| `kube-grafana` | `grafana+loki/manifests/grafana-storage-class.yaml` | `/srv/ha/kube-grafana` |

All three retain provisioner `nfs.csi.k8s.io` and use `parameters.server: ${nfs_server_ip}` with the selected VIP. No new Kubernetes namespace, Service, or Deployment is needed for the host-managed NFS HA service. Preserve application namespaces, workload names, and PVC names, including StatefulSet-generated claims discovered from the live cluster.

For explicitly created replacement PVs, use `nfs-ha-<namespace>-<pvc-name>` and record the resolved name before rebinding. PV names are cluster-wide; if concatenation exceeds Kubernetes name limits, choose and record a unique shorter name rather than silently truncating. In the recreated PVC manifest, retain its application-facing name but set `spec.volumeName` to the replacement PV; set that PV's `claimRef` to the intended namespace/claim name. Do not attempt to edit a bound PVC's volume name in place or reuse stale claim UIDs from exported YAML. Confirm the controller binding procedure during human review.

Keep each copied PVC directory's existing relative subdirectory name under the corresponding new share. Do not infer it from the PVC name: dynamic provisioning may have used a UID-based name. For example, a recorded `pvc-<existing-id>` under `/srv/kube-lv` becomes `/srv/ha/kube-lv/pvc-<existing-id>`. Record the exact new CSI `volumeHandle` in `new-pvs.yaml` using the installed driver's format and unique server/share/subdirectory identity; never blindly carry forward a handle containing the old endpoint. Old PV names remain in `old-pvs.yaml` for fallback. Use `Retain` on migration PVs until cleanup is deliberately reviewed.

After each deployed change, review discovery by both maintenance helpers and run the shutdown dry run; preserve NFS class identification and claim references so future shutdown/restore includes migrated workloads. Do not run the full infrastructure setup just to change storage definitions.

Original LVs and filesystems stay unchanged during storage preparation and provide per-stack fallback afterward. Before new writes, stop the affected stack and restore saved bindings to its old directories with fresh mounts. After new writes, rollback requires stopping writers and reconciling or restoring changed data. Never run independent writers against both copies of the same stack, and do not stop the entire HA service to roll back one stack if other migrated stacks depend on it.

## 5. Validation, recovery, and acceptance

For local LV creation, the operator manually reviews the direct commands and live storage inventory before executing. Disposable-VM testing and mocked storage-mutation tests are not prerequisites in this revised workflow.

Before execution, check:

- Correct hostname, VG/PV UUIDs, approved stable PV path, parent serial, and sole-PV membership.
- The Windows disk and root LV are not targets.
- Enough capacity remains for the 356 GiB allocation plus at least 512 GiB free.
- None of the five target LV names already exists. If a prior run partially completed, review and execute only the remaining commands.

Use human-reviewed preflight inventory, package simulation, service-state comparisons, and staged configuration as the main QA evidence. Check temporary installation-policy restoration and inspect failure handling in the shell scripts. Run `bash -n` and ShellCheck on changed scripts and native configuration validators when configuration changes. Existing focused tests may be useful, but extensive mocked checks, disposable-VM tests, and a new automated test framework are not required. Missing VIP, peer identity, export restrictions, service ownership, or fencing still prevents automatic HA activation.

Local acceptance:

- Five correctly sized linear LVs exist exclusively on the approved Linux PV.
- Root LV, partitions, boot configuration, and Windows disk remain unchanged.
- No new DRBD device is promoted, filesystem mounted, export active, or VIP assigned.
- Existing Kubernetes workloads and NFS mounts remain healthy.
- Changed scripts pass `bash -n` and ShellCheck, and the operator has reviewed commands and actual results.

Later HA acceptance:

- All five resources synchronize and have one active owner.
- Filesystems and exports follow that owner; the VIP appears last.
- A failed mount prevents NFS/VIP startup.
- Persistent client I/O and lock recovery survive controlled failover.
- Grafana and PostgreSQL retain their required numeric identities.
- Fencing, replication-link failure, cluster-link failure, and node restart produce the intended safe behavior.
- Maintenance leaves the surviving node active without automatic failback.

Monitor DRBD replication state, filesystem space/inodes, VG reserve, NFS recovery failures, and cluster/fencing failures. Configure disk health monitoring for the approved Linux disk only.

Routine growth extends matching backing LVs on both nodes, verifies both sizes, resizes DRBD with version-appropriate commands, and finally grows ext4 through the active DRBD device. Do not shrink established DRBD resources or automatically undo a partial growth operation.
