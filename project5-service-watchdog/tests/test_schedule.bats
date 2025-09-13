#!/usr/bin/env bats

# Load shared helpers if present (non-fatal if missing in CI)
load './fixtures/helpers' 2>/dev/null || true

@test "notify: --env dev emits JSON with required fields" {
  # Suppress stderr so jq sees pure JSON on stdout
  run bash -lc 'src/lib/notify.sh send --env dev --json 2>/dev/null'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.timestamp and .channel and .to and .from and .subject and .body and .level and .status'
}

@test "notify: direct overrides (--to/--from) work and JSON echoes inputs" {
  # Suppress stderr so jq sees pure JSON on stdout
  run bash -lc 'src/lib/notify.sh send \
    --to "someone@example.com" \
    --from "bot@example.com" \
    --subject "Test subject" \
    --body "Hello world" \
    --level "info" \
    --json 2>/dev/null'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.to=="someone@example.com" and .from=="bot@example.com" and .subject=="Test subject" and .body=="Hello world" and .level=="info"'
}

@test "notify: unknown env fails with clear message (non-zero)" {
  # Keep stderr so we can assert on the error message; bats `run` captures both
  run bash -lc 'src/lib/notify.sh send --env doesnotexist --json 2>&1'
  [ "$status" -ne 0 ]
  # Be tolerant of wording differences:
  # require it to mention 'env/ENV', the missing env name, and some form of 'not found' / 'missing'
  [[ "$output" =~ [Ee][Nn][Vv] ]] || false
  [[ "$output" =~ doesnotexist ]] || false
  [[ "$output" =~ (not[[:space:]]*found|missing|no[[:space:]]*such) ]] || false
}
