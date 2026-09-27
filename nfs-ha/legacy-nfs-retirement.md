# Final consumer cutover and legacy NFS mount retirement

Prepared 2026-09-27. **Retirement completed on 2026-09-27.** The operator
manually tested all applications after restoration and confirmed expected
operation. See
[the execution status](status-2026-09-27.md) and private
`staging/retirement-20260927-220750/` evidence. This
is the next runbook after [gradual migration](gradual-migration.md). It
supersedes that guide's abbreviated section D. The operator reports that
all existing stack PVCs have migrated; the private stage records below
substantiate the bindings and identify remaining evidence to close out.
No new data copy or PVC rebind is planned.

“Full cutover” here completes use of `192.168.1.240` for existing claims
and future provisioning, then retires the independent `.235` NFS service
and its three old local mounts. The supported service remains master2-only:
both votes required, five permanent slave1 restrictions retained, no
switchover or automatic failover. `NFS_HA_PHASE` remains `migration`.
Automatic two-host HA needs a separate isolation/fencing design, replacement
validation and tooling; removing the bans or setting one-vote quorum is
not a step in this plan.

## Evidence reviewed and closeout

Paths below are private, gitignored directories under `nfs-ha/staging/`.
Use the execution stages, not the earlier planner-only candidates. This
review reads saved evidence; collect fresh live evidence at execution.

| Stack | Execution stage | Claims | Recorded outcome / remaining evidence |
| --- | --- | ---: | --- |
| MeshCentral | `stack-meshcentral-20260927-1500/` | 1 | Map and `window-notes.txt` record checksum/metadata checks, VIP binding, restart persistence and HTTP 200. Operator confirmed application operation on 2026-09-27; application acceptance is complete and the map is now `validated=true`. |
| n8n | `stack-n8n-20260927-1344/` | 4 | All map entries have `validated=true`, including the old database and recovery claims. No separate application validation report in this stage; preserve the inactive database's zero replica count. |
| Grafana/Loki | `stack-grafana-loki-20260927-1417/` | 3 | All map entries validated; `validation.json` records checksums, Grafana SQLite integrity/login, Loki readiness/query, collector cursor and four ready promtail agents. |
| Keycloak | `stack-keycloak-20260927-1605/` | 2 | `window-notes.md` and bound-PV snapshot record both new bindings, metadata/checksums, PostgreSQL readiness and OIDC discovery. Operator confirmed application operation on 2026-09-27; application acceptance is complete and both map entries are now `validated=true`. Refresh maintenance and restart/persistence evidence in the retirement window. |

These ten claims include retained, currently unused claims; idle is not an
exemption from endpoint migration. On 2026-09-27 the operator confirmed that
both MeshCentral and Keycloak have been checked and are verified operational.
Their execution-stage maps and notes now record that acceptance; all ten map
entries are validated. This is operator confirmation, not a new automated test
run or evidence that every previously proposed individual test was executed.
Retain the fresh infrastructure, maintenance and post-retirement application
checks below. No repeat data migration or PVC rebinding is needed.

New directories are authoritative after new writes. The MeshCentral and
Keycloak execution records reflect this; some other maps still contain the
initial `old until first new write` placeholder. Do not interpret that
placeholder as authority to restore stale data. Old copies must remain unwritten.

The earlier `post-activation-20260927-0058/` evidence records the active
master2 service and slave1's old mounts. September 26 readiness documents
and planner-only stack documents are historical, not current execution state.
The unrelated `/srv/nfs-lv` retirement is already recorded in
[retire-legacy-nfs-lv.md](retire-legacy-nfs-lv.md); its pending disk/LV removal
is not part of this window.

## 1. Prepare a reviewable window

From the repository root on the control-plane host, choose a new private
window directory. Keep all evidence and any configuration copies private;
application backups are not required for this demo/development system.

```bash
umask 077
WINDOW="nfs-ha/staging/retirement-$(date -u +%Y%m%d-%H%M%S)"
mkdir -m 700 "$WINDOW"
./nfs-ha/scripts/nfs-ha-collect.sh "$WINDOW/preflight"
microk8s kubectl get pv -o json > "$WINDOW/pvs-before.json"
microk8s kubectl get pvc -A -o json > "$WINDOW/pvcs-before.json"
microk8s kubectl get storageclass -o json > "$WINDOW/storageclasses-before.json"
./bin/shutdown-nfs-workloads.sh --dry-run
./bin/restore-nfs-workloads.sh --dry-run
```

