# Infrastructure Namespace Setups

## Overview

** To Dos

- [x] Update [create-infrstructure](create-infrastructure.sh) to exclude KWASM plugin and include SpinKube install.

## Instructions

### Assumptions

Assumes and environment configuration file is pressent in <project_root>/.env that contains the following:

```
export aws_default_region=<default region>
export aws_access_key_id=<aws access key id to use - DON'T USE ROOT KEY!!!>
export aws_secret_access_key=<aws secret key assosciated with the above key id>
export aws_hosted_zone_id=<aws route53 zone ID that will be used by cert-manager>
export ecrtoken_issuer_schedule="0 */8 * * *"
export cert_issuer_mode=<prod | stage>
export nfs_server_id=<ip address of NFS Server by storage NFS CNI Storage>
```

Make sure all nodes are joined to cluster before running the script.

Label specific nodes in the following manner:
* Nodes with wired connections (i.e. supporting promiscous mode) should have a label of `net:wired`
* Neither AWS updater requires the `local-registry` node label; both use images imported onto all cluster nodes.

### Installation

To create run environment the following script.  

```
# ./create-infrastructure.sh
```

### AWS ECR updater image deployment

From the repository root, build, import, and deploy the updater with:

```bash
./infrastruture/redeploy-awsecr-updater.sh
```

Both this entrypoint and `create-infrastructure.sh` call
`scripts/build-import-awsecr.sh`. The helper builds `awsecr:1.0.0`, saves it with
`docker save -o <archive> awsecr:1.0.0`, and distributes it to the current cluster
nodes with `microk8s images import < <archive>`. The temporary archive is removed
on exit, and an unsuccessful build or import stops deployment. The redeploy
script applies the CronJob and RBAC in place after import succeeds.

The CronJob uses `imagePullPolicy: Never` and has no registry node affinity.
Every eligible node must have the image locally; a missing image prevents the
Pod from starting. Use MicroK8s 1.25 or newer for cluster-wide image import, and
ensure the build architecture matches the nodes (currently all amd64).

For image changes, use a new version in the helper, CronJob manifest, and
`../test/test-awsecr-pod.yaml`, then redeploy. Import the new version on every
node before applying the new CronJob. Retain the previous image version for
rollback; restore its manifest tag and re-import that image if necessary.
After adding or rebuilding nodes, import the deployed image again before
allowing the updater to schedule there. For an existing Docker image:

```bash
docker save -o /tmp/awsecr-1.0.0.tar awsecr:1.0.0
microk8s images import < /tmp/awsecr-1.0.0.tar
```

This distributes the existing build without rebuilding or changing its tag.
Remove the archive after a successful import. Re-import is also necessary if
a node's local copy is removed by image cleanup.

### AWS DNS updater image deployment

From the repository root, build, import, and deploy the DNS updater with:

```bash
./infrastruture/redeploy-awsdns-updater.sh
```

Both this entrypoint and `create-infrastructure.sh` call
`scripts/build-import-awsdns.sh`, which builds `awsdns:1.0.0`, saves a temporary
archive with `docker save -o <archive> awsdns:1.0.0`, and distributes it using
`microk8s images import < <archive>`. Build or import failures stop deployment;
temporary archives are cleaned up on exit. MicroK8s 1.25 or newer is required,
and the build architecture must match the nodes (currently all amd64).

The shared `scripts/deploy-awsdns.sh` helper discovers and validates the public
IPv4 address, substitutes only `${kube_host_ip}`, and validates the manifest
with a server-side dry run. It then deletes only the legacy standalone
`infrastructure/awsdns` Pod, waits for termination, applies the Deployment and
RBAC in place, and waits up to five minutes for rollout. The existing
`aws-credentials` Secret must already exist; infrastructure setup creates it
before calling the helper.

The Deployment runs one replica with `imagePullPolicy: Never` and no registry
node affinity. Its `Recreate` strategy stops the previous worker before starting
the replacement during upgrades, briefly pausing DNS processing. This does not
provide distributed locking during node failures. The updater continues to
check labeled Certificates and HTTPRoutes every 30 seconds.

For image changes, bump the version in `scripts/build-import-awsdns.sh` and
`create-awsdns-updater.yaml`, then run the redeploy entrypoint. Rebuilding an
unchanged tag does not trigger a Deployment rollout. A changed public IP updates
the Pod template, but existing records labeled `updated` are not automatically
reprocessed by the current updater.

