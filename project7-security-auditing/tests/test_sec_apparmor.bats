#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "apparmor: required and enabled -> up" {
  run bash -lc 'AAMODE=on SEC_AASTATUS=tests/helpers/aa-status ./src/sec.sh check --json --apparmor required | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "apparmor: required but disabled -> non-up" {
  run bash -lc 'AAMODE=off SEC_AASTATUS=tests/helpers/aa-status ./src/sec.sh check --json --apparmor required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

