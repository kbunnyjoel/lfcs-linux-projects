#!/usr/bin/env bats

setup() { cd "$BATS_TEST_DIRNAME/.." >/dev/null; chmod +x tests/helpers/* || true; }

@test "firewall fallback (nft): on -> up" {
  run bash -lc 'unset SEC_FIREWALLCTL; NFTMODE=on SEC_NFT=tests/helpers/nft ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "firewall fallback (nft): off -> non-up" {
  run bash -lc 'unset SEC_FIREWALLCTL; NFTMODE=off SEC_NFT=tests/helpers/nft ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

@test "firewall fallback (iptables-save): rules present -> up" {
  run bash -lc 'unset SEC_FIREWALLCTL; IPTMODE=on SEC_IPTABLESSAVE=tests/helpers/iptables-save ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [ "$status" -eq 0 ]
  [ "$output" = "up" ]
}

@test "firewall fallback (iptables-save): no rules -> non-up" {
  run bash -lc 'unset SEC_FIREWALLCTL; IPTMODE=off SEC_IPTABLESSAVE=tests/helpers/iptables-save ./src/sec.sh check --json --firewall required | tail -n 1 | jq -r .overall'
  [[ "$output" != "up" ]]
}

