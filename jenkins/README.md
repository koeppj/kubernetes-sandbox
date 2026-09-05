# Jenkins

This component runs one Jenkins controller on NFS-backed storage. The controller image is built and published to ECR as an explicit administrative step; deployment never builds it. Jenkins Configuration as Code (JCasC) is stored outside the image so operational configuration can change independently.

## Configure

```bash
cd jenkins
cp .env.sample .env
${EDITOR:-vi} .env
```

Set every `changeme` value. `JENKINS_IMAGE` must exactly match the ECR account, repository, and immutable controller tag defined by `AWS_ACCOUNT_ID`, `JENKINS_CONTROLLER_REPOSITORY`, and `JENKINS_CONTROLLER_TAG`. Do not commit `.env`.

The GitHub token must be a fine-grained token restricted to the repositories Jenkins scans. The webhook secret must be high entropy. Neither is written to JCasC; both are rendered into `github-credentials` and referenced at runtime.

### Create GitHub Credentials

Create one fine-grained personal access token for Jenkins:

1. In GitHub, open **Settings**, then **Developer settings**, **Personal access tokens**, and **Fine-grained tokens**.
2. Generate a token with a descriptive name such as `jenkins-controller`, an appropriate expiration, and access limited to the two application repositories Jenkins will scan.
3. Under repository permissions, grant `Contents: Read-only` and `Pull requests: Read-only`. `Metadata: Read-only` is included by GitHub. Do not grant `Webhooks` permission: this stack registers hooks manually. Grant `Commit statuses: Read and write` only if the application pipelines will publish build results as GitHub commit statuses.
4. Copy the generated token immediately and assign it to `GITHUB_TOKEN` in `jenkins/.env`. Set `GITHUB_USERNAME` to the GitHub account that owns the token.

Create the webhook signing secret locally. The value need not be memorized, but it must be kept private and used unchanged for every repository webhook:

```bash
openssl rand -hex 32
```

Assign the output to `GITHUB_WEBHOOK_SECRET` in `jenkins/.env`. Do not quote, commit, or share either value. If the repositories belong to an organization that requires SSO authorization for personal access tokens, authorize the new token for that organization before deploying Jenkins.

## Build And Publish

```bash
./jenkins/scripts/build-controller.sh
```

The script validates the repository and image tag relationship, builds `jenkins/Dockerfile`, pushes the configured immutable tag, and prints the locally known digest. It does not invoke the AWS CLI or log Docker in: Docker's configured ECR credential helper supplies authentication for `docker push`. Never republish an existing tag: increment `plugins-N` or the Jenkins baseline for every controller-image change.

The image uses Jenkins LTS `2.568.2` on JDK 21 and the exact plugin versions in `plugins.txt`. Transitive plugin dependencies are resolved during the image build.

Build and publish the pinned agent tools image separately before deployment:

```bash
./jenkins/scripts/build-tools.sh
```

`JENKINS_TOOLS_IMAGE` must exactly match its configured ECR account, repository, and immutable tag. It includes AWS CLI v2, `kubectl`, `buildctl`, Git, and CA certificates; it is not built during deployment.

## Deploy

```bash
./jenkins/scripts/deploy.sh
./jenkins/scripts/check-deploy.sh
```

Deploy first creates the namespace, then bootstraps `aws-ecr-secret` using the component AWS credentials. The namespace label lets the shared infrastructure refresh that pull secret afterwards. The controller specifically references the secret because it runs as `jenkins-admin`, not the namespace `default` service account.

The LAN UI is available at `http://jenkins.k8s.koeppster.lan` by default. The public route accepts only `https://jenkins-hooks.johnkoepp.com/github-webhook/`; it does not expose the Jenkins UI. Configure a webhook in each application repository under **Settings**, **Webhooks** with that URL, `application/json` content type, SSL verification enabled, and the value of `GITHUB_WEBHOOK_SECRET`. Enable the required `Pushes` and `Pull requests` events, then send a GitHub ping delivery after deployment.

JCasC creates a Kubernetes cloud with zero controller executors and two disposable agent templates. `jenkins-unprivileged` has no ECR credential or target-namespace RoleBinding. `jenkins-trusted-main` mounts the scoped ECR credentials and uses `jenkins-deployer`; both templates contain an inbound agent, the pinned tools image, a rootless BuildKit sidecar, and shared workspace and BuildKit-socket `emptyDir` volumes. The first target, `n8n`, applies a Role that only patches the `n8n` Deployment and reads Pods for rollout status.

## Set Up An Application Repository

Each repository Jenkins builds must contain a `Jenkinsfile` at its root. The pipeline should use the `kubernetes` agent label, test and build pull requests without pushing an image, and limit image publishing, deployment, and `kubectl rollout status` to the trusted main branch. Tag published images with the commit SHA, not `latest`. Add a `Dockerfile` and any test commands the application needs as well.

JCasC creates the `n8n` Multibranch Pipeline from `JENKINS_GITHUB_OWNER` and `JENKINS_GITHUB_REPOSITORY`, using `github-scm-token`, branch and same-repository pull-request discovery, and an hourly reconciliation scan. Set those variables to the repository that contains the `n8n/Jenkinsfile`, then confirm the first scan discovers the expected branches before creating the webhook. Fork pull-request discovery is intentionally not enabled.

Configure the repository webhook in GitHub under **Settings**, **Webhooks**:

1. Select **Add webhook** and use `https://jenkins-hooks.johnkoepp.com/github-webhook/` as the payload URL, or substitute the configured `JENKINS_WEBHOOK_HOSTNAME`.
2. Set content type to `application/json`, enable SSL verification, and set the secret to the exact `GITHUB_WEBHOOK_SECRET` value from `jenkins/.env`.
3. Select **Let me select individual events**, enable **Pushes** and **Pull requests**, keep the webhook active, and save it.
4. Use **Recent Deliveries** to redeliver the GitHub ping. It must succeed before relying on webhook-triggered builds; then push a non-production branch or open a pull request and confirm that Jenkins starts the matching multibranch build.

Before adding a deployment stage, create a narrowly scoped Role and RoleBinding in the target application namespace for the `jenkins` namespace's `jenkins-deployer` ServiceAccount. Limit it to the named Deployment's `get` and `patch` operations and the read access required for rollout status. Do not grant access to Secrets, RBAC, nodes, or other namespaces.

> Security boundary: the templates separate credentials and ServiceAccounts, but a controller that may create arbitrary pods can still be induced by untrusted Pipeline code to request a privileged template or Pod spec. Before accepting untrusted pull requests, restrict Pipeline authors from selecting arbitrary Kubernetes agents and pod YAML, or run trusted-main builds through a separate controller/runner identity whose credentials are unavailable to the pull-request controller. Protected main branches and the `when { branch 'main' }` check are necessary controls, but not sufficient authorization on their own.

## Destroy

```bash
./jenkins/scripts/destroy.sh
```

This removes routes, Service, controller, JCasC, RBAC, and generated credentials but preserves `jenkins-pv-claim` and its namespace. To permanently remove controller state:

```bash
./jenkins/scripts/destroy.sh --purge-data
```
