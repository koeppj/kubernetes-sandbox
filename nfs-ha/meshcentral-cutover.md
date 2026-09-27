# MeshCentral stack cutover to the master2 NFS migration service

## Execution update — 2026-09-27

Migration is complete. The operator confirmed that MeshCentral and Keycloak
have been checked and are verified operational. Application acceptance is
complete in `staging/stack-meshcentral-20260927-1500/`; its migration map is
marked validated. The procedure below is the original cutover plan, not an
instruction to repeat the completed move. Continue with
[legacy NFS retirement](legacy-nfs-retirement.md) for the remaining work.


This plan moves only MeshCentral's `meshcentral-data` claim. It follows
[gradual migration](gradual-migration.md) after the restricted Pacemaker service
has been activated and validated as described in
[Pacemaker cutover](pacemaker-cutover.md). The service stays on master2, requires
both Corosync votes, and cannot fail over to slave1. Other stacks continue on
the legacy NFS service during this window. The following sections preserve the original pre-migration plan; see the
execution update above for the completed outcome.

## Observed stack and binding

Read-only Kubernetes inventory on 2026-09-27 found one ready
`meshcentral/meshcentral` Deployment replica on ubuntu-slave2 and one Bound,
5Gi, ReadWriteOnce `meshcentral/meshcentral-data` PVC. No Job, CronJob, or HPA
was returned in that namespace. The Deployment mounts the claim at
`/opt/meshcentral/meshcentral-data`; its `meshcentral-config` Secret is a
separate read-only mount and does not move. The public HTTPRoute and Service
remain in place, so the website will be unavailable while the replica is
stopped. Check the live inventory again at the window: another Pod or writer
may have appeared, including one outside this namespace.

| Item | Reviewed value |
| --- | --- |
| Old PV | `pvc-be03149e-7acb-4049-89d4-027710f3fa29` |
| Old PVC UID | `be03149e-7acb-4049-89d4-027710f3fa29` |
| Old NFS source | `ubuntu-slave1.koeppster.lan:/srv/kube-lv/pvc-be03149e-7acb-4049-89d4-027710f3fa29` (`192.168.1.235`) |
| New NFS target | `ubuntu-master2.koeppster.lan:/srv/ha/kube-lv/pvc-be03149e-7acb-4049-89d4-027710f3fa29` (`192.168.1.240`) |
| Candidate new PV | `ha-75129fd1c50f8f4896024394454bddaf`, static and prebound to the same claim name |

The private candidate under `nfs-ha/staging/stack-meshcentral-20260927-1243/`
contains the source/target map, prebound PV/PVC JSON, old-PV Retain patch,
and before snapshots. It is local and gitignored. Re-run the planner with a
**new** output directory just before the window; use the new map and names if
the live binding has changed:

```bash
# From the repository root on the MicroK8s control-plane host.
./nfs-ha/scripts/nfs-ha-stack-plan.py --namespace meshcentral \
  --claim meshcentral-data --vip 192.168.1.240 \
  --output nfs-ha/staging/stack-meshcentral-YYYYMMDD-HHMM
```

Review the generated source subdirectory, target, UID, claim size, access
mode, class, labels, and new PV name. Confirm the old and new PV names and CSI
handle do not already exist in another mapping. The planner accepts only the
known legacy NFS CSI layout and does not prove it has found every writer.
Keep automatic PVC provisioning/reconciliation paused for the migration
window; leave `kube-nfs` pointing at the legacy share until all stacks move.

## Window entry checks

1. Confirm the master2 service still has both votes; four connected,
   UpToDate/UpToDate DRBD replicas with master2 Primary; four HA mounts;
   six exports; and the VIP on master2 only. Confirm slave1 retains the old
   export and has no HA mount or VIP. Stop this window if that boundary has
   changed. Use the live checks in [Pacemaker cutover](pacemaker-cutover.md).
2. Inventory all MeshCentral claim consumers with `microk8s kubectl get
   pvc,pods,deployments,statefulsets,jobs,cronjobs,hpa -n meshcentral -o wide`.
   Check other namespaces, direct NFS Pod volumes, unmanaged Pods, and external
   clients for use of this exact directory. Confirm no reconciling operator
   will recreate the claim during deletion.
3. Record the live Deployment replica count (currently one), old PV/PVC
   definitions and UIDs, and the public login/device behavior to test after
   restart. Confirm MeshCentral's persisted data and numeric ownership, ACLs,
   and xattrs on the source. The live JSON config Secret and Keycloak OIDC
   provider are separate dependencies; leave the Secret mounted and verify
   OIDC during application validation.
4. On master2, check `findmnt -T` for the target path's parent and DRBD state
   before creating the claim directory. The target must be inside the
   Pacemaker-mounted `/srv/ha/kube-lv`, not the underlying root filesystem.
   Ensure enough space. Verify the source path exists on slave1 and is the
   claim directory, not the export root.
5. From the repository root, run
   `./bin/shutdown-nfs-workloads.sh --dry-run` and review its discovery of
   `deployment meshcentral/meshcentral`. Run
   `./bin/restore-nfs-workloads.sh --dry-run` if its replica state file exists.
   At plan time the shutdown dry run found MeshCentral at one replica; the
   restore dry run reported that `bin/.nfs-workload-replicas.tsv` did not
   exist. That is not a reason to run a cluster-wide shutdown for this one
   stack. Record MeshCentral's replica count separately and preserve any
   existing global state file if one appears.

