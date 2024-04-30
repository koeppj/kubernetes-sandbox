# MicroK8S setups for Koeppsters Lab

## Items Incuded

- Multus network setup
- AWS Secrets
- AWS ECR Token Refesh Job Setup
- TLS Certificate Generation using [cert-manager](https://microk8s.io/docs/addon-cert-manager) and [Let's Encrypt](https://letsencrypt.org/)
- Automatic creaation of [AWS Route53](https://aws.amazon.com/route53/) A Records base on [Certificate](https://cert-manager.io/v1.8-docs/reference/api-docs/#cert-manager.io/v1.Certificate) resoures.