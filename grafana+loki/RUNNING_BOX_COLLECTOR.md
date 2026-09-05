# Running the Box Event Collector

This document describes how to configure, start, monitor, and reset the Box event collector in Kubernetes.

## Runtime behavior

The collector stores the Box stream cursor in:

```text
${COLLECTOR_CONFIG}/next_stream_position
```

On startup:

1. If no cursor exists and `BACKFILL_START_DATE` is non-empty, the collector requests `admin_logs` events after that date.
2. It sends the returned events to Loki.
3. It saves Box's `next_stream_position`.
4. It continues polling from that saved position.

If a cursor already exists, `BACKFILL_START_DATE` is ignored. A normal pod restart therefore resumes from the saved position instead of repeating the backfill.

The current implementation continues with the `admin_logs` stream; it does not switch to `admin_logs_streaming` after the backfill.

## Environment variables

### Required

| Variable | Description | Example |
|---|---|---|
| `BOX_CONFIG_JSON` | Path to the Box JWT configuration file inside the container. | `/var/run/box/box-config.json` |
| `COLLECTOR_CONFIG` | Directory containing the persisted cursor. Mount this directory on a persistent volume. | `/config` |

### Backfill and destination

| Variable | Description | Example |
|---|---|---|
| `BACKFILL_START_DATE` | Optional ISO-8601 timestamp used only when the cursor does not exist. | `2025-01-01T00:00:00Z` |
| `LOKI_URL` | Loki push endpoint. | `http://loki:3100/loki/api/v1/push` |

### Optional tuning

| Variable | Default | Description |
|---|---:|---|
| `POLL_INTERVAL_SEC` | `5` | Seconds between Box polling requests. |
| `LOKI_TIMEOUT_SEC` | `10` | Loki request timeout in seconds. |
| `RETRY_BASE_SLEEP_SEC` | `5` | Initial retry delay for Loki failures. |
| `RETRY_MAX_RETRIES` | `3` | Maximum Loki retry attempts. |
| `RETRY_BACKOFF_FACTOR` | `2` | Multiplier applied to each retry delay. |
| `FUTURE_SKEW_SEC` | `300` | Maximum accepted future skew for event timestamps before using the current time. |

Keep the Box JWT configuration in a Kubernetes Secret. Do not put credentials directly in this file or in a ConfigMap.

## Initial deployment with backfill

Set the backfill date in the Deployment. The state volume must be new or must not contain `next_stream_position`.

```yaml
env:
  - name: BOX_CONFIG_JSON
    value: /var/run/box/box-config.json
  - name: COLLECTOR_CONFIG
    value: /config
  - name: LOKI_URL
    value: http://loki.grafana.svc.cluster.local:3100/loki/api/v1/push
  - name: BACKFILL_START_DATE
    value: "2025-01-01T00:00:00Z"
  - name: POLL_INTERVAL_SEC
    value: "300"
```

Apply the manifest and wait for the pod to become ready:

```bash
kubectl -n grafana apply -f box-collector-deployment.yaml
kubectl -n grafana rollout status deployment/box-event-collector
kubectl -n grafana logs -f deployment/box-event-collector
```

Expected log messages include:

```text
Backfill: ... events from 2025-01-01T00:00:00Z
Fetched ... events (next pos: ...)
```

After the initial backfill, `BACKFILL_START_DATE` may be cleared from the manifest. The persisted cursor is what controls resumption. If the cursor is later lost, leaving the date configured provides a backfill starting point again.

## Normal restart or upgrade

Do not delete the state PVC during an application upgrade. A normal rollout preserves the cursor:

```bash
kubectl -n grafana rollout restart deployment/box-event-collector
kubectl -n grafana rollout status deployment/box-event-collector
```

Use one collector replica unless cursor coordination is added. Multiple replicas sharing one cursor can duplicate or skip processing.

## Reset and rerun a backfill

Resetting state causes the next startup to treat the deployment as a first run. Stop the collector before deleting the cursor so that an old pod cannot recreate or overwrite state.

1. Set the desired `BACKFILL_START_DATE` in the Deployment.
2. Scale the collector down:

   ```bash
   kubectl -n grafana scale deployment/box-event-collector --replicas=0
   kubectl -n grafana wait --for=delete pod -l app=box-event-collector --timeout=120s
   ```

3. Delete only the cursor file from the mounted state volume. For example, use a temporary maintenance pod that mounts the same PVC and run:

   ```bash
   rm -f /config/next_stream_position
   ```

   Verify that `/config` is the collector's state volume before running the command. Do not delete the PVC unless all persisted data on it is intentionally disposable.

4. Scale the collector back up:

   ```bash
   kubectl -n grafana scale deployment/box-event-collector --replicas=1
   kubectl -n grafana rollout status deployment/box-event-collector
   kubectl -n grafana logs -f deployment/box-event-collector
   ```

An alternative is to deploy with a new, empty PVC or a different `COLLECTOR_CONFIG` mount. This is usually safer when the existing state must be retained for investigation.

## Troubleshooting checklist

- Confirm the Box JWT Secret is mounted at the path in `BOX_CONFIG_JSON`.
- Confirm the collector can write to `COLLECTOR_CONFIG` as UID/GID `10001`.
- Confirm the state PVC is mounted at the same path used by `COLLECTOR_CONFIG`.
- Check whether `/config/next_stream_position` exists before changing `BACKFILL_START_DATE`.
- Check Loki connectivity and the exact `LOKI_URL`.
- Inspect logs for Box API errors, Loki errors, and the reported `next pos`.

The collector currently advances its cursor even when a Loki push is abandoned or skipped after an error. Treat Loki availability and the collector logs as critical during a backfill; otherwise events may not be recoverable from the Box stream position.
