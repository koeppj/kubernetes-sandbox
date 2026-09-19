# Deployment and maintenance dependencies

This inventory follows the repository's shell scripts, Dockerfiles, embedded
container commands, and operating guides. Package names below are Ubuntu/Debian
names; they identify which package provides a tool, not a command to upgrade an
existing host. Image pins remain in the Dockerfiles and manifests. Install only
the groups needed for the operation you are performing.

## Operator host baseline

Run the scripts on a Linux MicroK8s administration host with access to the target
cluster. They assume Bash and GNU utilities, not a generic POSIX `sh` or the
macOS/BSD utility set. Invoke scripts directly or with `bash`.

| Tool / package | Required use |
| --- | --- |
| Bash (`bash`) | Deployment and maintenance scripts use `source`, `BASH_SOURCE`, arrays, process substitution, and `pipefail`. NFS shutdown/restore needs Bash 4+ for associative arrays, `mapfile`, and lowercase expansion. |
| GNU coreutils (`coreutils`) | `base64`, `tr`, `dirname`, `cat`, `date`, `mkdir`, `mktemp`, `cp`, `mv`, `rm`, `rmdir`, `head`, `sort`, `tee`, `cut`, and `sleep` appear across scripts. `env` is used by Bash shebangs. `chmod` is needed when preparing executable files. CI/image workflows also use `install` and `sha256sum`. |
| `envsubst` (`gettext-base`) | Deploy-time rendering of selected manifests and Helm-related storage configuration; also used by several preview and destroy scripts. |
| `sed` (`sed`) | Box quarantine secret line-ending normalization, Jenkins JCasC indentation, and Postfix recipient-address escaping. |
| `grep` (`grep`) | Updater image-import error detection, Keycloak PVC cleanup, and SpinKube removal. |
| `xargs` (`findutils`) | `infrastruture/delete-spin.sh` uses GNU `xargs -r`. |
| `microk8s` (MicroK8s snap, managed by `snapd`) | Cluster administration through `microk8s kubectl`, addon management, Helm wrappers, and image import. The caller needs MicroK8s access and Kubernetes permissions for the resources the selected script manages. |
| Git (`git`) | Obtain/update the checkout and review changes. Deployment scripts themselves do not run Git. |
| Text editor | Configure the root/component `.env` and file-based secrets from samples. No particular editor is required. |

`echo`, `printf`, `read`, `test`, `command`, `source`, `cd`, `pwd`, `export`,
`shopt`, `mapfile`, `trap`, and `umask` are supplied by Bash in these scripts;
they do not each require a separate package. Keep `/snap/bin` available in the
script environment when that is where the `microk8s` command is installed.

### MicroK8s, Helm, and bare kubectl

Most scripts explicitly use `microk8s kubectl`. Infrastructure setup also calls
bare `kubectl`; several older guides use that shorthand. Ensure it targets the
same MicroK8s cluster. The setup script enables alias expansion and sources
`~/.bash_aliases`, so an existing `alias kubectl='microk8s kubectl'` there works
for that script. An interactive-only alias is not automatically inherited by
scripts. A `kubectl` wrapper on `PATH` that executes `microk8s kubectl "$@"` is
another option. Use `microk8s kubectl` when running guide commands manually.
Container and Jenkins-agent `kubectl` binaries use their in-cluster identity.

Infrastructure uses **both** `microk8s helm` and `microk8s helm3`; Grafana/Loki and
SpinKube use `microk8s helm`. Make both wrappers available before infrastructure
setup; it does not explicitly enable Helm. Installing standalone `helm` does
not satisfy these hard-coded commands. The infrastructure README records
MicroK8s 1.25+ for cluster-wide `microk8s images import`; that is an image-import
minimum, not a compatibility guarantee for every chart/manifest in the repo.

## Additional package providers

These packages are conditional on the workflow tables below. Preserve the
host's existing installation method when a tool is already managed there.

