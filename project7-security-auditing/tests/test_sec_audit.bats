#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "audit: report missing_rules when none loaded" {
  run bash -lc 'AUDITMODE=empty SEC_AUDITCTL=tests/helpers/auditctl ./src/sec.sh check --json --audit rules tests/fixtures/audit.rules.sample | jq -c "select(.component==\"audit\") | [.rules_required, (.missing_rules | length), (.missing_rules | type)]"'
  [ "$status" -eq 0 ]
  IFS="," read -r req count type <<<"$(echo "$output" | tr -d '[]"')"
  [ "$req" -eq 2 ]
  [ "$count" -eq 2 ]
  [ "$type" = "array" ]
}

@test "audit: missing_rules empty when all present" {
  run bash -lc 'AUDITMODE=ok SEC_AUDITCTL=tests/helpers/auditctl ./src/sec.sh check --json --audit rules tests/fixtures/audit.rules.sample | jq -r "select(.component==\"audit\") | .missing_rules | length"'
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "audit: tolerate comments and whitespace in required file" {
  run bash -lc '
    RF=$(mktemp); \
    printf "# comment\n   -w   /etc/passwd   -p   wa   -k  identity\n -w /etc/shadow -p wa -k identity   \n" > "$RF"; \
    AUDITMODE=ok SEC_AUDITCTL=tests/helpers/auditctl ./src/sec.sh check --json --audit rules "$RF" | jq -r "select(.component==\"audit\") | .missing_rules | length"'
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}
