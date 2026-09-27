# Existing stack maintenance with retained StorageClass names

Reviewed 2026-09-27 against this checkout's deployment scripts and private
migration stages. This explains the unchanged StorageClass names in
[legacy NFS retirement](legacy-nfs-retirement.md). The class endpoint changes
were applied in the retirement window; the NFS-server environment values and
matching sources on ubuntu-mini were verified afterwards. There is no
class-renaming task.

## What stays the same, and where the data lives

“Existing bindings retain compatible old class names” means each migrated
PVC and its bound PV keep the same `spec.storageClassName`, such as
`kube-nfs`. They also retain their claim name, PV identity and binding.
The migrated PV already specifies the new NFS VIP and exact copied directory.
Its class name does not redirect each mount through the class's current
server/share parameters.

For example, the executed MeshCentral stage records:

| Object / field | Value |
| --- | --- |
| Pod's claim reference | `meshcentral/meshcentral-data` |
| PVC `spec.storageClassName` | `kube-nfs` |
| PVC `spec.volumeName` | `ha-75129fd1c50f8f4896024394454bddaf` |
| Bound PV `spec.storageClassName` | `kube-nfs` |
| Bound PV CSI server | `192.168.1.240` |
| Bound PV CSI share | `/srv/ha/kube-lv/pvc-be03149e-7acb-4049-89d4-027710f3fa29` |
| Bound PV reclaim policy | `Retain` |

