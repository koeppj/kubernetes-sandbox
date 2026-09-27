# n8n stack cutover to the master2 NFS migration service

This plan moves all four `n8n` NFS claims in one stack window: the two active
volumes and the retained PostgreSQL 14 and recovery volumes. Follow
[gradual migration](gradual-migration.md) after the restricted service has
passed [Pacemaker cutover](pacemaker-cutover.md). The VIP stays on master2,
requires both Corosync votes, and cannot fail over to slave1. Other stacks
continue on the legacy NFS service. Preparing this plan does not move data,
claims, or workloads.

## Observed stack and claims

Read-only Kubernetes inventory on 2026-09-27 found one ready `n8n/n8n`
Deployment on ubuntu-slave2 and one ready `n8n/postgres-n8n-v17` StatefulSet
on ubuntu-master2. n8n mounts `n8n-pv-claim` at `/home/node/.n8n` and uses
`postgres-n8n-v17:5432`; PostgreSQL mounts its claim at
`/var/lib/postgresql/data` with `PGDATA` below it. The old
`postgres-n8n` StatefulSet is present at zero replicas. The Box MCP Deployment
has one replica and no PVC; it can remain running, but pause its external
callers if they might trigger n8n workflows. No CronJob or HPA was returned
in this namespace. The three completed PostgreSQL migration Jobs remain as
recovery evidence; their Pods refer to the n8n files or recovery claim but
are not active writers. Recheck for new Jobs, Pods, controllers, direct NFS
volumes, and external users at the window.

| Claim | Role and size | Old PV / source subdirectory | Candidate new PV |
| --- | --- | --- | --- |
| `n8n-pv-claim` | Active n8n config, files and binary data; 20Gi RWX, `kube-nfs` | `pvc-9f4c9510-98bc-4248-a901-996fb076f1a8` in `/srv/kube-lv` | `ha-481eb8385c28186a214b0e092883fce4` |
| `database-data-v17-postgres-n8n-v17-0` | Active PostgreSQL 17; 10Gi RWO, `kube-postgres` | `pvc-6e232a47-2ce4-43df-b6bc-165c7914bb4d` in `/srv/kube-postgres` | `ha-1b256f61fb5d3d82b24062a1cb97e487` |
| `database-data-postgres-n8n-0` | Retained PostgreSQL 14 rollback data; 10Gi RWO, `kube-postgres` | `pvc-1e104840-84ce-4dc6-b579-9bb5b6553d14` in `/srv/kube-postgres` | `ha-a347162b59bfb0844eba7c5efc705135` |
| `n8n-recovery-backup` | Completed migration backups; 40Gi RWX, `kube-nfs` | `pvc-0052ed24-fc1c-4499-846a-73382a4bae7c` in `/srv/kube-lv` | `ha-6282687cc2b5093bfaede13268d726b3` |

All four observed PVs already have `Retain` and point at legacy server
`192.168.1.235`. The target is the *same subdirectory* under
`/srv/ha/kube-lv` or `/srv/ha/kube-postgres` on master2, exported through
`192.168.1.240`. The private, gitignored candidate at
`nfs-ha/staging/stack-n8n-20260927-130237/` has the exact host paths, old
PVC UIDs, snapshots, Retain patches, and static prebound PV/PVC candidates.
Generate a fresh candidate before the window; use its names and paths if any
binding changed:

```bash
# From the repository root on a MicroK8s control-plane host.
./nfs-ha/scripts/nfs-ha-stack-plan.py --namespace n8n \
  --claim n8n-pv-claim \
  --claim database-data-v17-postgres-n8n-v17-0 \
  --claim database-data-postgres-n8n-0 \
  --claim n8n-recovery-backup --vip 192.168.1.240 \
  --output nfs-ha/staging/stack-n8n-YYYYMMDD-HHMM
```

Review every mapping, UID, PV handle, claim size, access mode, labels, and
source path. The planner validates the known NFS CSI layout but cannot prove
that every writer has been found. Keep provisioning and PVC reconciliation
paused for the window. Leave `kube-nfs` and `kube-postgres` pointing at slave1
until all stacks have migrated; these four claims get static prebound PVs.

