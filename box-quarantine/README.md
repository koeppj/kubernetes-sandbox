# Box Quarantine StatefulSet

This component deploys a single-replica `StatefulSet` based on the image `996472359368.dkr.ecr.us-east-1.amazonaws.com/box-quarantine-container:latest`.

## Kubernetes Artifacts

Located in [manifests](./manifests)

| Name | Type and Use |
|------|---------------|
| `box-enterprise-quarantine` | Namespace for the app. |
| `box-auth-config` | Secret mounted under `/var/run/box`, with the file path provided by `BOX_AUTH_CONFIG`. |
| `box-quarantine-template` | ConfigMap created from `config/quarantine-template.txt` and mounted under `/etc/box-quarantine`, with the file path provided by `QUARANTINE_TEMPLATE`. |
| `box-quarantine-listener` | Headless `Service` plus `StatefulSet` that runs one replica of the app. |
| `box-quarantine-state` | PVC mounted at the path defined by `COLLECTOR_CONFIG`. |

## Scripts

Located in [scripts](./scripts)

| Script | Usage |
|--------|-------|
| `deploy.sh` | Create or update all component resources. |
| `destroy.sh` | Remove the component from the cluster. |
| `pause.sh` | Scale the StatefulSet down to `0`. |
| `resume.sh` | Scale the StatefulSet back to `1`. |

## Secret for Box Auth Config

Place the Box JWT auth file at [secrets/box-jwt-auth.json](./secrets/box-jwt-auth.json). The deploy script normalizes line endings, imports it as the `box-auth-config` secret with the key `box-jwt.json`, and the StatefulSet mounts that secret under `/var/run/box`. `BOX_AUTH_CONFIG` should point to `/var/run/box/box-jwt.json`.

## Template Config

Place the quarantine placeholder template at [config/quarantine-template.txt](./config/quarantine-template.txt). The deploy script imports it as the `box-quarantine-template` ConfigMap. The StatefulSet mounts that ConfigMap under `/etc/box-quarantine`, and `QUARANTINE_TEMPLATE` should point to `/etc/box-quarantine/quarantine-template.txt`.

## StatefulSet Environment Variables

The container reads `BOX_AUTH_CONFIG` from the mounted secret file, `QUARANTINE_TEMPLATE` from the mounted ConfigMap file, and `COLLECTOR_CONFIG` from the mounted PVC path. Those paths are configured through the component `.env` file so the secret and template can stay separate from the state directory; placeholders are documented in [.env.sample](./.env.sample).

| Key | Description |
|------|-------------|
| `BOX_AUTH_CONFIG` | Full path to the Box JWT JSON config. The sample value is `/var/run/box/box-jwt.json`. |
| `QUARANTINE_FOLDER_ID` | ID of the Box folder that stores quarantined files. |
| `QUARANTINE_TEMPLATE` | Mounted file path for the placeholder template provided by the ConfigMap. The sample value is `/etc/box-quarantine/quarantine-template.txt`. |
| `QUARANTINE_CLEARED_LABEL` | Classification label applied when the file is released. |
| `QUARANTINE_LABEL` | Classification label that triggers quarantine. |
| `QUARANTINE_METADATA_TEMPLATE` | Metadata template containing `originalFolderId` and `replacementFileId`. |
| `COLLECTOR_CONFIG` | Directory for persisted listener state. This must match the PVC mount path. |
| `POLL_INTERVAL_SEC` | Seconds between poll cycles. Set to `-1` to process available events once and exit. |
| `EVENT_FETCH_LIMIT` | Maximum events fetched per poll. |
| `START_DATE` | Optional ISO-8601 date/time or date used to seed the initial catch-up request when no prior stream position is stored. |
| `ADMIN_LOGS_ONLY` | When `true`, always use `admin_logs` and never switch to streaming. |
| `EVENT_CACHE_TTL_HOURS` | Hours to keep processed event IDs in the cache. |
| `EVENT_CACHE_MAX` | Maximum processed event IDs to retain. |
