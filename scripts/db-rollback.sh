#!/usr/bin/env bash
#
# db-rollback.sh
#
# Reverts the most recent database migration using drizzle-kit.
#
# Usage:
#   ./scripts/db-rollback.sh [options]
#
# Options:
#   -e, --env <name>     Environment name (e.g. development, staging, production).
#                        Defaults to the value of NODE_ENV, or "development".
#   -y, --yes            Skip the interactive confirmation prompt.
#   -h, --help           Show this help message and exit.
#
# Environment variables:
#   DATABASE_URL         Required. Connection string for the target database.
#   NODE_ENV             Used as the default environment when --env is not given.
#
# Behavior:
#   - Validates that DATABASE_URL is set before doing anything else.
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

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

error() {
  printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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

if ! command -v npx >/dev/null 2>&1; then
  error "npx is not available. Install Node.js and npm before running ${SCRIPT_NAME}."
  exit 1
fi

log "Environment: ${ENVIRONMENT}"

if [ "${ENVIRONMENT}" = "production" ] && [ "${ASSUME_YES}" != "true" ]; then
  log "WARNING: You are about to roll back a migration in PRODUCTION."
  printf 'Type "yes" to continue: '
  read -r CONFIRMATION
  if [ "${CONFIRMATION}" != "yes" ]; then
    log "Rollback aborted by user."
    exit 2
  fi
fi

log "Reverting the most recent migration..."

set +e
npx drizzle-kit down
STATUS=$?
set -e

if [ "${STATUS}" -ne 0 ]; then
  error "Rollback failed with exit code ${STATUS}."
  exit 3
fi

log "Rollback completed successfully."
exit 0