## Window entry checks

1. Confirm both votes, four Connected and UpToDate/UpToDate DRBD replicas,
   master2 as the sole Primary and owner of all four HA mounts, six exports,
   NFS state bind and VIP. Confirm slave1 still serves legacy exports and has
   no HA mount or VIP. Stop if the service boundary differs from
   [Pacemaker cutover](pacemaker-cutover.md).
2. Inventory `microk8s kubectl get pvc,pods,deployments,statefulsets,jobs,cronjobs,hpa
   -n n8n -o wide`, inspect the Pod volume specs, and look for consumers of
   these four directories outside the namespace. Pause new backup/restore
   Jobs, workflow triggers and the Jenkins `n8n` main-branch deploy, which
   can replace the n8n Pod. Do not rerun the completed recovery Jobs.
3. Save the live replica counts (currently n8n 1, PostgreSQL 17 1, old
   PostgreSQL 0, Box MCP 1), four PV/PVC definitions and UIDs, completed Job
   status and logs, and a baseline of n8n workflows/credentials and endpoint
   behavior. Preserve the existing `n8n-secret` encryption key and database
   Secrets. Check source ownership, ACLs, xattrs, available space and the
   backup files' recorded SHA-256 checksums.
4. On master2, verify `findmnt -T` for each destination parent shows the
   Pacemaker-mounted HA filesystem, with the expected DRBD role. Check the
   exact source directories exist on slave1. Never create a destination on
   master2's underlying root filesystem or copy an entire export root.
5. Run `./bin/shutdown-nfs-workloads.sh --dry-run` from the repository root.
   At plan time it found n8n and PostgreSQL 17 at one replica and PostgreSQL
   14 at zero. Run `./bin/restore-nfs-workloads.sh --dry-run` if its state file
   exists; at plan time it reported no state file. Save n8n's counts
   separately. Do not run the cluster-wide shutdown for this stack window or
   overwrite an existing global replica state file.

## Stop, copy and rebind

Set `STAGE=nfs-ha/staging/stack-n8n-YYYYMMDD-HHMM` to the fresh output
directory from the repository root before using staged files below.
Keep n8n and PostgreSQL stopped until **all four** replacement claims are
Bound. Do not run `n8n/scripts/deploy-n8n.sh`, `destroy-n8n.sh`, or
`recover-postgres17.sh` during rebinding: they apply workloads, claims, or
recovery resources.

1. Stop workflow/webhook traffic and any newly found Jobs or reconcilers.
   Scale `deployment/n8n` to zero first; wait for its Pod and client mount to
   disappear. Then scale `statefulset/postgres-n8n-v17` to zero and wait for
   clean termination and mount release. Leave `postgres-n8n` at zero. Confirm
   no other Pod is using any selected claim. The public n8n route will be
   unavailable during this window.

   ```bash
   microk8s kubectl -n n8n scale deployment/n8n --replicas=0
   microk8s kubectl -n n8n rollout status deployment/n8n --timeout=5m
   microk8s kubectl -n n8n scale statefulset/postgres-n8n-v17 --replicas=0
   microk8s kubectl -n n8n rollout status statefulset/postgres-n8n-v17 --timeout=5m
   microk8s kubectl -n n8n get pods,pvc -o wide
   ```

   Verify zero live n8n/PostgreSQL Pods explicitly; a successful rollout
   command alone does not prove that an NFS mount was released. If the
   PostgreSQL shutdown was unclean, diagnose it before copying PGDATA.
2. For each old PV, apply its `retain-OLD_PV.json` patch from `$STAGE` and
   read the PV back. Require `Retain` and the same claimRef UID as the fresh
   `migration-map.json` before deleting any claim. The current Retain setting
   is useful evidence, but recheck all four at the window.
