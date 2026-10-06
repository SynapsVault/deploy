#!/usr/bin/env bash
#
# restore.sh - Restore a Postgres database from an encrypted backup produced by
# scripts/backup.sh, with an optional verification mode.
#
# Usage:
#   scripts/restore.sh [--backup <name>] [options]
#
# Options:
#   --backup <name>        Backup name, e.g. soroban-backup-20260101T020000Z
#                          (default: the newest backup in object storage)
#   --database-url <url>   Target Postgres connection string (default: $DATABASE_URL)
#   --verify-only          Restore into a throwaway database, check every table
#                          from the backup came back, then drop it
#   --work-dir <dir>       Working directory for downloads (default: mktemp -d)
#   --keep-work-dir        Do not delete the working directory on exit
#   --skip-contract-state  Do not re-apply CONTRACT_STATE_FILE after restore
#   -h, --help             Show this help
#
# Environment (same names as backup.sh; legacy names in parentheses):
#   BACKUP_STORAGE_BUCKET            Bucket name (BACKUP_BUCKET) - required
#   BACKUP_STORAGE_ENDPOINT          S3-compatible endpoint URL (BACKUP_ENDPOINT)
#   BACKUP_STORAGE_PREFIX            Key prefix, default "backups" (BACKUP_PREFIX)
#   BACKUP_STORAGE_REGION            Region, default us-east-1 (AWS_DEFAULT_REGION)
#   BACKUP_STORAGE_ACCESS_KEY_ID     Credentials (AWS_ACCESS_KEY_ID)
#   BACKUP_STORAGE_SECRET_ACCESS_KEY Credentials (AWS_SECRET_ACCESS_KEY)
#   BACKUP_ENCRYPTION_KEY            gpg passphrase used by backup.sh
#   BACKUP_AGE_IDENTITY_FILE         age identity file, for age-encrypted backups
#   DATABASE_URL                     Default target database connection string
#   CONTRACT_STATE_FILE              Optional SQL file to apply after restore
#
# Exit codes:
#   0  success
#   1  usage / configuration error
#   2  download or checksum failure
#   3  decryption failure
#   4  restore failure
#   5  verification mismatch
#
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  local code="$1"
  shift
  log "ERROR: $*"
  exit "$code"
}

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BACKUP_NAME=""
DATABASE_URL_ARG=""
VERIFY_ONLY="false"
WORK_DIR=""
KEEP_WORK_DIR="false"
SKIP_CONTRACT_STATE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      [[ $# -ge 2 ]] || die 1 "--backup requires a value"
      BACKUP_NAME="$2"
      shift 2
      ;;
    --database-url)
      [[ $# -ge 2 ]] || die 1 "--database-url requires a value"
      DATABASE_URL_ARG="$2"
      shift 2
      ;;
    --verify-only)
      VERIFY_ONLY="true"
      shift
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die 1 "--work-dir requires a value"
      WORK_DIR="$2"
      shift 2
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR="true"
      shift
      ;;
    --skip-contract-state)
      SKIP_CONTRACT_STATE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die 1 "unknown argument: $1"
      ;;
  esac
done

# Accept either a bare name or a full object name with a known suffix.
BACKUP_NAME="${BACKUP_NAME%.manifest.json}"
BACKUP_NAME="${BACKUP_NAME%.tar.gz.enc}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BUCKET="${BACKUP_STORAGE_BUCKET:-${BACKUP_BUCKET:-}}"
ENDPOINT="${BACKUP_STORAGE_ENDPOINT:-${BACKUP_ENDPOINT:-}}"
PREFIX="${BACKUP_STORAGE_PREFIX:-${BACKUP_PREFIX:-backups}}"
PREFIX="${PREFIX%/}"
REGION="${BACKUP_STORAGE_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_AGE_IDENTITY_FILE="${BACKUP_AGE_IDENTITY_FILE:-}"
CONTRACT_STATE_FILE="${CONTRACT_STATE_FILE:-}"

TARGET_DATABASE_URL="${DATABASE_URL_ARG:-${DATABASE_URL:-}}"

[[ -n "$BUCKET" ]] || die 1 "BACKUP_STORAGE_BUCKET is not set"
[[ -n "$TARGET_DATABASE_URL" ]] || die 1 "target database URL is not set (use --database-url or DATABASE_URL)"

for tool in aws psql gzip tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die 1 "required tool not found: $tool"
done

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d)"
  CREATED_WORK_DIR="true"
else
  mkdir -p "$WORK_DIR"
  CREATED_WORK_DIR="false"
fi

VERIFY_DB=""

