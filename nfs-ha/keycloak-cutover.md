# Keycloak stack cutover to the master2 NFS migration service

## Execution update — 2026-09-27

Migration is complete. The operator confirmed that MeshCentral and Keycloak
have been checked and are verified operational. Application acceptance is
complete in `staging/stack-keycloak-20260927-1605/`; its migration map is
marked validated. The procedure below is the original cutover plan, not an
instruction to repeat the completed move. Continue with
[legacy NFS retirement](legacy-nfs-retirement.md) for the remaining work.


Move the two `keycloak` claims together in one stack window, following
[gradual migration](gradual-migration.md) after the restricted service passes
[Pacemaker cutover](pacemaker-cutover.md). The VIP stays on master2, requires
both Corosync votes, and cannot fail over to slave1. Other stacks continue on
legacy NFS. The following sections preserve the original pre-migration plan; see the
execution update above for the completed outcome.

## Observed stack and claims

Read-only Kubernetes inventory on 2026-09-27 found one ready `keycloak`
Deployment Pod on ubuntu-slave2 and one ready `postgres-keycloak` StatefulSet
Pod on ubuntu-master2. The Deployment mounts `keycloak-data` at
`/opt/keycloak/data` and connects to `postgres-keycloak:5432`. PostgreSQL 18
mounts its claim at `/var/lib/postgresql/data`, which is also its `PGDATA`.
There were no Jobs, CronJobs, or HPAs in the namespace. No other Pod in the
cluster mounted these two claims in the observed snapshot. Recheck for new
writers, direct NFS mounts, unmanaged Pods, and external clients at the window.

| Claim | Old PV and PVC UID | Size / class | Source directory on slave1 | Target directory on master2 | Candidate new PV |
| --- | --- | --- | --- | --- | --- |
| `keycloak-data` | `pvc-a914897f-e662-4fe6-bf9c-36e11aa056ed` / `a914897f-e662-4fe6-bf9c-36e11aa056ed` | 5Gi RWO, `kube-nfs` | `/srv/kube-lv/pvc-a914897f-e662-4fe6-bf9c-36e11aa056ed` | `/srv/ha/kube-lv/pvc-a914897f-e662-4fe6-bf9c-36e11aa056ed` | `ha-726c900ae61c6ee8465005c7d83dc26f` |
| `database-data-postgres-keycloak-0` | `pvc-2b732ec0-3589-4152-9e93-bc6b80149424` / `2b732ec0-3589-4152-9e93-bc6b80149424` | 10Gi RWO, `kube-postgres` | `/srv/kube-postgres/pvc-2b732ec0-3589-4152-9e93-bc6b80149424` | `/srv/ha/kube-postgres/pvc-2b732ec0-3589-4152-9e93-bc6b80149424` | `ha-9789a591a524d6b3d77391092f1d9c97` |

Both old PVs use `Delete` and server `192.168.1.235`. The proposed static,
prebound PVs use `Retain`, server `192.168.1.240`, and the individual copied
claim directories. The private, gitignored candidate at
`nfs-ha/staging/stack-keycloak-20260927-140911/` contains the exact mappings,
old-PV Retain patches, before snapshots, and replacement PV/PVC JSON. Generate
a **fresh** candidate on a MicroK8s control-plane host immediately before the
window; use its values if any binding has changed:

```bash
# From the repository root.
./nfs-ha/scripts/nfs-ha-stack-plan.py --namespace keycloak \
  --claim keycloak-data --claim database-data-postgres-keycloak-0 \
  --vip 192.168.1.240 \
  --output nfs-ha/staging/stack-keycloak-YYYYMMDD-HHMM
```

Review each UID, source/target path, claim size, access mode, labels, PV name,
and CSI handle. The planner verifies the expected NFS CSI layout but cannot
prove it found every writer. Keep automatic PVC provisioning and reconciliation
paused for the window. Leave the shared `kube-nfs` and `kube-postgres` classes
on the legacy server until all stacks have moved.

## Window entry checks

1. Confirm both votes, all four DRBD replicas Connected and
   UpToDate/UpToDate, and master2 as sole owner of the four HA mounts, shared
   NFS state, six exports, and VIP. Confirm slave1 retains its legacy exports,
   has four DRBD Secondaries, and has no HA mount or VIP. Stop if this differs
   from [Pacemaker cutover](pacemaker-cutover.md).
2. Inventory `microk8s kubectl get pvc,pods,deployments,statefulsets,jobs,cronjobs,hpa
   -n keycloak -o wide` and inspect actual Pod volume specs. Check other
   namespaces and external clients for these exact source directories. Pause
   any job, GitOps loop, operator, or deploy automation that might recreate a
   Pod or claim. Record the two live replica counts (both one in the snapshot),
   old PV/PVC definitions and UIDs, and a baseline of realm/client/user login
   and token behavior. Preserve the database and Keycloak Secrets.
3. On master2, verify `findmnt -T` for each target **parent** resolves to its
   Pacemaker-mounted HA filesystem, with master2 Primary. Check available
   space and the exact source directories on slave1. Create destination claim
   directories only on verified HA mounts, never on the underlying root disk.
   Check numeric ownership, modes, ACLs, and xattrs. The old `keycloak-data`
   PV requested mount permissions `0777`; the new static PV uses
   `mountPermissions=0` to preserve copied permissions. Confirm the Keycloak
   container can write to its copied directory before restoring traffic.
4. Run `./bin/shutdown-nfs-workloads.sh --dry-run` from the repository root.
   It found both Keycloak workloads at one replica on 2026-09-27. Run
   `./bin/restore-nfs-workloads.sh --dry-run` if its state file exists; none
   existed at plan time. Save this stack's counts separately. Do not run the
   cluster-wide shutdown for this one-stack window or overwrite its state file.

