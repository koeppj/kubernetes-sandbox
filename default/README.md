# Default namespace Setups

Additions to the `default` namespace.  Can also be used as a template for setting up other namespaces.

## Prerequisites

Apply manifests with `microk8s kubectl`. The macvlan example additionally needs
Multus/network-attachment support and the configured host network interface;
route examples need the shared Gateway/API setup and their backend endpoints.
NFS test PVCs and Spin/WASM examples require their respective storage classes
and runtime/operator installations. See the [dependency inventory](../docs/dependencies.md).
