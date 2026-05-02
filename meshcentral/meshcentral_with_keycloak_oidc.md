# MicroK8s MeshCentral Setup

## Goal

Deploy MeshCentral on an existing MicroK8s cluster using Envoy Gateway, MetalLB, storage class `kube-nfs`, and Keycloak OIDC.

## Environment Assumptions

* MicroK8s control plane host already running
* Envoy Gateway / Gateway API already configured
* Existing HTTPS ingress on port 443
* DNS hostname: `mesh.johnkoepp.com`
* Keycloak available at `https://idp.johnkoepp.com`
* StorageClass: `kube-nfs`

## Recommended Architecture

```text
Internet -> Router 443 -> Envoy Gateway -> MeshCentral Service -> Pod -> PVC
```

## Namespace

```bash
kubectl create namespace meshcentral
```

## Sample Manifest

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: meshcentral-data
  namespace: meshcentral
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: kube-nfs
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: meshcentral
  namespace: meshcentral
spec:
  replicas: 1
  selector:
    matchLabels:
      app: meshcentral
  template:
    metadata:
      labels:
        app: meshcentral
    spec:
      containers:
        - name: meshcentral
          image: ghcr.io/ylianst/meshcentral:latest-slim
          ports:
            - containerPort: 4430
          volumeMounts:
            - name: data
              mountPath: /opt/meshcentral/meshcentral-data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: meshcentral-data
---
apiVersion: v1
kind: Service
metadata:
  name: meshcentral
  namespace: meshcentral
spec:
  type: ClusterIP
  selector:
    app: meshcentral
  ports:
    - port: 4430
      targetPort: 4430
```

## HTTPRoute

Route hostname `mesh.johnkoepp.com` to service `meshcentral:4430`.

## Keycloak OIDC + JIT Provisioning

### Keycloak Group Design

```text
/mesh-admins
/mesh-users
/mesh-readonly
```

### Keycloak Client Notes

* Client ID: `meshcentral`
* Protocol: OpenID Connect
* Confidential client
* Redirect URI: `https://mesh.johnkoepp.com/auth-oidc-callback`
* Web Origin: `https://mesh.johnkoepp.com`

### Required Group Mapper

Configure a Group Membership mapper so the token includes:

```json
{
  "groups": ["/mesh-admins", "/mesh-users"]
}
```

### Kubernetes Secret (Full Config File) (Full Config File)

````yaml
apiVersion: v1
kind: name: meshcentral-confige: meshcentral-config
  namespace: meshcentral
type: config.json: |
    {
      "settings": {
        "cert": "mesh.johnkoepp.com",
        "port": 4430,
        "aliasPort": 443,
        "TLSOffload": true
      },
      "domains": {
        "": {
          "newAccounts": true,
          "authStrategies": {
            "oidc": {
              "issuer": "https://idp.johnkoepp.com/realms/homelab",
              "clientid": "meshcentral",
              "clientsecret": "REPLACE_WITH_REAL_SECRET"
            }
          }
        }
      }
    }  {
  ### CONFIG_FILE Environment Variablec```yaml
env:
- name: CONFIG_FILE
  value: /run/secrets/meshcentral/config.json

volumeMounts:
- name: config
  mountPath: /run/secrets/meshcentral
  readOnly: true

volumes:
- name: config
  secret:
    secretName: meshcentralcom",
        "port": 4430,
        "aliasPort": 443,
        "TLSOffload": true
      },
      "domains": {
        "": {
          "newAccounts": true,
          "authStrategies": {
            "oidc": {
              "issuer": "https://idp.johnkoepp.com/realms### Startup Patternclientid": "meshcentral",
              "clientsecret": "REPLACE_WITHkubectl rollout restart deploy/meshcentral -n meshcentralvironment Variable
```json
{
  "domains": {
    "": {
      "newAccounts": true,
      "authStrategies": {
        "oidc": {
          "issuer": "https://idp.johnkoepp.com/realms/homelab",
          "clientid": "meshcentral /config/config.template.json > /opt/meshcentral/meshcentral-data/config.json
````

### Provisioning Model

1. User logs in through Keycloak.
2. MeshCentral receives OIDC claims.
3. If user does not exist and `newAccounts=true`, account is created.
4. Use first login to bootstrap admin rights.
5. Later restrict access by Keycloak group membership.

### Recommended Bootstrap

1. Enable `newAccounts: true`
2. Login as your Keycloak admin user
3. Grant MeshCentral admin rights
4. Restrict Keycloak client to approved users
5. Optionally disable broad self-registration later

## Validation

```bash
kubectl -n meshcentral get all
kubectl -n meshcentral get pvc
kubectl -n meshcentral logs deploy/meshcentral
```
