# Infrastructure Namespace Setups

## Overview

## Instructions

To create run the following script.  Assumes aws cli configuration file present
in ~/.aws/config and has beem configured with the appropriate AWS Key ID, AWS Access Key
and AWS Default Region+

```
# ./create-infrastructure.sh
```

## Components

The following files comprise the items used to create the `infrastructure` namespace and resoruces contained therein.
- [`create-infrastructure.sh`](./create-infrastructure.sh) - The shell script to run.
- [`awsecr.Dockerfile`](./awsecr.Dockerfile) - Used to create the docker image that is used to generate an AWS ECR Docker Login token.
- [`awsdns.Dockerfile`](./ewsdns.Dockerfile) - Used to create the docker image that is used to generate an AWS Route53 A Records based on Certificates.
- [`aws-ecr-role-and-cron.yaml`](./aws-ecr-role-and-cron.yaml) - A K8S manifest that defines the a service account, RBAC role and cronjob used to periodically update AWS ECR Docker Login ticket and attach it to the `default` service account of the configured `namespace`s
- [`create-aws-credentials.yaml`](./create-aws-credentials.yaml) - A K8S manifest that defines defines the AWS Credentials `secret` in both the `infrastructure` and `default` namespaces (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION`).
- `create-cert-issuer.yaml` - A K83 manifest to create a LetsEncrypt based `CusterIssuer` using [cert-manager](https://cert-manager.io/)
- [`create-storage-class.yaml`](./create-storage-class.yaml) - A K8S manifest to create a `StorageClass` based on the [NFS CSI](https://github.com/kubernetes-csi/csi-driver-nfs) storage driver.  Based on [this](https://microk8s.io/docs/how-to-nfs) how-to.
- [`create-awsdns-updater.yaml`](./create-awsdns-updater.yaml) - A K83 manifest to create a pod that continuously checks Certificates and creates AWS Route53 A records as required.
- [`create-records.sh`](./create-records.sh) - Shell script that does the work of UPSERTing AWS Route53 A records based on Certificates.  See [AWSDNS](./awsdns.Dockerfile) Dockerfile.