| Tool | Ubuntu/Debian provider or installation context |
| --- | --- |
| `docker` CLI and daemon | `docker.io` in distribution repositories, or an existing Docker Engine installation. MicroK8s containerd alone does not provide the Docker build/save/push commands. |
| `curl`, TLS trust roots | `curl`, `ca-certificates`. |
| `aws` | AWS CLI installation (`awscli` where suitable, or the AWS CLI installer). Check command compatibility: Jenkins uses `get-login-password`; the legacy ECR updater image uses `get-login`. |
| `jq` | `jq`, required in the DNS updater image or when running that worker manually. |
| `sudo`, `systemctl` | `sudo`, `systemd` on the local backup/restore host. |
| `tar`, gzip compression | `tar`, `gzip`. |
| `openssl` | `openssl`, for documented secret-generation examples. |
| `wget`, `unzip` | `wget`, `unzip`, installed by the Jenkins tools Dockerfile in the build image. |
| `iptables` | `iptables`, plus the already configured host firewall persistence solution. |
| PlantUML, `java`, `dot` | `plantuml`, a Java runtime such as `default-jre-headless`, and `graphviz`, only for local diagram rendering. |

## Dependencies by workflow

All script workflows require Bash, their listed core utilities, and MicroK8s
unless explicitly described as an image-only build. Paths are relative to the
repository root.

| Workflow / entry point | Additional operator-host tools and inputs |
| --- | --- |
| Infrastructure: `infrastruture/create-infrastructure.sh` | `envsubst`, `base64`, `tr`, `curl`, CA certificates, Docker CLI **and running daemon**, `grep`, `tee`, temporary-file utilities, both Helm wrappers, and bare `kubectl` resolution described above. Sources root `.env`. Run from `infrastruture/` because some manifest paths are relative to the working directory. |
| AWS updater rebuilds: `infrastruture/redeploy-awsecr-updater.sh`, `redeploy-awsdns-updater.sh`, `scripts/build-import-*.sh` | Docker build/save, `microk8s images import`, `mktemp`, `rm`, `rmdir`, `tee`, `grep`; disk space for image archives and reachability of every joined node. Redeploy scripts source root `.env` and need `envsubst`; DNS also calls `curl`. Build architecture must match target nodes. |
| DNS apply only: `infrastruture/scripts/deploy-awsdns.sh` | `curl`, CA certificates, `envsubst`, `mktemp`, `rm`; HTTPS IPv4 access to `icanhazip.com`, existing `aws-credentials` Secret, and images already imported. |
| Immediate ECR refresh: `infrastruture/scripts/run-secrets-job.sh` | `date`; existing `infrastructure/aws-ecr-secret-update` CronJob, its image, credentials and RBAC. Docker and a local AWS CLI are unnecessary for this operation. |
| SpinKube: `infrastruture/deploy-spinkube.sh`, `delete-spin.sh` | Helm for installation; `grep` and `xargs` for cleanup. Access to referenced GitHub releases, KWasm chart repository, and GHCR. |
| Node DNS labels: `infrastruture/set-extdn-labels.sh` | MicroK8s access and the node name argument. |
| n8n: `n8n/scripts/` | `envsubst`, `base64`, `tr`, component `.env`, and n8n/Box credentials or existing Secrets. Recovery helper needs existing completed backup Jobs and recovery PVC; database tools run in Jobs (see below). |
| Keycloak: `keyclock/scripts/` | `envsubst`, `base64`, `tr`, component `.env`; `grep` for destroy-time PostgreSQL PVC discovery. |
| Grafana/Loki: `grafana+loki/scripts/` | `envsubst`, `microk8s helm`, component `.env`, chart repository access, and `secrets/sandbox.json`. Reload-events also invokes Helm. |
| Box quarantine: `box/scripts/*quarantine.sh` | Deploy requires `envsubst`, `sed`, `mktemp`, `rm`, `box/.env`, `secrets/box-jwt-auth.json`, and `config/quarantine-template.txt`. Pause/resume use only MicroK8s. Current scripts target `box-enterprise-quarantine` for secrets/scaling while manifests use `box`; resolve this documented namespace mismatch before deployment. |
| Box portal: `box/scripts/*portal*.sh` | Deploy sources `box/.env` and requires the session secret plus `secrets/oidc.json`, `secrets/box-jwt-auth.json`, and `secrets/box_config.json`. It applies static YAML and does not invoke `envsubst`. |
| Box redaction: `box/scripts/*redact.sh` | MicroK8s and `dirname`; these scripts apply/remove the Service and route, and do not build the application image. |
| MeshCentral: `meshcentral/scripts/` | `envsubst` for deploy/destroy, component `.env`, and `secrets/config.json`; reload creates the Secret and restarts the workload. |
| Jenkins: `jenkins/scripts/deploy.sh` | `envsubst`, `base64`, `tr`, `sed`, **local AWS CLI** supporting `ecr get-login-password`, component `.env`, AWS/GitHub credentials, and pre-published controller/tools images. `openssl` is used by the README's webhook-secret generation command. |
| Jenkins image publishing: `jenkins/scripts/build-controller.sh`, `build-tools.sh` | Docker CLI and daemon, component `.env`, and an authenticated registry session authorized to push. These scripts do not log Docker in. Deployment does not call these builders. |
| Postfix: `postfix/scripts/` | `envsubst`, `sed`, component `.env`; Docker CLI/daemon and registry push access by default because deploy calls `build.sh`. With `POSTFIX_BUILD_IMAGE=false`, a previously published image is required instead. Preview/destroy still require `envsubst`. |
| Default and test manifests: `default/`, `test/` | `microk8s kubectl`; additional CRDs, storage, network attachments, runtimes, or images required by the selected example must already exist. Diagnostic commands run in the selected debug image. |

