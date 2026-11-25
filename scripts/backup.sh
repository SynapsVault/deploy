#!/usr/bin/env bash
#
# backup.sh — Full backup pipeline for the Soroban dApp backend.
#
# Responsibilities:
#   1. Dump the Postgres database via pg_dump (using DATABASE_URL).
#   2. Capture contract state (contract IDs + on-chain state snapshots via Soroban RPC).
#   3. Encrypt the resulting archive with age or gpg (using BACKUP_ENCRYPTION_KEY).
#   4. Upload the encrypted archive to object storage (S3-compatible via the
#      AWS CLI, or Supabase Storage via its REST API) using BACKUP_STORAGE_*
#      credentials.
#   5. Emit a JSON manifest with timestamp, checksum, size, and source metadata.
#   6. Expose a Prometheus textfile metric for backup success/failure and
#      last-success timestamp.
#
# This script is intended to be run from cron / a systemd timer / CI.
# scripts/restore.sh consumes the archives and manifests it produces.
#
# Set BACKUP_OUTPUT_DIR to also keep a local copy of the manifest (and a
# `manifest.json` pointing at the latest run), e.g. for CI artifact upload.
#
# Exit codes:
#   0  success
#   1  generic failure
#   2  configuration error
#   3  dependency missing

set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------------------
# Configuration & defaults
# ---------------------------------------------------------------------------

# Timestamp (UTC) used for artifact naming and manifest.
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
BACKUP_DATE_ISO="${BACKUP_DATE_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Unique run identifier. Every staging/archive/manifest/metrics artifact name
# includes this ID so that two concurrent invocations (even with the same
# BACKUP_TIMESTAMP) can never overwrite each other's files. Collision behavior:
#   - The run ID is derived from the PID plus a random suffix, so collisions are
#     practically impossible; if a collision were ever detected the run aborts
#     with a configuration error rather than reusing an existing artifact.
#   - An execution lock (see acquire_lock) additionally serializes runs that
#     share a lock file, so overlapping runs fail fast instead of racing.
BACKUP_RUN_ID="${BACKUP_RUN_ID:-$(printf '%s-%s' "$$" "$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || date -u +%N)")}"
# Execution lock file. Defaults to a file inside the work directory; set
# BACKUP_LOCK_FILE to a shared path to serialize runs across processes.
BACKUP_LOCK_FILE="${BACKUP_LOCK_FILE:-${WORK_DIR}/.backup.lock}"
# Set to 1 to skip acquiring the execution lock (not recommended).
BACKUP_SKIP_LOCK="${BACKUP_SKIP_LOCK:-0}"
# Required free bytes on the staging filesystem before a dump is created.
# Defaults to 1 GiB; override with BACKUP_REQUIRED_FREE_BYTES.
BACKUP_REQUIRED_FREE_BYTES="${BACKUP_REQUIRED_FREE_BYTES:-1073741824}"
# Set to 1 to skip the preflight free-space check.
BACKUP_SKIP_FREE_SPACE_CHECK="${BACKUP_SKIP_FREE_SPACE_CHECK:-0}"

# Working directory for staging artifacts.
WORK_DIR="${BACKUP_WORK_DIR:-$(mktemp -d -t soroban-backup-XXXXXXXX)}"
# Caller-owned directories may contain unrelated files; preserve them by default.
if [[ -n "${BACKUP_WORK_DIR:-}" ]]; then
  CLEANUP_WORK_DIR="${BACKUP_CLEANUP_WORK_DIR:-0}"
else
  CLEANUP_WORK_DIR="${BACKUP_CLEANUP_WORK_DIR:-1}"
fi

# Artifact naming.
# BACKUP_NAME is validated (see validate_artifact_name) before being used to
# build any local or remote path. The run ID is appended so concurrent runs
# never share archive/manifest names.
BACKUP_NAME="${BACKUP_NAME:-soroban-backup-${BACKUP_TIMESTAMP}}"
ARCHIVE_PATH=""
ENCRYPTED_PATH=""
MANIFEST_PATH=""

# Prometheus textfile collector output and optional Pushgateway endpoint.
PROM_DIR="${PROM_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM_FILE="${PROM_FILE:-${PROM_DIR}/soroban_backup.prom}"
PROM_PUSHGATEWAY_URL="${PROM_PUSHGATEWAY_URL:-}"
PROM_JOB_NAME="${PROM_JOB_NAME:-soroban_backup}"

# Encryption settings.
# BACKUP_ENCRYPTION_KEY may be:
#   - an age identity / recipient string (age1... or AGE-SECRET-KEY-...)
#   - a passphrase (used with gpg symmetric encryption)
#   - a path to a key file
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_ENCRYPTION_METHOD="${BACKUP_ENCRYPTION_METHOD:-auto}" # auto|age|gpg|none
# Optional path to an age recipients file containing one or more public
# recipients (one per line, blank lines and '#' comments ignored). When set,
# the archive is encrypted to every recipient in the file so that any one of
# the authorized custodians can decrypt it. Only public recipients belong in
# this file; private identities must never be stored alongside the backup.
BACKUP_AGE_RECIPIENTS_FILE="${BACKUP_AGE_RECIPIENTS_FILE:-}"
# Optional path to an age identity file used only for verification/decryption
# during tests. It is never read by the backup pipeline itself.
BACKUP_AGE_IDENTITY_FILE="${BACKUP_AGE_IDENTITY_FILE:-}"

# Storage settings.
BACKUP_STORAGE_PROVIDER="${BACKUP_STORAGE_PROVIDER:-s3}" # s3|supabase
BACKUP_STORAGE_BUCKET="${BACKUP_STORAGE_BUCKET:-}"
BACKUP_STORAGE_PREFIX="${BACKUP_STORAGE_PREFIX:-backups}"
BACKUP_STORAGE_ENDPOINT="${BACKUP_STORAGE_ENDPOINT:-}"
BACKUP_STORAGE_REGION="${BACKUP_STORAGE_REGION:-us-east-1}"
BACKUP_STORAGE_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-}"
BACKUP_STORAGE_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-}"
BACKUP_STORAGE_SESSION_TOKEN="${BACKUP_STORAGE_SESSION_TOKEN:-}"
# Supabase Storage uses the same S3-compatible API but requires a service key.
BACKUP_STORAGE_SUPABASE_URL="${BACKUP_STORAGE_SUPABASE_URL:-}"
BACKUP_STORAGE_SUPABASE_SERVICE_KEY="${BACKUP_STORAGE_SUPABASE_SERVICE_KEY:-}"

# Database settings.
DATABASE_URL="${DATABASE_URL:-}"

# Soroban RPC settings.
SOROBAN_RPC_URL="${SOROBAN_RPC_URL:-}"
SOROBAN_NETWORK_PASSPHRASE="${SOROBAN_NETWORK_PASSPHRASE:-}"
# Comma-separated list of contract IDs to snapshot.
SOROBAN_CONTRACT_IDS="${SOROBAN_CONTRACT_IDS:-}"

# Network deadlines and bounded retry policies.
# Per-attempt deadline (seconds) for a single Soroban RPC request.
BACKUP_RPC_TIMEOUT_SECONDS="${BACKUP_RPC_TIMEOUT_SECONDS:-${SOROBAN_RPC_TIMEOUT:-30}}"
# Maximum number of retries (in addition to the first attempt) for RPC calls.
BACKUP_RPC_MAX_RETRIES="${BACKUP_RPC_MAX_RETRIES:-3}"
# Per-attempt deadline (seconds) for a single object-storage upload.
BACKUP_STORAGE_TIMEOUT_SECONDS="${BACKUP_STORAGE_TIMEOUT_SECONDS:-${BACKUP_UPLOAD_TIMEOUT:-300}}"
# Maximum number of retries (in addition to the first attempt) for uploads.
BACKUP_STORAGE_MAX_RETRIES="${BACKUP_STORAGE_MAX_RETRIES:-3}"
# Base delay (seconds) for exponential backoff between retries.
BACKUP_RETRY_BACKOFF_SECONDS="${BACKUP_RETRY_BACKOFF_SECONDS:-2}"
# Upper bound (seconds) on any single backoff sleep.
BACKUP_RETRY_MAX_BACKOFF_SECONDS="${BACKUP_RETRY_MAX_BACKOFF_SECONDS:-30}"

# Optional: path to a file containing additional contract IDs (one per line).
SOROBAN_CONTRACT_IDS_FILE="${SOROBAN_CONTRACT_IDS_FILE:-}"

