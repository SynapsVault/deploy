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
#   --plan                 Inspect the backup and report its components, versions
#                          and intended target without writing to any database
#                          (no CREATE DATABASE, no restore, no post-restore SQL)
#   --work-dir <dir>       Working directory for downloads (default: mktemp -d)
#   --keep-work-dir        Do not delete the working directory on exit
#   --post-restore-sql <f> Optional SQL script to run against Postgres after
#                          restoring (aliases $CONTRACT_STATE_FILE). Note: this
#                          is a PostgreSQL .sql script, NOT the on-chain JSON
#                          snapshots under contracts/ in the backup archive.
#   --skip-contract-state  Do not apply CONTRACT_STATE_FILE / --post-restore-sql
#   --verify-grants        After restore, verify the application role can access
#                          every restored table (SELECT/INSERT/UPDATE/DELETE).
#                          Requires APP_DB_ROLE. Never grants privileges itself.
#   --audit-report <path>  Write a sanitized JSON restore audit report to <path>
#                          (default: $RESTORE_AUDIT_REPORT, if set)
#   -y, --yes              Skip interactive confirmation when restoring over a
#                          non-throwaway target database
#   -h, --help             Show this help
#
# Environment (same names as backup.sh; legacy names in parentheses):
#   BACKUP_STORAGE_PROVIDER          s3 (default) or supabase
#   BACKUP_STORAGE_BUCKET            Bucket name (BACKUP_BUCKET) - required
#   BACKUP_STORAGE_ENDPOINT          S3-compatible endpoint URL (BACKUP_ENDPOINT)
#   BACKUP_STORAGE_PREFIX            Key prefix, default "backups" (BACKUP_PREFIX)
#   BACKUP_STORAGE_REGION            Region, default us-east-1 (AWS_DEFAULT_REGION)
#   BACKUP_STORAGE_ACCESS_KEY_ID     Credentials (AWS_ACCESS_KEY_ID)
#   BACKUP_STORAGE_SECRET_ACCESS_KEY Credentials (AWS_SECRET_ACCESS_KEY)
#   BACKUP_STORAGE_SUPABASE_URL      Supabase project URL (when provider=supabase)
#   BACKUP_STORAGE_SUPABASE_SERVICE_KEY Supabase service role key (when provider=supabase)
#   BACKUP_ENCRYPTION_KEY            gpg passphrase used by backup.sh
#   BACKUP_AGE_IDENTITY_FILE         age identity file, for age-encrypted backups
#   DATABASE_URL                     Default target database connection string
#   CONTRACT_STATE_FILE              Optional post-restore PostgreSQL .sql file
#                                    (e.g. to update contract ID rows in DB;
#                                    for repointing env/ConfigMap contract IDs,
#                                    use scripts/rollback-contracts.cjs instead)
#   APP_DB_ROLE                      Application role checked by --verify-grants
#                                    (dumps omit ownership/grants, so this
#                                    confirms the role can still reach tables)
#   RESTORE_MAX_MEMBERS              Maximum number of archive members allowed
#                                    (default: 10000). Archives with more
#                                    members are rejected before extraction.
#   RESTORE_MAX_UNCOMPRESSED_BYTES   Maximum total uncompressed size of archive
#                                    members in bytes (default: 10737418240,
#                                    i.e. 10 GiB). Oversized archives are
#                                    rejected before extraction.
#
# Restore safety / verification:
#   RESTORE_REQUIRED_EXTENSIONS      Comma-separated extensions that must be
#                                    available on the target (also read from the
#                                    backup manifest's "extensions" list)
#   RESTORE_LOCK_TIMEOUT             lock_timeout for restore sessions, default 30s
#   RESTORE_STATEMENT_TIMEOUT        statement_timeout for restore sessions,
#                                    default 30min (0 disables)
#   RESTORE_CRITICAL_TABLES          Critical tables with expected counts/bounds,
#                                    e.g. "public.accounts>=100,public.ledger=42"
#                                    (also read from critical-tables.txt in the
#                                    backup archive when present)
#   RESTORE_AUDIT_REPORT             Path for the sanitized JSON audit report
#                                    (never contains passwords; CI-artifact safe)
#
# Exit codes:
#   0  success
#   1  usage / configuration error, or target preflight failure
#      (unreachable database or missing required privileges)
#   2  download or checksum failure
#   3  decryption failure
#   4  restore failure
#   5  verification mismatch (table list or application role grants)
#   6  pre-flight check failed (missing extensions / permissions / lock timeout)
#
set -euo pipefail
umask 077

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
  sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'
}

# Read a string field from the manifest written by backup.sh. The manifest has
# one "key": "value" pair per line, so a sed match is enough (no jq needed).
manifest_field() {
  local field="$1" file="$2"
  sed -n "s/^ *\"$field\": *\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

# Read a per-component checksum from the manifest's "components" object, e.g.
#   "components": {
#     "database.sql.gz": "sha256:<hex>",
#     "contracts": "sha256:<hex>"
#   }
# Returns the bare hex digest, or nothing when the component is not recorded.
manifest_component_sum() {
  local component="$1" file="$2"
  sed -n "s/^ *\"$component\": *\"sha256:\\([0-9a-f]\\{64\\}\\)\".*/\\1/p" "$file" | head -n 1
}

# Read a JSON string array field from the manifest, one element per line, e.g.
#   "extensions": ["pgcrypto", "uuid-ossp"]
# Tolerates a missing field (returns nothing).
manifest_string_array() {
  local field="$1" file="$2"
  python3 - "$field" "$file" <<'PY' 2>/dev/null || true
import json, sys
field, path = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
value = data.get(field)
if isinstance(value, list):
    for item in value:
        if isinstance(item, str) and item:
            print(item)
PY
}

# Redact password-like values from a connection string or free-form text so the
# audit report can be uploaded as a CI artifact.
redact_secrets() {
  local text="$1"
  # postgres://user:password@host -> postgres://user:***@host
  text="$(printf '%s' "$text" | sed -E 's#(://[^:/@]+):[^@/]*@#\1:***@#g')"
  # password=... / PGPASSWORD=... style assignments
  text="$(printf '%s' "$text" | sed -E 's#(([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Gg][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|passphrase)[[:space:]]*[=:][[:space:]]*)[^[:space:]",]+#\1***#g')"
  printf '%s' "$text"
}

