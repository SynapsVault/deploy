# Backup and Restore Runbook

This runbook describes how backups are taken, where they are stored, how long they are retained, and how to restore the system in the event of data loss or corruption.

## 1. Scope

The following data is backed up:

| Component | Description | Backup Method |
| --- | --- | --- |
| PostgreSQL database | Primary application database (users, transactions, metadata) | `pg_dump` logical backup |
| Contract state | On-chain contract state snapshots and deployment artifacts | State export script + artifact archive |
| Configuration | Environment configuration and secrets references (not secret values) | Config snapshot |

> **Note:** Secret values are **not** included in backups. Secrets are managed separately via the secrets manager and must be re-provisioned during restore.

## 2. Backup Schedule

| Backup Type | Frequency | Retention | Storage Location |
| --- | --- | --- | --- |
| Full Postgres backup | Daily at 02:00 UTC | 30 days | `s3://<backup-bucket>/postgres/full/` |
| Incremental Postgres backup | Every 6 hours | 7 days | `s3://<backup-bucket>/postgres/incremental/` |
| Contract state snapshot | Daily at 02:30 UTC | 90 days | `s3://<backup-bucket>/contract-state/` |
| Config snapshot | On change | 90 days | `s3://<backup-bucket>/config/` |

Backups are orchestrated by the workflow defined in [`.github/workflows/backup.yml`](../.github/workflows/backup.yml).

## 3. Retention Policy

- **Daily full backups:** retained for 30 days, then automatically expired.
- **Incremental backups:** retained for 7 days.
- **Contract state snapshots:** retained for 90 days to support audit and rollback requirements.
- **Config snapshots:** retained for 90 days.
- Retention is enforced by the lifecycle policy on the backup bucket and by the cleanup step in the backup workflow.

## 4. Encryption

- All backups are encrypted at rest using **AES-256** (SSE-S3 or SSE-KMS, depending on environment).
- Backups are encrypted in transit using **TLS 1.2+**.
- Encryption keys are managed by the cloud KMS. Key rotation follows the platform KMS rotation schedule.
- Access to the backup bucket is restricted to the backup service role and on-call engineers via least-privilege IAM policies.

## 5. Storage Locations

| Environment | Bucket | Region |
| --- | --- | --- |
| Production | `s3://prod-backups-<org>/` | `us-east-1` |
| Staging | `s3://staging-backups-<org>/` | `us-east-1` |
| Development | `s3://dev-backups-<org>/` | `us-east-1` |

Cross-region replication is enabled for production backups to `us-west-2` for disaster recovery.

## 6. RTO / RPO Targets

| Metric | Target | Notes |
| --- | --- | --- |
| **RPO** (Recovery Point Objective) | 6 hours | Maximum acceptable data loss |
| **RTO** (Recovery Time Objective) | 4 hours | Maximum acceptable downtime |

These targets assume the most recent incremental backup is available and the restore environment is provisioned.

## 7. Restore Procedure

### 7.1 Prerequisites

- Access to the backup bucket (IAM role or credentials).
- A target PostgreSQL instance with sufficient capacity.
- The restore script: [`scripts/restore.sh`](../scripts/restore.sh).
- The latest backup manifest (produced by the backup workflow).

### 7.2 Steps

1. **Identify the backup to restore.**
   ```bash
   aws s3 ls s3://<backup-bucket>/postgres/full/ | tail -n 5
   ```
   Select the most recent full backup that precedes the incident, plus any incremental backups after it.

2. **Provision the target database.**
   Ensure the target instance is running and reachable. Confirm the connection string in the environment configuration.

3. **Download the backup artifacts.**
   ```bash
   ./scripts/restore.sh download --bucket <backup-bucket> --date <YYYY-MM-DD>
   ```

4. **Restore the full backup.**
   ```bash
   ./scripts/restore.sh restore-full --file <full-backup-file>
   ```

5. **Apply incremental backups (if applicable).**
   ```bash
   ./scripts/restore.sh restore-incremental --file <incremental-backup-file>
   ```

6. **Restore contract state.**
   ```bash
   ./scripts/restore.sh restore-contract-state --snapshot <snapshot-id>
   ```

7. **Re-provision secrets.**
   Retrieve the required secrets from the secrets manager and inject them into the restored environment. Do **not** restore secrets from backups.

8. **Run migrations (if needed).**
   ```bash
   npm run migrate
   ```

9. **Restart application services.**
   Deploy or restart the application against the restored database.

### 7.3 Verification

After restore, verify the following:

- [ ] Database connectivity is healthy (`npm run db:health`).
- [ ] Row counts for critical tables match the backup manifest.
- [ ] Contract state matches the expected on-chain state (compare hashes).
- [ ] Application smoke tests pass (`npm run test:smoke`).
- [ ] No errors in application logs for 15 minutes post-restore.
- [ ] RTO/RPO targets were met (record actual times).

### 7.4 Rollback

If the restore fails or produces inconsistent data, roll back to the previous database instance and re-attempt with an earlier backup. Document the failure and notify the on-call engineer.

## 8. Testing

- Restore drills are performed **quarterly** in the staging environment.
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
- Incident response runbook: [`docs/INCIDENT-RESPONSE.md`](./INCIDENT-RESPONSE.md)
- Secrets management: [`docs/SECRETS.md`](./SECRETS.md)