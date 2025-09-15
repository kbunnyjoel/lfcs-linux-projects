#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "selinux (sestatus fallback): enforcing -> up" {
  run bash -lc 'unset SEC_GETENFORCE; SELINUXMODE=enforcing SEC_SESTATUS=tests/helpers/sestatus ./src/sec.sh check --json --selinux enforcing | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "selinux (sestatus fallback): permissive vs enforcing -> degraded" {
  run bash -lc 'unset SEC_GETENFORCE; SELINUXMODE=permissive SEC_SESTATUS=tests/helpers/sestatus ./src/sec.sh check --json --selinux enforcing | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "selinux (sestatus fallback): disabled when enforcing required -> degraded" {
  run bash -lc 'unset SEC_GETENFORCE; SELINUXMODE=disabled SEC_SESTATUS=tests/helpers/sestatus ./src/sec.sh check --json --selinux enforcing | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