# Comma-separated list of critical tables (schema.table or table) whose row
# counts are recorded at backup time so restore.sh can verify them afterwards.
# Example: BACKUP_CRITICAL_TABLES="public.accounts,public.orders"
BACKUP_CRITICAL_TABLES="${BACKUP_CRITICAL_TABLES:-}"
# Optional path to a file with one critical table per line (blank lines and
# lines starting with '#' are ignored). Merged with BACKUP_CRITICAL_TABLES.
BACKUP_CRITICAL_TABLES_FILE="${BACKUP_CRITICAL_TABLES_FILE:-}"

# Retention / behaviour toggles.
BACKUP_SKIP_DB="${BACKUP_SKIP_DB:-0}"
BACKUP_SKIP_CONTRACTS="${BACKUP_SKIP_CONTRACTS:-0}"
BACKUP_SKIP_UPLOAD="${BACKUP_SKIP_UPLOAD:-0}"
BACKUP_SKIP_PRUNE="${BACKUP_SKIP_PRUNE:-0}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_VERBOSE="${BACKUP_VERBOSE:-0}"
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-}"

# Dry-run mode: print the plan (components, destination, retention actions)
# with credentials redacted, then exit without dumping, uploading or deleting.
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-0}"

# Set by main(); read by the EXIT trap to report failure metrics.
START_TS=""

# JSON array of critical-table row counts captured during the dump (manifest).
CRITICAL_TABLE_COUNTS_JSON="[]"
# Set to a short reason string when a run fails for a specific, reportable
# reason (e.g. "insufficient_space"); surfaced in the failure metric.
FAILURE_REASON=""
# File descriptor held open for the execution lock.
LOCK_FD=""

# Phase status tracking. Upload and retention are tracked independently so a
# pruning failure never masks a successful (recoverable) upload.
# Values: pending | success | failed | skipped
UPLOAD_STATUS="pending"
RETENTION_STATUS="pending"
UPLOAD_ERROR=""
RETENTION_ERROR=""
UPLOADED_OBJECT_KEY=""
UPLOADED_SIZE_BYTES="0"
UPLOADED_CHECKSUM=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }

debug() {
  if [[ "${BACKUP_VERBOSE}" == "1" ]]; then
    log DEBUG "$@"
  fi
}

# Redact a value for display: show only a short prefix and a length hint so
# operators can confirm configuration without leaking credentials.
redact() {
  local value="${1:-}"
  if [[ -z "${value}" ]]; then
    printf '<unset>'
    return 0
  fi
  local len=${#value}
  if [[ "${len}" -le 4 ]]; then
    printf '***'
  else
    printf '%s*** (len=%d)' "${value:0:2}" "${len}"
  fi
}

die() {
  local code="${1:-1}"; shift
  error "$@"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 && -n "${START_TS}" ]]; then
    local end_ts
    end_ts="$(date -u +%s)"
    # If the upload already succeeded, the backup is recoverable even though
    # the run failed later (e.g. during retention cleanup). Report the upload
    # outcome separately so operators know a usable archive exists.
    local overall_success=0
    local err_msg="backup failed with exit code ${exit_code}"
    if [[ "${UPLOAD_STATUS}" == "success" ]]; then
      err_msg="backup failed after successful upload (exit ${exit_code}); retention=${RETENTION_STATUS}"
    fi
    if [[ -n "${FAILURE_REASON}" ]]; then
      err_msg="${err_msg} (reason=${FAILURE_REASON})"
    fi
    emit_metrics "${overall_success}" "$(( end_ts - START_TS ))" \
      "${UPLOADED_SIZE_BYTES}" "$(previous_last_success)" "${err_msg}" || true
    error "Backup failed with exit code ${exit_code}"
  fi
  if [[ -n "${LOCK_FD}" ]]; then
    flock -u "${LOCK_FD}" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
  fi
  if [[ "${CLEANUP_WORK_DIR}" == "1" && -d "${WORK_DIR}" ]]; then
    debug "Cleaning up work directory ${WORK_DIR}"
    rm -rf "${WORK_DIR}" || true
  else
    info "Preserving work directory ${WORK_DIR}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

