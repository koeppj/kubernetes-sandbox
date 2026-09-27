# Gradual stack migration on the master2-only service

This is the supported no-power-fencing path. The Pacemaker NFS service, VIP
and all DRBD Primaries remain on master2. Both cluster votes are required;
loss of either member or its Corosync link stops service when master2 can
perform stop actions. There is no automatic takeover by slave1. Complete the
network, VIP, DRBD and membership checks in
[Pacemaker cutover](pacemaker-cutover.md) before moving any production claim.
The operator confirmed `192.168.1.240` is excluded from DHCP; no further DHCP
verification is required. No firewalls are in place. NFS clients are the
Kubernetes nodes mounting PVC-backed volumes through the NFS StorageClasses;
validate those mounts after activation.
Each stack gets its own data-copy/rebind window; other legacy stacks can
continue on slave1 after the shared bootstrap outage.

## A. Start the migration service on master2

Set NFS_HA_PHASE=migration in the component .env. Render an offline stage
directly on master2, with no fencing-only base CIB. Execute cutover actions
on master2 as well:

~~~bash
./scripts/nfs-ha-stage.sh staging/migration-YYYYMMDD-HHMM
./scripts/nfs-ha-cutover.py submit --stage staging/migration-YYYYMMDD-HHMM
./scripts/nfs-ha-cutover.py activate --stage staging/migration-YYYYMMDD-HHMM
~~~

Commands without --execute print plans. For execution, add sudo and
--record PRIVATE_RECORD.json --execute after completing the maintenance gates.
Hash cib-stopped.xml with sha256sum for the record. The fresh stage must
simulate startup only with both nodes present and stopping on quorum loss.
Migration does not require retiring legacy NFS or stopping its writers after
the shared bootstrap. It does require stopping writers using the new HA
filesystems during a cluster-wide stop/start.

Verify all four DRBD Primaries/mounts, shared recovery-state bind, new exports
and VIP are on master2 only. Verify slave1 still serves its old shares and
has four Secondary replicas with no HA mounts. Test the new endpoint with a
disposable NFSv4.1 client, root squash, identities and read/write/fsync before
migrating production. A failed stop, hung master2 or disconnected DRBD link
requires manual diagnosis; never promote slave1 or move the group there.
Migrated clients wait for manual recovery when master2 cannot serve.

For a later controlled stop/start, preserve legitimate configuration changes
by staging a fresh stopped snapshot that keeps every migration restriction:

~~~bash
sudo cibadmin --query > staging/migration-restart-stopped.xml
./scripts/nfs-ha-stage-finalize.py --restart staging/migration-restart-stopped.xml staging/migration-restart-YYYYMMDD-HHMM
~~~

Use activate with this stage and a fresh maintenance record/hash.

## B. Plan one stack

Pause automatic PVC provisioning/reconciliation for the migration windows.
Keep the existing StorageClasses pointing to legacy shares during gradual
migration; each migrated claim receives a static prebound PV at the VIP.
This avoids sending newly provisioned directories to an endpoint before the
owning stack is ready. Record any intentional new claims separately.

Identify **all** claims/writers for the chosen application, including shared
claims, database jobs, init containers, CronJobs, HPAs/operators and external
clients. Do not assume a namespace is exactly one stack. On the control plane:

```bash
./scripts/nfs-ha-stack-plan.py --namespace YOUR_NAMESPACE \
  --claim FIRST_CLAIM --claim SECOND_CLAIM --vip RESERVED_VIP \
  --output staging/stack-NAME-YYYYMMDD-HHMM
```

This only reads Kubernetes and writes private artifacts:

- Original PV/StorageClass and namespace workload/PVC snapshots, including
  replica counts, Jobs, CronJobs and HPAs.
- `migration-map.json` with exact source and target host/directory per claim.
- Per-old-PV Retain patch files.
- `new-pvs.json` and `new-pvcs.json` with new handles, Retain, explicit two-way
  prebinding and the **same application-facing claim names**.

The planner accepts the observed NFS CSI layout only: server `.235`, one of
three known legacy shares, explicit safe `subdir`, and matching Bound PV/PVC
UIDs. Unexpected layouts fail rather than guessing a data location. Recreated
objects omit runtime UIDs, binding annotations, finalizers and owner references.
Review labels/selectors, owner lifecycle, custom annotations and resource
requests before using them. The new static PV mounts the exact copied directory;
`mountPermissions=0` preserves copied modes instead of forcing chmod.
The planner does not declare that the listed claims cover all writers.

Check the new PV names and handles are unused, old PVs/UIDs still match, and
there are no duplicate source/destination mappings. Record the application
owner, stop/start order, expected validation and rollback in this stack's
private record. Backups are not required for this demo/development system. Do
not run a component deploy/destroy script during rebinding:
it could reconcile or delete PVCs. Preserve the global NFS replica state file.

## C. Copy and rebind only that stack

