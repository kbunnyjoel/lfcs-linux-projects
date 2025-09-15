#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "sec: baseline summary up with no requirements" {
  run bash -lc "./src/sec.sh check --json | tail -n 1 | jq -r .overall"
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "firewall: required on -> up, off -> non-up" {
  run bash -lc 'FIREWALLMODE=on SEC_FIREWALLCTL=tests/helpers/firewallctl ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]

  run bash -lc 'FIREWALLMODE=off SEC_FIREWALLCTL=tests/helpers/firewallctl ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "selinux: require enforcing -> pass, permissive -> fail" {
  run bash -lc 'SELINUXMODE=enforcing SEC_GETENFORCE=tests/helpers/getenforce ./src/sec.sh check --json --selinux enforcing | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]

  run bash -lc 'SELINUXMODE=permissive SEC_GETENFORCE=tests/helpers/getenforce ./src/sec.sh check --json --selinux enforcing | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "audit: require rules file -> ok when loaded" {
  run bash -lc 'AUDITMODE=ok SEC_AUDITCTL=tests/helpers/auditctl ./src/sec.sh check --json --audit rules tests/fixtures/audit.rules.sample | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "audit: missing rules -> non-up" {
  run bash -lc 'AUDITMODE=empty SEC_AUDITCTL=tests/helpers/auditctl ./src/sec.sh check --json --audit rules tests/fixtures/audit.rules.sample | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "auth: max failed limit enforced" {
  run bash -lc 'AUTHMODE=1 SEC_LASTB=tests/helpers/lastb ./src/sec.sh check --json --auth max-failed 2 | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]

  run bash -lc 'AUTHMODE=3 SEC_LASTB=tests/helpers/lastb ./src/sec.sh check --json --auth max-failed 2 | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