A missing restore-state file is expected before a first global shutdown;
record that result, not a successful restore test. If a state file exists,
review its outstanding maintenance window before proceeding. Never overwrite
it with counts from already stopped workloads.

Join every live PVC to its PV and the ten stage mappings. Require exact
new PV names, claim UIDs, `.240` server and `/srv/ha/` claim directory,
`Bound`, and `Retain`. Inventory any extra claims created since the stages.
Classify every old-endpoint PV: expected old claims are `Released`/`Retain`
with their original claimRef UIDs; an old Bound or Available PV must be
resolved before retirement. Do not delete old PV records or strip finalizers.

Inventory all namespaces' Pods and Deployment, StatefulSet, DaemonSet, Job,
CronJob, HPA and operator templates, including direct `nfs` volumes and
inline CSI volumes. Include external clients, host fstab/automounts, scheduled
backup/restore jobs and pending PVCs. Check aliases for slave1 as well as
`.235`. Completed n8n migration Jobs must not be rerun against old paths.
Repository-only consumers such as Box, Jenkins and test manifests must
provision through the updated classes if deployed later.

Inspect actual kubelet/CSI mounts on nodes hosting consumers, including
ubuntu-slave2 (the stack execution records place Pods there). Earlier
assertions that a node was not a client are superseded where newer evidence
shows mounts. Preserve the prior operator acceptance that independent mount
verification on ubuntu-mini and ubuntu-slave1 is not required unless new
consumer evidence changes that scope. TCP connections alone neither prove
nor disprove a filesystem mount. Record the reviewed client set.

Require both Corosync votes; healthy links; all four DRBD resources Connected,
UpToDate/UpToDate; master2 as sole Primary and owner of the four HA mounts,
state bind, six exports and VIP. Slave1 remains Secondary with no HA mount
or VIP. Keep both Corosync/Pacemaker members running throughout retirement.
A slave1 reboot would also interrupt the master2 service under two-vote quorum.

## 2. Prepare StorageClass endpoint updates and lifecycle support

Keep the existing class names for all current and future claims. The
persistent, non-secret [storage-class mapping](storage-class-mapping.json)
records endpoint/share changes, not a class rename. Keep it in version control
outside private staging and record the revision/hash used in the window.
Its initial status is `planned_not_applied`. No duplicate classes are needed.

| StorageClass (unchanged) | Server | New share | Source manifest |
| --- | --- | --- | --- |
| `kube-nfs` | `192.168.1.240` | `/srv/ha/kube-lv` | `infrastruture/create-storage-class.yaml` |
| `kube-postgres` | `192.168.1.240` | `/srv/ha/kube-postgres` | `infrastruture/postgres-storage-class.yaml` |
| `kube-grafana` | `192.168.1.240` | `/srv/ha/kube-grafana` | `grafana+loki/manifests/grafana-storage-class.yaml` |

Prepare three reviewed StorageClass manifests in the private window. Preserve
`nfs.csi.k8s.io`, `Delete`, `Immediate`, `hard`, `nfsvers=4.1` and other reviewed
live settings/annotations, including `kube-nfs`'s `mountPermissions: "0777"`.
Preserve intentional default-class behavior. Existing migrated static PVs/PVCs
keep their class names, bindings, `Retain` and `mountPermissions=0`.

Update the three source manifests' shares and set `nfs_server_ip=192.168.1.240`
in the root `.env` used by the infrastructure script and `grafana+loki/.env`
on their deployment hosts. Preserve placeholders in sample files. Missing
local environment files must be verified on the hosts that own them; do not
copy their secrets into this repository. Render only these parameterized
StorageClass manifests with `envsubst '${nfs_server_ip}'` for review.