3. Copy each claim directory directly from slave1 to its matching verified
   master2 HA directory with root privileges on both ends. Use the four exact
   paths from `$STAGE/migration-map.json`, including trailing slashes. For
   each mapping, review a dry run, run the copy, then review a checksum dry
   run plus numeric ownership, permissions, ACLs and xattrs. For example,
   on master2 for the active PostgreSQL claim:

   ```bash
   sudo rsync -aHAX --numeric-ids --dry-run --itemize-changes \
     --rsync-path='sudo -n rsync' \
     ubuntu-slave1.koeppster.lan:/srv/kube-postgres/pvc-6e232a47-2ce4-43df-b6bc-165c7914bb4d/ \
     /srv/ha/kube-postgres/pvc-6e232a47-2ce4-43df-b6bc-165c7914bb4d/
   ```

   Repeat without `--dry-run`, then repeat with `--dry-run --checksum`.
   Review any deletion reconciliation explicitly; do not add blanket
   `--delete`. Do not copy through a root-squashed NFS client or mount DRBD
   ext4 by hand. Both application volumes must be copied from a stopped
   writer set so n8n files and the database represent the same outage.
4. Recheck all four old PVC UIDs, Retain policies, stopped consumers and
   paths. Delete only the four selected old PVCs. Wait until each is gone;
   leave its old PV and directory as a Released rollback record. If a
   completed Job Pod holds PVC protection, capture its logs/status and
   investigate before removing that Pod; do not strip finalizers. Apply
   `$STAGE/new-pvs.json` **before** `$STAGE/new-pvcs.json`. Require each
   replacement PVC to be Bound to its exact staged PV, with the CSI server
   `192.168.1.240` and share equal to the copied claim directory. Stop if a
   controller creates another PVC or a binding differs.

   ```bash
   microk8s kubectl -n n8n delete pvc n8n-pv-claim \
     database-data-v17-postgres-n8n-v17-0 \
     database-data-postgres-n8n-0 n8n-recovery-backup
   microk8s kubectl -n n8n wait --for=delete pvc/n8n-pv-claim \
     pvc/database-data-v17-postgres-n8n-v17-0 \
     pvc/database-data-postgres-n8n-0 pvc/n8n-recovery-backup --timeout=5m
   microk8s kubectl apply -f "$STAGE/new-pvs.json"
   microk8s kubectl apply -f "$STAGE/new-pvcs.json"
   microk8s kubectl -n n8n get pvc -o wide
   ```

5. Restore `postgres-n8n-v17` to its saved count first and require a ready
   Pod, PostgreSQL probe success, and the expected database/schema and
   workflow/credential counts. Keep `postgres-n8n` at zero. Then restore
   `deployment/n8n` to its saved count and require readiness, an unlocked
   credential using the preserved encryption key, workflow and webhook
   behavior, files/binary data, and restart persistence. Check both fresh
   client mounts use the VIP and intended subdirectories. Box MCP has no
   claim to rebind; verify its integration if a workflow uses it. Resume
   triggers and Jenkins deploys only after the new data path is verified.
6. Verify the copied recovery files against their recorded checksums without
   launching restore, and keep the old PostgreSQL 14 claim offline. Run both
   `./bin/shutdown-nfs-workloads.sh --dry-run` and
   `./bin/restore-nfs-workloads.sh --dry-run` against the deployed result;
   the latter needs a pre-existing state file and should not restore other
   stacks. Record the four validated mappings and the maintenance discovery.

If rebinding fails before new writes, keep writers stopped and explicitly
rebind the saved old PV/PVC definitions. The old PV claimRef contains the
deleted PVC UID: review and remove that stale reference before prebinding
the recreated claim, then verify its new UID and binding. Keep both sides at
`Retain`. After a new write, the VIP copy is authoritative. Stop the stack
and review reverse synchronization and PostgreSQL recovery before any return
to the legacy endpoint; never attach stale PGDATA or n8n files.

The normal n8n deploy script reapplies the `n8n-pv-claim` manifest, and the
StatefulSet keeps its `kube-postgres` volumeClaimTemplate. Before resuming
normal deploy/reconcile operations, verify that these definitions preserve
the prebound replacement claims. Update their storage definitions only in
the final StorageClass retirement step of [gradual migration](gradual-migration.md).
