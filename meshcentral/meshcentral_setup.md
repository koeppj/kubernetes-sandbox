# MicroK8s MeshCentral Setup

## Goal

Deploy MeshCentral on the existing MicroK8s cluster using the project-standard app stack pattern:

- Gateway API routes through the shared `johnkoepp-com-gateway`
- NFS-backed persistence through the existing `kube-nfs` StorageClass
- Keycloak OIDC for authentication
- Component-local `.env` and `secrets/` files for live values
- Component-local `scripts/` for deploy, destroy, and validation helpers
- Component-local `manifests/` for Kubernetes resources

MeshCentral should be deployed as a namespace-scoped app, matching the approach used by `n8n/`, `keyclock/`, and `grafana+loki/`.

## Environment Assumptions

- MicroK8s control plane is already running.
- Gateway API / Envoy Gateway is already configured.
- Public traffic enters through the shared `johnkoepp-com-gateway`.
- DNS hostname: `mesh.johnkoepp.com`.
- Keycloak is available at `https://idp.johnkoepp.com`.
- StorageClass `kube-nfs` already exists.
- Commands are run with `microk8s kubectl`, not plain `kubectl`.

## Recommended Architecture

```text
Internet -> Router 443 -> johnkoepp-com-gateway -> MeshCentral Service -> Pod -> PVC
```

## Recommended Directory Layout

When MeshCentral is implemented, use the same app-local contract as the other stacks:

```text
meshcentral/
  .env
  .env.sample
  .gitignore
  meshcentral_setup.md
  manifests/
    namespace.yaml
    meshcentral-pvc.yaml
    meshcentral-deployment.yaml
    meshcentral-service.yaml
    meshcentral-gateway.yaml
  scripts/
    deploy.sh
    destroy.sh
    check-deploy.sh
  secrets/
    .gitignore
    README.md
    config.json
    config.json.sample
```

Expected ownership:

- `.env` stores component-local deploy values and is treated as sensitive.
- `.env.sample` stores placeholder values only and stays synchronized with `.env`.
- `secrets/config.json` stores the live full MeshCentral configuration file and is not committed.
- `secrets/config.json.sample` stores a placeholder-only full MeshCentral configuration example.
- `manifests/` stores raw Kubernetes YAML.
- `scripts/deploy.sh` is the entrypoint for creating or updating the stack.
- `scripts/destroy.sh` tears down the stack in reverse dependency order.
- `scripts/check-deploy.sh` prints useful validation state without changing resources.

## Environment File

Keep runtime-specific values in `meshcentral/.env`.

Example `.env.sample`:

```bash
MESH_NAMESPACE=meshcentral
MESH_HOSTNAME=mesh.johnkoepp.com
MESH_STORAGE_CLASS=kube-nfs
MESH_STORAGE_SIZE=5Gi
MESH_SERVICE_PORT=4430
MESH_IMAGE=ghcr.io/ylianst/meshcentral:latest-slim
```

Do not put the Keycloak client secret in `.env` if the deployment uses the full `secrets/config.json` file. In that model, the OIDC secret lives only inside the uncommitted full JSON config.

## Full MeshCentral Config

Use a complete MeshCentral `config.json` file instead of assembling partial configuration through environment variables. This keeps MeshCentral configuration reviewable as one file and avoids mixing JSON generation into the Deployment manifest.

`secrets/config.json.sample` should contain the full shape with placeholder values:

```json
{
  "settings": {
    "cert": "mesh.johnkoepp.com",
    "port": 4430,
    "aliasPort": 443,
    "TLSOffload": true
  },
  "domains": {
    "": {
      "authStrategies": {
        "oidc": {
          "newAccounts": true,
          "issuer": "https://idp.johnkoepp.com/realms/homelab",
          "clientid": "meshcentral",
          "clientsecret": "REPLACE_WITH_KEYCLOAK_CLIENT_SECRET",
          "groups": {
            "required": ["mesh-admins", "mesh-users"],
            "siteadmin": ["mesh-admins"],
            "claim": "groups"
          }
        },
      }
    },
  }
}
```

The live `secrets/config.json` should be copied from the sample and updated locally with the real Keycloak client secret. Do not commit the live file.

## Secret Management

The deploy script should create the Kubernetes Secret from the full JSON file:

```bash
microk8s kubectl create secret generic meshcentral-config \
  -n "${MESH_NAMESPACE}" \
  --from-file=config.json="${secrets_dir}/config.json" \
  --dry-run=client \
  -o yaml | microk8s kubectl apply -f -
```

This is the preferred pattern for MeshCentral because the application expects a full JSON config file and because the config contains secrets. Avoid committing a Kubernetes Secret manifest with real values.

The Deployment should mount that Secret as a read-only file and point MeshCentral at it:

```yaml
env:
  - name: CONFIG_FILE
    value: /run/secrets/meshcentral/config.json

volumeMounts:
  - name: meshcentral-config
    mountPath: /run/secrets/meshcentral
    readOnly: true

volumes:
  - name: meshcentral-config
    secret:
      secretName: meshcentral-config
```

## Manifests

### Namespace

Create a dedicated namespace for MeshCentral. If the namespace needs AWS ECR credentials later, include the standard label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${MESH_NAMESPACE}
  labels:
    koeppster.net/aws_enabled: "true"
```

If MeshCentral only uses public images, the AWS label is optional.

### PVC

Use the existing NFS-backed `kube-nfs` StorageClass unless MeshCentral needs a dedicated NFS export.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: meshcentral-data
  namespace: ${MESH_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${MESH_STORAGE_CLASS}
  resources:
    requests:
      storage: ${MESH_STORAGE_SIZE}
```

