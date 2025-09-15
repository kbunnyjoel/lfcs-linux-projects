#!/usr/bin/env bats

setup() {
  chmod +x tests/helpers/getfacl
}

@test "acl: expectations met -> up" {
  run bash -lc 'ACLMODE=ok FS_GETFACL_CMD=tests/helpers/getfacl \
                FS_ACL_EXPECT="/tmp:user:app:rwx,default:user:backup:r-x" \
                ./src/fs.sh check --path /tmp --json | head -n1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "acl: missing expected entry -> non-up" {
  run bash -lc 'ACLMODE=missing FS_GETFACL_CMD=tests/helpers/getfacl \
                FS_ACL_EXPECT="/tmp:user:app:rwx,default:user:backup:r-x" \
                ./src/fs.sh check --path /tmp --json | tail -n1 | jq -r .overall'
  [[ "$output" != "up" ]]
}
