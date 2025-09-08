#!/usr/bin/env bats
# Sprint 1 tests for Project 4: Backup & Restore Orchestrator
# Focus: full backups (tar|dir), excludes, JSON summary, env loading, failure modes

load 'fixtures/helpers'

setup() {
  # Derive project root relative to this test file
  project_root="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  scripts_dir="${project_root}/src"
  outputs_dir="${project_root}/outputs"
  logs_dir="${project_root}/logs"
  mkdir -p "${outputs_dir}" "${logs_dir}"

  # Fresh sandbox per test
  : "${BATS_TEST_TMPDIR:=/tmp}"
  SANDBOX="${BATS_TEST_TMPDIR}/p4tests.$$.${BATS_TEST_NAME// /_}"
  SRC_BASE="${SANDBOX}/src"
  DST_BASE="${SANDBOX}/dst"
  mkdir -p "${SRC_BASE}/nested" "${DST_BASE}"

  # Create sample files
  printf '%s\n' "alpha" >"${SRC_BASE}/a.txt"
  printf '%s\n' "beta"  >"${SRC_BASE}/nested/c.txt"
  printf '%s\n' "temp"  >"${SRC_BASE}/b.tmp"

  # Ensure env dir exists for env-loading test
  mkdir -p "${project_root}/env"
}

teardown() {
  rm -rf -- "${SANDBOX}"
}

# Helper: extract backup id from mixed stdout (logs + JSON)
get_backup_id_from_stdout() {
  local out json
  out="$1"
  # Keep everything starting from the first line that begins with a '{'
  json="$(printf '%s\n' "$out" | sed -n '/^{/,$p')"
  printf '%s\n' "$json" | jq -r '.id'
}

@test "full tar.gz backup creates artifact, manifest, json and audit" {
  run bash -lc "'${scripts_dir}/backup.sh' full \
    --source '${SRC_BASE}' \
    --dest '${DST_BASE}' \
    --format tar \
    --compress gz \
    --label t1 \
    --exclude '*.tmp' \
    --json"
  [ "$status" -eq 0 ]

  id="$(get_backup_id_from_stdout "$output")"
  [ -n "$id" ]

  run bash -lc "test -f '${DST_BASE}/${id}.tar.gz'"
  [ "$status" -eq 0 ]

  run bash -lc "test -f '${outputs_dir}/${id}/manifest.txt' && test -f '${outputs_dir}/${id}/summary.json'"
  [ "$status" -eq 0 ]

  run bash -lc "grep -F 'b.tmp' '${outputs_dir}/${id}/manifest.txt' || true"
  [ -z "$output" ]

  # audit contains the id
  run bash -lc "grep -F '${id}' '${logs_dir}/audit.log'"
  [ "$status" -eq 0 ]
}

@test "full dir (snapshot) backup mirrors files and writes manifest" {
  run bash -lc "'${scripts_dir}/backup.sh' full \
    --source '${SRC_BASE}' \
    --dest '${DST_BASE}' \
    --format dir \
    --exclude '*.tmp' \
    --json"
  [ "$status" -eq 0 ]
  id="$(get_backup_id_from_stdout "$output")"
  [ -n "$id" ]

  run bash -lc "test -d '${DST_BASE}/${id}'"
  [ "$status" -eq 0 ]

  run bash -lc "test -f '${DST_BASE}/${id}/a.txt' && test -f '${DST_BASE}/${id}/nested/c.txt' && test ! -f '${DST_BASE}/${id}/b.tmp'"
  [ "$status" -eq 0 ]

  run bash -lc "grep -F 'a.txt' '${outputs_dir}/${id}/manifest.txt'"
  [ "$status" -eq 0 ]
}

@test "--json prints valid summary with key fields" {
  # Use sandbox prepared by setup(): SRC_BASE and DST_BASE
  run bash -lc "'${scripts_dir}/backup.sh' full --source '${SRC_BASE}' --dest '${DST_BASE}' --format tar --compress gz --json"
  echo "OUTPUT: $output"
  [ "$status" -eq 0 ]

  # Validate JSON structure using jq; strip any leading log lines
  run bash -lc 'json="$1"; printf "%s" "$json" | sed -n "/^{/,\$p" | jq -e ".id and .mode and .artifact and (.files|type==\"number\") and (.bytes|type==\"number\")"' _ "$output"
  echo "JQ STATUS: $status, JQ OUTPUT: $output"
  [ "$status" -eq 0 ]
}

@test "env loading via --env works" {
  ENV_NAME="ci"
  cat > "${project_root}/env/${ENV_NAME}" <<EOF
BACKUP_SRC='${SRC_BASE}'
BACKUP_DEST='${DST_BASE}'
EOF
  run bash -lc "'${scripts_dir}/backup.sh' full --env '${ENV_NAME}' --format tar --json"
  [ "$status" -eq 0 ]
  id="$(get_backup_id_from_stdout "$output")"
  [ -n "$id" ]
  run bash -lc "test -f '${outputs_dir}/${id}/summary.json'"
  [ "$status" -eq 0 ]
}

@test "non-existent source fails with non-zero" {
  run bash -lc "'${scripts_dir}/backup.sh' full --source '${SANDBOX}/no-such' --dest '${DST_BASE}' --format tar"
  [ "$status" -ne 0 ]
}
