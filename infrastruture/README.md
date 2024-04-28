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
- [`Dockerfile`](./Dockerfile) - Used to create the docker image that is used to generate an AWS ECR Docker Login token.
- [`aws-ecr-role-and-cron.yaml`](./aws-ecr-role-and-cron.yaml) - A K8S template that defines the a service account, RBAC role and cronjob used to periodically update AWS ECR Docker Login ticket and attach it to the `default` service account of the configured `namespace`s
- [`create-aws-credentials.yaml`](./create-aws-credentials.yaml) - A K8S template that defines defines the AWS Credentials `secret` in both the `infrastructure` and `default` namespaces (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION`).
- `create-cert-issuer.yaml` - A K83 template to create a LetsEncrypt based `CusterIssuer` using [cert-manager](https://cert-manager.io/)
- [`create-storage-class.yaml`](./create-storage-class.yaml) - A K8S template to create a `StorageClass` based on the [NFS CSI](https://github.com/kubernetes-csi/csi-driver-nfs) storage driver.  Based on [this](https://microk8s.io/docs/how-to-nfs) how-to.