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

# ---------------------------------------------------------------------------
# Configuration & defaults
# ---------------------------------------------------------------------------

# Timestamp (UTC) used for artifact naming and manifest.
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
BACKUP_DATE_ISO="${BACKUP_DATE_ISO:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Working directory for staging artifacts.
WORK_DIR="${BACKUP_WORK_DIR:-$(mktemp -d -t soroban-backup-XXXXXXXX)}"
CLEANUP_WORK_DIR="${BACKUP_CLEANUP_WORK_DIR:-1}"

# Artifact naming.
BACKUP_NAME="${BACKUP_NAME:-soroban-backup-${BACKUP_TIMESTAMP}}"
ARCHIVE_PATH="${WORK_DIR}/${BACKUP_NAME}.tar.gz"
ENCRYPTED_PATH="${ARCHIVE_PATH}.enc"
MANIFEST_PATH="${WORK_DIR}/${BACKUP_NAME}.manifest.json"

# Prometheus textfile collector output.
PROM_DIR="${PROM_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM_FILE="${PROM_FILE:-${PROM_DIR}/soroban_backup.prom}"

# Encryption settings.
# BACKUP_ENCRYPTION_KEY may be:
#   - an age identity / recipient string (age1... or AGE-SECRET-KEY-...)
#   - a passphrase (used with gpg symmetric encryption)
#   - a path to a key file
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_ENCRYPTION_METHOD="${BACKUP_ENCRYPTION_METHOD:-auto}" # auto|age|gpg|none

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

# Optional: path to a file containing additional contract IDs (one per line).
SOROBAN_CONTRACT_IDS_FILE="${SOROBAN_CONTRACT_IDS_FILE:-}"

# Retention / behaviour toggles.
BACKUP_SKIP_DB="${BACKUP_SKIP_DB:-0}"
BACKUP_SKIP_CONTRACTS="${BACKUP_SKIP_CONTRACTS:-0}"
BACKUP_SKIP_UPLOAD="${BACKUP_SKIP_UPLOAD:-0}"
BACKUP_VERBOSE="${BACKUP_VERBOSE:-0}"
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-}"

# Set by main(); read by the EXIT trap to report failure metrics.
START_TS=""

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
    emit_metrics 0 "$(( end_ts - START_TS ))" 0 "$(previous_last_success)" \
      "backup failed with exit code ${exit_code}" || true
    error "Backup failed with exit code ${exit_code}"
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
      # for age recipients (age1...) or recipient files; passphrases use gpg.
      if [[ ( "${BACKUP_ENCRYPTION_KEY}" == age1* || -f "${BACKUP_ENCRYPTION_KEY}" ) ]] \
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

  if [[ "${BACKUP_ENCRYPTION_METHOD}" != "none" && -z "${BACKUP_ENCRYPTION_KEY}" ]]; then
    die 2 "BACKUP_ENCRYPTION_KEY is required when encryption is enabled"
  fi

  if [[ "${BACKUP_ENCRYPTION_METHOD}" == "age" \
      && "${BACKUP_ENCRYPTION_KEY}" != age1* && ! -f "${BACKUP_ENCRYPTION_KEY}" ]]; then
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

# Emit metrics to the textfile collector. Always overwrites the file so that
# stale values do not persist across runs.
emit_metrics() {
  local success="$1"        # 1 or 0
  local duration_seconds="$2"
  local size_bytes="$3"
  local last_success_ts="$4" # unix epoch of last success (0 if unknown)
  local error_message="${5:-}"

  if [[ ! -d "${PROM_DIR}" ]]; then
    debug "Prometheus textfile directory ${PROM_DIR} does not exist; metrics not written"
    return 0
  fi

  local tmp
  tmp="$(mktemp "${PROM_FILE}.XXXXXX")"

  {
    printf '# HELP soroban_backup_success Whether the last backup run succeeded (1=success, 0=failure).\n'
    printf '# TYPE soroban_backup_success gauge\n'
    printf 'soroban_backup_success %s\n' "${success}"

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
  } > "${tmp}"

  mv -f "${tmp}" "${PROM_FILE}"
  debug "Wrote metrics to ${PROM_FILE}"
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

  curl -fsS \
    -X POST \
    -H 'Content-Type: application/json' \
    --max-time "${SOROBAN_RPC_TIMEOUT:-30}" \
    --data "${payload}" \
    "${SOROBAN_RPC_URL}"
}