## Stop, copy, and rebind

Set `STAGE=nfs-ha/staging/stack-keycloak-YYYYMMDD-HHMM` to the fresh planner
output from the repository root. Keep both workloads stopped until **both**
replacement claims are Bound. Do not run `keyclock/scripts/deploy.sh` or
`keyclock/scripts/destroy.sh` during rebinding: they apply or delete claims
and workloads. Keep the StatefulSet object in place; its claim template has
`whenDeleted: Delete`, so deleting the StatefulSet could remove its PVC.

1. Quiesce login/token traffic and dependent callers. Scale the Keycloak
   Deployment to zero first, wait for its Pod and old NFS mount to disappear,
   then scale PostgreSQL to zero and wait for a clean shutdown and mount
   release. Do not copy a database after an unclean stop without diagnosis.
   The public `idp.johnkoepp.com` route remains but is unavailable in this
   window. Confirm no other writer uses either claim.

   ```bash
   microk8s kubectl -n keycloak scale deployment/keycloak --replicas=0
   microk8s kubectl -n keycloak rollout status deployment/keycloak --timeout=5m
   microk8s kubectl -n keycloak scale statefulset/postgres-keycloak --replicas=0
   microk8s kubectl -n keycloak rollout status statefulset/postgres-keycloak --timeout=5m
   microk8s kubectl -n keycloak get pods,pvc -o wide
   ```

   Explicitly verify both Pods are gone; rollout completion alone does not
   prove the client mounts have been released.
2. Apply each `$STAGE/retain-OLD_PV.json` patch to its **existing** old PV.
   Read both PVs back and require `Retain` plus the same claimRef UIDs as the
   fresh `migration-map.json` before deleting either claim. The initial
   `Delete` policy would otherwise put the legacy data at risk.
3. Copy each claim directory directly from slave1's filesystem to its exact
   master2 HA directory with root privileges on both ends. For each mapping,
   run an itemized dry run, the copy, then a checksum dry run and ownership,
   ACL, and xattr checks. For example, on master2 for PostgreSQL:

   ```bash
   sudo rsync -aHAX --numeric-ids --dry-run --itemize-changes \
     --rsync-path='sudo -n rsync' \
     ubuntu-slave1.koeppster.lan:/srv/kube-postgres/pvc-2b732ec0-3589-4152-9e93-bc6b80149424/ \
     /srv/ha/kube-postgres/pvc-2b732ec0-3589-4152-9e93-bc6b80149424/
   ```

   Use the fresh map for the actual paths and repeat without `--dry-run` only
   after review. Preserve the trailing slashes. Never copy an export root or
   copy through a root-squashed NFS mount. Review deletions explicitly rather
   than adding blanket `--delete`; keep writers stopped through final sync.
4. Recheck both old PVC UIDs, Retain policies, stopped consumers, and copy
   results. Delete **only** the two selected PVCs and wait until both are
   gone. Apply staged `new-pvs.json` before `new-pvcs.json`. Require each
   replacement claim to bind to its exact staged PV, with the VIP and copied
   claim directory in its CSI attributes. Preserve the old Released PVs and
   their directories as rollback records. Do not strip PVC protection
   finalizers or proceed if a controller creates an unexpected claim.

   ```bash
   microk8s kubectl -n keycloak delete pvc keycloak-data \
     database-data-postgres-keycloak-0 --wait=true --timeout=5m
   microk8s kubectl apply -f "$STAGE/new-pvs.json"
   microk8s kubectl apply -f "$STAGE/new-pvcs.json"
   microk8s kubectl -n keycloak get pvc -o wide
   ```

5. Restore `statefulset/postgres-keycloak` to its saved count first. Require
   a ready Pod, clean PostgreSQL logs, and a successful database connection;
   then restore `deployment/keycloak`. Confirm both Pods remount through
   `.240` and their intended subdirectories. Check Keycloak readiness, realm
   and user data, browser login, token issuance, and a dependent OIDC login
   such as MeshCentral. Test a controlled persistent change and a Pod restart.
   Once either new directory receives a write, that copy is authoritative;
   keep the old directory unwritten.
6. Run both NFS maintenance dry runs against the deployed result and confirm
   they discover the Deployment and StatefulSet. Review the restore state file
   if one exists without restoring unrelated stacks. Resume paused callers
   and reconcilers only after verifying the replacement bindings. Record
   application validation in the private map and window notes.

## Abort and rollback

Before the first new write, leave both workloads stopped and rebind the same
claim names to the saved old Retain PVs using the saved definitions. Each old
PV retains the deleted PVC's UID in `claimRef`: review and remove that stale
reference before prebinding a recreated claim, then verify the intended new
PVC UID and binding. Keep both new PVs at `Retain` and preserve both copies.
Restore PostgreSQL before Keycloak after verifying the legacy service.

After any new write, stop both workloads and treat the new copy as
authoritative. Review reverse synchronization and PostgreSQL recovery before
any old-endpoint rebind; restarting against stale old data could lose realm or
login changes. A master2 failure or quorum loss does not authorize slave1
DRBD promotion. Follow the manual recovery boundary in
[Pacemaker cutover](pacemaker-cutover.md).

The Keycloak deploy script reapplies the generic `keycloak-data` PVC, while
the PostgreSQL StatefulSet retains its `kube-postgres` claim template. Review
that these definitions preserve the prebound replacements before resuming
normal deploy automation. The destroy script explicitly deletes both claims
and must remain out of this workflow. Update the shared StorageClasses and
repository definitions during the final legacy retirement step in
[gradual migration](gradual-migration.md).