Keep PVC manifests, StatefulSet claim-template class names, `MESH_STORAGE_CLASS`
and `JENKINS_STORAGE_CLASS` unchanged. There is no deferred class-renaming task.
Before resuming deployment reconciliation, verify endpoint sources cannot
restore `.235` and deployment scripts preserve existing prebound claims.
That binding check remains necessary even with unchanged class names. Do not
run the full infrastructure installer or stack deploy/destroy scripts just to
replace classes. Do not globally replace `.235`; it remains slave1's
Corosync/DRBD address. The mapping tracks endpoint verification on deployment
hosts without treating consumer class-name settings as pending updates.

**Maintenance record lifecycle.** The cutover helper supports two legacy
service states without changing `NFS_HA_PHASE=migration` or the cluster CIB:

| Record field | Before retirement / initial stop | After verified retirement / activation and later stops |
| --- | --- | --- |
| `legacy_service_state` | `preserved` | `retired` |
| `legacy_service_preserved` | `true` | `false` |
| `legacy_consumers_absent` | `false` (retirement gate not yet asserted) | `true`: no active or scheduled legacy consumers |
| `legacy_exports_absent` | `false` | `true`: old exports absent from config and live tables |
| `legacy_service_disabled` | `false` | `true`: slave1's independent server stopped, no threads/listener, boot startup disabled |
| `legacy_mounts_absent` | `false` | `true`: all three legacy local mounts absent |
| `legacy_boot_mounts_removed` | `false` | `true`: legacy fstab, mount/automount and startup entries retired |
| `legacy_retirement_evidence` | empty string | Nonempty note identifying reviewed evidence, host, paths and results |

Use `templates/maintenance-record.sample.json` for both states. Keep every
common gate true only after review. For the first stop, attest preservation;
after steps 5–6, create a fresh retired-state record for the new restart stage,
using its own candidate hash and review time within four hours. Include the
private window evidence paths and actual findings in `legacy_retirement_evidence`.
The helper validates the record's assertions; it does not independently query
slave1 to prove retirement. The host checks in steps 5–6 remain required.

Retired records are accepted only for `stop` and `activate`, never `submit`.
Missing/false retirement gates, empty evidence and contradictory preservation
assertions are rejected. Existing records without `legacy_service_state`
default to `preserved` and still require `legacy_service_preserved=true`.
All existing quorum, master2-only restrictions, stopped-writer, hash and freshness
checks remain in force. Do not mark retirement before it has actually completed.

For the effect on routine deploy, Helm upgrade, scaling, reload and destroy
operations, read [existing stack maintenance](existing-stack-storage-maintenance.md).
Keeping the three classes preserves provisioning/discovery; each deployment
path must also preserve its existing prebound claims.

## 3. Quiesce writers and stop the managed service

Reserve a shared application outage. Freeze deploy/Helm/GitOps/operator
reconciliation and new PVC requests. Suspend relevant CronJobs; drain Jobs
and external writers. Stop Loki producers, including the Box collector and
promtail (save Helm chart/version/values and restore through its existing Helm
workflow). The maintenance helpers do not stop DaemonSets, Jobs or direct NFS
clients. Quiesce login/token and n8n traffic before database shutdown.

Run the normal shutdown helper once from the repository root:

```bash
./bin/shutdown-nfs-workloads.sh
./bin/restore-nfs-workloads.sh --dry-run
```

Review and preserve `bin/.nfs-workload-replicas.tsv`; use the same explicit
`--state-file` on both helpers if a reviewed alternate is needed. Wait for all
writers/Pods to terminate and kubelet/CSI mounts to release, including retained
claim consumers. Diagnose busy mounts; do not use forced or lazy unmounts.
The helper stops Deployments before StatefulSets; preserve zero counts,
particularly `n8n/postgres-n8n`.

On master2, use the current reviewed migration stage and a fresh maintenance
record to preview then execute `nfs-ha-cutover.py stop` as described in
[Pacemaker cutover](pacemaker-cutover.md). Record the exact stage path, current
candidate SHA-256 and review time within four hours; do not assume a September
26 record remains valid. Allow the full 30-minute group timeout (six serial
export stops previously took about ten minutes with a 90-second lease), plus
clone stop time. Require actual absence of VIP, HA exports, mounts and state
bind, and stopped clones on both hosts. A target-role alone is insufficient.
If stop fails, keep writers stopped and diagnose; do not continue retirement.

