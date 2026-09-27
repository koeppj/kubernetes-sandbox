# Grafana and Loki stack cutover to the master2 NFS migration service

This plan moves the three persistent claims in the `grafana` namespace as one
stack. It follows [gradual migration](gradual-migration.md) after the
master2-only Pacemaker service has been activated and validated under
[Pacemaker cutover](pacemaker-cutover.md). The service requires both Corosync
votes and cannot fail over to slave1. Other stacks can stay on legacy NFS
during this window. This document records a plan; it has not moved claims or
data.

## Observed stack and bindings

Read-only inventory on 2026-09-27 found one Grafana Deployment replica, one
Loki StatefulSet replica, one Box event collector Deployment replica, and a
four-pod `loki-promtail` DaemonSet. No Job, CronJob, or HPA was returned in the
namespace. Grafana, Loki, and the collector each mount a distinct PVC. Promtail
has no PVC, but writes log streams to Loki and must be stopped before the Loki
snapshot. The collector writes event data to Loki and keeps its polling
position in its own claim. Review other namespaces and external clients for
additional Loki writers before the window.

| Claim | Old PV | Old PVC UID | Size / mode | Old NFS subdirectory | HA target subdirectory |
| --- | --- | --- | --- | --- | --- |
| `grafana-pv-claim` | `pvc-4bceb9de-4bc0-4927-8fba-e3309d0b733a` | `4bceb9de-4bc0-4927-8fba-e3309d0b733a` | 2Gi / RWO | `/srv/kube-grafana/pvc-4bceb9de-4bc0-4927-8fba-e3309d0b733a` | `/srv/ha/kube-grafana/pvc-4bceb9de-4bc0-4927-8fba-e3309d0b733a` |
| `loki-pv-claim` | `pvc-6ce20438-bf89-4b86-b66b-3ea6e32a6336` | `6ce20438-bf89-4b86-b66b-3ea6e32a6336` | 20Gi / RWO | `/srv/kube-lv/pvc-6ce20438-bf89-4b86-b66b-3ea6e32a6336` | `/srv/ha/kube-lv/pvc-6ce20438-bf89-4b86-b66b-3ea6e32a6336` |
| `box-collector-pv-claim` | `pvc-b06e8e97-4972-485f-8726-fda4d0f78659` | `b06e8e97-4972-485f-8726-fda4d0f78659` | 1Ki / RWO | `/srv/kube-lv/pvc-b06e8e97-4972-485f-8726-fda4d0f78659` | `/srv/ha/kube-lv/pvc-b06e8e97-4972-485f-8726-fda4d0f78659` |

The observed sources use NFS CSI at `192.168.1.235`; target server is the
reserved VIP `192.168.1.240`. All three existing PVs currently have reclaim
policy `Delete`; explicitly change and verify each as `Retain` before deleting
any PVC. Recollect all bindings at cutover time. The table is an inventory
snapshot, not authority to reuse a stale UID or path.

The private candidate stage is created immediately before the window. From
the repository root on the MicroK8s control-plane host, include all three
claims in one planner invocation:

```bash
./nfs-ha/scripts/nfs-ha-stack-plan.py --namespace grafana \
  --claim grafana-pv-claim \
  --claim loki-pv-claim \
  --claim box-collector-pv-claim \
  --vip 192.168.1.240 \
  --output nfs-ha/staging/stack-grafana-loki-YYYYMMDD-HHMM
```

Review every mapping, claim UID, requested size, access mode, storage class,
and generated PV/handle before use. The planner accepts only the known legacy
NFS CSI layout and cannot prove it found every writer. Keep `kube-nfs` and
`kube-grafana` pointing to slave1 during gradual migration. Do not run
`grafana+loki/scripts/deploy.sh` during rebinding: it reapplies all three
claim manifests, the Grafana StorageClass, both Helm releases, and the
collector Deployment. Preserve the existing `box-jwt` Secret and do not print
or copy its contents into migration records.

## Window entry checks

1. Confirm both Corosync votes; all four DRBD replicas connected and
   UpToDate/UpToDate; master2 as sole Primary; all four HA mounts; the shared
   recovery-state bind; six exports; and VIP `.240` on master2 only. Confirm
   slave1 continues serving legacy exports with no HA mount or VIP. Stop if
   this boundary differs from [Pacemaker cutover](pacemaker-cutover.md).
2. Refresh namespace and cluster-wide inventory, including DaemonSets,
   ReplicaSets, Jobs, CronJobs, direct NFS volumes and unmanaged Pods. Check
   Loki clients outside `grafana`, including any application writing directly
   to the Loki push endpoint. Pause deployments, Helm automation, and any
   reconciler that could recreate or scale these workloads or claims.
3. Record the live replicas (Grafana 1, Loki 1, collector 1, promtail 4), claim
   UIDs and PV definitions, Loki retention/query behavior, representative
   dashboards, Grafana login, and collector polling position. Check numeric
   ownership, ACLs, xattrs, capacity, and source readability. The collector
   state is a small position file; preserve it so restart does not trigger an
   unintended Box events backfill. Record the installed `loki` Helm chart
   version and effective values; use that same version for the temporary
   promtail pause and resume.
4. On master2, verify each destination's parent with `findmnt -T` and confirm
   the corresponding DRBD filesystem is mounted by Pacemaker. Verify all
   source directories on slave1. Do not create a destination on the root
   filesystem or copy a share root.
5. Run `./bin/shutdown-nfs-workloads.sh --dry-run` from the repository root
   and confirm it discovers the Grafana Deployment, Loki StatefulSet and
   collector Deployment. The helper does not report DaemonSets, so separately
   record the four promtail pods and their Helm-managed DaemonSet. Review the
   restore dry run if a global replica state file exists; do not run a
   cluster-wide shutdown or replace that file for this stack window.

