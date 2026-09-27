# NFS HA for MicroK8s

This directory holds the design, status, and tools for a two-member,
master2-only NFS migration service for the MicroK8s PVC exports. There is
no automatic failover or independent power-fencing requirement. Both
Corosync votes are required; loss of either member stops the service when
master2 can run its stop actions. The current target
has **three exported data resources** (`kube`, `grafana`, `postgres`) and one
private `nfs-state` resource. It does not include the legacy general NFS LV.

The [final consumer cutover and legacy mount retirement](legacy-nfs-retirement.md)
was completed on September 27. The [current status](status-2026-09-27.md)
records the live result and operator application acceptance.
All ten existing stack PVCs use the VIP, and slave1's independent NFS server,
exports and three old local mounts are retired. The old LVs and data remain
intact.

Keep the existing StorageClass names `kube-nfs`, `kube-postgres` and
`kube-grafana` for both existing and new claims. The
[persistent mapping](storage-class-mapping.json) records their live endpoint/share
changes to the VIP. The three StorageClass source manifests and the root and
Grafana deployment `.env` files on ubuntu-mini are updated and verified.
Claim class names and class-name environment variables remain unchanged.

[Existing stack maintenance](existing-stack-storage-maintenance.md) explains
why a retained class name still mounts the new storage and what this means
for deploy scripts, Helm upgrades, scaling, reloads and destroy operations.

The [HA overview](drbd-pacemaker-nfs-ha-overview.md) and
[September 26 status](status-2026-09-26.md) provide historical context. The old disk backing that general LV
logged I/O errors during initialization. The
[retirement runbook](retire-legacy-nfs-lv.md) records the completed legacy
export, boot mount, and DRBD resource retirement, plus the private-state
backing-path move. Its final legacy-LV/VG cleanup step remains pending. The
[next-stage runbook](nfs-ha-next-stage.md) covers the readiness checks and
later NFS/Pacemaker design.

The [implementation reference](new_node_implementation.md) records target
names and endpoints. The [DRBD initialization runbook](drbd-initialization.md)
and [peer storage preparation](ubuntu-slave1-storage-preparation.md) describe
completed historical preparation; the five-resource one-time scripts are
retired and exit without changes.

These local checks are read-only:

```bash
sudo ./scripts/nfs-ha-drbd-readiness.sh
sudo ./scripts/nfs-ha-service-inventory.sh
```

The readiness check requires the obsolete resource to be gone and the peer
private-state backing LV to be on `kube-vg`; both changes are complete in the
latest checkpoint. The repository checkout on `ubuntu-slave1`
may lag this one; the [next-stage runbook](nfs-ha-next-stage.md) shows how to
stream the current read-only checks over SSH without installing them there.

Run Kubernetes workload discovery and maintenance helpers from a MicroK8s
control-plane host with working `microk8s kubectl`. The helpers cover
Deployments and StatefulSets, not Jobs, unmanaged Pods, or external NFS
clients. September 27 execution records show the managed service activated
on master2 and stack claims rebound to the VIP.

For bootstrap history and controlled service operations, use
[Pacemaker cutover](pacemaker-cutover.md) and
[validation results](validation-2026-09-26.md). `scripts/nfs-ha-collect.sh`
collects private two-host and Kubernetes evidence; `nfs-ha-stage.sh` renders
and checks offline candidates using `.env`; `nfs-ha-cutover.py` previews or
explicitly executes submission, activation and stop operations.
Read the handoff restrictions before executing any cutover action.

The completed per-stack migration procedure is described in
[the stack-by-stack guide](gradual-migration.md).
The [MeshCentral stack cutover plan](meshcentral-cutover.md) applies that guide
to its single live NFS claim.
The [n8n stack cutover plan](n8n-cutover.md) covers its active n8n and
PostgreSQL claims plus the retained database and recovery claims.
The [Grafana and Loki stack cutover plan](grafana-loki-cutover.md) covers its
Grafana, Loki and Box collector state claims.
The [Keycloak stack cutover plan](keycloak-cutover.md) covers its application
data and PostgreSQL claims.
The service stays on master2 after consumer migration and legacy retirement.
The linked stack documents are the original plans; the retirement runbook
identifies their execution stages. The September 27 status records the live
infrastructure retirement and operator application acceptance.
`nfs-ha-stack-plan.py` prepares per-claim copy mappings and prebound PV/PVC
candidates without applying them. `nfs-ha-stage-finalize.py --restart` stages
a fresh stopped migration snapshot for controlled reactivation. The scripts
reject final HA, move and clear actions; slave1 cannot take over the service.
