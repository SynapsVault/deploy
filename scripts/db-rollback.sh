#!/usr/bin/env bash
#
# db-rollback.sh
#
# Reverts the most recent Drizzle migration by applying a hand-written reverse
# SQL file and removing the migration's row from drizzle.__drizzle_migrations,
# both inside a single transaction. Drizzle has no built-in "down" migrations;
# see docs/DATABASE-ROLLBACK.md for the full runbook.
#
# Usage:
#   ./scripts/db-rollback.sh --file <reverse.sql> [options]
#
# Options:
#   -f, --file <path>    Required. Reverse SQL that undoes the latest migration.
#   -e, --env <name>     Environment name (e.g. development, staging, production).
#                        Defaults to the value of NODE_ENV, or "development".
#   -n, --dry-run        Show what would be rolled back, then roll the
#                        transaction back instead of committing it.
#   -y, --yes            Skip the interactive confirmation prompt.
#   -h, --help           Show this help message and exit.
#
# Environment variables:
#   DATABASE_URL         Required. Connection string for the target database.
#   NODE_ENV             Used as the default environment when --env is not given.
#
# Behavior:
#   - Validates DATABASE_URL, the reverse SQL file and psql before doing anything.
#   - In production, prompts for explicit confirmation unless --yes is passed.
#   - Logs the migration being reverted and the outcome.
#
# Exit codes:
#   0  Rollback completed successfully.
#   1  Invalid usage or missing configuration.
#   2  User aborted the rollback.
#   3  Rollback command failed.
#

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

ENVIRONMENT="${NODE_ENV:-development}"
ASSUME_YES="false"
DRY_RUN="false"
REVERSE_SQL=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

error() {
  printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -e|--env)
      if [ -z "${2:-}" ]; then
        error "Option $1 requires an argument."
        exit 1
      fi
      ENVIRONMENT="$2"
      shift 2
      ;;
    -f|--file)
      if [ -z "${2:-}" ]; then
        error "Option $1 requires an argument."
        exit 1
      fi
      REVERSE_SQL="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN="true"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${DATABASE_URL:-}" ]; then
  error "DATABASE_URL is not set. Export it before running ${SCRIPT_NAME}."
  exit 1
fi

if [ -z "${REVERSE_SQL}" ]; then
  error "--file <reverse.sql> is required (Drizzle has no automatic down migrations)."
  exit 1
fi

if [ ! -r "${REVERSE_SQL}" ]; then
  error "Reverse SQL file not found or not readable: ${REVERSE_SQL}"
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  error "psql is not available. Install the PostgreSQL client before running ${SCRIPT_NAME}."
  exit 1
fi

log "Environment: ${ENVIRONMENT}"

LAST_MIGRATION="$(psql "${DATABASE_URL}" -X -At -v ON_ERROR_STOP=1 -c \
  "SELECT id || ' (hash ' || hash || ', created_at ' || created_at || ')'
     FROM drizzle.__drizzle_migrations ORDER BY created_at DESC, id DESC LIMIT 1;")" || {
  error "Could not read drizzle.__drizzle_migrations. Is DATABASE_URL correct?"
  exit 1
}

if [ -z "${LAST_MIGRATION}" ]; then
  error "No applied migrations recorded in drizzle.__drizzle_migrations; nothing to roll back."
  exit 1
fi

log "Latest applied migration: ${LAST_MIGRATION}"
log "Reverse SQL: ${REVERSE_SQL}"

if [ "${ENVIRONMENT}" = "production" ] && [ "${ASSUME_YES}" != "true" ]; then
  log "WARNING: You are about to roll back a migration in PRODUCTION."
  printf 'Type "yes" to continue: '
  read -r CONFIRMATION || CONFIRMATION=""
  if [ "${CONFIRMATION}" != "yes" ]; then
    log "Rollback aborted by user."
    exit 2
  fi
fi

if [ "${DRY_RUN}" = "true" ]; then
  FINISH="ROLLBACK"
  log "Dry run: the transaction will be rolled back, not committed."
else
  FINISH="COMMIT"
fi

log "Reverting the most recent migration..."

# Run the reverse SQL and the journal update in one transaction so a failure
# leaves both the schema and drizzle.__drizzle_migrations untouched.
set +e
psql "${DATABASE_URL}" -X -v ON_ERROR_STOP=1 \
  -c "BEGIN;" \
  -f "${REVERSE_SQL}" \
  -c "DELETE FROM drizzle.__drizzle_migrations
        WHERE id = (SELECT id FROM drizzle.__drizzle_migrations
                    ORDER BY created_at DESC, id DESC LIMIT 1);" \
  -c "${FINISH};"
STATUS=$?
set -e

if [ "${STATUS}" -ne 0 ]; then
  error "Rollback failed with exit code ${STATUS}; no changes were committed."
  exit 3
fi

if [ "${DRY_RUN}" = "true" ]; then
  log "Dry run completed successfully; no changes were committed."
else
  log "Rollback completed successfully."
fi
exit 0