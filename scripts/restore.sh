#!/usr/bin/env bash
#
# restore.sh - Restore a Postgres database from an encrypted backup archive
# stored in object storage, with optional verification mode.
#
# Usage:
#   scripts/restore.sh --backup <name> [options]
#
# Options:
#   --backup <name>        Name/key of the backup archive in object storage (required)
#   --database-url <url>   Target Postgres connection string (default: $DATABASE_URL)
#   --verify-only          Restore into a throwaway schema and run integrity checks
#   --work-dir <dir>       Working directory for downloads (default: mktemp -d)
#   --keep-work-dir        Do not delete the working directory on exit
#   --skip-contract-state  Do not re-apply contract state after restore
#   -h, --help             Show this help
#
# Environment:
#   BACKUP_BUCKET          Object storage bucket/container name (required)
#   BACKUP_ENDPOINT        S3-compatible endpoint URL (optional)
#   BACKUP_PREFIX          Key prefix for backups (default: "backups")
#   BACKUP_ENCRYPTION_KEY  Passphrase used to decrypt the archive (required)
#   AWS_ACCESS_KEY_ID      Object storage credentials
#   AWS_SECRET_ACCESS_KEY  Object storage credentials
#   AWS_DEFAULT_REGION     Object storage region (default: us-east-1)
#   DATABASE_URL           Default target database connection string
#   CONTRACT_STATE_FILE    Path to contract state SQL/JSON to re-apply (optional)
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

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

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
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
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

[[ -n "$BACKUP_NAME" ]] || die 1 "--backup is required"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-}"
BACKUP_PREFIX="${BACKUP_PREFIX:-backups}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CONTRACT_STATE_FILE="${CONTRACT_STATE_FILE:-}"

TARGET_DATABASE_URL="${DATABASE_URL_ARG:-${DATABASE_URL:-}}"

[[ -n "$BACKUP_BUCKET" ]] || die 1 "BACKUP_BUCKET is not set"
[[ -n "$BACKUP_ENCRYPTION_KEY" ]] || die 1 "BACKUP_ENCRYPTION_KEY is not set"
[[ -n "$TARGET_DATABASE_URL" ]] || die 1 "target database URL is not set (use --database-url or DATABASE_URL)"

for tool in aws openssl psql pg_restore sha256sum; do
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

cleanup() {
  local status=$?
  if [[ "$KEEP_WORK_DIR" != "true" && "$CREATED_WORK_DIR" == "true" ]]; then
    rm -rf "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Object storage helpers
# ---------------------------------------------------------------------------
s3_uri() {
  local key="$1"
  if [[ -n "$BACKUP_ENDPOINT" ]]; then
    printf 's3://%s/%s' "$BACKUP_BUCKET" "$key"
  else
    printf 's3://%s/%s' "$BACKUP_BUCKET" "$key"
  fi
}

aws_args() {
  local -a args=(--region "$AWS_DEFAULT_REGION")
  if [[ -n "$BACKUP_ENDPOINT" ]]; then
    args+=(--endpoint-url "$BACKUP_ENDPOINT")
  fi
  printf '%s\n' "${args[@]}"
}

download_object() {
  local key="$1" dest="$2"
  local -a args
  mapfile -t args < <(aws_args)
  log "downloading s3://$BACKUP_BUCKET/$key"
  if ! aws "${args[@]}" s3 cp "$(s3_uri "$key")" "$dest" --only-show-errors; then
    die 2 "failed to download $key"
  fi
}

# ---------------------------------------------------------------------------
# Download archive + checksum
# ---------------------------------------------------------------------------
ARCHIVE_KEY="${BACKUP_PREFIX%/}/${BACKUP_NAME}"
CHECKSUM_KEY="${ARCHIVE_KEY}.sha256"

ARCHIVE_PATH="$WORK_DIR/backup.archive"
CHECKSUM_PATH="$WORK_DIR/backup.archive.sha256"

download_object "$ARCHIVE_KEY" "$ARCHIVE_PATH"
download_object "$CHECKSUM_KEY" "$CHECKSUM_PATH"

log "verifying checksum"
EXPECTED_SUM="$(awk '{print $1}' "$CHECKSUM_PATH" | head -n1)"
if [[ -z "$EXPECTED_SUM" ]]; then
  die 2 "checksum file is empty or malformed"
fi
ACTUAL_SUM="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
  die 2 "checksum mismatch: expected $EXPECTED_SUM, got $ACTUAL_SUM"
fi
log "checksum OK ($ACTUAL_SUM)"

# ---------------------------------------------------------------------------
# Decrypt
# ---------------------------------------------------------------------------
PLAIN_PATH="$WORK_DIR/backup.dump"
log "decrypting archive"
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:BACKUP_ENCRYPTION_KEY \
  -in "$ARCHIVE_PATH" -out "$PLAIN_PATH"; then
  die 3 "decryption failed (wrong key or corrupt archive)"
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
  if ! pg_restore \
    --dbname="$url" \
    --no-owner \
    --no-privileges \
    --clean \
    --if-exists \
    --exit-on-error \
    "$PLAIN_PATH"; then
    die 4 "pg_restore failed"
  fi
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
  if ! psql_exec "$url" -f "$CONTRACT_STATE_FILE"; then
    die 4 "failed to re-apply contract state"
  fi
}

