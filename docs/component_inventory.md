# Component inventory

Live snapshot: **2026-11-07 UTC**, read from `microk8s kubectl` and `microk8s helm3` on the four-node cluster. This is an observed-state baseline for update impact assessments; rerun the commands below before changing versions. Desired state in manifests can differ from live state. No credentials or Secret values are included.

## Platform and Helm releases

| Component | Namespace | Installed chart / version | App version | Revision | Update owner |
| --- | --- | --- | --- | ---: | --- |
| `cert-manager` | `cert-manager` | `cert-manager-v1.17.1` | `v1.17.1` | 1 | `MicroK8s cert-manager addon` |
| `eg` | `envoy-gateway-system` | `gateway-helm-v1.5.0` | `v1.5.0` | 1 | `infrastruture/create-infrastructure.sh` |
| `grafana` | `grafana` | `grafana-9.4.5` | `12.1.1` | 2 | `grafana+loki/scripts/deploy.sh` |
| `loki` | `grafana` | `loki-stack-2.10.2` | `v2.9.3` | 8 | `grafana+loki/scripts/deploy.sh` |
| `exdns` | `infrastructure` | `k8s-gateway-3.2.7` | `1.6.0` | 1 | `infrastruture/create-infrastructure.sh` |
| `csi-driver-nfs` | `kube-system` | `csi-driver-nfs-4.11.0` | `4.11.0` | 1 | `infrastruture/create-infrastructure.sh` |
| `kwasm-operator` | `kwasm-system` | `kwasm-operator-0.2.2` | `0.2.2` | 1 | `MicroK8s kwasm addon` |

MicroK8s and all four kubelets report **v1.33.13**. The current nodes are `ubuntu-master2`, `ubuntu-mini`, `ubuntu-slave1`, and `ubuntu-slave2`. Enabled addons: `kwasm`, `cert-manager`, `community`, `dns`, `ha-cluster`, `helm`, `helm3`, `hostpath-storage`/`storage`, `metallb`, `metrics-server`, `rbac`, and `registry`. The `multus` and `ingress` addons are disabled. Gateway API is implemented by Envoy Gateway; `eg` is the GatewayClass.

## Live workload controllers

Every currently present Deployment, StatefulSet, DaemonSet, and CronJob is listed. `Desired/ready` is a snapshot; DaemonSet values are scheduled/ready and the CronJob shows its schedule. The image column includes init/sidecar images where present. `ECR/` means `996472359368.dkr.ecr.us-east-1.amazonaws.com/`.

