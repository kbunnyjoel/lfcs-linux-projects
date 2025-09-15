#!/usr/bin/env bats

setup() {
  chmod +x tests/helpers/repquota
}

@test "quota: present & under limit -> up" {
  run bash -o pipefail -lc 'REPMODE=ok FS_QUOTA_REQUIRED=1 FS_REPQUOTA_CMD=tests/helpers/repquota \
                ./src/fs.sh check --path /tmp --json | jq -r '\''select(.summary!=true) | .overall'\'''
  echo "DBG status=$status output=$output"
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "quota: present but exceeded -> down" {
  run bash -o pipefail -lc 'REPMODE=exceeded FS_QUOTA_REQUIRED=1 FS_REPQUOTA_CMD=tests/helpers/repquota \
                ./src/fs.sh check --path /tmp --json | jq -r '\''select(.summary!=true) | .overall'\'''
  echo "DBG status=$status output=$output"
  [ "$status" -eq 1 ]
  [ "$output" = "down" ]
}

@test "quota: required but ambiguous/empty -> non-up" {
  run bash -o pipefail -lc 'REPMODE=empty FS_QUOTA_REQUIRED=1 FS_REPQUOTA_CMD=tests/helpers/repquota \
                ./src/fs.sh check --path /tmp --json | jq -r '\''select(.summary==true) | .overall'\'''
  echo "DBG status=$status output=$output"
  [[ "$output" != "up" ]]
}