The application continues using this copied directory on restart. Renaming
or replacing a StorageClass does not copy data, update this PV's server,
change its reclaim policy, or rename the claim. Kubernetes documents binding
and reclaim behavior in its [Persistent Volumes guide](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

The retirement plan retains three StorageClass objects:

| StorageClass for existing and new claims | Live provisioning endpoint |
| --- | --- |
| `kube-nfs` | `.240:/srv/ha/kube-lv` |
| `kube-postgres` | `.240:/srv/ha/kube-postgres` |
| `kube-grafana` | `.240:/srv/ha/kube-grafana` |

Their server/share parameters are updated by replacing only the class objects
under the same names during the retirement window. No additional classes or
consumer class-name changes are needed. A new dynamic claim receives a new
directory; using the same class or the same claim name after deletion does
not recover the previous directory automatically. Existing migrated PVs stay
`Retain`; newly provisioned PVs inherit the live class policy `Delete`.

Keep all three class objects present. Existing NFS mounts use the bound PV's
endpoint, but the repository's maintenance discovery and provisioning templates
still depend on the StorageClass objects.

## Why a normal repository redeploy needs attention

The repository's deployment model is a component `.env`, raw YAML rendered
selectively with `envsubst`, and a `scripts/deploy*.sh` entrypoint; Grafana/Loki
also runs Helm with pre-created `existingClaim` PVCs. A deploy script often
applies storage and workloads in the same invocation. Updating an image is
therefore not necessarily a workload-only action when using that script.

Keep PVC class names, StatefulSet claim-template class names and class-name
environment settings unchanged. That removes the class-rename conflict from
normal redeploys. A remaining issue is that a generic PVC manifest can conflict
with the explicitly prebound `volumeName`, depending on apply history.
Keycloak's execution notes recorded that exact conflict. Do not fix it with
force replacement, deletion, or removal of claim protection.

Verify storage-preserving behavior before resuming deployment entrypoints.
Use two explicit paths within the existing deployment model where needed:

1. **Existing installation:** check expected claims and their exact PV/server/
   directory against the execution stage; preserve class and binding fields;
   update workloads/configuration using the existing claims. A Pending,
   Terminating or unexpected binding is an error, not permission to provision
   something else. Existence alone is not validation.
2. **New installation or deliberately new claim:** render the existing class name
   from the source/environment and create the claim. If a known migrated
   installation unexpectedly loses a claim, stop for recovery; do not silently
   classify it as a fresh install and start on an empty directory.

No new deployment framework is required. Preflight these storage decisions
before applying Secrets, classes or workloads, then use the existing apply/
Helm sequence. Errors must terminate the deployment reliably. Keep runtime
variables in embedded ConfigMap shell/SQL snippets unexpanded.

## Script-specific implications

The four migrated stack entrypoints now call
`nfs-ha/scripts/verify-migrated-claims.py` before any cluster mutation. The
checked-in mapping records exact PVC/PV identities and CSI paths. In this
migrated cluster, a missing or changed mapped claim blocks deployment; a fresh
cluster with no migrated PVs can create new claims. Existing claims are never
reapplied from generic PVC manifests. The PostgreSQL entrypoints also perform
a server-side StatefulSet apply dry run before updating Secrets or workloads.

| Stack / entrypoint | Current storage behavior | Required treatment for existing installations |
| --- | --- | --- |
| `n8n/scripts/deploy-n8n.sh` | Validates all four migrated claims, dry-runs the StatefulSet, and skips generic n8n PVC apply when the verified claim exists. | Keep the live database claim template and bindings; inspect errors for partial changes already applied. |
| `keyclock/scripts/deploy.sh` | Validates both claims, dry-runs the StatefulSet, skips existing PVC apply, and propagates command failures. | Keep the migrated claim and StatefulSet template identities. |
| `meshcentral/scripts/deploy.sh` | Validates the migrated claim before changing Secrets and skips existing PVC apply. | Keep `MESH_STORAGE_CLASS` unchanged. `reload-config.sh` changes the Secret and restarts the Deployment without deleting the PVC. |
| `grafana+loki/scripts/deploy.sh` | Checks `.240` environment value and all three bindings before Helm; skips existing PVC applies and pins the current chart versions. | Keep Helm `existingClaim` names. The ubuntu-mini `.env` and source were verified after cutover. |
| `jenkins/scripts/deploy.sh` | Unconditionally applies the PVC rendered from `JENKINS_STORAGE_CLASS`. | Apply the existing/new installation distinction if deployed; its inclusion here is source review, not evidence of an additional migrated stack. |
| `box/scripts/deploy-quarantine.sh` | Unconditionally applies the named state PVC before its StatefulSet. | Preserve existing claims when deployed. Its StatefulSet references an explicit claim, unlike the PostgreSQL claim-template case. |

The `check-deploy.sh` name has different meanings across components:
n8n/Keycloak render a selected manifest; MeshCentral inspects live resources
and logs. A preview is not automatically a server-side validation, and some
previews can include secrets. Keep those outputs private and add a server-side
dry run/diff of the intended existing-installation path before executing it.

## Routine operations

| Operation | Effect and maintenance guidance |
| --- | --- |
| Pod restart, reschedule, or node maintenance | Existing PVC/PV selects the same `.240` directory. No class rename or recopy is needed. Observe the master2/two-vote service boundary. |
| Application image/config update | Keep claims and mounts unchanged. The migrated entrypoints now verify exact bindings before mutation; first verify deployment-host `.env` values and rendered sources. Existing dedicated reload helpers must be inspected for PVC deletion first. |
| Stop and restore replicas for NFS maintenance | Use `bin/shutdown-nfs-workloads.sh` and `bin/restore-nfs-workloads.sh`. Preserve the saved counts; handle Jobs/DaemonSets/external writers separately. Keep all referenced classes present for discovery. |
| Deployment scale change | Reuses its named claim. Storage naming does not make shared writes or additional database replicas supported; retain the application's concurrency model. |
| StatefulSet restore to an existing ordinal | Reuses the existing claim if it was retained. Keep the same controller/template naming and verify the binding. |
| StatefulSet scale to a new ordinal | May create a new PVC from the live template, which still names `kube-postgres`. That class must provision on `.240`. New replicas need application-specific configuration; this plan does not enable PostgreSQL replication. |
| Newly installed stack or explicitly new claim | Use the same class name from the mapping after its endpoint update. It provisions new storage, not the old stack's data. |
| PVC expansion | A separate capacity change: check live class/driver support and backend capacity. Neither class renaming nor this plan grants expansion support. |

For n8n and Keycloak PostgreSQL, changing `volumeClaimTemplates` is not a
routine in-place update. An existing-installation renderer should preserve
that live template while allowing supported Pod-template updates; a fresh
installation uses the same class name. Validate both paths. Replacing
the StatefulSet solely to obtain a new class name introduces an unnecessary
storage lifecycle operation. Keycloak's source includes `whenDeleted: Delete`;
n8n's source explicitly retains claims on deletion/scaling. Inspect live
retention/owner references as well before any controller replacement. See the
[StatefulSet storage reference](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/).

## Destroy, reload and recovery are different operations

Do not treat destroy followed by deploy as an application upgrade.

- `keyclock/scripts/destroy.sh` deletes the application PVC and explicitly
  deletes PostgreSQL claims. `meshcentral/scripts/destroy.sh` deletes its PVC
  and namespace. `box/scripts/destroy-quarantine.sh` also deletes its PVC and
  namespace. These are not storage-preserving maintenance entrypoints.
- `n8n/scripts/destroy-n8n.sh` keeps PVCs by default and purges them only with
  `--purge-data`; `jenkins/scripts/destroy.sh` has a similar data-purge option.
  Even with preserved PVCs, recreation must account for old classes/templates
  and application Secrets/configuration. Prefer an ordinary upgrade for updates.
- `grafana+loki/scripts/reload-collector.sh` deletes the collector PVC before
  recreating it. `reload-events.sh` also deletes that PVC and uninstalls Loki;
  it contains a malformed Loki PVC deletion command. Neither is a safe
  restart procedure for migrated storage. Any maintenance update to these helpers must separate
  data-preserving restarts from explicit data reset operations.

`Retain` protects the backing data when a migrated PVC is deleted; it does
not keep that PVC alive, preserve its UID, or automatically attach a new claim
to its Released PV. A later deploy can provision an empty directory instead.
For recovery, stop writers, locate the authoritative migrated PV and directory
from private stage evidence, and use a reviewed explicit rebind procedure.
The class mapping alone is not a data-recovery map; retain per-claim execution
maps and current binding evidence. Never fall back to stale `.235` data after
new writes. New dynamic `Delete` PVs need particular care with destroy scripts.

## Maintenance discovery and deployment validation

`bin/shutdown-nfs-workloads.sh` first selects NFS-provisioned StorageClasses,
then discovers claims/templates referring to those names. Deleting `kube-nfs`
while a migrated claim still names it can exclude its workload even though
that PV continues to mount NFS successfully. `restore-nfs-workloads.sh` uses
the saved state file; it cannot repair an omission in shutdown discovery.

Keep both maintenance dry runs in the cutover/deployment validation criteria.
If no saved replica state exists, record the restore helper's missing-state
result; do not manufacture a successful restore test. For relevant deployed
spec/class changes, verify discovery of the actual live workload templates.

Keep all three class objects for existing claims, StatefulSet templates and
new installations. There is no later class-name retirement or second data
migration planned. The endpoint-only update keeps source and live class names
aligned without creating parallel sets of classes.

The migrated claim preflight and shell syntax checks passed against all ten
live claims from ubuntu-mini after retirement. Both PostgreSQL source
StatefulSets passed server-side apply dry runs. The root and Grafana `.env`
values and StorageClass sources on that deployment host match `.240`. Full
deploy entrypoints were not run during the storage cutover; keep the
destructive reload/destroy helpers separate from routine updates.