## Stop, copy, and rebind

Set `STAGE` to the newly generated output directory before using the commands
below, for example `STAGE=nfs-ha/staging/stack-meshcentral-YYYYMMDD-HHMM` from
the repository root. Keep all
MeshCentral writers stopped until the new claim is Bound. Do not run the
component deploy, destroy, or config-reload scripts during rebinding: they
can reconcile the PVC or restart the Deployment.

1. Suspend any newly discovered MeshCentral CronJobs/reconcilers. Scale only
   `deployment/meshcentral` to zero and wait until its Pods terminate and its
   old NFS client mount is released. Confirm there is no other writer to the
   source directory. Save the original count for restoration.

   ```bash
   microk8s kubectl scale deployment/meshcentral -n meshcentral --replicas=0
   microk8s kubectl get pods -n meshcentral -l app=meshcentral
   ```

   Repeat the Pod check until none remain; investigate if termination stalls.

2. Apply the stage's `retain-OLD_PV.json` patch to the **existing** old PV;
   read it back and require `Retain` before deleting any PVC. Check its
   claimRef still names the observed MeshCentral PVC UID.

   ```bash
   microk8s kubectl patch pv pvc-be03149e-7acb-4049-89d4-027710f3fa29 \
     --type=merge --patch-file="$STAGE/retain-pvc-be03149e-7acb-4049-89d4-027710f3fa29.json"
   microk8s kubectl get pv pvc-be03149e-7acb-4049-89d4-027710f3fa29 \
     -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

3. Copy directly between the host filesystems with root privileges on both
   ends. Use the exact per-claim paths from the fresh `migration-map.json`.
   On master2, create the destination directory only after verifying its
   parent HA mount. First review an itemized dry run; then run the same rsync
   without `--dry-run` and repeat the dry run with `--checksum`.

   ```bash
   sudo rsync -aHAX --numeric-ids --dry-run --itemize-changes \
     --rsync-path='sudo -n rsync' \
     ubuntu-slave1.koeppster.lan:/srv/kube-lv/pvc-be03149e-7acb-4049-89d4-027710f3fa29/ \
     /srv/ha/kube-lv/pvc-be03149e-7acb-4049-89d4-027710f3fa29/
   ```

   Preserve trailing slashes and do not substitute an export root. Inspect
   checksum differences, ownership, modes, ACLs, and xattrs. If files were
   removed between attempts, review deletion reconciliation explicitly;
   never add blanket `--delete`. Do not copy through a root-squashed NFS
   client mount or mount DRBD ext4 manually.
4. Recheck the old PVC UID, its sole stopped writer, and both copy paths.
   Delete only `meshcentral/meshcentral-data` and wait for it to disappear.
   Apply the staged `new-pvs.json` before `new-pvcs.json`. Require the new
   claim to bind to the exact staged PV and inspect its CSI server/share.
   Leave the old Retain PV and old directory untouched as rollback records.

   ```bash
   microk8s kubectl delete pvc meshcentral-data -n meshcentral \
     --wait=true --timeout=180s
   microk8s kubectl apply -f "$STAGE/new-pvs.json"
   microk8s kubectl apply -f "$STAGE/new-pvcs.json"
   microk8s kubectl get pvc meshcentral-data -n meshcentral -o wide
   ```

   If a controller creates an unexpected replacement claim, stop here and
   inspect it. Do not remove PVC protection finalizers to force deletion.
5. Restore `deployment/meshcentral` to its recorded count (one in the current
   snapshot), wait for rollout, and verify the Pod has a fresh mount of the
   VIP's claim directory. Check startup logs, website/API access, Keycloak
   login, existing devices/users, and a controlled application write that
   survives a Pod restart. Confirm numeric ownership and expected files are
   intact. After the first new write, the new directory is authoritative and
   the old directory must remain unwritten.
6. Run both NFS maintenance dry runs again against the deployed result.
   Confirm the shutdown helper still discovers MeshCentral and the restore
   helper behaves consistently with its state-file status. Resume only this
   stack's paused jobs/reconcilers after confirming they use the new claim.
   Record validation in the private `migration-map.json` and window notes.

## Abort and rollback

Before the first write to the new directory, keep MeshCentral stopped and
rebind the same claim name to the retained old PV using the saved old PV/PVC
definitions. The old PV's claimRef contains the deleted claim's UID: review
and clear that stale reference before prebinding a recreated PVC, and require
the old PV to bind to the intended new PVC UID. Keep the new PV at `Retain` and
do not delete either data directory. Resume the saved replica count only
after the old endpoint and application data have been checked.

After any write on the new directory, stop MeshCentral and treat the new copy
as authoritative. Review reverse synchronization and application data
consistency before any old-endpoint rebind; simply restarting against the old
directory would lose new writes. A master2 failure or quorum loss does not
authorize a slave1 DRBD promotion: leave clients stopped and follow the
manual recovery boundary in [Pacemaker cutover](pacemaker-cutover.md).

The existing `meshcentral/manifests/meshcentral-pvc.yaml` describes a generic
`kube-nfs` claim. During gradual migration, keep it out of deploy/reconcile
operations for this claim. Before normal component deploys resume, review how
that manifest will preserve the prebound PV; after all stacks migrate, the
shared StorageClass endpoint is updated through the final legacy retirement
procedure in [gradual migration](gradual-migration.md).