# Reject artifact names / storage prefixes that could escape the intended
# directory or object namespace. Rejects:
#   - empty values
#   - any '/' (path separators)
#   - '..' or '.' path segments
#   - control characters (including newlines, tabs, NUL)
#   - leading '-' (would be parsed as an option)
# Usage: validate_artifact_name <label> <value> [allow_slash]
validate_artifact_name() {
  local label="$1"
  local value="$2"
  local allow_slash="${3:-0}"

  if [[ -z "${value}" ]]; then
    die 2 "${label} must not be empty"
  fi

  # Control characters (0x00-0x1F, 0x7F).
  if printf '%s' "${value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die 2 "${label} contains control characters: $(printf '%q' "${value}")"
  fi

  if [[ "${value}" == -* ]]; then
    die 2 "${label} must not start with '-': $(printf '%q' "${value}")"
  fi

  if [[ "${allow_slash}" != "1" && "${value}" == */* ]]; then
    die 2 "${label} must not contain '/': $(printf '%q' "${value}")"
  fi

  # Reject '.' and '..' segments (also catches '..' anywhere when slashes are
  # disallowed, since the whole value is a single segment).
  local segment
  local IFS='/'
  for segment in ${value}; do
    if [[ "${segment}" == "." || "${segment}" == ".." ]]; then
      die 2 "${label} contains a traversal segment: $(printf '%q' "${value}")"
    fi
  done
  unset IFS

  if [[ "${value}" == *..* && "${allow_slash}" != "1" ]]; then
    die 2 "${label} contains a traversal segment: $(printf '%q' "${value}")"
  fi
}

# Validate all user-controlled names and derive artifact paths.
validate_configuration() {
  validate_artifact_name "BACKUP_NAME" "${BACKUP_NAME}"
  validate_artifact_name "BACKUP_STORAGE_PREFIX" "${BACKUP_STORAGE_PREFIX}" 1
  validate_artifact_name "BACKUP_RUN_ID" "${BACKUP_RUN_ID}"

  ARCHIVE_PATH="${WORK_DIR}/${BACKUP_NAME}-${BACKUP_RUN_ID}.tar.gz"
  ENCRYPTED_PATH="${ARCHIVE_PATH}.enc"
  MANIFEST_PATH="${WORK_DIR}/${BACKUP_NAME}-${BACKUP_RUN_ID}.manifest.json"
}

# ---------------------------------------------------------------------------
# Execution lock
# ---------------------------------------------------------------------------

# Acquire an exclusive, non-blocking lock so overlapping runs fail fast rather
# than racing on shared artifact names. Uses flock(1) when available; if flock
# is unavailable the unique run ID still prevents artifact collisions.
acquire_lock() {
  if [[ "${BACKUP_SKIP_LOCK}" == "1" ]]; then
    warn "Execution lock disabled (BACKUP_SKIP_LOCK=1); relying on unique run ID only"
    return 0
  fi

  if ! command -v flock >/dev/null 2>&1; then
    warn "flock not available; relying on unique run ID to avoid artifact collisions"
    return 0
  fi

  mkdir -p "$(dirname "${BACKUP_LOCK_FILE}")"
  exec {LOCK_FD}>"${BACKUP_LOCK_FILE}"
  if ! flock -n "${LOCK_FD}"; then
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_FD=""
    FAILURE_REASON="lock_contention"
    die 1 "Another backup run holds the lock ${BACKUP_LOCK_FILE}; aborting to avoid overlap"
  fi
  debug "Acquired execution lock ${BACKUP_LOCK_FILE}"
}

# ---------------------------------------------------------------------------
# Preflight free-space check
# ---------------------------------------------------------------------------

# Fail early if the staging filesystem lacks BACKUP_REQUIRED_FREE_BYTES.
check_free_space() {
  if [[ "${BACKUP_SKIP_FREE_SPACE_CHECK}" == "1" ]]; then
    warn "Preflight free-space check disabled (BACKUP_SKIP_FREE_SPACE_CHECK=1)"
    return 0
  fi

  if ! [[ "${BACKUP_REQUIRED_FREE_BYTES}" =~ ^[0-9]+$ ]]; then
    die 2 "BACKUP_REQUIRED_FREE_BYTES must be a non-negative integer: ${BACKUP_REQUIRED_FREE_BYTES}"
  fi

  mkdir -p "${WORK_DIR}"
  local available
  available="$(df -Pk "${WORK_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${available}" ]]; then
    warn "Could not determine free space for ${WORK_DIR}; skipping preflight check"
    return 0
  fi
  # df -Pk reports 1024-byte blocks.
  local available_bytes=$(( available * 1024 ))

  if [[ "${available_bytes}" -lt "${BACKUP_REQUIRED_FREE_BYTES}" ]]; then
    FAILURE_REASON="insufficient_space"
    die 1 "Insufficient free space in ${WORK_DIR}: ${available_bytes} bytes available, ${BACKUP_REQUIRED_FREE_BYTES} required (set BACKUP_REQUIRED_FREE_BYTES to adjust)"
  fi
  debug "Free space check passed: ${available_bytes} bytes available, ${BACKUP_REQUIRED_FREE_BYTES} required"
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die 3 "Required command not found: ${cmd}"
  fi
}

check_dependencies() {
  require_cmd tar
  require_cmd sha256sum
  require_cmd date
  require_cmd mktemp

  if [[ "${BACKUP_SKIP_DB}" != "1" ]]; then
    require_cmd pg_dump
    require_cmd psql
  fi

  if [[ "${BACKUP_SKIP_CONTRACTS}" != "1" ]]; then
    require_cmd curl
  fi

  case "${BACKUP_ENCRYPTION_METHOD}" in
    age)  require_cmd age ;;
    gpg)  require_cmd gpg ;;
    none) warn "Encryption explicitly disabled (BACKUP_ENCRYPTION_METHOD=none)" ;;
    auto)
      # age cannot read a passphrase non-interactively, so it is only chosen
      # for age recipients (age1...), recipient files, or an explicit
      # BACKUP_AGE_RECIPIENTS_FILE; passphrases use gpg.
      if [[ ( "${BACKUP_ENCRYPTION_KEY}" == age1* || -f "${BACKUP_ENCRYPTION_KEY}" \
              || -n "${BACKUP_AGE_RECIPIENTS_FILE}" ) ]] \
          && command -v age >/dev/null 2>&1; then
        BACKUP_ENCRYPTION_METHOD="age"
      elif command -v gpg >/dev/null 2>&1; then
        BACKUP_ENCRYPTION_METHOD="gpg"
      else
        # Never silently fall back to uploading plaintext database dumps.
        die 3 "Neither age nor gpg found; install one or set BACKUP_ENCRYPTION_METHOD=none explicitly"
      fi
      ;;
    *)
      die 2 "Invalid BACKUP_ENCRYPTION_METHOD: ${BACKUP_ENCRYPTION_METHOD}"
      ;;
  esac

  if [[ "${BACKUP_ENCRYPTION_METHOD}" == "age" && -n "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
    if [[ ! -f "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
      die 2 "BACKUP_AGE_RECIPIENTS_FILE does not exist: ${BACKUP_AGE_RECIPIENTS_FILE}"
    fi
    if ! grep -Eq '^[[:space:]]*age1[0-9a-z]+' "${BACKUP_AGE_RECIPIENTS_FILE}"; then
      die 2 "BACKUP_AGE_RECIPIENTS_FILE contains no age1... recipients"
    fi
  fi

  if [[ "${BACKUP_ENCRYPTION_METHOD}" != "none" && -z "${BACKUP_ENCRYPTION_KEY}" \
      && -z "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
    die 2 "BACKUP_ENCRYPTION_KEY or BACKUP_AGE_RECIPIENTS_FILE is required when encryption is enabled"
  fi

  if [[ "${BACKUP_ENCRYPTION_METHOD}" == "age" \
      && "${BACKUP_ENCRYPTION_KEY}" != age1* && ! -f "${BACKUP_ENCRYPTION_KEY}" \
      && -z "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
    die 2 "age needs an age1... recipient or a recipients file; use gpg for passphrases"
  fi

  if [[ "${BACKUP_SKIP_UPLOAD}" != "1" ]]; then
    if [[ -z "${BACKUP_STORAGE_BUCKET}" ]]; then
      die 2 "BACKUP_STORAGE_BUCKET is required for upload"
    fi
    case "${BACKUP_STORAGE_PROVIDER}" in
      s3)       require_cmd aws ;;
      supabase) require_cmd curl ;;
      *)        die 2 "Unsupported BACKUP_STORAGE_PROVIDER: ${BACKUP_STORAGE_PROVIDER}" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------

# Emit metrics to the textfile collector and/or Prometheus Pushgateway (for CI runs).
emit_metrics() {
  local success="$1"        # 1 or 0
  local duration_seconds="$2"
  local size_bytes="$3"
  local last_success_ts="$4" # unix epoch of last success (0 if unknown)
  local error_message="${5:-}"

  local payload_file="${WORK_DIR}/soroban_backup-${BACKUP_RUN_ID}.prom"
  mkdir -p "${WORK_DIR}"

  # Map phase statuses to numeric gauges: 1=success, 0=failed/skipped/pending.
  local upload_ok=0 retention_ok=0
  [[ "${UPLOAD_STATUS}" == "success" ]] && upload_ok=1
  [[ "${RETENTION_STATUS}" == "success" || "${RETENTION_STATUS}" == "skipped" ]] && retention_ok=1

  {
    printf '# HELP soroban_backup_success Whether the last backup run succeeded (1=success, 0=failure).\n'
    printf '# TYPE soroban_backup_success gauge\n'
    printf 'soroban_backup_success %s\n' "${success}"

    printf '# HELP soroban_backup_upload_success Whether the archive upload succeeded (1=success, 0=failure).\n'
    printf '# TYPE soroban_backup_upload_success gauge\n'
    printf 'soroban_backup_upload_success %s\n' "${upload_ok}"

    printf '# HELP soroban_backup_retention_success Whether retention cleanup succeeded (1=success/skipped, 0=failure).\n'
    printf '# TYPE soroban_backup_retention_success gauge\n'
    printf 'soroban_backup_retention_success %s\n' "${retention_ok}"

    printf '# HELP soroban_backup_upload_status Upload phase status (1=success, 0=failed/skipped/pending).\n'
    printf '# TYPE soroban_backup_upload_status gauge\n'
    printf 'soroban_backup_upload_status{status="%s"} 1\n' "${UPLOAD_STATUS}"

    printf '# HELP soroban_backup_retention_status Retention phase status (1=success, 0=failed/skipped/pending).\n'
    printf '# TYPE soroban_backup_retention_status gauge\n'
    printf 'soroban_backup_retention_status{status="%s"} 1\n' "${RETENTION_STATUS}"

    printf '# HELP soroban_backup_last_success_timestamp_seconds Unix timestamp of the last successful backup.\n'
    printf '# TYPE soroban_backup_last_success_timestamp_seconds gauge\n'
    printf 'soroban_backup_last_success_timestamp_seconds %s\n' "${last_success_ts}"

    printf '# HELP soroban_backup_duration_seconds Duration of the last backup run in seconds.\n'
    printf '# TYPE soroban_backup_duration_seconds gauge\n'
    printf 'soroban_backup_duration_seconds %s\n' "${duration_seconds}"

    printf '# HELP soroban_backup_size_bytes Size of the last backup archive in bytes.\n'
    printf '# TYPE soroban_backup_size_bytes gauge\n'
    printf 'soroban_backup_size_bytes %s\n' "${size_bytes}"

    printf '# HELP soroban_backup_last_run_timestamp_seconds Unix timestamp of the last backup run (success or failure).\n'
    printf '# TYPE soroban_backup_last_run_timestamp_seconds gauge\n'
    printf 'soroban_backup_last_run_timestamp_seconds %s\n' "$(date -u +%s)"

    if [[ -n "${error_message}" ]]; then
      printf '# HELP soroban_backup_last_error_info Information about the last backup error (always 1).\n'
      printf '# TYPE soroban_backup_last_error_info gauge\n'
      local escaped
      escaped="$(printf '%s' "${error_message}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/ /g')"
      printf 'soroban_backup_last_error_info{message="%s"} 1\n' "${escaped}"
    fi

    if [[ -n "${UPLOAD_ERROR}" ]]; then
      printf '# HELP soroban_backup_upload_error_info Information about the last upload error (always 1).\n'
      printf '# TYPE soroban_backup_upload_error_info gauge\n'
      local up_escaped
      up_escaped="$(printf '%s' "${UPLOAD_ERROR}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/ /g')"
      printf 'soroban_backup_upload_error_info{message="%s"} 1\n' "${up_escaped}"
    fi

    if [[ -n "${RETENTION_ERROR}" ]]; then
      printf '# HELP soroban_backup_retention_error_info Information about the last retention error (always 1).\n'
      printf '# TYPE soroban_backup_retention_error_info gauge\n'
      local ret_escaped
      ret_escaped="$(printf '%s' "${RETENTION_ERROR}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/ /g')"
      printf 'soroban_backup_retention_error_info{message="%s"} 1\n' "${ret_escaped}"
    fi
    if [[ -n "${FAILURE_REASON}" ]]; then
      printf '# HELP soroban_backup_failure_reason Whether the last run failed for a specific reason (1=yes).\n'
      printf '# TYPE soroban_backup_failure_reason gauge\n'
      local reason_escaped
      reason_escaped="$(printf '%s' "${FAILURE_REASON}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\n/ /g')"
      printf 'soroban_backup_failure_reason{reason="%s"} 1\n' "${reason_escaped}"
    fi
  } > "${payload_file}"

  if [[ -d "${PROM_DIR}" ]]; then
    local tmp
    tmp="$(mktemp "${PROM_FILE}.XXXXXX")"
    cp -f "${payload_file}" "${tmp}"
    mv -f "${tmp}" "${PROM_FILE}"
    debug "Wrote metrics to ${PROM_FILE}"
  else
    debug "Prometheus textfile directory ${PROM_DIR} does not exist; skipping local textfile write"
  fi

  if [[ -n "${BACKUP_OUTPUT_DIR}" ]]; then
    mkdir -p "${BACKUP_OUTPUT_DIR}"
    cp -f "${payload_file}" "${BACKUP_OUTPUT_DIR}/soroban_backup.prom"
  fi

  if [[ -n "${PROM_PUSHGATEWAY_URL}" ]]; then
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS -X POST --data-binary "@${payload_file}" \
          "${PROM_PUSHGATEWAY_URL%/}/metrics/job/${PROM_JOB_NAME}" >/dev/null; then
        info "Pushed backup metrics to Pushgateway (${PROM_PUSHGATEWAY_URL%/}/metrics/job/${PROM_JOB_NAME})"
      else
        warn "Failed to push backup metrics to Pushgateway (${PROM_PUSHGATEWAY_URL})"
      fi
    fi
  fi
}

# Read the previous last-success timestamp from the existing metrics file so
# that a failed run does not reset it.
previous_last_success() {
  if [[ -f "${PROM_FILE}" ]]; then
    awk '/^soroban_backup_last_success_timestamp_seconds / {print $2; exit}' "${PROM_FILE}" || echo 0
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------

# Classify a failure as transient (retryable) or permanent (fail fast).
# Arguments: exit code, and a text blob (stderr / response) to inspect.
# Returns 0 if the failure is transient, 1 if it is permanent.
is_transient_failure() {
  local exit_code="$1"
  local detail="${2:-}"

  # Authentication / authorization failures must never be retried: retrying
  # invalid credentials only delays the inevitable and can lock accounts.
  if [[ "${detail}" =~ (401|403|Unauthorized|Forbidden|AccessDenied|AccessDeniedException|InvalidAccessKeyId|SignatureDoesNotMatch|InvalidToken|invalid_grant|authentication failed|password authentication failed) ]]; then
    return 1
  fi

  # HTTP 5xx responses are transient.
  if [[ "${detail}" =~ (HTTP[^0-9]*5[0-9][0-9]|status[^0-9]*5[0-9][0-9]|"status":[[:space:]]*5[0-9][0-9]) ]]; then
    return 0
  fi

  # curl exit codes: 6 (resolve), 7 (connect), 28 (timeout), 35 (TLS), 52 (empty reply), 56 (recv).
  case "${exit_code}" in
    6|7|28|35|52|56) return 0 ;;
  esac

  # AWS CLI / generic transient markers.
  if [[ "${detail}" =~ (timed?\ out|timeout|connection\ reset|connection\ refused|temporarily\ unavailable|ServiceUnavailable|SlowDown|RequestTimeout|Throttl|ECONNRESET|ETIMEDOUT|network) ]]; then
    return 0
  fi

  return 1
}

# Run a command with bounded exponential backoff, retrying only transient
# failures. Usage: retry_with_backoff <max_retries> <label> <cmd...>
retry_with_backoff() {
  local max_retries="$1"; shift
  local label="$1"; shift

  local attempt=0
  local rc=0
  local err_file
  err_file="$(mktemp "${WORK_DIR}/retry.XXXXXX" 2>/dev/null || mktemp)"

  while :; do
    rc=0
    "$@" 2>"${err_file}" || rc=$?

    if [[ "${rc}" -eq 0 ]]; then
      rm -f "${err_file}"
      return 0
    fi

    local detail
    detail="$(cat "${err_file}" 2>/dev/null || true)"

    if ! is_transient_failure "${rc}" "${detail}"; then
      error "${label} failed with a non-retryable error (exit ${rc})"
      [[ -n "${detail}" ]] && printf '%s\n' "${detail}" >&2
      rm -f "${err_file}"
      return "${rc}"
    fi

    if [[ "${attempt}" -ge "${max_retries}" ]]; then
      error "${label} failed after ${attempt} retries (exit ${rc})"
      [[ -n "${detail}" ]] && printf '%s\n' "${detail}" >&2
      rm -f "${err_file}"
      return "${rc}"
    fi

    local delay=$(( BACKUP_RETRY_BACKOFF_SECONDS * (1 << attempt) ))
    if [[ "${delay}" -gt "${BACKUP_RETRY_MAX_BACKOFF_SECONDS}" ]]; then
      delay="${BACKUP_RETRY_MAX_BACKOFF_SECONDS}"
    fi
    warn "${label} failed transiently (exit ${rc}); retry $(( attempt + 1 ))/${max_retries} in ${delay}s"
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
  done
}

# ---------------------------------------------------------------------------
# Database dump
# ---------------------------------------------------------------------------

dump_database() {
  local out_dir="$1"
  if [[ "${BACKUP_SKIP_DB}" == "1" ]]; then
    info "Skipping database dump (BACKUP_SKIP_DB=1)"
    return 0
  fi

  if [[ -z "${DATABASE_URL}" ]]; then
    die 2 "DATABASE_URL is required for database dump"
  fi

  info "Dumping Postgres database"
  local dump_path="${out_dir}/database.sql.gz"

  # Capture client and server version metadata for the manifest.
  PG_DUMP_VERSION="$(pg_dump --version 2>/dev/null | head -n1 || true)"
  PG_SERVER_VERSION="$(psql "${DATABASE_URL}" -X -At -v ON_ERROR_STOP=1 -c 'SHOW server_version;' 2>/dev/null | head -n1 || true)"
  if [[ -z "${PG_SERVER_VERSION}" ]]; then
    warn "Could not determine PostgreSQL server version"
  fi
  debug "pg_dump: ${PG_DUMP_VERSION:-unknown}; server: ${PG_SERVER_VERSION:-unknown}"

  # Plain SQL with DROP ... IF EXISTS statements so restore.sh can replay it
  # onto an existing database with psql. pg_dump writes to stdout so we can
  # pipe directly into gzip without a temp file.
  if ! pg_dump --no-owner --no-privileges --format=plain --clean --if-exists \
      "${DATABASE_URL}" | gzip -9 > "${dump_path}"; then
    die 1 "pg_dump failed"
  fi

  # Record the table list so restore.sh --verify-only can check that every
  # table came back.
  if ! psql "${DATABASE_URL}" -X -At -v ON_ERROR_STOP=1 -c \
      "SELECT schemaname || '.' || tablename FROM pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY 1;" > "${out_dir}/tables.txt"; then
    die 1 "failed to list tables for the backup manifest"
  fi

  debug "Database dump written to ${dump_path} ($(stat -c '%s' "${dump_path}" 2>/dev/null || stat -f '%z' "${dump_path}") bytes)"

  # Record row counts for the configured critical tables so restore.sh can
  # verify that no critical data went missing even when every table exists.
  record_critical_table_counts "${out_dir}"
}

# Resolve the list of critical tables from env var and/or file.
resolve_critical_tables() {
  local tables=()

  if [[ -n "${BACKUP_CRITICAL_TABLES}" ]]; then
    IFS=',' read -r -a _env_tables <<< "${BACKUP_CRITICAL_TABLES}"
    for t in "${_env_tables[@]}"; do
      t="$(printf '%s' "${t}" | tr -d '[:space:]')"
      [[ -n "${t}" ]] && tables+=("${t}")
    done
  fi

  if [[ -n "${BACKUP_CRITICAL_TABLES_FILE}" && -f "${BACKUP_CRITICAL_TABLES_FILE}" ]]; then
    while IFS= read -r line; do
      line="$(printf '%s' "${line}" | tr -d '[:space:]')"
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      tables+=("${line}")
    done < "${BACKUP_CRITICAL_TABLES_FILE}"
  fi

  # De-duplicate while preserving order.
  if [[ ${#tables[@]} -gt 0 ]]; then
    printf '%s\n' "${tables[@]}" | awk '!seen[$0]++'
  fi
}

# Quote an identifier for safe use in SQL (schema.table or table).
sql_quote_ident() {
  local ident="$1"
  printf '"%s"' "${ident//\"/\"\"}"
}

# Write critical-tables.txt (TSV: table<TAB>row_count) into the staging dir and
# populate CRITICAL_TABLE_COUNTS_JSON for the manifest.
record_critical_table_counts() {
  local out_dir="$1"
  CRITICAL_TABLE_COUNTS_JSON="[]"

  local tables
  tables="$(resolve_critical_tables || true)"
  if [[ -z "${tables}" ]]; then
    debug "No critical tables configured; skipping row count capture"
    return 0
  fi

  info "Recording row counts for critical tables"
  local counts_file="${out_dir}/critical-tables.txt"
  : > "${counts_file}"

  local entries=()
  local table count
  while IFS= read -r table; do
    [[ -z "${table}" ]] && continue

    local qualified
    if [[ "${table}" == *.* ]]; then
      local schema="${table%%.*}"
      local rel="${table#*.}"
      qualified="$(sql_quote_ident "${schema}").$(sql_quote_ident "${rel}")"
    else
      qualified="$(sql_quote_ident "${table}")"
    fi

    count="$(psql "${DATABASE_URL}" -X -At -v ON_ERROR_STOP=1 \
      -c "SELECT count(*) FROM ${qualified};" 2>/dev/null | head -n1 || true)"

    if [[ -z "${count}" || ! "${count}" =~ ^[0-9]+$ ]]; then
      warn "Could not record row count for critical table ${table}"
      printf '%s\t%s\n' "${table}" "unknown" >> "${counts_file}"
      entries+=("$(printf '{"table":"%s","rowCount":null}' "$(json_escape "${table}")")")
      continue
    fi

    printf '%s\t%s\n' "${table}" "${count}" >> "${counts_file}"
    entries+=("$(printf '{"table":"%s","rowCount":%s}' "$(json_escape "${table}")" "${count}")")
    debug "Critical table ${table}: ${count} rows"
  done <<< "${tables}"

  local joined="" entry
  for entry in "${entries[@]}"; do
    if [[ -n "${joined}" ]]; then
      joined="${joined},${entry}"
    else
      joined="${entry}"
    fi
  done
  CRITICAL_TABLE_COUNTS_JSON="[${joined}]"
}

# ---------------------------------------------------------------------------
# Contract state capture
# ---------------------------------------------------------------------------

# Resolve the list of contract IDs from env var and/or file.
resolve_contract_ids() {
  local ids=()

  if [[ -n "${SOROBAN_CONTRACT_IDS}" ]]; then
    IFS=',' read -r -a _env_ids <<< "${SOROBAN_CONTRACT_IDS}"
    for id in "${_env_ids[@]}"; do
      id="$(printf '%s' "${id}" | tr -d '[:space:]')"
      [[ -n "${id}" ]] && ids+=("${id}")
    done
  fi

  if [[ -n "${SOROBAN_CONTRACT_IDS_FILE}" && -f "${SOROBAN_CONTRACT_IDS_FILE}" ]]; then
    while IFS= read -r line; do
      line="$(printf '%s' "${line}" | tr -d '[:space:]')"
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      ids+=("${line}")
    done < "${SOROBAN_CONTRACT_IDS_FILE}"
  fi

  # De-duplicate while preserving order.
  if [[ ${#ids[@]} -gt 0 ]]; then
    printf '%s\n' "${ids[@]}" | awk '!seen[$0]++'
  fi
}

# Perform a JSON-RPC call against the Soroban RPC endpoint.
soroban_rpc_call() {
  local method="$1"
  local params="$2"

  local payload
  payload="$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "${method}" "${params}")"

  retry_with_backoff "${BACKUP_RPC_MAX_RETRIES}" "Soroban RPC ${method}" \
    curl -fsS \
      -X POST \
      -H 'Content-Type: application/json' \
      --connect-timeout "${BACKUP_RPC_TIMEOUT_SECONDS}" \
      --max-time "${BACKUP_RPC_TIMEOUT_SECONDS}" \
      --data "${payload}" \
      "${SOROBAN_RPC_URL}"
}

# Fetch the latest ledger entries for a contract's instance and persistent storage.
fetch_contract_state() {
  local contract_id="$1"
  local out_file="$2"

  local instance_params
  instance_params="$(printf '{"contractId":"%s","durability":"persistent"}' "${contract_id}")"

  local instance_response
  if ! instance_response="$(soroban_rpc_call "getContractData" "${instance_params}" 2>/dev/null)"; then
    warn "Failed to fetch instance state for contract ${contract_id}"
    printf '{"contractId":"%s","error":"rpc_call_failed"}\n' "${contract_id}" > "${out_file}"
    return 1
  fi

  local persistent_entries="[]"
  if [[ -n "${SOROBAN_CONTRACT_STORAGE_KEYS:-}" ]]; then
    local -a entry_jsons=()
    local key_xdr
    IFS=',' read -r -a _keys <<< "${SOROBAN_CONTRACT_STORAGE_KEYS}"
    for key_xdr in "${_keys[@]}"; do
      key_xdr="$(printf '%s' "${key_xdr}" | tr -d '[:space:]')"
      [[ -z "${key_xdr}" ]] && continue
      local key_params key_resp
      key_params="$(printf '{"contractId":"%s","key":"%s","durability":"persistent"}' "${contract_id}" "${key_xdr}")"
      if key_resp="$(soroban_rpc_call "getContractData" "${key_params}" 2>/dev/null)"; then
        entry_jsons+=("$(printf '{"key":"%s","result":%s}' "${key_xdr}" "${key_resp}")")
      fi
    done
    if [[ ${#entry_jsons[@]} -gt 0 ]]; then
      local joined=""
      local item
      for item in "${entry_jsons[@]}"; do
        if [[ -n "${joined}" ]]; then
          joined="${joined},${item}"
        else
          joined="${item}"
        fi
      done
      persistent_entries="[${joined}]"
    fi
  fi

  printf '{"contractId":"%s","instance":%s,"persistentStorage":%s}\n' \
    "${contract_id}" "${instance_response}" "${persistent_entries}" > "${out_file}"
  return 0
}

capture_contract_state() {
  local out_dir="$1"
  if [[ "${BACKUP_SKIP_CONTRACTS}" == "1" ]]; then
    info "Skipping contract state capture (BACKUP_SKIP_CONTRACTS=1)"
    return 0
  fi

  if [[ -z "${SOROBAN_RPC_URL}" ]]; then
    warn "SOROBAN_RPC_URL not set; skipping contract state capture"
    return 0
  fi

  local contracts_dir="${out_dir}/contracts"
  mkdir -p "${contracts_dir}"

  local ids
  ids="$(resolve_contract_ids || true)"

  if [[ -z "${ids}" ]]; then
    warn "No contract IDs configured; writing empty contract index"
    printf '{"contracts":[],"capturedAt":"%s"}\n' "${BACKUP_DATE_ISO}" \
      > "${contracts_dir}/index.json"
    return 0
  fi

  info "Capturing on-chain state for contracts"
  local index_entries=()
  local id
  while IFS= read -r id; do
    [[ -z "${id}" ]] && continue
    local safe_id
    safe_id="$(printf '%s' "${id}" | tr -c 'A-Za-z0-9._-' '_')"
    local state_file="${contracts_dir}/${safe_id}.json"

    if fetch_contract_state "${id}" "${state_file}"; then
      index_entries+=("$(printf '{"contractId":"%s","file":"%s","status":"ok"}' "${id}" "${safe_id}.json")")
    else
      index_entries+=("$(printf '{"contractId":"%s","file":"%s","status":"error"}' "${id}" "${safe_id}.json")")
    fi
  done <<< "${ids}"

  {
    printf '{"capturedAt":"%s","rpcUrl":"%s","networkPassphrase":"%s","contracts":[' \
      "${BACKUP_DATE_ISO}" "${SOROBAN_RPC_URL}" "${SOROBAN_NETWORK_PASSPHRASE}"
    local first=1
    for entry in "${index_entries[@]}"; do
      if [[ ${first} -eq 0 ]]; then
        printf ','
      fi
      printf '%s' "${entry}"
      first=0
    done
    printf ']}\n'
  } > "${contracts_dir}/index.json"

  debug "Contract state captured in ${contracts_dir}"
}

# ---------------------------------------------------------------------------
# Archive creation
# ---------------------------------------------------------------------------

create_archive() {
  local staging_dir="$1"
  info "Creating archive ${ARCHIVE_PATH}"

  # Deterministic ordering for reproducibility.
  tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH:-$(date -u +%s)}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -czf "${ARCHIVE_PATH}" \
    -C "${staging_dir}" .

  debug "Archive created: $(stat -c '%s' "${ARCHIVE_PATH}" 2>/dev/null || stat -f '%z' "${ARCHIVE_PATH}") bytes"
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

encrypt_archive() {
  local input="$1"
  local output="$2"

  case "${BACKUP_ENCRYPTION_METHOD}" in
    none)
      info "Encryption disabled; copying archive"
      cp -f "${input}" "${output}"
      ;;
    age)
      info "Encrypting archive with age"
      local recipient="${BACKUP_ENCRYPTION_KEY}"
      # check_dependencies already verified that BACKUP_ENCRYPTION_KEY is either
      # an existing recipients file or an age1... recipient public key, and that
      # BACKUP_AGE_RECIPIENTS_FILE (if set) contains at least one recipient.
      if [[ -n "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
        # Encrypt to every recipient in the file so any authorized custodian
        # can decrypt. Only public recipients are read; identities stay out.
        local -a recipient_args=()
        local line
        while IFS= read -r line; do
          line="$(printf '%s' "${line}" | tr -d '[:space:]')"
          [[ -z "${line}" || "${line}" == \#* ]] && continue
          recipient_args+=(--recipient "${line}")
        done < "${BACKUP_AGE_RECIPIENTS_FILE}"
        if [[ ${#recipient_args[@]} -eq 0 ]]; then
          die 2 "BACKUP_AGE_RECIPIENTS_FILE contains no usable recipients"
        fi
        debug "Encrypting to ${#recipient_args[@]} age recipient(s) from ${BACKUP_AGE_RECIPIENTS_FILE}"
        age --encrypt "${recipient_args[@]}" \
          --output "${output}" "${input}"
      elif [[ -f "${BACKUP_ENCRYPTION_KEY}" ]]; then
        age --encrypt --recipients-file "${BACKUP_ENCRYPTION_KEY}" \
          --output "${output}" "${input}"
      elif [[ "${BACKUP_ENCRYPTION_KEY}" == age1* ]]; then
        age --encrypt --recipient "${recipient}" \
          --output "${output}" "${input}"
      else
        die 2 "age requires an age1... recipient or a recipients file; use gpg for passphrases"
      fi
      ;;
    gpg)
      info "Encrypting archive with gpg"
      if [[ -f "${BACKUP_ENCRYPTION_KEY}" ]]; then
        gpg --batch --yes --no-tty \
          --output "${output}" \
          --encrypt --recipient-file "${BACKUP_ENCRYPTION_KEY}" \
          "${input}"
      else
        printf '%s' "${BACKUP_ENCRYPTION_KEY}" \
          | gpg --batch --yes --no-tty --passphrase-fd 0 \
              --symmetric --cipher-algo AES256 \
              --output "${output}" \
              "${input}"
      fi
      ;;
    *)
      die 2 "Unsupported encryption method: ${BACKUP_ENCRYPTION_METHOD}"
      ;;
  esac

  if [[ ! -s "${output}" ]]; then
    die 1 "Encryption produced an empty output file"
  fi
}

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------

# Compute the object key for the given local file.
object_key_for() {
  local filename="$1"
  printf '%s/%s' "${BACKUP_STORAGE_PREFIX%/}" "${filename}"
}

# Upload a file to S3-compatible storage (AWS S3, R2, MinIO, Supabase's S3
# endpoint, ...) with the AWS CLI, which handles SigV4 signing and multipart
# uploads for large archives.
upload_s3() {
  local file="$1"
  local key="$2"

  local -a args=(--region "${BACKUP_STORAGE_REGION}" --only-show-errors)
  if [[ -n "${BACKUP_STORAGE_ENDPOINT}" ]]; then
    args+=(--endpoint-url "${BACKUP_STORAGE_ENDPOINT%/}")
  fi

  retry_with_backoff "${BACKUP_STORAGE_MAX_RETRIES}" "S3 upload ${key}" \
    env \
      AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      AWS_SESSION_TOKEN="${BACKUP_STORAGE_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}" \
      AWS_CLI_READ_TIMEOUT="${BACKUP_STORAGE_TIMEOUT_SECONDS}" \
      AWS_CLI_CONNECT_TIMEOUT="${BACKUP_STORAGE_TIMEOUT_SECONDS}" \
      aws s3 cp "${args[@]}" "${file}" "s3://${BACKUP_STORAGE_BUCKET}/${key}"
}

# Upload a file to Supabase Storage using its REST API.
upload_supabase() {
  local file="$1"
  local key="$2"

  if [[ -z "${BACKUP_STORAGE_SUPABASE_URL}" || -z "${BACKUP_STORAGE_SUPABASE_SERVICE_KEY}" ]]; then
    die 2 "Supabase storage requires BACKUP_STORAGE_SUPABASE_URL and BACKUP_STORAGE_SUPABASE_SERVICE_KEY"
  fi

  local url="${BACKUP_STORAGE_SUPABASE_URL%/}/storage/v1/object/${BACKUP_STORAGE_BUCKET}/${key}"
  local content_type="application/octet-stream"

  retry_with_backoff "${BACKUP_STORAGE_MAX_RETRIES}" "Supabase upload ${key}" \
    curl -fsS \
      -X POST \
      -H "Authorization: Bearer ${BACKUP_STORAGE_SUPABASE_SERVICE_KEY}" \
      -H "Content-Type: ${content_type}" \
      -H "x-upsert: true" \
      --data-binary "@${file}" \
      --connect-timeout "${BACKUP_STORAGE_TIMEOUT_SECONDS}" \
      --max-time "${BACKUP_STORAGE_TIMEOUT_SECONDS}" \
      "${url}"
}

upload_artifact() {
  local file="$1"
  local key="$2"

  if [[ "${BACKUP_SKIP_UPLOAD}" == "1" ]]; then
    info "Skipping upload (BACKUP_SKIP_UPLOAD=1)"
    return 0
  fi

  case "${BACKUP_STORAGE_PROVIDER}" in
    s3)
      info "Uploading ${file} to s3://${BACKUP_STORAGE_BUCKET}/${key}"
      upload_s3 "${file}" "${key}"
      ;;
    supabase)
      info "Uploading ${file} to supabase://${BACKUP_STORAGE_BUCKET}/${key}"
      upload_supabase "${file}" "${key}"
      ;;
    *)
      die 2 "Unsupported BACKUP_STORAGE_PROVIDER: ${BACKUP_STORAGE_PROVIDER}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

# Escape arbitrary strings for safe inclusion inside JSON string literals.
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

# Schema version for the manifest format. Bump when fields change shape.
BACKUP_MANIFEST_SCHEMA_VERSION="${BACKUP_MANIFEST_SCHEMA_VERSION:-1}"

write_manifest() {
  local encrypted_file="$1"
  local checksum="$2"
  local size_bytes="$3"
  local object_key="$4"
  local db_included="$5"
  local contracts_included="$6"
  local db_checksum="${7:-}"
  local contracts_checksum="${8:-}"

  local hostname
  hostname="$(hostname 2>/dev/null || echo unknown)"
  local git_commit="${GIT_COMMIT:-}"
  local environment="${ENVIRONMENT:-${APP_ENV:-unknown}}"
  local enc_basename
  enc_basename="$(basename "${encrypted_file}")"

  cat > "${MANIFEST_PATH}" <<EOF
{
  "schemaVersion": ${BACKUP_MANIFEST_SCHEMA_VERSION},
  "name": "$(json_escape "${BACKUP_NAME}")",
  "timestamp": "$(json_escape "${BACKUP_DATE_ISO}")",
  "timestampEpoch": $(date -u +%s),
  "checksum": {
    "algorithm": "sha256",
    "value": "$(json_escape "${checksum}")"
  },
  "sizeBytes": ${size_bytes},
  "encryption": {
    "method": "$(json_escape "${BACKUP_ENCRYPTION_METHOD}")",
    "enabled": $([[ "${BACKUP_ENCRYPTION_METHOD}" == "none" ]] && echo false || echo true)
  },
  "storage": {
    "provider": "$(json_escape "${BACKUP_STORAGE_PROVIDER}")",
    "bucket": "$(json_escape "${BACKUP_STORAGE_BUCKET}")",
    "key": "$(json_escape "${object_key}")"
  },
  "status": {
    "upload": "$(json_escape "${UPLOAD_STATUS}")",
    "retention": "$(json_escape "${RETENTION_STATUS}")"
  },
  "source": {
    "hostname": "$(json_escape "${hostname}")",
    "environment": "$(json_escape "${environment}")",
    "gitCommit": "$(json_escape "${git_commit}")",
    "databaseIncluded": ${db_included},
    "contractsIncluded": ${contracts_included},
    "sorobanRpcUrl": "$(json_escape "${SOROBAN_RPC_URL}")",
    "sorobanNetworkPassphrase": "$(json_escape "${SOROBAN_NETWORK_PASSPHRASE}")"
  },
  "versions": {
    "postgresServer": "$(json_escape "${PG_SERVER_VERSION:-}")",
    "pgDumpClient": "$(json_escape "${PG_DUMP_VERSION:-}")"
  },
  "componentChecksums": {
    "database": "$(json_escape "${db_checksum}")",
    "contracts": "$(json_escape "${contracts_checksum}")"
  },
  "criticalTables": ${CRITICAL_TABLE_COUNTS_JSON:-[]},
  "runId": "$(json_escape "${BACKUP_RUN_ID}")",
  "artifacts": {
    "archive": "$(json_escape "$(basename "${ARCHIVE_PATH}")")",
    "encrypted": "$(json_escape "${enc_basename}")",
    "manifest": "$(json_escape "$(basename "${MANIFEST_PATH}")")"
  }
}
EOF

  # Record the final phase statuses once known. The manifest is written before
  # upload, so statuses are patched in afterwards by update_manifest_status.
  debug "Manifest written to ${MANIFEST_PATH}"
}

# Patch the manifest's status block in place after upload/retention complete.
update_manifest_status() {
  [[ -f "${MANIFEST_PATH}" ]] || return 0
  local tmp
  tmp="$(mktemp "${MANIFEST_PATH}.XXXXXX")"
  awk -v up="${UPLOAD_STATUS}" -v ret="${RETENTION_STATUS}" '
    /"status": \{/ { in_status=1 }
    in_status && /"upload":/ { sub(/"upload": "[^"]*"/, "\"upload\": \"" up "\""); print; next }
    in_status && /"retention":/ { sub(/"retention": "[^"]*"/, "\"retention\": \"" ret "\""); print; in_status=0; next }
    { print }
  ' "${MANIFEST_PATH}" > "${tmp}" && mv -f "${tmp}" "${MANIFEST_PATH}"
}

# ---------------------------------------------------------------------------
# Dry-run plan
# ---------------------------------------------------------------------------

# Print the planned components, destination and retention actions with all
# credentials redacted. Performs no dumps, uploads or deletions.
print_dry_run_plan() {
  local db_planned="yes" contracts_planned="yes"
  [[ "${BACKUP_SKIP_DB}" == "1" ]] && db_planned="no (BACKUP_SKIP_DB=1)"
  [[ "${BACKUP_SKIP_CONTRACTS}" == "1" ]] && contracts_planned="no (BACKUP_SKIP_CONTRACTS=1)"

  local upload_planned="yes"
  [[ "${BACKUP_SKIP_UPLOAD}" == "1" ]] && upload_planned="no (BACKUP_SKIP_UPLOAD=1)"

  local prune_planned="yes"
  if [[ "${BACKUP_SKIP_UPLOAD}" == "1" || "${BACKUP_SKIP_PRUNE}" == "1" ]]; then
    prune_planned="no (skipped)"
  elif [[ -z "${BACKUP_RETENTION_DAYS}" || "${BACKUP_RETENTION_DAYS}" -le 0 ]]; then
    prune_planned="no (retention disabled)"
  fi

  local enc_desc="${BACKUP_ENCRYPTION_METHOD}"
  if [[ "${BACKUP_ENCRYPTION_METHOD}" == "age" && -n "${BACKUP_AGE_RECIPIENTS_FILE}" ]]; then
    local n_recipients
    n_recipients="$(grep -Ec '^[[:space:]]*age1[0-9a-z]+' "${BACKUP_AGE_RECIPIENTS_FILE}" 2>/dev/null || echo 0)"
    enc_desc="age (${n_recipients} recipient(s) from ${BACKUP_AGE_RECIPIENTS_FILE})"
  fi

  local dest="local only"
  if [[ "${BACKUP_SKIP_UPLOAD}" != "1" ]]; then
    dest="${BACKUP_STORAGE_PROVIDER}://${BACKUP_STORAGE_BUCKET}/${BACKUP_STORAGE_PREFIX%/}"
  fi

  {
    printf 'DRY RUN — no data will be dumped, uploaded or deleted.\n'
    printf '  backup name:        %s\n' "${BACKUP_NAME}"
    printf '  timestamp:          %s\n' "${BACKUP_DATE_ISO}"
    printf '  work dir:           %s\n' "${WORK_DIR}"
    printf '  database dump:      %s\n' "${db_planned}"
    printf '  contract snapshot:  %s\n' "${contracts_planned}"
    printf '  encryption:         %s\n' "${enc_desc}"
    printf '  upload:             %s\n' "${upload_planned}"
    printf '  destination:        %s\n' "${dest}"
    printf '  retention prune:    %s (retention days: %s)\n' "${prune_planned}" "${BACKUP_RETENTION_DAYS}"
    printf '  credentials (redacted):\n'
    printf '    DATABASE_URL:                          %s\n' "$(redact "${DATABASE_URL}")"
    printf '    BACKUP_ENCRYPTION_KEY:                 %s\n' "$(redact "${BACKUP_ENCRYPTION_KEY}")"
    printf '    BACKUP_STORAGE_ACCESS_KEY_ID:          %s\n' "$(redact "${BACKUP_STORAGE_ACCESS_KEY_ID}")"
    printf '    BACKUP_STORAGE_SECRET_ACCESS_KEY:      %s\n' "$(redact "${BACKUP_STORAGE_SECRET_ACCESS_KEY}")"
    printf '    BACKUP_STORAGE_SESSION_TOKEN:          %s\n' "$(redact "${BACKUP_STORAGE_SESSION_TOKEN}")"
    printf '    BACKUP_STORAGE_SUPABASE_SERVICE_KEY:   %s\n' "$(redact "${BACKUP_STORAGE_SUPABASE_SERVICE_KEY}")"
  } >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local start_ts
  start_ts="$(date -u +%s)"
  START_TS="${start_ts}"

  info "Starting backup ${BACKUP_NAME} (run ${BACKUP_RUN_ID})"

  validate_configuration
  check_dependencies
  acquire_lock

  if [[ "${BACKUP_DRY_RUN}" == "1" ]]; then
    print_dry_run_plan
    info "Dry run complete; no changes made"
    # Prevent the EXIT trap from emitting failure metrics for a dry run.
    START_TS=""
    exit 0
  fi

  mkdir -p "${WORK_DIR}"
  local staging_dir="${WORK_DIR}/staging-${BACKUP_RUN_ID}"
  mkdir -p "${staging_dir}"

  # Preflight: fail before creating any dump if staging space is insufficient.
  check_free_space

  # 1. Database dump.
  dump_database "${staging_dir}"

  # 2. Contract state.
  capture_contract_state "${staging_dir}"

  # 3. Archive.
  create_archive "${staging_dir}"

  # 4. Encrypt.
  encrypt_archive "${ARCHIVE_PATH}" "${ENCRYPTED_PATH}"

  # 5. Checksum + size.
  local checksum
  checksum="$(sha256sum "${ENCRYPTED_PATH}" | awk '{print $1}')"
  local size_bytes
  size_bytes="$(stat -c '%s' "${ENCRYPTED_PATH}" 2>/dev/null || stat -f '%z' "${ENCRYPTED_PATH}")"

  # Per-component checksums (database dump and contract snapshot).
  local db_checksum="" contracts_checksum=""
  if [[ -f "${staging_dir}/database.sql.gz" ]]; then
    db_checksum="$(sha256sum "${staging_dir}/database.sql.gz" | awk '{print $1}')"
  fi
  if [[ -d "${staging_dir}/contracts" ]]; then
    contracts_checksum="$(cd "${staging_dir}" && tar --sort=name -cf - contracts 2>/dev/null | sha256sum | awk '{print $1}')"
  fi

  # 6. Upload encrypted archive + manifest.
  local encrypted_key
  encrypted_key="$(object_key_for "$(basename "${ENCRYPTED_PATH}")")"

  local db_included="false"
  [[ "${BACKUP_SKIP_DB}" != "1" ]] && db_included="true"
  local contracts_included="false"
  [[ "${BACKUP_SKIP_CONTRACTS}" != "1" ]] && contracts_included="true"

  UPLOADED_SIZE_BYTES="${size_bytes}"
  UPLOADED_CHECKSUM="${checksum}"
  UPLOADED_OBJECT_KEY="${encrypted_key}"

  write_manifest "${ENCRYPTED_PATH}" "${checksum}" "${size_bytes}" \
    "${encrypted_key}" "${db_included}" "${contracts_included}" \
    "${db_checksum}" "${contracts_checksum}"

  # 6a. Upload encrypted archive + manifest. Track upload status separately
  # from retention so a later prune failure does not mask a recoverable backup.
  if [[ "${BACKUP_SKIP_UPLOAD}" == "1" ]]; then
    UPLOAD_STATUS="skipped"
    info "Skipping upload (BACKUP_SKIP_UPLOAD=1)"
  else
    local upload_rc=0
    upload_artifact "${ENCRYPTED_PATH}" "${encrypted_key}" || upload_rc=$?
    if [[ "${upload_rc}" -eq 0 ]]; then
      local manifest_key
      manifest_key="$(object_key_for "$(basename "${MANIFEST_PATH}")")"
      upload_artifact "${MANIFEST_PATH}" "${manifest_key}" || upload_rc=$?
    fi
    if [[ "${upload_rc}" -eq 0 ]]; then
      UPLOAD_STATUS="success"
      info "Upload succeeded: ${encrypted_key}"
    else
      UPLOAD_STATUS="failed"
      UPLOAD_ERROR="upload failed with exit code ${upload_rc}"
      error "Upload failed (exit ${upload_rc}); no recoverable backup was published"
    fi
  fi

  # 6b. Prune expired backups exceeding BACKUP_RETENTION_DAYS. A prune failure
  # is reported separately and must not invalidate a successful upload.
  local prune_rc=0
  prune_old_backups || prune_rc=$?
  if [[ "${prune_rc}" -ne 0 ]]; then
    RETENTION_STATUS="failed"
    RETENTION_ERROR="retention cleanup failed with exit code ${prune_rc}"
    warn "Retention cleanup failed (exit ${prune_rc}); uploaded backup remains available"
  elif [[ "${RETENTION_STATUS}" == "pending" ]]; then
    RETENTION_STATUS="success"
  fi

  update_manifest_status

  # 7. Metrics. Overall success requires a successful upload (or an explicit
  # skip) and a non-failed retention phase.
  local end_ts duration
  end_ts="$(date -u +%s)"
  duration=$(( end_ts - start_ts ))

  local overall_success=1
  if [[ "${UPLOAD_STATUS}" == "failed" || "${RETENTION_STATUS}" == "failed" ]]; then
    overall_success=0
  fi

  local overall_error=""
  if [[ "${UPLOAD_STATUS}" == "failed" ]]; then
    overall_error="${UPLOAD_ERROR}"
  elif [[ "${RETENTION_STATUS}" == "failed" ]]; then
    overall_error="${RETENTION_ERROR}"
  fi

  emit_metrics "${overall_success}" "${duration}" "${size_bytes}" "${end_ts}" "${overall_error}"

  # 8. Optional local copy of the manifest (e.g. for CI artifact upload).
  # The run-scoped copy is always written; the shared `manifest.json` pointer
  # is only updated on success and is last-writer-wins by design.
  if [[ -n "${BACKUP_OUTPUT_DIR}" ]]; then
    mkdir -p "${BACKUP_OUTPUT_DIR}"
    cp -f "${MANIFEST_PATH}" "${BACKUP_OUTPUT_DIR}/"
    cp -f "${MANIFEST_PATH}" "${BACKUP_OUTPUT_DIR}/manifest.json"
    info "Manifest copied to ${BACKUP_OUTPUT_DIR}"
  fi

  if [[ "${UPLOAD_STATUS}" == "failed" ]]; then
    die 1 "Backup upload failed; no recoverable backup was published"
  fi

  if [[ "${RETENTION_STATUS}" == "failed" ]]; then
    warn "Backup uploaded successfully (${size_bytes} bytes, sha256=${checksum}) but retention cleanup failed"
    die 1 "Retention cleanup failed after successful upload"
  fi

  info "Backup completed successfully in ${duration}s (${size_bytes} bytes, sha256=${checksum})"
}

prune_old_backups() {
  if [[ "${BACKUP_SKIP_UPLOAD}" == "1" || "${BACKUP_SKIP_PRUNE}" == "1" ]]; then
    debug "Skipping backup pruning"
    RETENTION_STATUS="skipped"
    return 0
  fi
  if [[ -z "${BACKUP_RETENTION_DAYS}" || "${BACKUP_RETENTION_DAYS}" -le 0 ]]; then
    RETENTION_STATUS="skipped"
    return 0
  fi

  local cutoff_ts=""
  cutoff_ts="$(date -u -d "${BACKUP_RETENTION_DAYS} days ago" +%Y%m%dT%H%M%SZ 2>/dev/null \
    || date -u -v-"${BACKUP_RETENTION_DAYS}"d +%Y%m%dT%H%M%SZ 2>/dev/null \
    || true)"
  if [[ -z "${cutoff_ts}" ]]; then
    warn "Could not compute retention cutoff timestamp; skipping prune"
    RETENTION_STATUS="skipped"
    return 0
  fi

  info "Pruning backups older than ${BACKUP_RETENTION_DAYS} days (cutoff ${cutoff_ts})"

  if [[ "${BACKUP_STORAGE_PROVIDER}" == "s3" ]]; then
    local -a args=(--region "${BACKUP_STORAGE_REGION}")
    if [[ -n "${BACKUP_STORAGE_ENDPOINT}" ]]; then
      args+=(--endpoint-url "${BACKUP_STORAGE_ENDPOINT%/}")
    fi
    local prefix="${BACKUP_STORAGE_PREFIX%/}"
    local listing=""
    listing="$(AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
      AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
      AWS_SESSION_TOKEN="${BACKUP_STORAGE_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}" \
      aws "${args[@]}" s3 ls "s3://${BACKUP_STORAGE_BUCKET}/${prefix}/" 2>/dev/null || true)"

    local obj_name
    while IFS= read -r obj_name; do
      [[ -n "${obj_name}" ]] || continue
      if [[ "${obj_name}" =~ ^soroban-backup-([0-9]{8}T[0-9]{6}Z)(-[0-9A-Za-z]+)?\.(tar\.gz\.enc|manifest\.json)$ ]]; then
        local obj_ts="${BASH_REMATCH[1]}"
        if [[ "${obj_ts}" < "${cutoff_ts}" ]]; then
          info "Deleting expired backup object s3://${BACKUP_STORAGE_BUCKET}/${prefix}/${obj_name}"
          AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
          AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
          AWS_SESSION_TOKEN="${BACKUP_STORAGE_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}" \
            aws "${args[@]}" s3 rm "s3://${BACKUP_STORAGE_BUCKET}/${prefix}/${obj_name}" --only-show-errors || \
            warn "Failed to delete expired object ${obj_name}"
        fi
      fi
    done < <(printf '%s\n' "${listing}" | awk '{print $4}')
  fi
}

# Called directly (not as `if ! main`) so `set -e` stays in effect inside it;
# failure metrics are emitted by the EXIT trap.
main