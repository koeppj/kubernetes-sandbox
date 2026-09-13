# n8n on MicroK8s

The production deployment runs n8n 2.37.10 against PostgreSQL 17.11. Both
images are pinned by tag and digest. Use `scripts/deploy-n8n.sh` for normal
idempotent deployments.

## Data safety

- `n8n-pv-claim` contains n8n configuration and filesystem-backed binary data.
- `database-data-v17-postgres-n8n-v17-0` contains the active PostgreSQL 17 data.
- `database-data-postgres-n8n-0` is the retained pre-migration PostgreSQL 14
  rollback volume. Do not delete it before 2026-09-12 and at least one complete
  scheduled-workflow cycle has succeeded.
- `n8n-recovery-backup` contains the verified pre-migration database dump,
  inventory, and n8n filesystem archive. It is on the same NFS server as the
  source volumes and therefore is not protection from loss of that server.
- The live `n8n-secret` contains the encryption key copied from the existing
  n8n configuration. Never replace this key when restoring existing credentials.

The default destroy command removes workloads but deliberately retains data:

```bash
./scripts/destroy-n8n.sh
```

Permanent removal requires `--purge-data` and an interactive confirmation.

## PostgreSQL 14 to 17 recovery artifacts

`manifests/recovery-backup.yaml` and `manifests/postgres-restore-job.yaml` are
one-shot recovery resources. `scripts/recover-postgres17.sh` refuses to restore
when the restore Job already exists so an initialized database cannot be
accidentally overlaid. Preserve the completed Jobs until the rollback retention
period ends because their status and logs record checksum and row-count checks.

The recovered database was validated against these pre-migration invariants:

- 9 workflows
- 3 credentials
- 0 stored executions
- 253 schema migrations
- migration 253: `AddProjectManageMembersScopeToCustomRoles1787140858009`

## Follow-up maintenance

n8n reports that the legacy `binaryData` directory will be renamed in n8n 3.
Schedule that filesystem migration separately from database recovery. The image
also warns that its internal Python task runner is unavailable; the restored
workflows contain no Python Code nodes, so this does not block the current
deployment. Use an external task runner before introducing Python Code nodes.