Retain previous images for rollback. Re-import the previous image if needed,
restore its manifest tag, and run `scripts/deploy-awsdns.sh` to apply it without
rebuilding. After adding or rebuilding nodes, or removing cached images, import
the deployed image again before allowing the updater to schedule there:

```bash
docker save -o /tmp/awsdns-1.0.0.tar awsdns:1.0.0
microk8s images import < /tmp/awsdns-1.0.0.tar
```

Remove the archive after successful import. A node missing the image cannot
start the updater because registry pulls are disabled.

Check rollout and logs with:

```bash
microk8s kubectl -n infrastructure rollout status deployment/awsdns --timeout=5m
microk8s kubectl -n infrastructure get pods -l app=awsdns -o wide
microk8s kubectl -n infrastructure logs deployment/awsdns --tail=100
./bin/shutdown-nfs-workloads.sh --dry-run
```

The DNS Deployment mounts no PVCs, so it is excluded from NFS maintenance
shutdown discovery and the resulting restore state.

### On-demand AWS ECR refresh

The AWS ECR updater normally runs on its CronJob schedule. To run it immediately
and wait for the refresh to finish, execute:

```bash
./infrastruture/scripts/run-secrets-job.sh
```

The Job refreshes `aws-ecr-secret` and the `default` ServiceAccount in every
namespace labeled `koeppster.net/aws_enabled=true`. The script prints the Job
logs and exits nonzero if the refresh fails or does not complete within five
minutes.

## Components

The following files comprise the items used to create the `infrastructure` namespace and resoruces contained therein.
- [`create-infrastructure.sh`](./create-infrastructure.sh) - The shell script to run.
- [`awsecr.Dockerfile`](./awsecr.Dockerfile) - Used to create the docker image that is used to generate an AWS ECR Docker Login token.
- [`awsdns.Dockerfile`](./awsdns.Dockerfile) - Builds the AWS Route53 updater image for labeled Certificates and HTTPRoutes.
- [`aws-ecr-role-and-cron.yaml`](./aws-ecr-role-and-cron.yaml) - A K8S manifest that defines the a service account, RBAC role and cronjob used to periodically update AWS ECR Docker Login ticket and attach it to the `default` service account of the configured `namespace`s
- [`create-gateways.yaml`](./create-gateways.yaml) - A K8S resource manifest to create the two general use HTTP/S gateways deployed.
- [`create-aws-credentials.yaml`](./create-aws-credentials.yaml) - A K8S manifest that defines defines the AWS Credentials `secret` in both the `infrastructure` and `default` namespaces (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION`).
- [`create-gateway-cert.yaml`](./create-gateway-cert.yaml) -The TLS Certificte resource for the public facing gateway (johnkoepp.com)
- `create-cert-issuer.yaml` - A K83 manifest to create a LetsEncrypt based `CusterIssuer` using [cert-manager](https://cert-manager.io/)
- [`create-storage-class.yaml`](./create-storage-class.yaml) - A K8S manifest to create a `StorageClass` based on the [NFS CSI](https://github.com/kubernetes-csi/csi-driver-nfs) storage driver.  Based on [this](https://microk8s.io/docs/how-to-nfs) how-to.
- [`create-awsdns-updater.yaml`](./create-awsdns-updater.yaml) - Defines the single-replica DNS updater Deployment, ServiceAccount, and RBAC.
- [`create-records.sh`](./create-records.sh) - Shell script that does the work of UPSERTing AWS Route53 A records based on Certificates.  See [AWSDNS](./awsdns.Dockerfile) Dockerfile.
- [`redeploy-awsdns-updater.sh`](./redeploy-awsdns-updater.sh) - Shell script to redeploy the AWS Route53 Updater stuff (for testing and if the public facing IP changes)
- [`redeploy-awsecr-updater.sh`](./redeploy-awsecr-updater.sh) - Shell script to build/deploy the AWS ECR Token components.
- [`scripts/build-import-awsecr.sh`](./scripts/build-import-awsecr.sh) - Builds and imports the versioned ECR updater image onto all cluster nodes.
- [`scripts/build-import-awsdns.sh`](./scripts/build-import-awsdns.sh) - Builds and imports the versioned DNS updater image onto all cluster nodes.
- [`scripts/deploy-awsdns.sh`](./scripts/deploy-awsdns.sh) - Validates and applies the DNS updater, migrates the legacy Pod, and waits for rollout after image import.
- [`scripts/run-secrets-job.sh`](./scripts/run-secrets-job.sh) - Runs the AWS ECR secret-update CronJob immediately and waits for completion.