Docker builds/pushes require access to base-image registries and the destination
registry, including its existing TLS/insecure-registry configuration where
applicable. ECR publishing additionally needs an authenticated Docker session;
use AWS credentials with the intended registry permissions. Jenkins's
`get-login-password` call creates a Kubernetes pull Secret, not a Docker login.
`curl` needs `ca-certificates` for the HTTPS public-IP lookup.

## Maintenance host tools

| Operation | Tools and operational dependencies |
| --- | --- |
| `bin/shutdown-nfs-workloads.sh` | Bash 4+, `microk8s kubectl`, `dirname`, `cat`, `sort`, `mkdir`, `mktemp`, `date`, `mv`, `rm`; cluster-wide read access to StorageClasses, PVCs, Deployments and StatefulSets, plus scale/wait access for shutdown. Writable state-file directory. |
| `bin/restore-nfs-workloads.sh` | Bash 4+, `microk8s kubectl`, `dirname`, `cat`, `head`, `sort`, `rm`; matching saved replica-state file, workload read/scale/rollout access, and healthy NFS. Dry run still reads live resources. |
| `bin/backup-cluster.sh` | `sudo`, `systemctl` (`systemd`), `tar` (`tar`), gzip support (`gzip`), `date`, `mkdir`, `mktemp`, `cp`, `rm`; local MicroK8s snap data and space for staging/archive. |
| `bin/restore-cluster.sh` | `sudo`, `systemctl`, `tar`, `gzip`, `mktemp`, `mkdir`, `cp`, `rm`; local snap data paths, backup archive, root authority through sudo, and interactive confirmation. |

The cluster backup/restore scripts assume `/var/snap/microk8s/current` and
specific systemd units. Backup stops `snap.microk8s.daemon-etcd`; restore starts
`daemon-apiserver`, `daemon-controller-manager`, `daemon-etcd`, `daemon-kubelet`,
`daemon-proxy`, and `daemon-flanneld` under the `snap.microk8s.` prefix. Verify
these units exist on the target installation before use. Installations using
different service names or datastore layouts require script adaptation; tool
installation alone does not make these backups compatible. These scripts copy
local cluster state, not NFS application data.