# Parse a postgres:// URL into host, port, database and user without exposing
# the password. Prints "host<TAB>port<TAB>database<TAB>user".
parse_db_identity() {
  local url="$1"
  python3 - "$url" <<'PY' 2>/dev/null || printf '\t\t\t\n'
import sys
from urllib.parse import urlsplit, unquote
url = sys.argv[1]
try:
    parts = urlsplit(url)
except Exception:
    print("\t\t\t")
    sys.exit(0)
host = parts.hostname or ""
port = str(parts.port) if parts.port else ""
db = unquote(parts.path.lstrip("/")) if parts.path else ""
user = unquote(parts.username) if parts.username else ""
print("\t".join([host, port, db, user]))
PY
}

# Verify a per-component checksum recorded in the manifest against a file on
# disk. Missing manifest entries are tolerated (older manifests); a recorded
# checksum that does not match is fatal.
verify_component_sum() {
  local component="$1" path="$2" file="$3"
  local expected actual
  expected="$(manifest_component_sum "$component" "$file")"
  if [[ -z "$expected" ]]; then
    log "WARNING: manifest has no checksum for $component; skipping component verification"
    return 0
  fi
  [[ -f "$path" ]] || die 2 "cannot verify $component: file not found at $path"
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    die 2 "component checksum mismatch for $component: expected $expected, got $actual"
  fi
  log "component checksum OK for $component ($actual)"
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

# Report the database name (and host) of a postgres:// URL without connecting.
database_name_of() {
  local url="$1"
  if [[ "$url" =~ ^postgres(ql)?://([^/?]+)(/([^?]*))?(\?.*)?$ ]]; then
    local host="${BASH_REMATCH[2]}" db="${BASH_REMATCH[4]}"
    [[ -n "$db" ]] || db="(default)"
    printf '%s on %s' "$db" "$host"
  else
    printf '(unparseable URL)'
  fi
}

# Sourced by bats: expose with_database and manifest_field, then stop.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# ---------------------------------------------------------------------------
# Audit report state
# ---------------------------------------------------------------------------
AUDIT_REPORT_PATH=""
AUDIT_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
AUDIT_COMPONENTS=()   # "name<TAB>status<TAB>detail"
AUDIT_VERIFICATIONS=() # "name<TAB>status<TAB>detail"
AUDIT_TARGET_HOST=""
AUDIT_TARGET_PORT=""
AUDIT_TARGET_DB=""
AUDIT_TARGET_USER=""
AUDIT_MODE="restore"
AUDIT_EXIT_CODE=""

audit_component() {
  local name="$1" status="$2" detail="${3:-}"
  AUDIT_COMPONENTS+=("$(printf '%s\t%s\t%s' "$name" "$status" "$(redact_secrets "$detail")")")
}

audit_verification() {
  local name="$1" status="$2" detail="${3:-}"
  AUDIT_VERIFICATIONS+=("$(printf '%s\t%s\t%s' "$name" "$status" "$(redact_secrets "$detail")")")
}

# Emit the sanitized JSON audit report. Never includes passwords: target
# identity is host/port/db/user only and all free-form details are redacted.
write_audit_report() {
  [[ -n "$AUDIT_REPORT_PATH" ]] || return 0
  local ended_at
  ended_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$(dirname "$AUDIT_REPORT_PATH")" 2>/dev/null || true
  AUDIT_BACKUP_NAME="$BACKUP_NAME" \
  AUDIT_MODE="$AUDIT_MODE" \
  AUDIT_EXIT_CODE="${AUDIT_EXIT_CODE:-0}" \
  AUDIT_STARTED_AT="$AUDIT_STARTED_AT" \
  AUDIT_ENDED_AT="$ended_at" \
  AUDIT_TARGET_HOST="$AUDIT_TARGET_HOST" \
  AUDIT_TARGET_PORT="$AUDIT_TARGET_PORT" \
  AUDIT_TARGET_DB="$AUDIT_TARGET_DB" \
  AUDIT_TARGET_USER="$AUDIT_TARGET_USER" \
  AUDIT_STORAGE_PROVIDER="$STORAGE_PROVIDER" \
  AUDIT_STORAGE_BUCKET="$BUCKET" \
  AUDIT_COMPONENTS="$(printf '%s\n' "${AUDIT_COMPONENTS[@]:-}")" \
  AUDIT_VERIFICATIONS="$(printf '%s\n' "${AUDIT_VERIFICATIONS[@]:-}")" \
  python3 - "$AUDIT_REPORT_PATH" <<'PY' || log "WARNING: failed to write audit report to $AUDIT_REPORT_PATH"
import json, os, sys

def rows(var):
    out = []
    for line in os.environ.get(var, "").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 3:
            parts.append("")
        out.append({"name": parts[0], "status": parts[1], "detail": parts[2]})
    return out

report = {
    "schema_version": 1,
    "backup": os.environ.get("AUDIT_BACKUP_NAME", ""),
    "mode": os.environ.get("AUDIT_MODE", ""),
    "exit_code": int(os.environ.get("AUDIT_EXIT_CODE", "0") or 0),
    "started_at": os.environ.get("AUDIT_STARTED_AT", ""),
    "ended_at": os.environ.get("AUDIT_ENDED_AT", ""),
    "target": {
        "host": os.environ.get("AUDIT_TARGET_HOST", ""),
        "port": os.environ.get("AUDIT_TARGET_PORT", ""),
        "database": os.environ.get("AUDIT_TARGET_DB", ""),
        "user": os.environ.get("AUDIT_TARGET_USER", ""),
    },
    "storage": {
        "provider": os.environ.get("AUDIT_STORAGE_PROVIDER", ""),
        "bucket": os.environ.get("AUDIT_STORAGE_BUCKET", ""),
    },
    "components": rows("AUDIT_COMPONENTS"),
    "verifications": rows("AUDIT_VERIFICATIONS"),
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  log "wrote sanitized audit report to $AUDIT_REPORT_PATH"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
BACKUP_NAME=""
DATABASE_URL_ARG=""
VERIFY_ONLY="false"
PLAN_ONLY="false"
ASSUME_YES="false"
WORK_DIR=""
KEEP_WORK_DIR="false"
SKIP_CONTRACT_STATE="false"
POST_RESTORE_SQL_ARG=""
VERIFY_GRANTS="false"

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
    --plan)
      PLAN_ONLY="true"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="true"
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
    --post-restore-sql)
      [[ $# -ge 2 ]] || die 1 "--post-restore-sql requires a path to a .sql file"
      POST_RESTORE_SQL_ARG="$2"
      shift 2
      ;;
    --skip-contract-state)
      SKIP_CONTRACT_STATE="true"
      shift
      ;;
    --verify-grants)
      VERIFY_GRANTS="true"
      shift
      ;;
    --audit-report)
      [[ $# -ge 2 ]] || die 1 "--audit-report requires a path"
      AUDIT_REPORT_PATH="$2"
      shift 2
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

if [[ "$PLAN_ONLY" == "true" && "$VERIFY_ONLY" == "true" ]]; then
  die 1 "--plan and --verify-only are mutually exclusive"
fi

# Accept either a bare name or a full object name with a known suffix.
BACKUP_NAME="${BACKUP_NAME%.manifest.json}"
BACKUP_NAME="${BACKUP_NAME%.tar.gz.enc}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
STORAGE_PROVIDER="${BACKUP_STORAGE_PROVIDER:-s3}"
BUCKET="${BACKUP_STORAGE_BUCKET:-${BACKUP_BUCKET:-}}"
ENDPOINT="${BACKUP_STORAGE_ENDPOINT:-${BACKUP_ENDPOINT:-}}"
PREFIX="${BACKUP_STORAGE_PREFIX:-${BACKUP_PREFIX:-backups}}"
PREFIX="${PREFIX%/}"
REGION="${BACKUP_STORAGE_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
SUPABASE_URL="${BACKUP_STORAGE_SUPABASE_URL:-}"
SUPABASE_SERVICE_KEY="${BACKUP_STORAGE_SUPABASE_SERVICE_KEY:-}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_AGE_IDENTITY_FILE="${BACKUP_AGE_IDENTITY_FILE:-}"
CONTRACT_STATE_FILE="${CONTRACT_STATE_FILE:-}"
APP_DB_ROLE="${APP_DB_ROLE:-}"

TARGET_DATABASE_URL="${DATABASE_URL_ARG:-${DATABASE_URL:-}}"

RESTORE_REQUIRED_EXTENSIONS="${RESTORE_REQUIRED_EXTENSIONS:-}"
RESTORE_LOCK_TIMEOUT="${RESTORE_LOCK_TIMEOUT:-30s}"
RESTORE_STATEMENT_TIMEOUT="${RESTORE_STATEMENT_TIMEOUT:-30min}"
RESTORE_CRITICAL_TABLES="${RESTORE_CRITICAL_TABLES:-}"
AUDIT_REPORT_PATH="${AUDIT_REPORT_PATH:-${RESTORE_AUDIT_REPORT:-}}"

[[ -n "$BUCKET" ]] || die 1 "BACKUP_STORAGE_BUCKET is not set"
# In plan mode the target is only reported, never connected to, so a missing
# target URL is not fatal there.
if [[ "$PLAN_ONLY" != "true" ]]; then
  [[ -n "$TARGET_DATABASE_URL" ]] || die 1 "target database URL is not set (use --database-url or DATABASE_URL)"
fi
if [[ "$VERIFY_GRANTS" == "true" ]]; then
  [[ -n "$APP_DB_ROLE" ]] || die 1 "--verify-grants requires APP_DB_ROLE to name the application role"
  [[ "$APP_DB_ROLE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die 1 "invalid APP_DB_ROLE: $APP_DB_ROLE"
fi

# Record the sanitized target identity for the audit report (never the password).
IFS=$'\t' read -r AUDIT_TARGET_HOST AUDIT_TARGET_PORT AUDIT_TARGET_DB AUDIT_TARGET_USER \
  <<< "$(parse_db_identity "$TARGET_DATABASE_URL")"

for tool in psql gzip tar sha256sum python3; do
  command -v "$tool" >/dev/null 2>&1 || die 1 "required tool not found: $tool"
done

case "$STORAGE_PROVIDER" in
  s3)
    command -v aws >/dev/null 2>&1 || die 1 "required tool not found: aws"
    ;;
  supabase)
    command -v curl >/dev/null 2>&1 || die 1 "required tool not found: curl"
    [[ -n "$SUPABASE_URL" && -n "$SUPABASE_SERVICE_KEY" ]] || \
      die 1 "Supabase storage requires BACKUP_STORAGE_SUPABASE_URL and BACKUP_STORAGE_SUPABASE_SERVICE_KEY"
    ;;
  *)
    die 1 "unsupported BACKUP_STORAGE_PROVIDER: $STORAGE_PROVIDER (expected s3 or supabase)"
    ;;
esac

# ---------------------------------------------------------------------------
# Target preflight
# ---------------------------------------------------------------------------
# Fail fast, before any download or decryption, when the target database is
# unreachable or the role lacks the privileges the restore needs. This keeps
# expensive work (and decrypted staging artifacts) from being produced for a
# target that cannot accept the restore.
preflight_target() {
  local url="$1" verify_only="$2"

  log "preflight: checking connectivity to target database"
  if ! PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" \
       psql "$url" -v ON_ERROR_STOP=1 -X -At -q -c 'SELECT 1' >/dev/null 2>&1; then
    die 1 "preflight failed: cannot connect to target database (check --database-url / DATABASE_URL, network access and credentials)"
  fi

  # The dump replays DROP/CREATE statements, so the role needs CREATE on the
  # target database and on the public schema, plus TRUNCATE/INSERT on any
  # existing tables it will overwrite.
  local missing
  missing="$(psql "$url" -v ON_ERROR_STOP=1 -X -At -q -c "
    SELECT missing FROM (
      SELECT 'CREATE on database' AS missing
       WHERE NOT has_database_privilege(current_user, current_database(), 'CREATE')
      UNION ALL
      SELECT 'CREATE on schema public'
       WHERE NOT has_schema_privilege(current_user, 'public', 'CREATE')
      UNION ALL
      SELECT 'TRUNCATE on ' || schemaname || '.' || tablename
        FROM pg_tables
       WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
         AND NOT has_table_privilege(current_user, quote_ident(schemaname) || '.' || quote_ident(tablename), 'TRUNCATE')
      UNION ALL
      SELECT 'INSERT on ' || schemaname || '.' || tablename
        FROM pg_tables
       WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
         AND NOT has_table_privilege(current_user, quote_ident(schemaname) || '.' || quote_ident(tablename), 'INSERT')
    ) AS checks;
  " 2>/dev/null)" || die 1 "preflight failed: could not evaluate target database privileges"

  if [[ -n "$missing" ]]; then
    log "preflight: missing required privileges:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && log "  - $line"
    done <<< "$missing"
    die 1 "preflight failed: target role lacks required privileges (see above)"
  fi

  if [[ "$verify_only" == "true" ]]; then
    log "preflight: checking CREATEDB for --verify-only"
    local can_create
    can_create="$(psql "$url" -v ON_ERROR_STOP=1 -X -At -q -c \
      "SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user;" 2>/dev/null)" \
      || die 1 "preflight failed: could not evaluate CREATEDB privilege"
    if [[ "$can_create" != "t" ]]; then
      die 1 "preflight failed: --verify-only requires the target role to have CREATEDB"
    fi
  fi

  log "preflight: target database OK"
}

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
ARCHIVE_PATH=""
EXTRACT_DIR=""

# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap below
cleanup() {
  local status=$?
  AUDIT_EXIT_CODE="$status"
  write_audit_report || true
  if [[ -n "$VERIFY_DB" ]]; then
    psql "$TARGET_DATABASE_URL" -X -q -c "DROP DATABASE IF EXISTS \"$VERIFY_DB\";" >/dev/null 2>&1 || \
      log "WARNING: could not drop verification database $VERIFY_DB"
  fi
  if [[ "$KEEP_WORK_DIR" != "true" ]]; then
    # Remove decrypted staging artifacts on any failure, even when the caller
    # supplied --work-dir, so plaintext dumps never linger after a failed run.
    if [[ "$status" -ne 0 ]]; then
      [[ -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]] && rm -f "$ARCHIVE_PATH"
      [[ -n "$EXTRACT_DIR" && -d "$EXTRACT_DIR" ]] && rm -rf "$EXTRACT_DIR"
    fi
    if [[ "$CREATED_WORK_DIR" == "true" ]]; then
      rm -rf "$WORK_DIR"
    fi
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
  case "$STORAGE_PROVIDER" in
    s3)
      log "downloading s3://$BUCKET/$key"
      aws "${AWS_ARGS[@]}" s3 cp "s3://$BUCKET/$key" "$dest" --only-show-errors \
        || die 2 "failed to download $key"
      ;;
    supabase)
      log "downloading supabase://$BUCKET/$key"
      local url="${SUPABASE_URL%/}/storage/v1/object/${BUCKET}/${key}"
      curl -fsS \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
        --max-time "${BACKUP_DOWNLOAD_TIMEOUT:-300}" \
        -o "$dest" \
        "$url" \
        || die 2 "failed to download $key from Supabase Storage"
      ;;
  esac
}

latest_backup_name() {
  # Backup names embed a UTC timestamp, so lexical order is chronological.
  case "$STORAGE_PROVIDER" in
    s3)
      aws "${AWS_ARGS[@]}" s3 ls "s3://$BUCKET/$PREFIX/" \
        | awk '{print $4}' \
        | grep -E '\.manifest\.json$' \
        | sort \
        | tail -n 1 \
        | sed 's/\.manifest\.json$//'
      ;;
    supabase)
      local list_url="${SUPABASE_URL%/}/storage/v1/object/list/${BUCKET}"
      local body
      body="$(printf '{"prefix":"%s","limit":1000,"sortBy":{"column":"name","order":"asc"}}' "$PREFIX")"
      curl -fsS \
        -X POST \
        -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
        -H "Content-Type: application/json" \
        --data "$body" \
        "$list_url" \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+\.manifest\.json"' \
        | sed -E 's/.*"([^"]+)\.manifest\.json"/\1/' \
        | sort \
        | tail -n 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight the target before any download or decryption work
# ---------------------------------------------------------------------------
preflight_target "$TARGET_DATABASE_URL" "$VERIFY_ONLY"

# ---------------------------------------------------------------------------
# Download, verify, decrypt, extract
# ---------------------------------------------------------------------------
if [[ -z "$BACKUP_NAME" ]]; then
  BACKUP_NAME="$(latest_backup_name || true)"
  [[ -n "$BACKUP_NAME" ]] || die 2 "no backups found under ${STORAGE_PROVIDER}://$BUCKET/$PREFIX/"
  log "no --backup given; using newest backup: $BACKUP_NAME"
fi

[[ "$BACKUP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 1 "invalid backup name"

MANIFEST_PATH="$WORK_DIR/$BACKUP_NAME.manifest.json"
download_object "$PREFIX/$BACKUP_NAME.manifest.json" "$MANIFEST_PATH"

# Validate the manifest schema version and required fields before touching any
# database. Unsupported versions are rejected here, before restore.
python3 "$(dirname "${BASH_SOURCE[0]}")/validate-archive.py" --manifest "$MANIFEST_PATH" \
  || die 2 "manifest validation failed (unsupported schema version or missing/invalid fields)"

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

# Validate the decrypted archive before extraction: reject unsafe paths/types,
# duplicate normalized member names, and archives exceeding the configured
# member-count / uncompressed-size budgets.
python3 "$(dirname "${BASH_SOURCE[0]}")/validate-archive.py" "$ARCHIVE_PATH" \
  --max-members "${RESTORE_MAX_MEMBERS:-10000}" \
  --max-uncompressed-bytes "${RESTORE_MAX_UNCOMPRESSED_BYTES:-10737418240}" \
  || die 3 "archive rejected: unsafe paths or file types, duplicate member paths, or exceeds size/member budget"

# Check the archive's top-level components against the restore allowlist before
# extracting or touching any database. Unknown required components, unexpected
# executables, or unrelated files fail closed here (exit 3).
log "validating archive contents against the restore component allowlist"
python3 "$(dirname "${BASH_SOURCE[0]}")/validate-archive.py" --allowlist "$ARCHIVE_PATH" \
  || die 3 "archive contents failed allowlist validation (unexpected or missing components)"

EXTRACT_DIR="$(mktemp -d "$WORK_DIR/extracted.XXXXXXXX")"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR" || die 3 "archive is not a valid tar.gz"

DUMP_PATH="$EXTRACT_DIR/database.sql.gz"
[[ -f "$DUMP_PATH" ]] || die 4 "backup does not contain a database dump (was it taken with BACKUP_SKIP_DB=1?)"

# Verify per-component integrity after decryption/extraction and before any
# restore is applied.
log "verifying per-component checksums"
verify_component_sum "database.sql.gz" "$DUMP_PATH" "$MANIFEST_PATH"
if [[ -d "$EXTRACT_DIR/contracts" ]]; then
  log "contract state snapshots extracted to $EXTRACT_DIR/contracts (use --keep-work-dir to inspect)"
  CONTRACTS_SUM="$(manifest_component_sum "contracts" "$MANIFEST_PATH")"
  if [[ -n "$CONTRACTS_SUM" ]]; then
    CONTRACTS_ACTUAL="$(cd "$EXTRACT_DIR" && find contracts -type f -print0 \
      | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
    if [[ "$CONTRACTS_SUM" != "$CONTRACTS_ACTUAL" ]]; then
      die 2 "component checksum mismatch for contracts: expected $CONTRACTS_SUM, got $CONTRACTS_ACTUAL"
    fi
    log "component checksum OK for contracts ($CONTRACTS_ACTUAL)"
  else
    log "WARNING: manifest has no checksum for contracts; skipping component verification"
  fi
fi

# ---------------------------------------------------------------------------
# Plan mode
# ---------------------------------------------------------------------------
# Report what a restore would do without writing to any database. Everything
# below is read-only: no CREATE DATABASE, no psql restore, no post-restore SQL.
print_plan() {
  local schema_version created_at pg_version source_db
  schema_version="$(manifest_field schema_version "$MANIFEST_PATH")"
  created_at="$(manifest_field created_at "$MANIFEST_PATH")"
  pg_version="$(manifest_field pg_version "$MANIFEST_PATH")"
  source_db="$(manifest_field database "$MANIFEST_PATH")"

  printf 'Restore plan\n' >&2
  printf '============\n' >&2
  printf 'Backup name:        %s\n' "$BACKUP_NAME" >&2
  printf 'Storage:            %s://%s/%s\n' "$STORAGE_PROVIDER" "$BUCKET" "$PREFIX" >&2
  printf 'Archive key:        %s\n' "$ARCHIVE_KEY" >&2
  printf 'Manifest schema:    %s\n' "${schema_version:-unknown}" >&2
  printf 'Created at:         %s\n' "${created_at:-unknown}" >&2
  printf 'Postgres version:   %s\n' "${pg_version:-unknown}" >&2
  printf 'Source database:    %s\n' "${source_db:-unknown}" >&2
  printf 'Encryption method:  %s\n' "${ENCRYPTION_METHOD:-unknown}" >&2
  printf 'Archive checksum:   %s (verified)\n' "$ACTUAL_SUM" >&2

  printf '\nComponents:\n' >&2
  local dump_sum contracts_sum
  dump_sum="$(manifest_component_sum "database.sql.gz" "$MANIFEST_PATH")"
  printf '  database.sql.gz   %s\n' "${dump_sum:+sha256:$dump_sum (verified)}${dump_sum:-no checksum recorded}" >&2
  if [[ -d "$EXTRACT_DIR/contracts" ]]; then
    contracts_sum="$(manifest_component_sum "contracts" "$MANIFEST_PATH")"
    printf '  contracts/        %s\n' "${contracts_sum:+sha256:$contracts_sum (verified)}${contracts_sum:-no checksum recorded}" >&2
  else
    printf '  contracts/        not present in archive\n' >&2
  fi
  if [[ -f "$EXTRACT_DIR/tables.txt" ]]; then
    local table_count
    table_count="$(grep -c . "$EXTRACT_DIR/tables.txt" || true)"
    printf '  tables.txt        %s table(s) recorded\n' "$table_count" >&2
  else
    printf '  tables.txt        not present in archive\n' >&2
  fi

  printf '\nIntended target:\n' >&2
  if [[ -n "$TARGET_DATABASE_URL" ]]; then
    printf '  %s\n' "$(database_name_of "$TARGET_DATABASE_URL")" >&2
  else
    printf '  (no target configured; pass --database-url or set DATABASE_URL)\n' >&2
  fi

  printf '\nPlanned actions:\n' >&2
  if [[ "$VERIFY_ONLY" == "true" ]]; then
    printf '  - create a throwaway verification database and restore into it\n' >&2
    printf '  - compare restored tables against the backup table list\n' >&2
    printf '  - drop the throwaway database\n' >&2
  else
    printf '  - restore over the target database (DROP ... IF EXISTS)\n' >&2
    local sql_file="${POST_RESTORE_SQL_ARG:-${CONTRACT_STATE_FILE:-}}"
    if [[ "$SKIP_CONTRACT_STATE" == "true" ]]; then
      printf '  - skip post-restore SQL (--skip-contract-state)\n' >&2
    elif [[ -n "$sql_file" ]]; then
      printf '  - apply post-restore SQL from %s\n' "$sql_file" >&2
    else
      printf '  - no post-restore SQL configured\n' >&2
    fi
  fi

  printf '\nPlan only: no database writes were performed.\n' >&2
}

if [[ "$PLAN_ONLY" == "true" ]]; then
  print_plan
  exit 0
fi

# ---------------------------------------------------------------------------
# Restore helpers
# ---------------------------------------------------------------------------
# Every restore session gets bounded lock/statement timeouts so a conflicting
# active session cannot leave an unattended restore waiting indefinitely.
psql_exec() {
  local url="$1"
  shift
  PGOPTIONS="${PGOPTIONS:-} -c lock_timeout=${RESTORE_LOCK_TIMEOUT} -c statement_timeout=${RESTORE_STATEMENT_TIMEOUT}" \
    psql "$url" -v ON_ERROR_STOP=1 -q -X "$@"
}

restore_into() {
  local url="$1"
  log "restoring into target database (lock_timeout=$RESTORE_LOCK_TIMEOUT, statement_timeout=$RESTORE_STATEMENT_TIMEOUT)"
  # The dump contains DROP ... IF EXISTS statements, so it can be replayed onto
  # an existing database. A single transaction makes a failed restore a no-op.
  local rc=0
  gzip -dc "$DUMP_PATH" | psql_exec "$url" --single-transaction >/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    audit_component "database" "failed" "restore failed (exit $rc); transaction rolled back"
    if [[ "$rc" -eq 3 || "$rc" -eq 55 ]]; then
      die 6 "restore aborted: could not acquire a lock within ${RESTORE_LOCK_TIMEOUT} (a conflicting session is holding the database); terminate it or raise RESTORE_LOCK_TIMEOUT"
    fi
    die 4 "restore failed; the transaction was rolled back"
  fi
  audit_component "database" "ok" "restored from database.sql.gz"
}

# ---------------------------------------------------------------------------
# Pre-flight checks (run before any destructive SQL is applied)
# ---------------------------------------------------------------------------
# Inventory required extensions (env + manifest) and compare them with target
# availability and CREATE privilege. Aborts with actionable diagnostics.
check_extensions() {
  local url="$1"
  local required=()
  local ext
  if [[ -n "$RESTORE_REQUIRED_EXTENSIONS" ]]; then
    IFS=',' read -r -a required <<< "$RESTORE_REQUIRED_EXTENSIONS"
  fi
  while IFS= read -r ext; do
    [[ -n "$ext" ]] && required+=("$ext")
  done < <(manifest_string_array "extensions" "$MANIFEST_PATH")

  # Trim whitespace and drop empties.
  local cleaned=()
  for ext in "${required[@]:-}"; do
    ext="$(printf '%s' "$ext" | tr -d '[:space:]')"
    [[ -n "$ext" ]] && cleaned+=("$ext")
  done
  required=("${cleaned[@]:-}")

  if [[ "${#required[@]}" -eq 0 || -z "${required[0]:-}" ]]; then
    log "no required extensions configured; skipping extension pre-flight"
    audit_verification "extensions" "skipped" "no required extensions configured"
    return 0
  fi

  log "pre-flight: checking ${#required[@]} required extension(s) on target"
  local can_create
  can_create="$(psql_exec "$url" -At -c \
    "SELECT has_database_privilege(current_database(), 'CREATE');" 2>/dev/null || echo "f")"

  local missing=() unavailable=() present=() problems=0
  for ext in "${required[@]}"; do
    local installed available
    installed="$(psql_exec "$url" -At -c \
      "SELECT 1 FROM pg_extension WHERE extname = '$ext';" 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      present+=("$ext")
      continue
    fi
    available="$(psql_exec "$url" -At -c \
      "SELECT 1 FROM pg_available_extensions WHERE name = '$ext';" 2>/dev/null || true)"
    if [[ -z "$available" ]]; then
      unavailable+=("$ext")
      problems=1
    elif [[ "$can_create" != "t" ]]; then
      missing+=("$ext")
      problems=1
    else
      missing+=("$ext")
    fi
  done

  if [[ "${#present[@]}" -gt 0 && -n "${present[0]:-}" ]]; then
    log "extensions already installed: ${present[*]}"
  fi
  if [[ "${#missing[@]}" -gt 0 && -n "${missing[0]:-}" ]]; then
    log "extensions to be created by restore: ${missing[*]}"
  fi
  if [[ "${#unavailable[@]}" -gt 0 && -n "${unavailable[0]:-}" ]]; then
    log "ERROR: extensions not available on target: ${unavailable[*]}"
    log "  -> install the extension packages on the target server (e.g. postgresql-contrib) or remove them from RESTORE_REQUIRED_EXTENSIONS"
  fi
  if [[ "$can_create" != "t" ]]; then
    log "ERROR: current role lacks CREATE privilege on the target database; CREATE EXTENSION will fail"
    log "  -> grant CREATE on the database to the restore role or pre-create the extensions as a superuser"
    problems=1
  fi

  if [[ "$problems" -ne 0 ]]; then
    audit_verification "extensions" "failed" "missing=${missing[*]:-} unavailable=${unavailable[*]:-} can_create=$can_create"
    die 6 "pre-flight extension check failed; aborting before applying destructive SQL"
  fi
  audit_verification "extensions" "ok" "required=${required[*]} installed=${present[*]:-none}"
}

# ---------------------------------------------------------------------------
# Critical-table row-count verification
# ---------------------------------------------------------------------------
# Parse "schema.table=count" or "schema.table>=count" / "<=count" specs into
# lines of "schema<TAB>table<TAB>op<TAB>expected". Sources: RESTORE_CRITICAL_TABLES
# and critical-tables.txt in the backup archive (recorded at backup time).
critical_table_specs() {
  local raw="$1"
  local spec
  IFS=',' read -r -a _specs <<< "$raw"
  for spec in "${_specs[@]:-}"; do
    spec="$(printf '%s' "$spec" | tr -d '[:space:]')"
    [[ -n "$spec" ]] || continue
    if [[ "$spec" =~ ^([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)(>=|<=|=)([0-9]+)$ ]]; then
      printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
      log "WARNING: ignoring malformed critical-table spec: $spec"
    fi
  done
}

verify_critical_tables() {
  local url="$1"
  local specs=""
  [[ -n "$RESTORE_CRITICAL_TABLES" ]] && specs="$RESTORE_CRITICAL_TABLES"
  local recorded="$EXTRACT_DIR/critical-tables.txt"
  if [[ -f "$recorded" ]]; then
    local extra
    extra="$(grep -vE '^[[:space:]]*(#|$)' "$recorded" | paste -sd, -)"
    if [[ -n "$extra" ]]; then
      specs="${specs:+$specs,}$extra"
    fi
  fi

  if [[ -z "$specs" ]]; then
    log "no critical tables configured; skipping row-count verification"
    audit_verification "critical_tables" "skipped" "no critical tables configured"
    return 0
  fi

  log "verifying critical table row counts"
  local mismatch=0
  local schema table op expected actual ok
  while IFS=$'\t' read -r schema table op expected; do
    [[ -n "$schema" ]] || continue
    if ! actual="$(psql_exec "$url" -At -c "SELECT count(*) FROM \"$schema\".\"$table\";" 2>/dev/null)"; then
      log "ERROR: critical table $schema.$table is missing or unreadable after restore"
      audit_verification "critical_table:$schema.$table" "failed" "missing or unreadable"
      mismatch=1
      continue
    fi
    ok=0
    case "$op" in
      "=")  [[ "$actual" -eq "$expected" ]] && ok=1 ;;
      ">=") [[ "$actual" -ge "$expected" ]] && ok=1 ;;
      "<=") [[ "$actual" -le "$expected" ]] && ok=1 ;;
    esac
    if [[ "$ok" -eq 1 ]]; then
      log "critical table $schema.$table: $actual rows (expected $op $expected) OK"
      audit_verification "critical_table:$schema.$table" "ok" "actual=$actual expected=$op$expected"
    else
      log "ERROR: critical table $schema.$table: $actual rows, expected $op $expected"
      audit_verification "critical_table:$schema.$table" "failed" "actual=$actual expected=$op$expected"
      mismatch=1
    fi
  done < <(critical_table_specs "$specs")

  if [[ "$mismatch" -ne 0 ]]; then
    die 5 "verification failed: critical table row counts do not match expectations"
  fi
}

apply_contract_state() {
  local url="$1"
  if [[ "$SKIP_CONTRACT_STATE" == "true" ]]; then
    log "skipping post-restore SQL application (--skip-contract-state)"
    return 0
  fi
  local sql_file="${POST_RESTORE_SQL_ARG:-${CONTRACT_STATE_FILE:-}}"
  if [[ -z "$sql_file" ]]; then
    log "no CONTRACT_STATE_FILE / --post-restore-sql configured; skipping post-restore SQL"
    return 0
  fi
  [[ -f "$sql_file" ]] || die 4 "post-restore SQL file not found: $sql_file"
  if [[ "$sql_file" == *.json ]]; then
    die 1 "CONTRACT_STATE_FILE ($sql_file) must be a PostgreSQL .sql script, not a JSON contract snapshot (use scripts/rollback-contracts.cjs to repoint on-chain contract IDs)"
  fi
  log "applying post-restore SQL from $sql_file"
  psql_exec "$url" -f "$sql_file" || die 4 "failed to apply post-restore SQL from $sql_file"
}

# Verify that the application role can reach every restored table. Dumps omit
# ownership and privileges, so after a restore the role may not own or have
# grants on the tables it needs. This check is read-only: it never grants
# anything (and never elevates the role to superuser).
verify_grants() {
  local url="$1"
  if [[ "$VERIFY_GRANTS" != "true" ]]; then
    return 0
  fi
  log "verifying grants for application role '$APP_DB_ROLE'"

  # Prefer the table list recorded at backup time; fall back to every
  # non-system table currently in the database.
  local tables=""
  local expected_list="$EXTRACT_DIR/tables.txt"
  if [[ -f "$expected_list" ]]; then
    tables="$(grep -v '^[[:space:]]*$' "$expected_list" || true)"
  fi
  if [[ -z "$tables" ]]; then
    log "no tables.txt in backup; checking all non-system tables"
    tables="$(psql_exec "$url" -At -c \
      "SELECT schemaname || '.' || tablename FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY 1;")"
  fi

  if [[ -z "$tables" ]]; then
    log "WARNING: no tables found to check grants against"
    return 0
  fi

  local role_exists
  role_exists="$(psql_exec "$url" -At -c \
    "SELECT 1 FROM pg_roles WHERE rolname = '$APP_DB_ROLE';")"
  if [[ "$role_exists" != "1" ]]; then
    die 5 "verification failed: application role '$APP_DB_ROLE' does not exist in the restored database"
  fi

  local mismatch=0 table schema name priv missing
  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    schema="${table%%.*}"
    name="${table#*.}"
    missing=""
    for priv in SELECT INSERT UPDATE DELETE; do
      local allowed
      allowed="$(psql_exec "$url" -At -c \
        "SELECT has_table_privilege('$APP_DB_ROLE', '\"$schema\".\"$name\"', '$priv');")"
      if [[ "$allowed" != "t" ]]; then
        missing+="${missing:+, }$priv"
      fi
    done
    if [[ -n "$missing" ]]; then
      log "ERROR: role '$APP_DB_ROLE' lacks $missing on $table"
      mismatch=1
    else
      log "grants OK for $table"
    fi
  done <<< "$tables"

  if [[ "$mismatch" -ne 0 ]]; then
    die 5 "verification failed: application role '$APP_DB_ROLE' is missing required table privileges (re-apply ownership/grants manually; this script does not grant them)"
  fi

  log "grant verification passed for role '$APP_DB_ROLE'"
}

# ---------------------------------------------------------------------------
# Verification mode
# ---------------------------------------------------------------------------
verify_restore() {
  local base_url="$1"
  AUDIT_MODE="verify-only"
  VERIFY_DB="restore_verify_$(date -u +%Y%m%d%H%M%S)_$$"
  log "verify-only mode: restoring into throwaway database '$VERIFY_DB'"

  check_extensions "$base_url"

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
    audit_verification "table_list" "failed" "missing tables or unreadable tables"
    die 5 "verification failed: integrity mismatch"
  fi
  audit_verification "table_list" "ok" "all expected tables present and readable"

  verify_critical_tables "$verify_url"

  verify_grants "$verify_url"

  log "verification passed"
}

confirm_restore() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die 1 "refusing to restore over a non-throwaway database non-interactively without --yes"
  fi
  log "WARNING: about to restore backup '$BACKUP_NAME' over the target database (DROP ... IF EXISTS)."
  printf 'Type "restore" to confirm: ' >&2
  local answer=""
  read -r answer || answer=""
  if [[ "$answer" != "restore" ]]; then
    die 1 "restore aborted by user"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$VERIFY_ONLY" == "true" ]]; then
  verify_restore "$TARGET_DATABASE_URL"
else
  AUDIT_MODE="restore"
  check_extensions "$TARGET_DATABASE_URL"
  confirm_restore
  restore_into "$TARGET_DATABASE_URL"
  apply_contract_state "$TARGET_DATABASE_URL"
  verify_grants "$TARGET_DATABASE_URL"
  log "restore complete"
fi

exit 0