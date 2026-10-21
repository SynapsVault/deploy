#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/restore.sh"
}

@test "with_database rewrites the database name and keeps the query string" {
  run with_database "postgres://user:pass@localhost:5432/olddb?sslmode=require" "restore_verify"
  [ "$status" -eq 0 ]
  [ "$output" = "postgres://user:pass@localhost:5432/restore_verify?sslmode=require" ]
}

@test "with_database accepts a postgresql scheme" {
  run with_database "postgresql://localhost/app" "other"
  [ "$status" -eq 0 ]
  [ "$output" = "postgresql://localhost/other" ]
}

@test "with_database rejects a non-postgres URL" {
  run with_database "http://localhost/olddb" "other"
  [ "$status" -eq 1 ]
}

@test "manifest_field reads key, value, and method" {
  local manifest="$BATS_TEST_TMPDIR/sample.manifest.json"
  cat >"$manifest" <<'EOF'
{
  "key": "backups/soroban-backup-20260101T020000Z.tar.gz.enc",
  "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "method": "gpg"
}
EOF
  run manifest_field key "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "backups/soroban-backup-20260101T020000Z.tar.gz.enc" ]

  run manifest_field value "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]

  run manifest_field method "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "gpg" ]
}

@test "restore.sh --help exits 0" {
  run "$REPO_ROOT/scripts/restore.sh" --help
  [ "$status" -eq 0 ]
}

@test "restore.sh rejects an unknown flag" {
  run "$REPO_ROOT/scripts/restore.sh" --not-a-flag
  [ "$status" -eq 1 ]
}