| Namespace | Kind / name | Desired / ready | Declared container image(s) | Update owner |
| --- | --- | ---: | --- | --- |
| `afrba` | Deployment `afrba-demo` | 1 / 1 | `afrba-demo: ECR/rrdemo-custom:latest` | `External to this repository` |
| `afrba` | Deployment `rrembed` | 1 / 1 | `rrembed: ECR/rrdemo-embed:latest` | `External to this repository` |
| `box` | Deployment `box-redaction` | 1 / 1 | `box-redaction: ECR/boxredact:latest` | `box/scripts/deploy-redact.sh` |
| `cert-manager` | Deployment `cert-manager` | 1 / 1 | `cert-manager-controller: quay.io/jetstack/cert-manager-controller:v1.17.1` | `MicroK8s cert-manager addon / Helm cert-manager` |
| `cert-manager` | Deployment `cert-manager-cainjector` | 1 / 1 | `cert-manager-cainjector: quay.io/jetstack/cert-manager-cainjector:v1.17.1` | `MicroK8s cert-manager addon / Helm cert-manager` |
| `cert-manager` | Deployment `cert-manager-webhook` | 1 / 1 | `cert-manager-webhook: quay.io/jetstack/cert-manager-webhook:v1.17.1` | `MicroK8s cert-manager addon / Helm cert-manager` |
| `container-registry` | Deployment `registry` | 1 / 1 | `registry: registry:2.8.3` | `MicroK8s registry addon` |
| `default` | Deployment `httpbin` | 1 / 1 | `httpbin: kennethreitz/httpbin:latest` | `test/ (manual examples)` |
| `default` | Deployment `observer` | 1 / 1 | `observer: gcr.io/k8s-staging-gateway-api/echo-basic:v20231214-v1.0.0-140-gf544a46e` | `test/ (manual examples)` |
| `envoy-gateway-system` | Deployment `envoy-gateway` | 1 / 1 | `envoy-gateway: docker.io/envoyproxy/gateway:v1.5.0` | `Helm eg / infrastruture/create-infrastructure.sh` |
| `envoy-gateway-system` | Deployment `envoy-infrastructure-johnkoepp-com-gateway-e68ea736` | 1 / 1 | `envoy: docker.io/envoyproxy/envoy:distroless-v1.35.0`<br>`shutdown-manager: docker.io/envoyproxy/gateway:v1.5.0` | `Envoy Gateway generates this proxy from the shared Gateway` |
| `envoy-gateway-system` | Deployment `envoy-infrastructure-koeppster-lan-gateway-29aa4d45` | 1 / 1 | `envoy: docker.io/envoyproxy/envoy:distroless-v1.35.0`<br>`shutdown-manager: docker.io/envoyproxy/gateway:v1.5.0` | `Envoy Gateway generates this proxy from the shared Gateway` |
| `grafana` | DaemonSet `loki-promtail` | 4 / 4 | `promtail: docker.io/grafana/promtail:2.9.3` | `grafana+loki/scripts/deploy.sh` |
| `grafana` | Deployment `box-event-collector` | 1 / 1 | `collector: ECR/boxevents:1.1` | `grafana+loki/scripts/deploy.sh` |
| `grafana` | Deployment `grafana` | 1 / 1 | `grafana: docker.io/grafana/grafana:12.1.1` | `grafana+loki/scripts/deploy.sh` |
| `grafana` | StatefulSet `loki` | 1 / 1 | `loki: grafana/loki:2.6.1` | `grafana+loki/scripts/deploy.sh` |
| `infrastructure` | CronJob `aws-ecr-secret-update` | schedule `* */8 * * *` | `aws-ecr-secret-update: awsecr:1.0.0` | `infrastruture/create-infrastructure.sh` |
| `infrastructure` | Deployment `awsdns` | 1 / 1 | `awsdns: awsdns:1.0.0` | `infrastruture/create-infrastructure.sh` |
| `infrastructure` | Deployment `exdns-k8s-gateway` | 1 / 1 | `k8s-gateway: ghcr.io/k8s-gateway/k8s_gateway:1.6.0` | `infrastruture/create-infrastructure.sh` |
| `keycloak` | Deployment `keycloak` | 1 / 1 | `wait-for-postgres: alpine/psql`<br>`keycloak: quay.io/keycloak/keycloak:26.7.3` | `keyclock/scripts/deploy.sh` |
| `keycloak` | StatefulSet `postgres-keycloak` | 1 / 1 | `postgres-keycloak: postgres:18.1` | `keyclock/scripts/deploy.sh` |
| `kube-system` | DaemonSet `calico-node` | 4 / 4 | `upgrade-ipam: docker.io/calico/cni:v3.29.3`<br>`install-cni: docker.io/calico/cni:v3.29.3`<br>`calico-node: docker.io/calico/node:v3.29.3` | `MicroK8s cluster networking` |
| `kube-system` | DaemonSet `csi-nfs-node` | 4 / 4 | `liveness-probe: registry.k8s.io/sig-storage/livenessprobe:v2.15.0`<br>`node-driver-registrar: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.13.0`<br>`nfs: registry.k8s.io/sig-storage/nfsplugin:v4.11.0` | `Helm csi-driver-nfs / infrastruture/create-infrastructure.sh` |
| `kube-system` | Deployment `calico-kube-controllers` | 1 / 1 | `calico-kube-controllers: docker.io/calico/kube-controllers:v3.29.3` | `MicroK8s cluster networking` |
| `kube-system` | Deployment `coredns` | 1 / 1 | `coredns: coredns/coredns:1.12.1` | `MicroK8s dns addon` |
| `kube-system` | Deployment `csi-nfs-controller` | 1 / 1 | `csi-provisioner: registry.k8s.io/sig-storage/csi-provisioner:v5.2.0`<br>`csi-resizer: registry.k8s.io/sig-storage/csi-resizer:v1.13.1`<br>`csi-snapshotter: registry.k8s.io/sig-storage/csi-snapshotter:v8.2.0`<br>`liveness-probe: registry.k8s.io/sig-storage/livenessprobe:v2.15.0`<br>`nfs: registry.k8s.io/sig-storage/nfsplugin:v4.11.0` | `Helm csi-driver-nfs / infrastruture/create-infrastructure.sh` |
| `kube-system` | Deployment `hostpath-provisioner` | 1 / 1 | `hostpath-provisioner: cdkbot/hostpath-provisioner:1.5.0` | `MicroK8s hostpath-storage addon` |
| `kube-system` | Deployment `metrics-server` | 1 / 1 | `metrics-server: registry.k8s.io/metrics-server/metrics-server:v0.7.2` | `MicroK8s metrics-server addon` |
| `kwasm-system` | Deployment `kwasm-operator` | 1 / 1 | `kwasm-operator: ghcr.io/kwasm/kwasm-operator:kwasm-operator-0.2.2` | `MicroK8s kwasm addon / Helm kwasm-operator` |
| `meshcentral` | Deployment `meshcentral` | 1 / 1 | `meshcentral: ghcr.io/ylianst/meshcentral:latest-slim` | `meshcentral/scripts/deploy.sh` |
| `metallb-system` | DaemonSet `speaker` | 4 / 4 | `speaker: quay.io/metallb/speaker:v0.14.9` | `MicroK8s metallb addon` |
| `metallb-system` | Deployment `controller` | 1 / 1 | `controller: quay.io/metallb/controller:v0.14.9` | `MicroK8s metallb addon` |
| `n8n` | Deployment `box-mcp-server` | 1 / 1 | `box-mcp-server: ECR/mcp-server-box@sha256:53ca80058fe7a255753a31e8dd754115c6c5d9465f1f24bdab386ed0a0eba6d1` | `n8n/scripts/deploy-n8n.sh` |
| `n8n` | Deployment `n8n` | 1 / 1 | `n8n: n8nio/n8n:2.37.10@sha256:307d6065be25619aa24cfc63a7c2f04ca56d084a08c05c8e9f189a89f353b1ec` | `n8n/scripts/deploy-n8n.sh` |
| `n8n` | StatefulSet `postgres-n8n` | 0 / 0 | `postgres-n8n: postgres:14` | `Retained PostgreSQL 14 migration rollback; no longer applied by current deploy script` |
| `n8n` | StatefulSet `postgres-n8n-v17` | 1 / 1 | `postgres-n8n: postgres:17.11-bookworm@sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0` | `n8n/scripts/deploy-n8n.sh` |
| `ntfy` | StatefulSet `ntfy` | 1 / 1 | `ntfy: binwiederhier/ntfy:v2.36.0` | `ntfy/scripts/deploy.sh` |