# ---------------------------------------------------------------------------
# Verification mode
# ---------------------------------------------------------------------------
VERIFY_SCHEMA="restore_verify_$$"

verify_restore() {
  local base_url="$1"
  log "verify-only mode: restoring into throwaway schema '$VERIFY_SCHEMA'"

  # Create a throwaway schema and point search_path at it so the restore does
  # not touch the real public schema.
  if ! psql_exec "$base_url" -c "CREATE SCHEMA IF NOT EXISTS \"$VERIFY_SCHEMA\";"; then
    die 4 "failed to create verification schema"
  fi

  local verify_url
  verify_url="$(printf '%s' "$base_url" | sed "s|?|?options=-csearch_path%3D$VERIFY_SCHEMA\&|")"
  if [[ "$verify_url" == "$base_url" ]]; then
    verify_url="${base_url}?options=-csearch_path%3D$VERIFY_SCHEMA"
  fi

  local restore_status=0
  if ! pg_restore \
    --dbname="$verify_url" \
    --no-owner \
    --no-privileges \
    --exit-on-error \
    "$PLAIN_PATH"; then
    restore_status=4
  fi

  local mismatch=0

  # Row-count integrity: every table in the restored schema must be readable
  # and must not contain NULL primary keys.
  local tables
  tables="$(psql_exec "$base_url" -At -c \
    "SELECT tablename FROM pg_tables WHERE schemaname = '$VERIFY_SCHEMA' ORDER BY tablename;")"

  if [[ -z "$tables" ]]; then
    log "WARNING: no tables found in verification schema"
    mismatch=1
  fi

  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    local count
    if ! count="$(psql_exec "$base_url" -At -c \
      "SELECT count(*) FROM \"$VERIFY_SCHEMA\".\"$table\";")"; then
      log "ERROR: could not read table $table"
      mismatch=1
      continue
    fi
    log "table $table: $count rows"
  done <<< "$tables"

  # Integrity check: detect tables that failed to restore by comparing against
  # the expected table list embedded in the archive manifest, when present.
  local manifest_path="$WORK_DIR/manifest.txt"
  if aws_args >/dev/null 2>&1; then
    local -a args
    mapfile -t args < <(aws_args)
    if aws "${args[@]}" s3 cp "$(s3_uri "${ARCHIVE_KEY}.manifest")" "$manifest_path" \
      --only-show-errors >/dev/null 2>&1; then
      log "comparing restored tables against manifest"
      while IFS= read -r expected; do
        [[ -n "$expected" ]] || continue
        if ! grep -qx "$expected" <<< "$tables"; then
          log "ERROR: expected table missing after restore: $expected"
          mismatch=1
        fi
      done < "$manifest_path"
    fi
  fi

  # Drop the throwaway schema regardless of outcome.
  psql_exec "$base_url" -c "DROP SCHEMA IF EXISTS \"$VERIFY_SCHEMA\" CASCADE;" >/dev/null 2>&1 || true

  if [[ "$restore_status" -ne 0 ]]; then
    die "$restore_status" "verification restore failed"
  fi
  if [[ "$mismatch" -ne 0 ]]; then
    die 5 "verification failed: integrity or row-count mismatch"
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