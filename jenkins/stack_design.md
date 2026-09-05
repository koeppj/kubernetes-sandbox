# Jenkins Stack Design

## Purpose

This stack provides a small, reproducible Jenkins installation for demo builds and deployments on the local MicroK8s cluster. It is intentionally not an enterprise CI/CD platform.

The design supports:

- Jenkins configuration through Configuration as Code (JCasC)
- A pinned Jenkins controller and pinned plugins
- GitHub multibranch Pipelines
- Disposable Kubernetes build agents
- Docker-compatible image builds without mounting a node Docker socket
- Image pushes to the existing AWS ECR registry
- Direct deployment to selected Kubernetes namespaces

The design does not add GitOps, an external secrets manager, a permanent build farm, or a highly available Jenkins controller.

## Target Architecture

```text
GitHub repository
    |
    | HTTPS webhook to /github-webhook/
    | periodic reconciliation scan
    v
Jenkins controller
    | JCasC configuration
    | no local build executors
    |
    +--> Disposable Kubernetes agent
            | test and package application
            | rootless BuildKit sidecar
            | push commit-tagged image to ECR
            | deploy through a limited ServiceAccount
            v
        Application namespace
```

## Repository Layout

The Jenkins component should retain the repository's raw-manifest and script-based deployment pattern.

```text
jenkins/
  .env
  .env.sample
  Dockerfile
  tools.Dockerfile
  plugins.txt
  README.md
  stack_design.md
  casc/
    jenkins.yaml
  manifests/
    aws-credentials-secret.yaml
    github-credentials-secret.yaml
    jenkins-casc-configmap.yaml
    jenkins-deployment.yaml
    jenkins-gateway.yaml
    jenkins-pvc.yaml
    jenkins-rbac.yaml
    jenkins-service.yaml
    jenkins-webhook-gateway.yaml
    namespace.yaml
  scripts/
    build-controller.sh
    build-tools.sh
    check-deploy.sh
    deploy.sh
    destroy.sh
```

Application-specific deployment Roles and RoleBindings should live with the application they authorize rather than in the Jenkins component.

`Dockerfile` and `tools.Dockerfile` are independently versioned administrative images. Neither is built from `deploy.sh`.

## Controller Image

The controller image is built separately from deployment and stored in AWS ECR. Jenkins is not responsible for building the image it needs in order to start.

The image contains:

- A specific Jenkins LTS and JDK version
- The plugins listed in `plugins.txt`
- No live credentials
- No environment-specific JCasC configuration

Example `Dockerfile` shape:

```dockerfile
FROM jenkins/jenkins:2.568.2-jdk21

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt

RUN jenkins-plugin-cli \
    --plugin-file /usr/share/jenkins/ref/plugins.txt
```

The Jenkins base version should be updated deliberately after checking its upgrade notes. Do not use the mutable `lts` tag for the deployed controller.

### Plugin Set

Keep the initial plugin set small:

- `configuration-as-code`
- `credentials-binding`
- `github`
- `github-branch-source`
- `kubernetes`
- `kubernetes-cli`
- `workflow-aggregator`

Each entry in `plugins.txt` must specify an exact version. Transitive dependencies are resolved by `jenkins-plugin-cli`. Plugin changes require building and publishing a new controller image.

### Image Naming

Use a versioned tag that identifies both the Jenkins baseline and the plugin-set revision:

```text
996472359368.dkr.ecr.us-east-1.amazonaws.com/jenkins-controller:2.568.2-plugins-1
```

Do not overwrite a published version tag. Increment the plugin revision or Jenkins version for every controller image change.

For additional reproducibility, the deployment may use the ECR image digest after the initial build has been verified.

### Build Workflow

`scripts/build-controller.sh` should:

1. Resolve its location and source the component `.env`.
2. Validate the ECR account, region, repository, and controller tag variables.
3. Authenticate Docker to ECR with `aws ecr get-login-password`.
4. Build the controller image from `jenkins/Dockerfile`.
5. Push the versioned image to ECR.
6. Print the published tag and digest without printing credentials.

Building the controller is an explicit administrative operation. It is not part of the regular `deploy.sh` path.

### Tools Image Build Workflow

The Kubernetes agent tools container must use a custom, immutable image; plain Alpine does not provide the AWS CLI, `kubectl`, or BuildKit client required by the application pipeline. Build and publish this image through `scripts/build-tools.sh` before deploying a JCasC change that references its tag.

`tools.Dockerfile` should pin all upstream inputs and provide:

- `aws` CLI v2 for requesting ECR authorization and validating the dedicated push identity
- `kubectl` at the Kubernetes version selected for this MicroK8s cluster
- `buildctl` pinned to the same BuildKit release as the sidecar
- `git`, CA certificates, and a POSIX shell for checkout and pipeline commands

The image should be named and tagged independently from the controller, for example:

```text
996472359368.dkr.ecr.us-east-1.amazonaws.com/jenkins-tools:buildkit-0.26.2-tools-1
```

Never install these tools at build time with unpinned package-manager `latest` versions. `build-tools.sh` follows the controller build script's explicit administrative publication model and validates `JENKINS_TOOLS_IMAGE` against `AWS_ACCOUNT_ID`, `JENKINS_TOOLS_REPOSITORY`, and `JENKINS_TOOLS_TAG`.

## Configuration as Code

JCasC remains outside the controller image so configuration can change without rebuilding Jenkins.

`casc/jenkins.yaml` should configure:

- The Jenkins root URL
- Zero executors on the built-in controller node
- The Kubernetes cloud
- The internal Jenkins Service URL used by agents
- A default disposable agent template
- GitHub credentials by reference
- The GitHub webhook URL override and shared-secret credential
- A basic authorization strategy
- Build retention defaults where supported

The configuration should be stored in a ConfigMap and mounted read-only into the controller. The Deployment should set:

```yaml
env:
  - name: CASC_JENKINS_CONFIG
    value: /var/jenkins_casc/jenkins.yaml
```

Secrets referenced by JCasC must come from Kubernetes Secrets or environment variables. Real credentials must never appear in `casc/jenkins.yaml`.

JCasC-managed settings should not also be maintained through the Jenkins UI because UI changes will be replaced on restart.

## Controller Workload

The existing raw Deployment is sufficient for this demo stack with the following changes:

- Use the ECR-hosted, versioned controller image.
- Set `strategy.type: Recreate` so two controllers never use the same Jenkins home concurrently.
- Set the built-in executor count to zero through JCasC.
- Remove the manually created `jenkins-admin-secret` service-account token.
- Mount the JCasC ConfigMap read-only.
- Add a startup probe for slow first starts and plugin initialization.
- Retain the existing readiness and liveness probes.
- Retain the NFS-backed PVC.
- Explicitly reference `aws-ecr-secret` in `imagePullSecrets`.

The explicit image pull secret is necessary because the controller uses `jenkins-admin`, while the existing ECR refresh workflow patches only the namespace's `default` ServiceAccount.

The controller service account should only have the pod permissions required by the Jenkins Kubernetes plugin. Build and deployment permissions belong to separate agent identities.

## ECR Bootstrap and Credentials

The namespace label enables the existing infrastructure CronJob to create and refresh `aws-ecr-secret`. A new namespace may not have that Secret when its first controller pod is created.

To make the first deployment reliable, `deploy.sh` should:

1. Create the Jenkins namespace.
2. Use the component AWS credentials to request an ECR login password.
3. Create or update `aws-ecr-secret` with `kubectl create secret docker-registry --dry-run=client -o yaml | kubectl apply -f -`.
4. Apply RBAC, storage, JCasC, the controller, Service, and route.

The infrastructure CronJob can continue rotating the pull Secret afterward.

For demo application pushes, static AWS credentials are acceptable. Use the same component-local-secret pattern as `infrastruture/create-aws-credentials.yaml`: `deploy.sh` base64-encodes `JENKINS_ECR_PUSH_ACCESS_KEY_ID`, `JENKINS_ECR_PUSH_SECRET_ACCESS_KEY`, and `JENKINS_ECR_PUSH_DEFAULT_REGION` from `jenkins/.env`, then renders `manifests/aws-credentials-secret.yaml` as an opaque `jenkins-aws-credentials` Secret in the Jenkins namespace. Do not try to reuse the infrastructure namespace's Secret: Kubernetes Secrets are namespace-scoped.

This Secret is separate from `aws-ecr-secret`. The latter is a short-lived Docker registry pull credential maintained by the infrastructure CronJob; it cannot authenticate `aws ecr` or `buildctl` image pushes. The new Secret contains only `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION`, and is injected with `envFrom` only into the privileged tools container. `AWS_ACCOUNT_ID` is non-secret deployment configuration and must also be available to that container so it can construct the target ECR registry hostname.