The `postgres-n8n` PostgreSQL 14 StatefulSet is retained at **0 replicas** with its old `kube-postgres` PVC. The active n8n database is `postgres-n8n-v17` (PostgreSQL 17.11); `n8n` connects to its Service. Three completed n8n migration backup/restore Jobs remain in the API; they are historical Jobs, not continuously scheduled workloads. The Loki chart reports app version `v2.9.3`, while the live Loki container declares `grafana/loki:2.6.1`; compare both chart and image when assessing a Loki update. The Keycloak init image `alpine/psql` has no declared tag and resolves to `latest`.

Mutable image tags (`latest` and `latest-slim`) are not reliable version identifiers. At snapshot time, the running pod image digests were:

| Workload | Running image digest |
| --- | --- |
| `afrba/afrba-demo` | `sha256:70f721a69c6db1815d6fdd3fbe0af8bec8792114247468e0c21a276f6cdcdcf4` |
| `afrba/rrembed` | `sha256:1474e269e9103311be357bfc922084e04c9843b25d3af88879cb835fb62f6490` |
| `box/box-redaction` | `sha256:2bc02ea74530a0253cdf591fbda1cb3015f009fa8ab6020a02ee94b3b9edd86e` |
| `default/httpbin` | `sha256:599fe5e5073102dbb0ee3dbb65f049dab44fa9fc251f6835c9990f8fb196a72b` |
| `meshcentral/meshcentral` | `sha256:f2250e9911480e02f861b7456dcbfaa45baeccfac9fd083d7907129dbc4f56be` |
| `keycloak/wait-for-postgres` init container | `sha256:7cd118b8061fa4e7b4e90a16da14b4761da0977f9a2ced983b266dad59410e93` |