## 4. Switch future provisioning

While requests/reconcilers are paused and no Pending request can race this
change, replace the three StorageClass objects under their **existing names**
using the reviewed private manifests. Server/share parameters cannot be
changed by an in-place apply: delete and recreate only each StorageClass
object, one at a time, then verify its target and preserved settings against
the mapping. Do not delete PVs/PVCs, rename classes or force-replace claims.
Save old definitions for comparison. Restore all three class objects before
running maintenance discovery.

No class may still provision against `.235` when its exports are retired.
Keep provisioning frozen until the endpoint is active and step 7 passes.
Both existing templates and new installations continue using `kube-nfs`,
`kube-postgres` and `kube-grafana`. Do not restore legacy endpoint definitions
as an application rollback. Record actual class-replacement and source/
deployment-host endpoint verification in the window and mapping.

## 5. Retire slave1's exports and independent server

Run host operations on **ubuntu-slave1 only**, after verifying its hostname.
Review `/etc/exports`, `/etc/exports.d/*.exports`, `exportfs -v` and
`/var/lib/nfs/etab` together. Remove just the entries for `/srv/kube-lv`,
`/srv/kube-grafana` and `/srv/kube-postgres`, for every configured client.
Unexpected exports or consumers block server shutdown until accounted for.

```bash
sudo exportfs -ra
sudo exportfs -v
sudo systemctl disable --now nfs-server.service
```

Verify no legacy export in the live table/etab, no running nfsd threads and
no NFS listener. Inspect the installed `nfs-kernel-server` alias and any
custom startup units/cron hooks to ensure independent NFS cannot restart at
boot. Preserve slave1's local `/var/lib/nfs` recovery data. Stop residual NFS
server helpers only after checking their dependencies; do not disable NFS
client machinery, DRBD, Corosync or Pacemaker. Do not mask units required by
the reviewed server wrapper. Master2's NFS units remain Pacemaker-managed
and disabled for standalone boot.

## 6. Retire the three old local mounts

Distinguish slave1's local ext4 source mounts from the new exported DRBD
mounts. The saved service inventory records these exact legacy devices;
verify live device/UUID identities before editing anything:

| Mount on slave1 | Recorded legacy source | Must remain intact |
| --- | --- | --- |
| `/srv/kube-lv` | `/dev/mapper/kube--vg-kube--lv` | `kube-vg/drbd-kube` |
| `/srv/kube-grafana` | `/dev/mapper/kube--vg-kube--grafana` | `kube-vg/drbd-grafana` |
| `/srv/kube-postgres` | `/dev/mapper/kube--vg-kube--postgres` | `kube-vg/drbd-postgres` |

Also retain `kube-vg/drbd-nfs-state`. The legacy and DRBD LVs share `kube-vg`;
**do not deactivate/remove that VG or its physical disk.**

Inspect `findmnt`, `lsblk -f`, LVM UUIDs, `/etc/fstab`, native `.mount` and
`.automount` units, bind mounts and local processes referencing each path.
Remove/comment only the three verified legacy fstab entries, including any
associated automount/custom startup configuration. Run `systemctl daemon-reload`
and unmount each exact legacy path normally once no local process or nested
mount uses it. If a mount is busy or I/O blocks, stop and investigate.

Require all three paths absent from `findmnt`, no boot/automount path that
can remount them, and no exports referencing them. Retain the unmounted LVs,
old PV objects, directory contents and stage mappings as recovery evidence.
Do not recursively remove directories, run `lvremove`/`vgremove`/`pvremove`,
format a filesystem or reuse those LVs. Data deletion and the suspect
`nfs-vg` disk's disposition are separate reviewed operations.

## 7. Reactivate, prove provisioning, restore applications

On master2, with both votes and the legacy retirement checks complete,
use a fresh stopped live CIB, not an old rendered configuration:

```bash
# From the repository root; WINDOW is this window's private directory.
sudo cibadmin --query > "$WINDOW/stopped-live.xml"
./nfs-ha/scripts/nfs-ha-stage-finalize.py --restart \
  "$WINDOW/stopped-live.xml" "$WINDOW/restart"
sha256sum "$WINDOW/restart/cib-stopped.xml"
./nfs-ha/scripts/nfs-ha-cutover.py activate --stage "$WINDOW/restart"
```