NFS shutdown/restore operates through Kubernetes and does not require an NFS
server package on the operator host. Follow the [root maintenance procedure](../README.md#nfs-server-maintenance)
and separately account for Jobs/unmanaged Pods using NFS.

## Node, storage-server, and network dependencies

- MicroK8s nodes need Linux NFS client support for NFSv4.1 mounts. On Ubuntu,
  `nfs-common` provides client/admin helpers such as `mount.nfs` and `showmount`;
  `mount`/`umount` are provided by the `mount` package. The NFS CSI driver is
  installed in Kubernetes; it does not provision the backing NFS server or exports.
- The storage server needs NFS service/export tooling (`nfs-kernel-server`,
  including `exportfs`, on Ubuntu) and the configured exports, ownership, and
  network access. General app storage uses `kube-nfs`, PostgreSQL uses
  `kube-postgres`, and Grafana uses its dedicated `kube-grafana` export/class.
- The local `nfs-ha/` planning documents describe a separate, **planned** storage
  server workflow: `lvm2`, `drbd-utils` and a compatible kernel DRBD module,
  `pacemaker`, `pacemaker-cli-utils` (`crm_verify`, `crm_simulate`), `corosync`,
  `pcs`, `resource-agents-base`, `resource-agents-extra`, `nfs-kernel-server`,
  `nfs-common`, `rsync`, `acl` (`getfacl`/`setfacl`), `attr`
  (`getfattr`/`setfattr`), `smartmontools` (`smartctl`), and `shellcheck`.
  They also depend on systemd/sudo and Ubuntu package-management tools
  (`apt-get`, `dpkg`); LVM, ext4 filesystem, mount/device inspection and locking
  utilities are server-side concerns (`lvm2`, `e2fsprogs`, `mount`, `util-linux`):
  examples include `pvs`/`vgs`/`lvs`, `vgcfgbackup`, `lvcreate`/`lvextend`,
  `mkfs.ext4`/`resize2fs`, `lsblk`, `findmnt`, and `flock`.
  Fencing hardware and its appropriate agent remain prerequisites for HA
  activation. These are not dependencies of ordinary app deployment or the
  existing `bin/` NFS maintenance scripts.
- Infrastructure installs/enables community, RBAC, cert-manager, MetalLB,
  registry, metrics-server, KWasm, Envoy Gateway, NFS CSI, and `k8s_gateway`.
  Multus/network-attachment support must also be present for the macvlan
  example, including the `macvlan` and `host-local` CNI plugins; infrastructure
  setup does not currently enable Multus. SpinKube has
  its own install entry point.
- App routes depend on shared Gateways and Gateway API CRDs; public TLS routes
  also need cert-manager/issuers/certificates and working DNS. Postfix needs the
  `TCPRoute` CRD and the shared Gateway's SMTP listener. Its host forwarding
  procedure needs `iptables` and the host's existing rule-persistence mechanism,
  elevated access, and external TCP/25 testing capability.
- AWS-backed operations need AWS API reachability and credentials with the
  required Route53/ECR/STS permissions. Box integrations need Box credentials
  and API reachability; OIDC integrations need their configured identity
  provider. Image pulls need registry access and, for private ECR images, a
  valid pull Secret. Namespace labels and updater RBAC must be in place.

## Tools supplied by images or external application projects

These requirements belong in the image/build environment, not on every
MicroK8s host. Confirm them when changing a base image.

| Image / workflow | Required tools |
| --- | --- |
| `infrastruture/awsdns.Dockerfile` and `create-records.sh` | Base `alpine/k8s:1.29.4` is expected to supply `/bin/ash`, bare `kubectl`, AWS CLI, `jq`, `tr`, `cut`, `mktemp`, `cat`, and `sleep`. AWS credentials arrive via Kubernetes. Local Docker builds do not execute this updater on the host. |
| `infrastruture/awsecr.Dockerfile` and `create-awsecr-secret.sh` | Same base image; `/bin/ash`, bare `kubectl`, AWS CLI, and `cut`. The script uses legacy `aws ecr get-login`, so it requires a CLI exposing that command (AWS CLI v1), unlike Jenkins's `get-login-password` flow. Treat that as a compatibility constraint when replacing the image. Running these updater scripts manually outside their images requires their tools and credentials locally. |
| n8n/Keycloak PostgreSQL init and readiness | `sh`/Bash as specified by the image, `psql`, `pg_isready`, and `sleep` in PostgreSQL/client containers. No operator-host PostgreSQL installation is used by deployment. |
| n8n recovery Jobs | PostgreSQL image: `pg_dump`, `pg_restore`, `psql`, `sha256sum`, `sed`, `sleep`, and shell/core utilities. Alpine file-backup image: `sh`, `tar` with gzip support, and `sha256sum`. |
| n8n and Box MCP | n8n executable/runtime in its image; Box MCP manifest explicitly invokes `/usr/local/bin/python`. Python Code nodes would require the external runner described in the n8n README; installing host Python does not enable them. |
| Jenkins controller | JDK 21 and `jenkins-plugin-cli` from the Jenkins base image; plugins from `jenkins/plugins.txt`. These are image dependencies. |
| Jenkins tools and agents | `jenkins/tools.Dockerfile` installs CA certificates, Git, `wget`, `unzip`, AWS CLI, `kubectl`, and `buildctl`; build also uses `tar`, `install`, `chmod`, and `rm`. CI uses `sh`, Git, `base64`, `tr`, `mktemp`, `install`, `rm`, AWS CLI, `kubectl`, and `buildctl`. The JCasC agent templates supply the inbound Java agent and a rootless `buildkitd` sidecar with a shared socket. Docker is used for administrative image publishing, while pipeline builds use BuildKit. |
| Postfix | Dockerfile installs Postfix; `postconf` configures the image and `postfix start-fg` runs under `/bin/sh`. Queue inspection uses Postfix tools in the container. No host Postfix installation is needed. |
| Box portal reference guide | Docker/registry access for building in the external application checkout, Node.js/npm for its documented `npm run setup:oidc --workspace backend` helper, OpenSSL for session-secret generation, and `curl` for its health check. The sandbox deploy script consumes prepared JSON files and an existing image. |

## Optional documentation and validation tools

`openssl` (package `openssl`) is required when following the Jenkins/portal
secret-generation examples; it is not invoked by their deploy scripts. `curl`
is needed for the portal guide's HTTP check. The SMTP validation procedure needs
an SMTP client and a host outside the LAN, but does not mandate a particular
client. Network troubleshooting images in `test/` supply their own utilities.

Rendering `docs/c4/*.puml` locally requires PlantUML and a Java runtime, with
Graphviz (`dot`) for the diagrams' layout. The files use `!includeurl` for
C4-PlantUML, so rendering needs access to the referenced GitHub content or a
locally configured copy. Reading Markdown alone requires none of these tools.
ShellCheck is specified by the planned NFS HA script validation; existing app
scripts have no automated test harness or mandatory local ShellCheck step.

## Read-only prerequisite checks

Run these on the intended operator host. They check tool availability without
sourcing secrets, installing packages, building images, or deploying resources:

```bash
bash --version
for tool in microk8s envsubst base64 tr dirname cat date mkdir mktemp cp mv rm rmdir head sort tee cut sleep sed grep xargs; do
  command -v "$tool" || printf 'Missing tool: %s\n' "$tool"
done
microk8s status
microk8s kubectl get nodes
microk8s helm version
microk8s helm3 version
```

For the selected additional workflow, also check `docker version` (client and
daemon), `aws --version`, `curl --version`, `openssl version`, or
`tar --version` and `gzip --version`. Before local cluster backup/restore,
inspect `systemctl list-unit-files 'snap.microk8s.*'`. Successful tool checks do
not validate credentials, image availability, writable paths, or cluster RBAC;
use the component's documented status checks to validate its deployed result.