## Other versioned and shared components

| Component | Live state / version | Change impact |
| --- | --- | --- |
| Gateway API CRDs | `Gateway` and `HTTPRoute` serve `v1` and `v1beta1`; `TCPRoute` serves `v1alpha2`. | Envoy Gateway, all HTTP routes, and the undeployed Postfix TCPRoute. |
| cert-manager CRDs and issuers | `Certificate` and `ClusterIssuer` serve `v1`; `cert-issuer-prod` and `cert-issuer-stage` are installed. | Wildcard certificate renewal and public HTTPS Gateway. |
| Shared Gateways | `infrastructure/johnkoepp-com-gateway` listens on 80, 443, and 25; `koeppster-lan-gateway` listens on 80. | Public HTTP/HTTPS, SMTP listener, and LAN HTTP routing. No TCPRoute is currently installed. |
| NFS CSI StorageClasses | `kube-nfs` → `192.168.1.240:/srv/ha/kube-lv`; `kube-postgres` → `192.168.1.240:/srv/ha/kube-postgres`; `kube-grafana` → `192.168.1.240:/srv/ha/kube-grafana`. All use `nfs.csi.k8s.io` (chart 4.11.0). | Persistent app data and NFS maintenance. Existing PVs retain their provision-time endpoints, so inspect PVs and the NFS HA runbook before storage changes. |
| MicroK8s hostpath | `microk8s-hostpath` StorageClass; registry uses its PVC. | Local registry state is outside NFS workload shutdown discovery. |
| WASM runtime | `wasmtime-spin` RuntimeClass is installed; no Spin operator release or SpinApp workload is present. | SpinKube manifests are available in `infrastruture/`, but are not active in this snapshot. |

## Deployed routes and repository-only stacks

The shared Gateways carry public routes for `rrdemo`, `rrembed`, `boxredact`, `localapp`, `mcpemo`/`mcp`, `boxhook`, `httpbin`, `observer`, `grafana`, `idp`, `mesh`, `orchestration`, and `ntfy` under `johnkoepp.com`. LAN routes exist for Grafana, Loki, and httpbin under `k8s.koeppster.lan`. The `boxmcp` namespace has a Service and routes but no workload controller or Service endpoints, even though both HTTPRoutes report accepted references. Its HTTPS and redirect routes currently name different hosts (`mcpemo` and `mcp`).

Repository manifests exist for Jenkins, Box portal, Box quarantine, and Postfix, but **none has a live workload controller** in this snapshot. The `postfix` namespace and Gateway SMTP listener exist without a Postfix Deployment or TCPRoute. The `jenkins` namespace is absent. The `box` namespace currently runs only redaction; its `localapp` route proxies an external endpoint. `afrba` workloads and `boxmcp` resources have no owner in this repository. Treat these as separate change owners during impact assessment.

## Refresh commands

```bash
microk8s version
microk8s status
microk8s kubectl get nodes -o wide
microk8s helm3 list -A
microk8s kubectl get deploy,statefulset,daemonset,cronjob -A -o wide
microk8s kubectl get pods -A -o json  # inspect status.containerStatuses[].imageID for mutable tags
microk8s kubectl get gateway,httproute,tcproute -A
microk8s kubectl get storageclass,pvc,pv -A
```

For NFS changes, run `./bin/shutdown-nfs-workloads.sh --dry-run`, then separately inspect Jobs, DaemonSets, unmanaged Pods, and external NFS clients. The restore helper's `--dry-run` requires a saved replica state file from a real shutdown (or a matching `--state-file`). The scripts discover only Deployments and StatefulSets that currently mount NFS-backed claims.