Use a dedicated IAM user whose policy permits `ecr:GetAuthorizationToken` and only the ECR upload actions needed by the configured application repositories (`BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, and `PutImage`). Do not reuse the infrastructure Route53 or controller-pull credentials.

Before every privileged image push, the tools container must perform an ECR registry login. The AWS CLI obtains an ECR authorization token using its standard environment credential chain, then the pipeline writes a temporary Docker-compatible config for `buildctl`:

```bash
registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
token="$(aws ecr get-login-password --region "${AWS_DEFAULT_REGION}")"
auth="$(printf 'AWS:%s' "${token}" | base64 | tr -d '\n')"
install -d -m 0700 "${DOCKER_CONFIG}"
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "${registry}" "${auth}" > "${DOCKER_CONFIG}/config.json"
unset token auth
```

Set `DOCKER_CONFIG` to a per-build directory in the agent's `emptyDir` workspace. `buildctl` reads `$DOCKER_CONFIG/config.json` and supplies the ECR credentials to BuildKit; no Docker daemon or `/var/run/docker.sock` is involved. The ECR token expires after 12 hours, so obtain it for each build rather than persisting it in the controller or Kubernetes Secret.

ECR push credentials must only be mounted in a privileged, trusted-main execution path. Pull-request agents must receive neither the Secret nor any Kubernetes deployment ServiceAccount. A Jenkinsfile branch condition alone does not provide this separation; the implementation must enforce it with distinct unprivileged and privileged agent execution paths before target-namespace RoleBindings are granted.

## GitHub Integration

Use the GitHub Branch Source plugin and a Multibranch Pipeline. Each application repository owns its `Jenkinsfile`.

For source access:

- Use a fine-grained GitHub personal access token.
- Restrict it to the demo repositories.
- Grant only the repository permissions Jenkins needs.
- Store it in the component's live `.env` and render it into a Kubernetes Secret.
- Expose it to Jenkins as a JCasC-managed string credential rather than embedding it in the JCasC ConfigMap.

For build triggers, configure a manual webhook on each demo repository:

- Payload URL: `https://${JENKINS_WEBHOOK_HOSTNAME}/github-webhook/`
- Content type: `application/json`
- Secret: the same high-entropy value supplied as `GITHUB_WEBHOOK_SECRET`
- SSL verification: enabled
- Events: push and pull request events required by the multibranch job

Manual webhook registration keeps the GitHub token free of repository-hook administration permissions. Jenkins should validate webhook signatures with the shared-secret credential and SHA-256.

Retain an hourly periodic multibranch scan as a recovery mechanism. Webhooks provide normal immediate triggering, while the scan discovers events missed during controller or network downtime.

### Public Webhook Route

Add `manifests/jenkins-webhook-gateway.yaml` with two public `HTTPRoute` resources attached to `johnkoepp-com-gateway`:

1. An HTTPS route on the `https` listener for `${JENKINS_WEBHOOK_HOSTNAME}`. Its only backend rule must match `PathPrefix: /github-webhook/` and forward to `jenkins-service`.
2. An HTTP route on the `http` listener that redirects the same hostname to HTTPS. Apply the repository's Route53 discovery labels to this redirect route.

The HTTPS route must not contain a catch-all rule. Requests for `/`, `/login`, `/job`, and other Jenkins UI paths must not be forwarded by the public gateway. The existing LAN route remains the only route to the Jenkins UI.

The public gateway address must be reachable from GitHub through the existing router or firewall port forwarding. The wildcard `johnkoepp.com` certificate already terminated by the shared gateway covers the webhook hostname.

The deploy script should apply the webhook HTTPS route followed by the HTTP redirect route. The destroy script should remove both before deleting the Jenkins Service.

### Webhook Secrets

`manifests/github-credentials-secret.yaml` should hold both the GitHub SCM token and webhook secret. The deploy script should base64-encode the values and render only this Secret manifest.

The controller Deployment should load the values through individual `secretKeyRef` entries. JCasC should create separate Jenkins string credentials for source access and signature verification, then configure the GitHub plugin to use the signature credential for incoming hooks.

Rotating the webhook secret requires updating the GitHub repository webhooks and the local `.env`, redeploying the Secret, and restarting or reloading JCasC. Validate a GitHub ping delivery after rotation.

GitHub OAuth login is not required for this single-user demo stack.

## Kubernetes Build Agents

Jenkins must not run application builds on the controller. The Kubernetes plugin should create a disposable agent pod for each build.

The initial agent pod should contain:

- The Jenkins inbound agent container
- A custom, pinned tools container with the AWS CLI, `kubectl`, and `buildctl`
- A rootless `moby/buildkit:rootless` sidecar
- An `emptyDir` workspace shared by the necessary containers
- An `emptyDir` mounted at the BuildKit socket path in both the tools and BuildKit containers

The tools container invokes `buildctl --addr unix:///run/user/1000/buildkit/buildkitd.sock`. The socket directory must be a shared volume; sharing only the workspace does not make the rootless BuildKit daemon reachable. Pin the tools image's `buildctl` release to the sidecar release.

The privileged tools template loads `jenkins-aws-credentials` with `envFrom`. It runs only after the trusted-main boundary described in [ECR Bootstrap and Credentials](#ecr-bootstrap-and-credentials) has been implemented. The unprivileged PR template has no `envFrom` AWS credentials and uses a ServiceAccount with no target-namespace RoleBindings.

Using a per-build BuildKit sidecar keeps the setup self-contained and avoids:

- Mounting `/var/run/docker.sock`
- Granting agents control of a cluster node's Docker daemon
- Maintaining a separate permanent BuildKit service

Agent pods should use resource requests and limits and should be deleted after the build completes.

## Application Pipeline

The recommended pipeline behavior is intentionally small.

### Pull Requests

```text
checkout -> test -> build without push
```

Pull-request agents receive no AWS credentials and no deployment identity.

### Main Branch

```text
checkout -> test -> build -> push to ECR -> deploy -> rollout status
```

Images should be tagged with the Git commit SHA:

```text
<account>.dkr.ecr.<region>.amazonaws.com/<repository>:<git-commit>
```

Avoid using `latest` as the deployment reference. A commit tag is sufficient for this demo; digest-based deployment can be added later.

Each `Jenkinsfile` should also include:

- A pipeline timeout
- `disableConcurrentBuilds()`
- A build discarder
- Deployment only from the trusted main branch
- `kubectl rollout status` with a bounded timeout

## Kubernetes Deployment Access

Create a `jenkins-deployer` ServiceAccount for deployment agents. Do not reuse the controller service account.

Each target application namespace should provide a Role and RoleBinding that authorize only the deployment operations required by that application. For a `kubectl set image` deployment, this normally includes:

- `get` and `patch` on the target Deployment
- Read access to the Deployment and Pods for rollout status

Where practical, restrict the Role to named Deployments with `resourceNames`.

The deployer does not need access to:

- Kubernetes Secrets
- Nodes
- Namespace management
- RBAC management
- Cluster-wide administrative resources

Example deployment sequence:

```bash
kubectl -n example-app set image \
  deployment/example-app \
  example-app="${ECR_REPOSITORY}:${GIT_COMMIT}"

kubectl -n example-app rollout status \
  deployment/example-app \
  --timeout=3m
```

Commands running inside the Kubernetes agent use that pod's projected ServiceAccount token. A static kubeconfig or permanent Kubernetes token is not required.

## Persistence and Destruction

The existing NFS-backed PVC remains appropriate for the controller. Back up Jenkins home before controller or plugin upgrades that may perform data migrations.

`destroy.sh` should preserve the PVC by default. Permanent data deletion should require an explicit option such as:

```bash
./jenkins/scripts/destroy.sh --purge-data
```

Removing the workload and preserving the PVC allows the controller to be redeployed without losing configuration, job history, or credentials.

## Environment Variables

The exact names can be finalized during implementation, but `.env.sample` should cover:

```dotenv
JENKINS_NAMESPACE=jenkins
JENKINS_HOSTNAME=jenkins.k8s.koeppster.lan
JENKINS_WEBHOOK_HOSTNAME=jenkins-hooks.johnkoepp.com
JENKINS_STORAGE_CLASS=kube-nfs
JENKINS_STORAGE_SIZE=20Gi
JENKINS_HTTP_PORT=8080
JENKINS_AGENT_PORT=50000

JENKINS_CONTROLLER_REPOSITORY=jenkins-controller
JENKINS_CONTROLLER_TAG=2.568.2-plugins-1
JENKINS_IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/jenkins-controller:2.568.2-plugins-1

JENKINS_TOOLS_REPOSITORY=jenkins-tools
JENKINS_TOOLS_TAG=buildkit-0.26.2-tools-1
JENKINS_TOOLS_IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/jenkins-tools:buildkit-0.26.2-tools-1
JENKINS_N8N_ECR_REPOSITORY=n8n
JENKINS_GITHUB_OWNER=changeme
JENKINS_GITHUB_REPOSITORY=kubernetes-sandbox

AWS_ACCESS_KEY_ID=changeme
AWS_SECRET_ACCESS_KEY=changeme
AWS_DEFAULT_REGION=us-east-1
AWS_ACCOUNT_ID=changeme

JENKINS_ECR_PUSH_ACCESS_KEY_ID=changeme
JENKINS_ECR_PUSH_SECRET_ACCESS_KEY=changeme
JENKINS_ECR_PUSH_DEFAULT_REGION=us-east-1

GITHUB_USERNAME=changeme
GITHUB_TOKEN=changeme
GITHUB_WEBHOOK_SECRET=changeme
```

The GitHub token, webhook secret, and AWS credentials remain in the ignored live `.env` or in separate ignored secret files. Only placeholder values belong in `.env.sample`.

## Implementation Order

**Controller stack implementation: partially complete.** The repository contains the pinned controller build, Docker credential-helper-based publication script, JCasC configuration, controller workload and RBAC changes, ECR pull-secret bootstrap, GitHub credential wiring, public webhook routes, and PVC-preserving destroy flow. The current agent template is not yet able to perform the designed build/push/deploy workflow: it uses plain Alpine, does not share the BuildKit socket, and has no scoped ECR push credentials. It also does not yet enforce separate PR and trusted-main identities.

- [x] Add the pinned `Dockerfile` and `plugins.txt`.
- [x] Add `scripts/build-controller.sh`. It builds the configured tag and uses `docker push`; the preconfigured Docker ECR credential helper authenticates the push. Publishing the first versioned tag remains an explicit administrator action.
- [x] Add the JCasC file and ConfigMap manifest.
- [x] Update controller RBAC and remove the permanent service-account token.
- [x] Update the Deployment for the ECR image, JCasC mount, `Recreate` strategy, startup probe, and `imagePullSecrets`.
- [x] Update `deploy.sh` to bootstrap the ECR pull Secret before creating the controller.
- [x] Configure the Kubernetes cloud and default agent through JCasC.
- [x] Add the initial rootless BuildKit agent pod template.
- [x] Add `tools.Dockerfile` and `scripts/build-tools.sh` for pinned AWS CLI, `kubectl`, `buildctl`, Git, and CA certificates.
- [ ] Publish the first immutable tools tag. The configuration and `JENKINS_TOOLS_*` variables are ready, but publication requires administrator ECR authority.
- [x] Add `JENKINS_TOOLS_*` variables to `.env.sample` and reference the tools image from JCasC.
- [x] Add `manifests/aws-credentials-secret.yaml` and render a dedicated `jenkins-aws-credentials` Secret from the component `.env`.
- [x] Add a shared BuildKit socket `emptyDir` and mount it in the tools and BuildKit containers.
- [x] Separate unprivileged PR agents from privileged trusted-main agents. Only the latter mount ECR credentials or use `jenkins-deployer`.
- [ ] Enforce the trusted-main boundary independently of repository-controlled Pipeline code before accepting untrusted pull requests. A second controller/runner identity or a policy that prevents untrusted agent specifications is required.
- [x] Add the path-restricted public webhook route and HTTPS redirect.
- [x] Configure the GitHub webhook secret through Kubernetes credentials and JCasC.
- [x] Configure the `n8n` GitHub multibranch project through JCasC with an hourly reconciliation scan. Webhook registration remains a manual GitHub administrator action.
- [x] Add limited deployer RBAC to the `n8n` target application.
- [x] Add the first application `Jenkinsfile` for `n8n`.
- [x] Change `destroy.sh` to preserve the PVC unless `--purge-data` is supplied.

## Validation

After implementation, validate the following:

- The controller pulls its image from ECR on a clean node.
- The controller starts successfully using only JCasC configuration.
- Installed Jenkins and plugin versions match the pinned files.
- The tools image contains the expected pinned `aws`, `kubectl`, and `buildctl` versions.
- The tools container can connect to the rootless BuildKit socket and complete a build without a Docker socket.
- A privileged build obtains a fresh ECR token, writes it only to its per-build `DOCKER_CONFIG`, and `buildctl` pushes successfully without Docker.
- The built-in node has zero executors.
- A multibranch scan discovers the demo repository and branches.
- GitHub can deliver a webhook ping over HTTPS and receives a successful response.
- The public gateway forwards `/github-webhook/` but does not expose `/`, `/login`, or `/job`.
- A webhook with an invalid signature is rejected.
- Push and pull request webhooks trigger the expected multibranch jobs without waiting for the periodic scan.
- A pull request can test and build but cannot access ECR push or deployment credentials.
- A main-branch build pushes a commit-tagged image to ECR.
- The deployment agent can update its intended Deployment.
- The deployment agent cannot read Secrets or modify unrelated namespaces.
- A controller restart preserves Jenkins home.
- A normal destroy and redeploy preserves the PVC and Jenkins state.