## Stop, copy, and rebind

Set `STAGE=nfs-ha/staging/stack-grafana-loki-YYYYMMDD-HHMM` to the fresh
planner output directory. Keep all Loki producers and these workloads stopped
until all three replacement PVCs are Bound.

1. Stop and suspend the Box collector first so it saves its polling position
   and stops producing Loki events. Pause promtail through the existing Loki
   Helm release by upgrading the same chart version with
   `--reuse-values --set promtail.enabled=false`; verify the DaemonSet and all
   promtail Pods are gone. Stop any newly discovered external writers. Then
   scale Grafana to
   zero and wait for its Pod to terminate. Finally scale `statefulset/loki`
   to zero and wait for the Pod to terminate; its termination grace period is
   long, so allow it to flush and exit cleanly. Verify no Pod still mounts any
   of the three claims and no process is writing to Loki.

   ```bash
   microk8s kubectl -n grafana scale deployment/box-event-collector --replicas=0
   microk8s kubectl -n grafana wait --for=delete pod \
     -l app=box-event-collector --timeout=5m
   microk8s helm upgrade loki grafana/loki-stack -n grafana \
     --version "$LOKI_CHART_VERSION" --reuse-values --set promtail.enabled=false
   microk8s kubectl -n grafana scale deployment/grafana --replicas=0
   microk8s kubectl -n grafana scale statefulset/loki --replicas=0
   microk8s kubectl -n grafana get pods,pvc -o wide
   ```

   Ensure Helm automation is paused. Keep these workloads stopped until the
   claims are rebound. The Loki StatefulSet is scaled directly after the
   Helm change; do not run another Helm upgrade until its claim is rebound.
2. For each old PV, apply its staged `retain-OLD_PV.json` patch, read back
   `persistentVolumeReclaimPolicy`, and verify `claimRef` still contains the
   observed PVC UID. Require `Retain` on all three before deleting any claim.
3. Copy all three claim directories directly between host filesystems with
   root privileges on both ends. The writers remain stopped for the complete
   copy, so Loki's index/chunk data and collector cursor are consistent. On
   master2, for each exact mapping in `$STAGE/migration-map.json`, review an
   itemized dry run, execute the copy, then review a checksum dry run. Example:

   ```bash
   sudo rsync -aHAX --numeric-ids --dry-run --itemize-changes \
     --rsync-path='sudo -n rsync' \
     ubuntu-slave1.koeppster.lan:/srv/kube-lv/pvc-6ce20438-bf89-4b86-b66b-3ea6e32a6336/ \
     /srv/ha/kube-lv/pvc-6ce20438-bf89-4b86-b66b-3ea6e32a6336/
   ```

   Repeat for Grafana and collector paths, using the staged map verbatim and
   preserving trailing slashes. Inspect ownership, permissions, ACLs, xattrs,
   Loki index and chunk files, and the collector cursor. Do not copy through a
   root-squashed client mount, use blanket `--delete`, or mount DRBD ext4 by
   hand. Review any deletion reconciliation explicitly.
4. Recheck all three PVC UIDs, PV Retain policies, stopped consumers, and
   mappings. Delete only the three selected PVCs and wait for deletion; leave
   old PVs and directories untouched as rollback records. Apply staged
   `new-pvs.json` before `new-pvcs.json`. Require each claim to bind to its
   exact staged PV, with server `192.168.1.240` and the matching target path.

   ```bash
   microk8s kubectl -n grafana delete pvc grafana-pv-claim loki-pv-claim \
     box-collector-pv-claim --wait=true --timeout=5m
   microk8s kubectl apply -f "$STAGE/new-pvs.json"
   microk8s kubectl apply -f "$STAGE/new-pvcs.json"
   microk8s kubectl -n grafana get pvc -o wide
   ```

   If any controller creates an unexpected claim or any binding differs,
   stop before starting workloads. Do not strip PVC protection finalizers.
5. Restart in dependency order. First scale Loki to one and wait for its Pod
   to become Ready; confirm `/ready` and query a known recent log stream.
   Restore Grafana to one and verify login, dashboards, datasource connectivity
   and persisted settings. Resume promtail through the existing Loki Helm
   release, using the recorded chart version and values:

   ```bash
   microk8s helm upgrade loki grafana/loki-stack -n grafana \
     --version "$LOKI_CHART_VERSION" --reuse-values --set promtail.enabled=true
   ```

   Verify its four node agents are ready and new node logs arrive.
   Restore the Box collector to one last; check its saved cursor and confirm
   event polling resumes without replaying the full history. Confirm all new
   NFS mounts use `.240` and the intended claim subdirectories. Resume Helm
   automation only after verifying the configured existing claims remain
   intact.
6. Run shutdown and restore maintenance dry runs against the deployed result.
   Confirm the two Deployments and Loki StatefulSet are discovered; record the
   separate promtail DaemonSet check because the helpers cover only
   Deployments and StatefulSets. Do not restore unrelated stack counts. Mark
   these three mappings validated only after data and application checks pass.

If rebinding fails before any new writes, keep all writers stopped and
explicitly rebind the saved old PV/PVC definitions after reviewing and
clearing the stale old `claimRef` UID. Preserve `Retain` on all three PVs.
After a write to the VIP copy, the new directory is authoritative; stop the
stack and review reverse synchronization and Loki index/chunk consistency
before any return to legacy NFS. Do not attach the stale source after new
writes.

After every stack has moved, the final StorageClass and legacy NFS retirement
steps are in [gradual migration](gradual-migration.md). At that time update
the `kube-grafana` and `kube-nfs` definitions and the stack's stored
deployment configuration so they cannot point new claims back to slave1.