Use `ReadWriteOnce` for the single MeshCentral pod. Switch to `ReadWriteMany` only if the deployment model later requires multiple writers.

### Deployment

The Deployment should:

- run a single replica unless clustering is intentionally added later
- mount `meshcentral-data` at `/opt/meshcentral/meshcentral-data`
- mount the full `config.json` Secret read-only
- set `CONFIG_FILE=/run/secrets/meshcentral/config.json`
- expose container port `4430`

### Service

Expose MeshCentral inside the namespace with a `ClusterIP` Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: meshcentral
  namespace: ${MESH_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: meshcentral
  ports:
    - port: ${MESH_SERVICE_PORT}
      targetPort: 4430
```

### HTTPRoute

Use Gateway API, not Ingress. Public access should attach to `johnkoepp-com-gateway` in the `infrastructure` namespace.

Provide both:

- an HTTPS route forwarding to the MeshCentral Service
- an HTTP redirect route labeled for Route53 automation
- required `X-Forwarded-*` headers on the HTTPS route

The redirect route should include:

```yaml
labels:
  koeppster.net/aws_common_name: mesh.johnkoepp.com
  koeppster.net/aws_status: waiting
```

The HTTPS route must follow the existing Keycloak route pattern and set forwarded headers before proxying to MeshCentral:

```yaml
filters:
  - type: RequestHeaderModifier
    requestHeaderModifier:
      set:
        - name: X-Forwarded-Proto
          value: https
        - name: X-Forwarded-Host
          value: mesh.johnkoepp.com
        - name: X-Forwarded-Port
          value: "443"
```

## Deploy Script

`scripts/deploy.sh` should follow the existing shell script pattern:

1. Resolve `SCRIPT_DIR` from `BASH_SOURCE[0]`.
2. `source "${SCRIPT_DIR}/../.env"`.
3. Export `manifests_dir` and `secrets_dir`.
4. Validate that `secrets/config.json` exists before applying resources.
5. Apply resources in dependency order:
   - namespace
   - full `config.json` Secret
   - PVC
   - Deployment
   - Service
   - HTTPRoute
6. Use `envsubst` only for manifests that intentionally contain deploy-time placeholders.

Suggested structure:

```bash
#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "${SCRIPT_DIR}/../.env"
export manifests_dir="${SCRIPT_DIR}/../manifests"
export secrets_dir="${SCRIPT_DIR}/../secrets"

if [ ! -f "${secrets_dir}/config.json" ]; then
  echo "Missing ${secrets_dir}/config.json"
  exit 1
fi

envsubst < "${manifests_dir}/namespace.yaml" | microk8s kubectl apply -f -

microk8s kubectl create secret generic meshcentral-config \
  -n "${MESH_NAMESPACE}" \
  --from-file=config.json="${secrets_dir}/config.json" \
  --dry-run=client \
  -o yaml | microk8s kubectl apply -f -

envsubst < "${manifests_dir}/meshcentral-pvc.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/meshcentral-deployment.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/meshcentral-service.yaml" | microk8s kubectl apply -f -
envsubst < "${manifests_dir}/meshcentral-gateway.yaml" | microk8s kubectl apply -f -
```

## Destroy Script

`scripts/destroy.sh` should delete resources in reverse dependency order and use `--ignore-not-found=true`:

```bash
#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

source "${SCRIPT_DIR}/../.env"
export manifests_dir="${SCRIPT_DIR}/../manifests"

microk8s kubectl delete -f "${manifests_dir}/meshcentral-gateway.yaml" --ignore-not-found=true
microk8s kubectl delete -f "${manifests_dir}/meshcentral-service.yaml" --ignore-not-found=true
microk8s kubectl delete -f "${manifests_dir}/meshcentral-deployment.yaml" --ignore-not-found=true
microk8s kubectl delete -f "${manifests_dir}/meshcentral-pvc.yaml" --ignore-not-found=true
microk8s kubectl delete secret meshcentral-config -n "${MESH_NAMESPACE}" --ignore-not-found=true
microk8s kubectl delete -f "${manifests_dir}/namespace.yaml" --ignore-not-found=true
```

If preserving MeshCentral data is required, remove the PVC deletion from the default destroy script or add a separate destructive cleanup script.

## Keycloak OIDC

### Group Design

```text
/mesh-admins
/mesh-users
/mesh-readonly
```

### Client Settings

- Client ID: `meshcentral`
- Protocol: OpenID Connect
- Client type: confidential
- Redirect URI: `https://mesh.johnkoepp.com/auth-oidc-callback`
- Web origin: `https://mesh.johnkoepp.com`

## Bootstrap Model

Recommended first-run flow:

1. Set `"newAccounts": true` in `secrets/config.json`.
2. Deploy MeshCentral.
3. Log in through Keycloak with the intended admin user.
4. Grant MeshCentral admin rights inside MeshCentral.
5. Restrict the Keycloak client to approved users or groups.
6. Optionally disable broad self-registration later.
7. Redeploy or restart the Deployment after updating `secrets/config.json`.

To force MeshCentral to reload a changed Secret-mounted config:

```bash
microk8s kubectl rollout restart deploy/meshcentral -n meshcentral
```

## Validation

Use `scripts/check-deploy.sh` for a repeatable status view. It should include:

```bash
microk8s kubectl -n meshcentral get all
microk8s kubectl -n meshcentral get pvc
microk8s kubectl -n meshcentral get secret meshcentral-config
microk8s kubectl -n meshcentral logs deploy/meshcentral
microk8s kubectl -n meshcentral get httproute
```

Manual route validation:

```bash
microk8s kubectl -n meshcentral describe httproute meshcentral-route
microk8s kubectl -n meshcentral describe httproute meshcentral-redirect
```
