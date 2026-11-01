# Self Hosted NTFY Service

Self hosted [NTFY](https://docs.ntfy.sh/) service 

## Features:

* *URL:* https://ntfy.johnkoepp.com
* *Public:* False
* *User Management and Auth Control:* Single Auth Token
* *Persistent Message Cache:* True
* *Namespace:*: ntfy

## Kubernetes Resources Required

The following Kubernetes resources will be required.

### Namespace

```
apiVersion: v1
kind: Namespace
metadata:
  name: ntfy
  labels:
    koeppster.net/aws_enabled: "true"
```

### Stateful Set

Deployed as a stateful set with PVCs for the Auth DB and Cache DB 
and a configMap for the server config

``` Example
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ntfy
  namespace: ntfy
spec:
  selector:
    matchLabels:
      app: ntfy
  serviceName: ntfy
  template:
    metadata:
      labels:
        app: ntfy
    spec:
      containers:
      - name: ntfy
        image: binwiederhier/ntfy:v2.36.0
        args: ["serve", "--cache-file", "/var/cache/ntfy/cache.db"]
        ports:
        - containerPort: 80
          name: http
        env:
        - name: NTFY_AUTH_USERS
          valueFrom:
            secretKeyRef:
              name: ntfy
              key: NTFY_AUTH_USERS
        - name: NTFY_AUTH_ACCESS
          valueFrom:
            secretKeyRef:
              name: ntfy
              key: NTFY_AUTH_ACCESS
        - name: NTFY_AUTH_TOKENS
          valueFrom:
            secretKeyRef:
              name: ntfy
              key: NTFY_AUTH_TOKENS
        volumeMounts:
        - name: config
          mountPath: "/etc/ntfy"
          readOnly: true
        - name: cache
          mountPath: "/var/cache/ntfy"
        - name: users
          mountPath: "/var/lib/ntfy"
      volumes:
        - name: config
          configMap:
            name: ntfy
        - name: cache
          persistentVolumeClaim:
            claimName: cache
        - name: users
          persistentVolumeClaim:
            claimName: users
```

### PVCs

PVCs for Auth File and Cache File `volume`s referenced in the [Stateful Set](#stateful-set)

* *Storage Class*: kube-nfs
* *Size*: 10MiB

### Service

Single service mapping port TCP 80 to same target port in [Stateful Set](#stateful-set)

### Gateway (HTTP Routes)

Standard cluster HTTPS routes for public ingess and SSL termination.  Be sure http redirects to https.
See [meshcentral-gateway.yaml](../meshcentral/manifests/meshcentral-gateway.yaml) as an example.

* *hostname:* ntfy.johnkoepp.com

## Server Config File

Passed as the `configMap` referenced in the [Stateful Set](#stateful-set)

``` Config Map Contents
# Server
base-url: "https://ntfy.johnkoepp.com"
behind-proxy: true

# Access control
auth-file: "/var/lib/ntfy/auth.db"
auth-default-access: "deny-all"
enable-login: true
require-login: true

# Message cache
cache-file: "/var/cache/ntfy/cache.db"

# Upstream
upstream-base-url: "https://ntfy.sh"
```

## Environment Variables

Passed as Kubernetes Secrets.

* *Secret Name:* ntfy

``` Secrets
NTFY_AUTH_USERS=<from .env file>
NTFY_AUTH_ACCESS=<from .env file>
NTFY_AUTH_TOKENS=<from .env file>
```


## Deploy and manage

The endpoint uses the shared public Gateway and TLS certificate; “Public: False”
means publishing and subscribing require authentication. The web app requires
login. ntfy also supports password login for the provisioned account; the shared
token is the credential intended for publishing/subscribing clients.

Prerequisites: the NFS CSI driver and `kube-nfs` StorageClass, plus
`infrastructure/johnkoepp-com-gateway` with `http` and `https` listeners and a
certificate covering `ntfy.johnkoepp.com`. Run these scripts from any directory;
they resolve manifests and `.env` relative to their own location.

```bash
cp ntfy/.env.sample ntfy/.env
chmod 600 ntfy/.env
# Edit ntfy/.env and replace the password hash and token placeholders.
./ntfy/scripts/check-deploy.sh --render
./ntfy/scripts/deploy.sh
./ntfy/scripts/check-deploy.sh
```

`--render` prints only non-secret manifests and uses preview checksum values.
`deploy.sh` templates only the Secret and StatefulSet annotations, applies the
resources, waits for rollout, and runs the NFS shutdown dry run to verify that
`statefulset ntfy/ntfy` is discovered. The image is pinned to `v2.36.0` (the full
release tag for the README's v2.36 example).

### Credentials and rotation

The ignored `.env` supplies all three Secret keys. Use one regular user, one ACL,
and one token, as shown in `.env.sample`. The ntfy formats are:

- `NTFY_AUTH_USERS`: `username:bcrypt-password-hash:user`
- `NTFY_AUTH_ACCESS`: `username:topic-pattern:rw` (use `*` for all topics)
- `NTFY_AUTH_TOKENS`: `username:tk_<29 lowercase letters or digits>:description`

Generate a password hash interactively with
`docker run --rm -it binwiederhier/ntfy:v2.36.0 user hash`.
Keep values single quoted in `.env` so Bash preserves bcrypt dollar signs.
The deploy script preserves whitespace when encoding Secret values. Never commit
`.env`, rendered Secrets, or the live token.

To rotate credentials or change access, edit `.env` and rerun `deploy.sh`.
Checksums of the Secret and ConfigMap in the pod template trigger a rollout when
these inputs change. ntfy reconciles provisioned users, ACLs, and tokens at
startup; manage this account through `.env` so subsequent deploys stay consistent.
See the [ntfy access-control documentation](https://docs.ntfy.sh/config/#access-control).

### Verify access and message persistence

After deploying, check the HTTPRoute conditions (`Accepted` and `ResolvedRefs`)
and the redirect:

```bash
microk8s kubectl -n ntfy describe httproute ntfy-route ntfy-redirect
curl -I http://ntfy.johnkoepp.com
# Must return an authorization error (401/403), without publishing a message:
curl -i -d 'anonymous check' https://ntfy.johnkoepp.com/stack-check
# Set NTFY_TOKEN to only the tk_... token, then test authenticated publishing:
curl -H "Authorization: Bearer ${NTFY_TOKEN}" \
  -d 'persistent cache check' https://ntfy.johnkoepp.com/stack-check
microk8s kubectl -n ntfy rollout restart statefulset/ntfy
microk8s kubectl -n ntfy rollout status statefulset/ntfy --timeout=5m
curl -H "Authorization: Bearer ${NTFY_TOKEN}" \
  'https://ntfy.johnkoepp.com/stack-check/json?poll=1&since=all'
```

The authenticated poll should still include the message after restart. Each PVC
requests 10Mi on `kube-nfs` with `ReadWriteOnce`, matching the specification.
NFS CSI requests do not necessarily enforce a filesystem quota; monitor actual
usage and increase the requested capacity/export capacity if needed. Keep one
replica because both SQLite databases are shared through these claims. The
Gateway route disables request deadlines for long-lived subscriptions.

### NFS maintenance and teardown

The StatefulSet mounts `cache` and `users` directly. This is covered by the shared
maintenance scripts without changing them:

```bash
./bin/shutdown-nfs-workloads.sh --dry-run
./bin/shutdown-nfs-workloads.sh
./bin/restore-nfs-workloads.sh --dry-run
./bin/restore-nfs-workloads.sh
```

Run shutdown before NFS maintenance and restore after NFS is healthy. Shutdown
records `statefulset/ntfy` and its replica count; restore starts StatefulSets
before Deployments. The restore dry run needs the state file produced by a real
shutdown. Do not run a real shutdown just to test discovery.

```bash
# Remove routes, workload, Service, ConfigMap, and Secret; retain both databases:
./ntfy/scripts/destroy.sh
# Delete the PVCs and namespace as well (permanently deletes NFS data with Delete policy):
./ntfy/scripts/destroy.sh --purge-data
```

Back up both database directories while ntfy is stopped before purging or doing
storage maintenance. A regular deploy after a regular teardown reuses the claims.

## Artifact validation

Validated the non-secret rendered manifests with `microk8s kubectl apply
--dry-run=client` and checked Bash syntax. An isolated Docker run of the pinned
image verified health checks, denial of anonymous publishing/subscribing,
authenticated publishing, cache/auth persistence across container recreation,
and rejection of the previous token after rotation. Secret rendering was checked
for preservation of bcrypt dollar signs and token-description whitespace.

Both NFS maintenance scripts were exercised in dry-run mode with rows derived
from these manifests. The live cluster shutdown dry run also completed, but ntfy
was not yet deployed. `deploy.sh` performs the required live ntfy discovery check
after rollout. Actual NFS mounting, Gateway routing/TLS, and public DNS still
need verification after deployment with live credentials.
