#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "aide: required and ok -> up, counts zero" {
  run bash -lc 'AIDEMODE=ok SEC_AIDE=tests/helpers/aide ./src/sec.sh check --json --aide required | jq -r "select(.component==\"aide\") | [.added, .changed, .removed] | @tsv"'
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r add chg rem <<<"$output"
  [ "$add" = "0" ]
  [ "$chg" = "0" ]
  [ "$rem" = "0" ]
  run bash -lc 'AIDEMODE=ok SEC_AIDE=tests/helpers/aide ./src/sec.sh check --json --aide required | tail -n 1 | jq -r .overall'
  [ "$output" = "up" ]
}

@test "aide: required and changes -> non-up with counts" {
  run bash -lc 'AIDEMODE=changed SEC_AIDE=tests/helpers/aide ./src/sec.sh check --json --aide required | jq -r "select(.component==\"aide\") | [.added, .changed, .removed] | @tsv"'
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r add chg rem <<<"$output"
  [ "$add" = "2" ]
  [ "$chg" = "3" ]
  [ "$rem" = "1" ]
  run bash -lc 'AIDEMODE=changed SEC_AIDE=tests/helpers/aide ./src/sec.sh check --json --aide required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "aide: required but binary missing -> non-up" {
  run bash -lc 'unset SEC_AIDE; PATH=/nonexistent:$PATH ./src/sec.sh check --json --aide required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

