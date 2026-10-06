# Backup and Restore Runbook

This runbook describes how backups are taken, where they are stored, how long they are retained, and how to restore the system in the event of data loss or corruption.

## 1. Scope

The following data is backed up:

| Component | Description | Backup Method |
| --- | --- | --- |
| PostgreSQL database | Primary application database (users, transactions, metadata) | `pg_dump` logical backup |
| Contract state | Soroban RPC snapshots of configured contract instances | `getContractData` via `scripts/backup.sh` |

> **Note:** Secret values are **not** included in backups. Secrets are managed separately via the secrets manager and must be re-provisioned during restore.

## 2. Backup Schedule

| Job | Schedule | What it does |
| --- | --- | --- |
| Backup | Daily at 02:00 UTC | `scripts/backup.sh`: `pg_dump` + contract state snapshot → encrypted archive + manifest in object storage |
| Restore verification | Sundays at 04:00 UTC | `scripts/restore.sh --verify-only` against staging: restores the newest backup into a throwaway database and checks every table came back |

Both run from [`.github/workflows/backup.yml`](../.github/workflows/backup.yml) and can also be started manually (**Run workflow** → `backup`, `verify-restore` or `both`). Until the required secrets are configured, the jobs are skipped with a warning instead of failing.

### Required configuration

Repository secrets:

