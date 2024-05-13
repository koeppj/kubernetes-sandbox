# MicroK8S setups for Koeppster's Lab

## Overview

This project memorializes the setups performed to create my [MicroK8s](https://microk8s.io/) environment.  It can used create/recreate the environment at will and as a model or other learnig, prototype and personal developent environents.

## TO-DO list

- [ ] Update [Notes on Use](#notes-on-use) section.
- [ ] Update [AWS Account Permissions](#aws-account-permissions) section.
- [x] Update [Infrastructure README](/README.md) to include [SpinKube](https://www.spinkube.dev/) install
- [ ] Update for using k8s_gateway

## Items Included

- [Multus](https://github.com/k8snetworkplumbingwg/multus-cni) plug-in for multiple network support (for stuff like macvlans).
- The [Istio](https://istio.io/latest/docs/setup/platform-setup/microk8s/) plug-in [Gateway API Support](https://kubernetes.io/docs/concepts/services-networking/gateway/).
- AWS Secrets
- AWS ECR Token Refesh Job Setup to support pulling images from an [AWS Elastic Container Registry](https://aws.amazon.com/ecr/)
- TLS Certificate Generation using [cert-manager](https://microk8s.io/docs/addon-cert-manager) and [Let's Encrypt](https://letsencrypt.org/)
- Automatic creaation of [AWS Route53](https://aws.amazon.com/route53/) A Records base on [Certificate](https://cert-manager.io/v1.8-docs/reference/api-docs/#cert-manager.io/v1.Certificate) resoures.
- NFS based [StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/) 
- [SpinKube](https://www.spinkube.dev/) for WebAssembly runtime support.
- [k8s_gateway](https://github.com/ori-edge/k8s_gateway) for providing DNS Service for externally exposed [Gateway](https://gateway-api.sigs.k8s.io/) routes.

## Notes on use

### Automated TLS Certificate Generation

Notes:
- Two ClusterIssuers created.  Use cert-issuer-prod for production and cert-issuer-state for test.

### Automated Refresh of AWS ECR Access Tokens.

Notes
- Scoped to namespaces with the label `koeppster.net/aws_enables=true`

### Automated Generation of AWS Route33 A Records

Creates A records for Certificate and HTTPRoute resources.
- Scoped to resources with the label `koeppster.net/aws_status=waiting`
- Will use FQDN in label `koeppster.net/aws_common_name` when creating A record.

### Using k8s_gateway to connect to local lab DNS server

### Gateaways created

Two general purpose HTTP/s gateways creeated.
- johnkoepp-com-gateway - For use with public facing services.
- k8s-koeppster-lan-gateway - For use with lan faceing servies.

## Assumptions and Requirements

- Developed and tested on [Ubuntu 23.10.1 (Mantic Minitaur)](https://aws.amazon.com/ecr/) Server.
- An NFS Server should be exposed and acessible.  See [create-storage-class.yaml](./infrastruture/create-storage-class.yaml) for details.
- I have a private [Amazon Web Services](https://aws.amazon.com/) account, making use of both [AWS Elastic Container Registry](https://aws.amazon.com/ecr/) and [AWS Route53](https://aws.amazon.com/route53//)

### AWS Account Permissions

Whatever AWS account is used to access AWS should have the following policies attached.