1. Stop the selected application's writers using its recorded replica counts
   and database shutdown procedure. Suspend its CronJobs and reconcile loops;
   wait for Pods and old client mounts to release the claims. Other stacks
   remain on legacy NFS. Current NFS traffic comes from Kubernetes nodes
   mounting PVCs through the StorageClasses; check for any direct or unmanaged
   NFS mounts before copying this stack.
2. Before deleting **any** binding, set each **existing** PV's reclaim policy
   to Retain using the corresponding staged patch, then read the PV back to
   confirm:

   ```bash
   microk8s kubectl patch pv OLD_PV --type=merge \
     --patch-file=staging/stack-NAME-YYYYMMDD-HHMM/retain-OLD_PV.json
   microk8s kubectl get pv OLD_PV -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'
   ```

3. Check the destination is really mounted from its expected DRBD device on
   master2 (`findmnt -T TARGET_DIRECTORY` plus DRBD role/state). Copy directly
   from the source filesystem on slave1 to the target filesystem on master2
   with root privileges on **both** ends; root-squashed NFS client copies cannot
   reliably preserve ownership. For each reviewed mapping, on master2:

   ```bash
   # Substitute exact paths from migration-map.json. Trailing slashes matter.
   # Use an already reviewed privileged SSH identity; do not disable host checks.
   sudo rsync -aHAX --numeric-ids --dry-run --itemize-changes \
     --rsync-path='sudo -n rsync' \
     ubuntu-slave1.koeppster.lan:/EXACT_SOURCE_DIRECTORY/ /EXACT_TARGET_DIRECTORY/
   # After review, repeat without --dry-run; then repeat the dry run.
   ```

   Source/destination must refer to only this claim's directory, never an export
   root. Create the destination directory only on the verified HA filesystem.
   Writers remain stopped through the final sync. Review a checksum dry run
   (`--checksum`) and ACL/xattr/numeric ownership before rebinding. A retry after
   writes/deletions may need deletion reconciliation; review it explicitly—no
   blanket `--delete` command is generated. Never mount ext4 manually.
4. Recheck original UIDs and the stopped writer set. Delete **only the selected
   old PVCs**, wait for deletion, and leave their old Retain PVs/directories
   intact as Released rollback records. Never strip protection finalizers to
   force deletion. Create new PVs before replacement claims:

   ```bash
   microk8s kubectl delete pvc -n YOUR_NAMESPACE FIRST_CLAIM SECOND_CLAIM
   microk8s kubectl apply -f staging/stack-NAME-YYYYMMDD-HHMM/new-pvs.json
   microk8s kubectl apply -f staging/stack-NAME-YYYYMMDD-HHMM/new-pvcs.json
   microk8s kubectl get pvc -n YOUR_NAMESPACE -o wide
   ```

   Wait for the old PVC deletion to finish before the applies. Check every claim
   binds to its exact staged new PV. Stop if a controller creates an unexpected
   claim; do not start the application against it. Old PV claimRef UIDs must
   stay intact unless performing an explicit rollback.
5. Restore only this stack's saved counts, databases first, then applications.
   Verify mounts use the VIP and copied directory; new file handles require
   fresh client mounts. Check DB consistency/startup, numeric ownership, reads,
   writes, restart persistence and application behavior. Mark this mapping
   validated only after checks pass; old data becomes stale after the first
   new write. Keep the old directories protected and unwritten.
6. Run both `bin/shutdown-nfs-workloads.sh --dry-run` and
   `bin/restore-nfs-workloads.sh --dry-run` from the repository root against
   the deployed result; review the restore state file without restoring all
   stacks. Document results. Resume this stack's jobs/reconcilers only after
   verifying they use the replacement claims. Repeat B/C for the next stack.

If rebinding fails before new writes, leave writers stopped and use the saved
old PV/PVC definitions to explicitly rebind the same claim name back to the
Retain old PV (review and remove its stale claimRef UID before rebinding).
If new writes occurred, the new directory is authoritative: stop the stack,
review a reverse synchronization and database recovery first. Do not simply
rebind to stale old data. Preserve Retain on both sides during rollback.

## D. Retire legacy NFS after all consumers move

Use [final consumer cutover and legacy mount retirement](legacy-nfs-retirement.md)
for the September 27 execution-stage review and complete remaining sequence.
It covers the three StorageClasses, independent slave1 NFS service, local
mounts and boot configuration, provisioning tests, application restoration
and retained old data.

The helper accepts `legacy_service_state=preserved` before retirement and
`legacy_service_state=retired` for stop/activate after verified retirement.
The latter requires `legacy_service_preserved=false`, all five retirement gates
and a nonempty evidence note. Follow the retirement runbook's record table;
all common gates and master2-only restrictions remain required. Initial
submission still requires preserved legacy service.

This completes consumer migration, not automatic HA. Corosync still requires
both votes and Pacemaker can serve only from master2. If master2 fails,
clients remain unavailable until the operator verifies it is off and
recovers the service on master2. The scripts intentionally have no finalize,
move or clear action; enabling slave1 takeover would require a separate
isolation design and new validation.

The static PV parameter choices follow the
[NFS CSI driver's documentation](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md).
