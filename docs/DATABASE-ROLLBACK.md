# Database Migration Rollback Runbook

This runbook describes how to safely roll back database migrations for this project.

## Overview

- **Migration tool:** [`drizzle-kit`](https://orm.drizzle.team/docs/kit-overview) (paired with `drizzle-orm`).
- **Migration files:** stored in `drizzle/` (SQL files) with metadata in `drizzle/meta/`.
- **Database:** Supabase (PostgreSQL).
- **Applied migrations tracking:** Drizzle records applied migrations in the `__drizzle_migrations` table in the `drizzle` schema.

> ⚠️ Drizzle does not generate "down" migrations automatically. Rollbacks are performed either by applying a hand-written reverse SQL migration or by restoring from a Supabase backup. Choose the approach that matches the change.

---

## 1. List Applied Migrations

Inspect the migrations Drizzle has recorded as applied:

```bash
# Using psql against the Supabase connection string
psql "$DATABASE_URL" -c "SELECT id, hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at;"
```

You can also list the migration files present locally:

```bash
ls -1 drizzle/*.sql
```

Compare the two lists to determine which migrations are applied vs. pending.

---

## 2. Roll Back the Last Migration

Drizzle has no built-in `down` command, so roll back by applying a reverse migration.

1. **Identify the last applied migration:**

   ```bash
   psql "$DATABASE_URL" -c "SELECT id, hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at DESC LIMIT 1;"
   ```

2. **Write a reverse SQL migration** that undoes the change (e.g. `DROP TABLE`, `DROP COLUMN`, restore prior constraint). Save it as a new file, e.g. `drizzle/9999_rollback_last.sql`.

3. **Apply the reverse migration:**

   ```bash
   psql "$DATABASE_URL" -f drizzle/9999_rollback_last.sql
   ```

4. **Remove the corresponding row** from the migrations table so Drizzle no longer considers the original migration applied:

   ```bash
   psql "$DATABASE_URL" -c "DELETE FROM drizzle.__drizzle_migrations WHERE id = '<migration_id>';"
   ```

5. **Verify** with the checklist in section 5.

> Prefer creating a new forward migration that reverses the change rather than deleting history, when possible. Deleting rows from `__drizzle_migrations` is only appropriate when you are certain no other environment depends on that migration record.

---

## 3. Roll Back to a Specific Migration

To roll back multiple migrations to a target point:

1. **List applied migrations in reverse chronological order:**

   ```bash
   psql "$DATABASE_URL" -c "SELECT id, hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at DESC;"
   ```

2. **Determine the target migration** you want to keep. Everything applied *after* it must be reversed.

3. **Write reverse SQL** for each migration to be undone, in reverse order (newest first). Combine them into a single script, e.g. `drizzle/rollback_to_<target>.sql`.

4. **Apply the reverse script:**

   ```bash
   psql "$DATABASE_URL" -f drizzle/rollback_to_<target>.sql
   ```

5. **Delete the corresponding rows** from the migrations table:

   ```bash
   psql "$DATABASE_URL" -c "DELETE FROM drizzle.__drizzle_migrations WHERE id IN ('<id1>', '<id2>', ...);"
   ```

6. **Verify** with the checklist in section 5.

---

## 4. Restore from a Supabase Point-in-Time Backup

Use this when a rollback cannot be expressed as reverse SQL, or when data corruption occurred.

1. **Open the Supabase Dashboard** → your project → **Database** → **Backups**.

2. **Choose a point in time** prior to the problematic migration. Supabase retains PITR backups based on your plan's retention window.

3. **Initiate the restore.** Supabase will provision a restored instance. Note the connection details of the restored database.

4. **Validate the restored data** before switching traffic:
   - Confirm the target migration state in `drizzle.__drizzle_migrations`.
   - Spot-check critical tables and row counts.

5. **Repoint the application** to the restored database by updating `DATABASE_URL` (and any Supabase keys if the project reference changed).

6. **Re-apply any migrations** that were intentionally made after the restore point, using `drizzle-kit`:

   ```bash
   npx drizzle-kit migrate
   ```

7. **Verify** with the checklist in section 5.

> ⚠️ PITR restores are destructive to the current database state. Always take a manual snapshot or confirm the restore target before proceeding.

---

## 5. Pre/Post-Rollback Verification Checklist

### Pre-Rollback

- [ ] Confirmed the migration(s) to be rolled back and their IDs.
- [ ] Captured a fresh backup / snapshot of the current database.
- [ ] Notified stakeholders and confirmed a maintenance window if needed.
- [ ] Application traffic paused or put into read-only mode (if applicable).
- [ ] Reverse SQL script reviewed by a second engineer.
- [ ] Verified `DATABASE_URL` points to the intended environment (not production by accident).

### Post-Rollback

- [ ] Reverse SQL applied without errors.
- [ ] `drizzle.__drizzle_migrations` reflects the expected state:
      `psql "$DATABASE_URL" -c "SELECT id, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at;"`
- [ ] Schema matches expectations (tables, columns, constraints, indexes).
- [ ] Application starts successfully and connects to the database.
- [ ] Smoke tests pass (auth, core read/write paths).
- [ ] No orphaned or missing foreign key references.
- [ ] Logs show no migration- or schema-related errors.
- [ ] Stakeholders notified that rollback is complete.

---

## Notes

- Always run migrations and rollbacks against a staging environment first.
- Keep reverse SQL scripts in version control alongside the forward migrations.
- If unsure, prefer restoring from a Supabase backup over ad-hoc SQL edits.