# Fetch the latest ledger entry for a contract's instance.
fetch_contract_state() {
  local contract_id="$1"
  local out_file="$2"

  local params
  params="$(printf '{"contractId":"%s"}' "${contract_id}")"

  local response
  if ! response="$(soroban_rpc_call "getContractData" "${params}" 2>/dev/null)"; then
    warn "Failed to fetch state for contract ${contract_id}"
    printf '{"contractId":"%s","error":"rpc_call_failed"}\n' "${contract_id}" > "${out_file}"
    return 1
  fi

  printf '%s\n' "${response}" > "${out_file}"
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
      # If the key looks like a path to a file, use it as a recipient file.
      if [[ -f "${BACKUP_ENCRYPTION_KEY}" ]]; then
        age --encrypt --recipients-file "${BACKUP_ENCRYPTION_KEY}" \
          --output "${output}" "${input}"
      elif [[ "${BACKUP_ENCRYPTION_KEY}" == age1* ]]; then
        age --encrypt --recipient "${recipient}" \
          --output "${output}" "${input}"
      else
        # Fall back to passphrase-based age encryption.
        printf '%s' "${BACKUP_ENCRYPTION_KEY}" \
          | age --encrypt --passphrase --output "${output}" "${input}"
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

  AWS_ACCESS_KEY_ID="${BACKUP_STORAGE_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}" \
  AWS_SECRET_ACCESS_KEY="${BACKUP_STORAGE_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}" \
  AWS_SESSION_TOKEN="${BACKUP_STORAGE_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}" \
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

  curl -fsS \
    -X POST \
    -H "Authorization: Bearer ${BACKUP_STORAGE_SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: ${content_type}" \
    -H "x-upsert: true" \
    --data-binary "@${file}" \
    --max-time "${BACKUP_UPLOAD_TIMEOUT:-300}" \
    "${url}" >/dev/null
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

write_manifest() {
  local encrypted_file="$1"
  local checksum="$2"
  local size_bytes="$3"
  local object_key="$4"
  local db_included="$5"
  local contracts_included="$6"

  local hostname
  hostname="$(hostname 2>/dev/null || echo unknown)"
  local git_commit="${GIT_COMMIT:-}"
  local environment="${ENVIRONMENT:-${APP_ENV:-unknown}}"

  cat > "${MANIFEST_PATH}" <<EOF
{
  "name": "${BACKUP_NAME}",
  "timestamp": "${BACKUP_DATE_ISO}",
  "timestampEpoch": $(date -u +%s),
  "checksum": {
    "algorithm": "sha256",
    "value": "${checksum}"
  },
  "sizeBytes": ${size_bytes},
  "encryption": {
    "method": "${BACKUP_ENCRYPTION_METHOD}",
    "enabled": $([[ "${BACKUP_ENCRYPTION_METHOD}" == "none" ]] && echo false || echo true)
  },
  "storage": {
    "provider": "${BACKUP_STORAGE_PROVIDER}",
    "bucket": "${BACKUP_STORAGE_BUCKET}",
    "key": "${object_key}"
  },
  "source": {
    "hostname": "${hostname}",
    "environment": "${environment}",
    "gitCommit": "${git_commit}",
    "databaseIncluded": ${db_included},
    "contractsIncluded": ${contracts_included},
    "sorobanRpcUrl": "${SOROBAN_RPC_URL}",
    "sorobanNetworkPassphrase": "${SOROBAN_NETWORK_PASSPHRASE}"
  },
  "artifacts": {
    "archive": "${BACKUP_NAME}.tar.gz",
    "encrypted": "$(basename "${encrypted_file}")",
    "manifest": "${BACKUP_NAME}.manifest.json"
  }
}
EOF

  debug "Manifest written to ${MANIFEST_PATH}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local start_ts
  start_ts="$(date -u +%s)"
  START_TS="${start_ts}"

  info "Starting backup ${BACKUP_NAME}"

  check_dependencies

  mkdir -p "${WORK_DIR}"
  local staging_dir="${WORK_DIR}/staging"
  mkdir -p "${staging_dir}"

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

  # 6. Upload encrypted archive + manifest.
  local encrypted_key
  encrypted_key="$(object_key_for "$(basename "${ENCRYPTED_PATH}")")"

  local db_included="false"
  [[ "${BACKUP_SKIP_DB}" != "1" ]] && db_included="true"
  local contracts_included="false"
  [[ "${BACKUP_SKIP_CONTRACTS}" != "1" ]] && contracts_included="true"

  write_manifest "${ENCRYPTED_PATH}" "${checksum}" "${size_bytes}" \
    "${encrypted_key}" "${db_included}" "${contracts_included}"

  upload_artifact "${ENCRYPTED_PATH}" "${encrypted_key}"

  local manifest_key
  manifest_key="$(object_key_for "$(basename "${MANIFEST_PATH}")")"
  upload_artifact "${MANIFEST_PATH}" "${manifest_key}"

  # 7. Metrics.
  local end_ts duration
  end_ts="$(date -u +%s)"
  duration=$(( end_ts - start_ts ))

  emit_metrics 1 "${duration}" "${size_bytes}" "${end_ts}" ""

  # 8. Optional local copy of the manifest (e.g. for CI artifact upload).
  if [[ -n "${BACKUP_OUTPUT_DIR}" ]]; then
    mkdir -p "${BACKUP_OUTPUT_DIR}"
    cp -f "${MANIFEST_PATH}" "${BACKUP_OUTPUT_DIR}/"
    cp -f "${MANIFEST_PATH}" "${BACKUP_OUTPUT_DIR}/manifest.json"
    info "Manifest copied to ${BACKUP_OUTPUT_DIR}"
  fi

  info "Backup completed successfully in ${duration}s (${size_bytes} bytes, sha256=${checksum})"
}

# Called directly (not as `if ! main`) so `set -e` stays in effect inside it;
# failure metrics are emitted by the EXIT trap.
main