| Secret | Used by | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | backup | Production database to dump |
| `STAGING_DATABASE_URL` | verify-restore | Staging database; the role needs `CREATEDB` |
| `BACKUP_ENCRYPTION_KEY` | both | gpg passphrase used to encrypt/decrypt archives |
| `BACKUP_STORAGE_BUCKET` | both | Bucket name |
| `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY` | both | S3-compatible credentials |
| `BACKUP_STORAGE_REGION` | both | Optional, default `us-east-1` |
| `BACKUP_STORAGE_ENDPOINT` | both | Optional, for non-AWS S3 (R2, MinIO, Supabase's S3 endpoint, ...) |

Optional repository variables for the contract-state snapshot: `SOROBAN_RPC_URL`, `SOROBAN_NETWORK_PASSPHRASE`, `SOROBAN_CONTRACT_IDS` (comma-separated).

### Backup layout

Each run writes two objects under `s3://<bucket>/backups/`:

- `soroban-backup-<UTC timestamp>.tar.gz.enc` — encrypted tarball containing `database.sql.gz` (plain SQL with `DROP ... IF EXISTS`), `tables.txt` (table list used for verification) and `contracts/` (contract state snapshots, when configured).
- `soroban-backup-<UTC timestamp>.manifest.json` — timestamp, SHA-256 of the encrypted archive, size, encryption method and source metadata. A copy is uploaded as a workflow artifact.

## 3. Retention Policy

- Backups are retained according to the lifecycle policy on the backup bucket (recommended: 30 days for daily backups). The scripts never delete old backups.
- Workflow artifacts (manifests) are kept for 30 days.

## 4. Encryption

- Archives are encrypted client-side before upload: with gpg (AES-256, symmetric passphrase from `BACKUP_ENCRYPTION_KEY`) by default, or with [age](https://age-encryption.org) when `BACKUP_ENCRYPTION_KEY` is an `age1...` recipient or a recipients file. `backup.sh` refuses to fall back to unencrypted uploads; plaintext requires an explicit `BACKUP_ENCRYPTION_METHOD=none`.
- Uploads use TLS. Enable server-side encryption on the bucket as an additional layer.
- Access to the backup bucket should be restricted to the backup credentials and on-call engineers via least-privilege policies.

## 5. Storage Locations

| Environment | Bucket | Region |
| --- | --- | --- |
| Production | `s3://prod-backups-<org>/` | `us-east-1` |
| Staging | `s3://staging-backups-<org>/` | `us-east-1` |
| Development | `s3://dev-backups-<org>/` | `us-east-1` |

## 6. RTO / RPO Targets

| Metric | Target | Notes |
| --- | --- | --- |
| **RPO** (Recovery Point Objective) | 24 hours | One full backup per day |
| **RTO** (Recovery Time Objective) | 4 hours | Maximum acceptable downtime |

For a tighter RPO, use your database provider's point-in-time recovery (e.g. Supabase PITR) alongside these logical backups.

## 7. Restore Procedure

### 7.1 Prerequisites

- `aws` CLI, `psql`, `gpg` (or `age`), `tar`, `gzip`, `sha256sum`.
- Access to the backup bucket and the encryption key.
- A target PostgreSQL instance with sufficient capacity.

`scripts/restore.sh` reads the same `BACKUP_STORAGE_*` and `BACKUP_ENCRYPTION_KEY` variables as `backup.sh` (for age-encrypted backups, set `BACKUP_AGE_IDENTITY_FILE` instead).

### 7.2 Steps

1. **Identify the backup to restore.**
   ```bash
   aws s3 ls s3://<backup-bucket>/backups/ | grep manifest | tail -n 5
   ```
   Pick the newest backup that precedes the incident. If you omit `--backup`, `restore.sh` uses the newest one.

2. **Rehearse against a scratch database (recommended).**
   ```bash
   ./scripts/restore.sh --backup soroban-backup-<timestamp> --verify-only \
     --database-url postgresql://<user>:<pass>@<staging-host>:5432/postgres
   ```

3. **Restore into the target database.**
   ```bash
   ./scripts/restore.sh --backup soroban-backup-<timestamp> --database-url "$DATABASE_URL"
   ```
   The script downloads the manifest and archive, verifies the SHA-256 checksum, decrypts, and replays the dump in a single transaction (a failed restore changes nothing). Objects in the target that are not in the backup are left in place.

4. **Inspect contract state snapshots (if needed).** Add `--keep-work-dir` to keep the extracted `contracts/` snapshots. On-chain state cannot be "restored"; use the snapshots to confirm which contract IDs the application should point at, and use `scripts/rollback-contracts.cjs` to repoint it.

5. **Re-provision secrets.** Retrieve the required secrets from the secrets manager and inject them into the restored environment. Do **not** restore secrets from backups.

6. **Run migrations (if the backup predates the current release).** The Kubernetes `migrate` initContainer does this on the next rollout, or run it manually:
   ```bash
   kubectl -n synapsvault rollout restart deployment/backend
   ```

7. **Restart application services** against the restored database.

### 7.3 Verification

After restore, verify the following:

- [ ] `restore.sh` finished with `restore complete` (exit code 0).
- [ ] Row counts for critical tables look plausible (`--verify-only` logs counts for every table).
- [ ] The application's `/health` endpoint reports healthy.
- [ ] Smoke tests pass (`BACKEND_URL=... npm run test:smoke`).
- [ ] No errors in application logs for 15 minutes post-restore.
- [ ] RTO/RPO targets were met (record actual times).

### 7.4 Rollback

If the restore fails, `restore.sh` rolls its transaction back and exits non-zero (2 = download/checksum, 3 = decryption, 4 = restore, 5 = verification). Fix the cause and re-run, or re-attempt with an earlier backup. Document the failure and notify the on-call engineer.

## 8. Testing

- Restores are verified automatically **weekly** against staging by the `verify-restore` job.
- Full restore drills are performed **quarterly** in the staging environment.
- Drill results (time to restore, issues encountered) are recorded in the incident log.
- Any gaps identified during drills must be addressed before the next drill.

## 9. Escalation and On-Call Contacts

| Role | Contact | Escalation Path |
| --- | --- | --- |
| Primary on-call engineer | PagerDuty: `platform-oncall` | First responder |
| Secondary on-call engineer | PagerDuty: `platform-oncall` (backup) | Escalate after 15 min |
| Database administrator | `#db-ops` Slack channel | Escalate for DB-specific issues |
| Engineering manager | `#eng-leads` Slack channel | Escalate for extended outages |
| Security team | `security@<org>.example` | Escalate for suspected data breach |

**Escalation timeline:**

1. Acknowledge the incident within **15 minutes**.
2. If unresolved after **30 minutes**, escalate to the secondary on-call.
3. If unresolved after **1 hour**, escalate to the engineering manager.
4. If a data breach is suspected, notify the security team **immediately**.

## 10. References

- Backup workflow: [`.github/workflows/backup.yml`](../.github/workflows/backup.yml)
- Restore script: [`scripts/restore.sh`](../scripts/restore.sh)
- Backup script: [`scripts/backup.sh`](../scripts/backup.sh)
- Database migration rollback: [`docs/DATABASE-ROLLBACK.md`](./DATABASE-ROLLBACK.md)
- Environment variables: [`docs/ENVIRONMENT-VARIABLES.md`](./ENVIRONMENT-VARIABLES.md)