Review the generated simulations/ordering and fill the retired-state maintenance
record with actual retirement evidence, fresh time and candidate hash. Execute
activate with `sudo`, `--record` and `--execute` only after that review. Do not
submit resources again or push `simulation-start.xml`. If agents have taken
DRBD down, reconcile readiness with the reviewed stopped-resource recovery
procedure before activation; never force promotion or manually mount ext4.

Require four Connected/UpToDate replicas, sole master2 Primary ownership,
four mounts, shared recovery-state bind, six correct exports and VIP; slave1
has four Secondaries, no HA mounts/state bind/VIP and no independent exports.
Use a disposable NFSv4.1 client to verify IDs, root squash, read/write/fsync,
locking and restart persistence. Retain the previously completed partition
and quorum-loss evidence; repeat controlled outage tests if cluster safety
configuration changed, with production writers still stopped.

Create a disposable dynamically provisioned PVC and consumer Pod for **each
of the three classes**. Require the generated PV server `.240`, correct `/srv/ha/` root and
unique subdirectory, then verify write/read/fsync and persistence after Pod
recreation with representative numeric identities. Inspect controller errors
for mkdir/chmod failures under root squash; do not relax export security to
make the test pass. Remove only test Pods/PVCs; verify expected `Delete`
cleanup of their PVs/subdirectories without touching production mappings.
NFS CSI dynamically creates subdirectories and its `mountPermissions` setting
can perform chmod; see the [driver parameters](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md).
Class reclaim policy applies to newly provisioned volumes; see
[Kubernetes StorageClasses](https://kubernetes.io/docs/concepts/storage/storage-classes/).

With all three classes present, run both maintenance dry runs against the
deployed definitions. Review saved counts, then run the normal restore helper:

```bash
./bin/shutdown-nfs-workloads.sh --dry-run
./bin/restore-nfs-workloads.sh --dry-run
./bin/restore-nfs-workloads.sh
./bin/shutdown-nfs-workloads.sh --dry-run
```

The restore helper waits for StatefulSets before starting Deployments, but
does not enforce readiness ordering among application Deployments. Keep
external traffic and independent log producers paused until their services
are ready. Check PostgreSQL before Keycloak/n8n, Loki before promtail and
collector ingestion, and Keycloak before MeshCentral OIDC acceptance. Resume
promtail via its saved Helm configuration and other paused jobs/reconcilers
only after checking their claims. The helper removes its state file only on
success; preserve a private copy in the window before restoration. Afterwards,
a restore dry run's missing-state result is expected and should be recorded.

Repeat the stack acceptance checks from the evidence table, including
retained n8n claims, fresh node mounts, application login/token behavior and
persistence. Confirm the same ten claim/PV mappings and no new use of `.235`.

## Abort, recovery and completion

Any unexpected old consumer, incomplete stop, wrong mount/device, failed
provisioning or data check blocks the next step. Keep affected writers and
reconciliation stopped; retain the replica state and diagnose. A failed
reactivation is not permission to promote slave1 or remove placement bans.

If only legacy retirement fails, leave its disks/data untouched and finish
no destructive cleanup; return to the reviewed master2 restart path when
healthy. Re-enabling old exports does not make their stale data authoritative.
After any new write, returning a claim to an old copy requires a separate
stopped-writer reverse synchronization and database recovery review. Never
blindly apply saved old PVC/PV manifests or copy stale source data over HA data.

Complete the window record with timestamps, resolved stack checks, before/after
PV and class inventory, old mount UUIDs and disabled boot entries, service
and two-host DRBD/Pacemaker evidence, three provisioning tests, maintenance
results and restored counts. Record any deliberate exceptions with an owner.
Cutover completion requires that all current/allowed future consumers use `.240`, no old export or
mount can return at boot, applications pass acceptance and both maintenance
helpers still discover the workloads. Update the README and status documents
with actual execution results. Keep unreviewed deployment reconciliation paused
until deployment-host NFS endpoint values and rendered sources are verified. Keep retained legacy data protected until a
separate deletion decision. The two-vote master2-only availability boundary
continues after retirement.
