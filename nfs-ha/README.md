# NFS HA for MicroK8s

This directory holds the design, status, and tools for a two-node,
active/passive NFS service for the MicroK8s PVC exports. The current target
has **three exported data resources** (`kube`, `grafana`, `postgres`) and one
private `nfs-state` resource. It does not include the legacy general NFS LV.

Start with the [HA overview](drbd-pacemaker-nfs-ha-overview.md) and
[current status](status-2026-09-26.md). The old disk backing that general LV
logged I/O errors during initialization. The
[retirement runbook](retire-legacy-nfs-lv.md) identifies the live export,
boot mount, installed DRBD resource, and private-state backing path that
must be changed before HA activation. The
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
private-state backing LV to be moved to `kube-vg`. It will fail until those
remediation steps are complete. The repository checkout on `ubuntu-slave1`
may lag this one; the [next-stage runbook](nfs-ha-next-stage.md) shows how to
stream the current read-only checks over SSH without installing them there.

Run Kubernetes workload discovery and maintenance helpers from a MicroK8s
control-plane host with working `microk8s kubectl`. The helpers cover
Deployments and StatefulSets, not Jobs, unmanaged Pods, or external NFS
clients. No HA mount, clustered NFS export, VIP, or Pacemaker CIB has been
activated yet.
