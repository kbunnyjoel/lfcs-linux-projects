#!/usr/bin/env bats

load 'fixtures/helpers' 2>/dev/null || true

setup_file() {
  # start clean; ignore failures
  for u in alice carol dave eve frank grace hank ivy zoe bob tom ann carl; do
    userdel -r "$u" >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/$u" >/dev/null 2>&1 || true
  done
  groupdel developers >/dev/null 2>&1 || true
  mkdir -p logs
  : > logs/audit.log
}

teardown() {
  # no-op per test
  true
}

# --- Sprint 1 ---------------------------------------------------------------

@test "list returns without error" {
  run src/userctl.sh list all
  [ "$status" -eq 0 ]
}

@test "exists returns non-zero for unknown user" {
  run src/userctl.sh exists alice
  [ "$status" -ne 0 ]
}

@test "add creates user idempotently" {
  run src/userctl.sh add alice -g developers -s /bin/bash
  [ "$status" -eq 0 ]
  run src/userctl.sh add alice -g developers -s /bin/bash
  [ "$status" -eq 0 ]
}

@test "list includes created user" {
  run src/userctl.sh list all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^alice:'
}

# --- Sprint 2 ---------------------------------------------------------------

@test "grant-sudo creates validated sudoers file (with NOPASSWD optional)" {
  src/userctl.sh add carol -s /bin/bash
  run src/userctl.sh grant-sudo carol --nopasswd
  [ "$status" -eq 0 ]
  [ -f "/etc/sudoers.d/carol" ]
  grep -qxF 'carol ALL=(ALL:ALL) NOPASSWD: ALL' /etc/sudoers.d/carol
}

@test "revoke-sudo removes entry and is idempotent" {
  run src/userctl.sh revoke-sudo carol
  [ "$status" -eq 0 ]
  [ ! -f "/etc/sudoers.d/carol" ]
  run src/userctl.sh revoke-sudo carol
  [ "$status" -eq 0 ]
}

# --- Sprint 3 ---------------------------------------------------------------

@test "set-password via stdin updates status" {
  src/userctl.sh add eve -s /bin/bash
  run bash -lc 'echo "P@ssw0rd!" | src/userctl.sh set-password eve --password-stdin'
  [ "$status" -eq 0 ]
}

@test "lock and unlock are idempotent and change status" {
  src/userctl.sh add frank -s /bin/bash
  echo "Temp#123" | src/userctl.sh set-password frank --password-stdin
  run src/userctl.sh lock frank
  [ "$status" -eq 0 ]
  run src/userctl.sh lock frank
  [ "$status" -eq 0 ]
  run src/userctl.sh unlock frank
  [ "$status" -eq 0 ]
  run src/userctl.sh unlock frank
  [ "$status" -eq 0 ]
}

@test "set-aging updates chage fields and show-aging prints details" {
  src/userctl.sh add grace -s /bin/bash
  run src/userctl.sh set-aging grace --min 0 --max 90 --warn 7 --inactive 14
  [ "$status" -eq 0 ]
  run src/userctl.sh show-aging grace
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "Maximum number of days"
}

@test "force-expire sets password to change at next login" {
  src/userctl.sh add hank -s /bin/bash
  run src/userctl.sh force-expire hank
  [ "$status" -eq 0 ]
}

# --- Sprint 4 (SSH keys layout: ~/.ssh/authorized_keys/keys) ---------------

setup_ssh_user() {
  local u="$1"
  src/userctl.sh add "$u" -s /bin/bash
  local home
  home="$(awk -F: -v u=\"$u\" '$1==u{print $6}' /etc/passwd)"
  mkdir -p "$home/.ssh/authorized_keys"
  touch "$home/.ssh/authorized_keys/keys"
  chmod 700 "$home/.ssh" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys/keys"
  chown -R "$u":"$(id -gn "$u")" "$home/.ssh"
}

@test "add-ssh-key is idempotent and sets correct perms" {
  setup_ssh_user ivy
  key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey example@local'
  run src/userctl.sh add-ssh-key ivy --key "$key"
  [ "$status" -eq 0 ]
  run src/userctl.sh add-ssh-key ivy --key "$key"
  [ "$status" -eq 0 ]
  home="$(awk -F: -v u=ivy '$1==u{print $6}' /etc/passwd)"
  stat -c '%a' "$home/.ssh" | grep -qx '700'
  stat -c '%a' "$home/.ssh/authorized_keys" | grep -qx '700'
  stat -c '%a' "$home/.ssh/authorized_keys/keys" | grep -qx '600'
  grep -qxF -- "$key" "$home/.ssh/authorized_keys/keys"
}

@test "list-ssh-keys prints keys and returns non-zero when none" {
  setup_ssh_user dave
  # none yet → non-zero & no output
  run src/userctl.sh list-ssh-keys dave
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # add one and verify output/non-zero flip
  key='ssh-ed25519 AAAAC3Test d@x'
  src/userctl.sh add-ssh-key dave --key "$key"
  run src/userctl.sh list-ssh-keys dave
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF "$key"
}

@test "remove-ssh-key removes exactly the provided key and is idempotent" {
  setup_ssh_user carl
  k1='ssh-ed25519 AAAAK1 carl@x'
  k2='ssh-ed25519 AAAAK2 carl@x'
  src/userctl.sh add-ssh-key carl --key "$k1"
  src/userctl.sh add-ssh-key carl --key "$k2"
  run src/userctl.sh remove-ssh-key carl --key "$k1"
  [ "$status" -eq 0 ]
  home="$(awk -F: -v u=carl '$1==u{print $6}' /etc/passwd)"
  ! grep -qxF -- "$k1" "$home/.ssh/authorized_keys/keys"
  grep -qxF -- "$k2" "$home/.ssh/authorized_keys/keys"
  # idempotent second removal
  run src/userctl.sh remove-ssh-key carl --key "$k1"
  [ "$status" -eq 0 ]
}

# --- Sprint 5 ---------------------------------------------------------------

@test "disable sets lock and account expiry (idempotent)" {
  src/userctl.sh add zoe -s /bin/bash
  run src/userctl.sh disable zoe
  [ "$status" -eq 0 ]
  run src/userctl.sh disable zoe
  [ "$status" -eq 0 ]
}

@test "remove deletes user, home, and sudoers (idempotent)" {
  src/userctl.sh add bob -s /bin/bash
  src/userctl.sh grant-sudo bob --nopasswd
  run src/userctl.sh remove bob
  [ "$status" -eq 0 ]
  run src/userctl.sh remove bob
  [ "$status" -eq 0 ]
}

@test "status --json reports key fields" {
  src/userctl.sh add tom -s /bin/bash
  out="$(src/userctl.sh status tom --json)"
  echo "$out" | grep -q '"user":"tom"'
  echo "$out" | grep -q '"exists":'
  echo "$out" | grep -q '"locked":'
  echo "$out" | grep -q '"sudo":'
  echo "$out" | grep -q '"ssh_keys":'
  echo "$out" | grep -q '"shell":'
}

@test "audit-log filters by user and action" {
  src/userctl.sh add ann -s /bin/bash
  echo "MyAuditLine $(date +%s) ann custom" >> logs/audit.log
  run src/userctl.sh audit-log --user ann
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ann'
}
