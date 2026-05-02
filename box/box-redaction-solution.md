# Box Redaction Solution Deployment

This component deploys a single-replica `Deployment` based on the image `996472359368.dkr.ecr.us-east-1.amazonaws.com/boxredact:latest`. The Docker image itself is a basic standalone static web deployment
with no dependencies. It will be publicly available on https://boxredact.johnkoepp.com via the
public existing gateway `johnkoepp-com-gateway`. All artifacts are deployed in the `box` namespace.

## Kubernetes Artifacts

Located in [manifests](./manifests)

| Name | Type and Use |
|------|---------------|
| `namespace` | Namespace for the app (Box). |
| `box-redaction-service` | `Service` plus `Deployment` that runs one replica of the app. |
| `box-redaction-route` | HTTPRoute attached to `johnkoepp-com-gateway` for FQDN `boxredact.johnkoepp.com` |

## Scripts

Located in [scripts](./scripts)

| Script | Usage |
|--------|-------|
| `deploy-redact.sh` | Create or update all component resources. |
| `destroy-redact.sh` | Remove the component from the cluster. |
