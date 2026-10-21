#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "db-rollback.sh --help exits 0" {
  run "$REPO_ROOT/scripts/db-rollback.sh" --help
  [ "$status" -eq 0 ]
}

@test "db-rollback.sh rejects an unknown option" {
  run "$REPO_ROOT/scripts/db-rollback.sh" --not-an-option
  [ "$status" -eq 1 ]
}

@test "db-rollback.sh requires --file" {
  run env -u DATABASE_URL DATABASE_URL="postgres://localhost/app" "$REPO_ROOT/scripts/db-rollback.sh"
  [ "$status" -eq 1 ]
}

@test "db-rollback.sh requires DATABASE_URL" {
  run env -u DATABASE_URL "$REPO_ROOT/scripts/db-rollback.sh" --file "$BATS_TEST_TMPDIR/reverse.sql"
  [ "$status" -eq 1 ]
}