# shellcheck disable=SC2317  # invoked via the EXIT trap below
cleanup() {
  local status=$?
  if [[ -n "$VERIFY_DB" ]]; then
    psql "$TARGET_DATABASE_URL" -X -q -c "DROP DATABASE IF EXISTS \"$VERIFY_DB\";" >/dev/null 2>&1 || \
      log "WARNING: could not drop verification database $VERIFY_DB"
  fi
  if [[ "$KEEP_WORK_DIR" != "true" && "$CREATED_WORK_DIR" == "true" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Object storage helpers
# ---------------------------------------------------------------------------
AWS_ARGS=(--region "$REGION")
if [[ -n "$ENDPOINT" ]]; then
  AWS_ARGS+=(--endpoint-url "${ENDPOINT%/}")
fi

download_object() {
  local key="$1" dest="$2"
  log "downloading s3://$BUCKET/$key"
  aws "${AWS_ARGS[@]}" s3 cp "s3://$BUCKET/$key" "$dest" --only-show-errors \
    || die 2 "failed to download $key"
}

latest_backup_name() {
  # Backup names embed a UTC timestamp, so lexical order is chronological.
  aws "${AWS_ARGS[@]}" s3 ls "s3://$BUCKET/$PREFIX/" \
    | awk '{print $4}' \
    | grep -E '\.manifest\.json$' \
    | sort \
    | tail -n 1 \
    | sed 's/\.manifest\.json$//'
}

# Read a string field from the manifest written by backup.sh. The manifest has
# one "key": "value" pair per line, so a sed match is enough (no jq needed).
manifest_field() {
  local field="$1" file="$2"
  sed -n "s/^ *\"$field\": *\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

# Replace the database name in a postgres:// URL, keeping any query string.
with_database() {
  local url="$1" db="$2"
  if [[ "$url" =~ ^(postgres(ql)?://[^/?]+)(/[^?]*)?(\?.*)?$ ]]; then
    printf '%s/%s%s' "${BASH_REMATCH[1]}" "$db" "${BASH_REMATCH[4]}"
  else
    die 1 "cannot parse database URL for --verify-only (expected postgres://...)"
  fi
}

# ---------------------------------------------------------------------------
# Download, verify, decrypt, extract
# ---------------------------------------------------------------------------
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="$(latest_backup_name || true)"
  [[ -n "$BACKUP_NAME" ]] || die 2 "no backups found under s3://$BUCKET/$PREFIX/"
  log "no --backup given; using newest backup: $BACKUP_NAME"
fi

MANIFEST_PATH="$WORK_DIR/$BACKUP_NAME.manifest.json"
download_object "$PREFIX/$BACKUP_NAME.manifest.json" "$MANIFEST_PATH"

ARCHIVE_KEY="$(manifest_field key "$MANIFEST_PATH")"
EXPECTED_SUM="$(manifest_field value "$MANIFEST_PATH")"
ENCRYPTION_METHOD="$(manifest_field method "$MANIFEST_PATH")"
[[ -n "$ARCHIVE_KEY" ]] || ARCHIVE_KEY="$PREFIX/$BACKUP_NAME.tar.gz.enc"
[[ "$EXPECTED_SUM" =~ ^[0-9a-f]{64}$ ]] || die 2 "manifest has no valid sha256 checksum"

ENCRYPTED_PATH="$WORK_DIR/backup.tar.gz.enc"
download_object "$ARCHIVE_KEY" "$ENCRYPTED_PATH"

log "verifying checksum"
ACTUAL_SUM="$(sha256sum "$ENCRYPTED_PATH" | awk '{print $1}')"
if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
  die 2 "checksum mismatch: expected $EXPECTED_SUM, got $ACTUAL_SUM"
fi
log "checksum OK ($ACTUAL_SUM)"

ARCHIVE_PATH="$WORK_DIR/backup.tar.gz"
log "decrypting archive (method: ${ENCRYPTION_METHOD:-unknown})"
case "$ENCRYPTION_METHOD" in
  gpg)
    command -v gpg >/dev/null 2>&1 || die 1 "required tool not found: gpg"
    if [[ -n "$BACKUP_ENCRYPTION_KEY" && ! -f "$BACKUP_ENCRYPTION_KEY" ]]; then
      # Symmetric (passphrase) encryption.
      printf '%s' "$BACKUP_ENCRYPTION_KEY" \
        | gpg --batch --yes --no-tty --quiet --passphrase-fd 0 --pinentry-mode loopback \
            --output "$ARCHIVE_PATH" --decrypt "$ENCRYPTED_PATH" \
        || die 3 "decryption failed (wrong passphrase or corrupt archive)"
    else
      # Public-key encryption: the private key must be in the local keyring.
      gpg --batch --yes --no-tty --quiet --output "$ARCHIVE_PATH" --decrypt "$ENCRYPTED_PATH" \
        || die 3 "decryption failed (is the private key imported?)"
    fi
    ;;
  age)
    command -v age >/dev/null 2>&1 || die 1 "required tool not found: age"
    [[ -f "$BACKUP_AGE_IDENTITY_FILE" ]] || die 1 "BACKUP_AGE_IDENTITY_FILE is required for age-encrypted backups"
    age --decrypt --identity "$BACKUP_AGE_IDENTITY_FILE" --output "$ARCHIVE_PATH" "$ENCRYPTED_PATH" \
      || die 3 "decryption failed (wrong identity or corrupt archive)"
    ;;
  none)
    cp -f "$ENCRYPTED_PATH" "$ARCHIVE_PATH"
    ;;
  *)
    die 3 "unsupported encryption method in manifest: '${ENCRYPTION_METHOD}'"
    ;;
esac

EXTRACT_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" || die 3 "archive is not a valid tar.gz"

DUMP_PATH="$EXTRACT_DIR/database.sql.gz"
[[ -f "$DUMP_PATH" ]] || die 4 "backup does not contain a database dump (was it taken with BACKUP_SKIP_DB=1?)"
if [[ -d "$EXTRACT_DIR/contracts" ]]; then
  log "contract state snapshots extracted to $EXTRACT_DIR/contracts (use --keep-work-dir to inspect)"
fi

# ---------------------------------------------------------------------------
# Restore helpers
# ---------------------------------------------------------------------------
psql_exec() {
  local url="$1"
  shift
  psql "$url" -v ON_ERROR_STOP=1 -q -X "$@"
}

restore_into() {
  local url="$1"
  log "restoring into target database"
  # The dump contains DROP ... IF EXISTS statements, so it can be replayed onto
  # an existing database. A single transaction makes a failed restore a no-op.
  gzip -dc "$DUMP_PATH" | psql_exec "$url" --single-transaction >/dev/null \
    || die 4 "restore failed; the transaction was rolled back"
}

apply_contract_state() {
  local url="$1"
  if [[ "$SKIP_CONTRACT_STATE" == "true" ]]; then
    log "skipping contract state re-application (--skip-contract-state)"
    return 0
  fi
  if [[ -z "$CONTRACT_STATE_FILE" ]]; then
    log "no CONTRACT_STATE_FILE configured; skipping contract state re-application"
    return 0
  fi
  [[ -f "$CONTRACT_STATE_FILE" ]] || die 4 "contract state file not found: $CONTRACT_STATE_FILE"
  log "re-applying contract state from $CONTRACT_STATE_FILE"
  psql_exec "$url" -f "$CONTRACT_STATE_FILE" || die 4 "failed to re-apply contract state"
}

# ---------------------------------------------------------------------------
# Verification mode
# ---------------------------------------------------------------------------
verify_restore() {
  local base_url="$1"
  VERIFY_DB="restore_verify_$(date -u +%Y%m%d%H%M%S)_$$"
  log "verify-only mode: restoring into throwaway database '$VERIFY_DB'"

  psql_exec "$base_url" -c "CREATE DATABASE \"$VERIFY_DB\";" \
    || die 4 "failed to create verification database (does the role have CREATEDB?)"

  local verify_url
  verify_url="$(with_database "$base_url" "$VERIFY_DB")"
  restore_into "$verify_url"

  local restored
  restored="$(psql_exec "$verify_url" -At -c \
    "SELECT schemaname || '.' || tablename FROM pg_tables
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      ORDER BY 1;")"

  local mismatch=0
  if [[ -z "$restored" ]]; then
    log "ERROR: no tables found after restore"
    mismatch=1
  fi

  # Every table must be readable; log row counts for the job output.
  local table
  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    local schema="${table%%.*}" name="${table#*.}" count
    if ! count="$(psql_exec "$verify_url" -At -c "SELECT count(*) FROM \"$schema\".\"$name\";")"; then
      log "ERROR: could not read table $table"
      mismatch=1
      continue
    fi
    log "table $table: $count rows"
  done <<< "$restored"

  # Every table recorded at backup time must exist after restore.
  local expected_list="$EXTRACT_DIR/tables.txt"
  if [[ -f "$expected_list" ]]; then
    log "comparing restored tables against the backup's table list"
    while IFS= read -r table; do
      [[ -n "$table" ]] || continue
      if ! grep -qxF "$table" <<< "$restored"; then
        log "ERROR: expected table missing after restore: $table"
        mismatch=1
      fi
    done < "$expected_list"
  else
    log "WARNING: backup has no tables.txt; skipping table list comparison"
  fi

  if [[ "$mismatch" -ne 0 ]]; then
    die 5 "verification failed: integrity mismatch"
  fi

  log "verification passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$VERIFY_ONLY" == "true" ]]; then
  verify_restore "$TARGET_DATABASE_URL"
else
  restore_into "$TARGET_DATABASE_URL"
  apply_contract_state "$TARGET_DATABASE_URL"
  log "restore complete"
fi

exit 0
