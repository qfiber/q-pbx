#!/usr/bin/env bash
# Runs inside a Debian 12 container with CAP_NET_ADMIN (see ../integration_test.sh).
set -euo pipefail
apt-get -qq update >/dev/null && apt-get -qq install -y nftables netcat-openbsd >/dev/null
fail() { echo "FAIL: $*"; exit 1; }
req() { echo "$1" | nc -U -q 2 /run/fwd.sock; }
start() { /fwd/qpbx-fwd -socket /run/fwd.sock -sets mgmt_v4:ipv4,mgmt_v6:ipv6 -state /var/lib/sets.json >/tmp/fwd.log 2>&1 & sleep 0.5; }
rules() { nft list chain inet qpbx input; }

nft -f /fwd/testdata/base.nft
before=$(rules)
start

r=$(req '{"op":"replace","set":"mgmt_v4","addresses":["198.51.100.0/24","198.51.100.9","203.0.113.7"]}')
[[ $r == '{"ok":true}' ]] || fail "replace: $r"
nft list set inet qpbx mgmt_v4 | grep -q '198.51.100.0/24' || fail "prefix missing"
nft list set inet qpbx mgmt_v4 | grep -q '203.0.113.7' || fail "address missing"

r=$(req '{"op":"add","set":"mgmt_v6","address":"2001:db8::/32"}'); [[ $r == '{"ok":true}' ]] || fail "add v6: $r"
r=$(req '{"op":"remove","set":"mgmt_v4","address":"203.0.113.7"}'); [[ $r == '{"ok":true}' ]] || fail "remove: $r"
nft list set inet qpbx mgmt_v4 | grep -q '203.0.113.7' && fail "remove did not remove"

for bad in '{"op":"add","set":"mgmt_v4","address":"1.2.3.4 } ; flush ruleset ; add element inet qpbx mgmt_v4 { 1.1.1.1"}' \
           '{"op":"add","set":"input","address":"1.2.3.4"}' \
           '{"op":"flush","set":"mgmt_v4"}' \
           '{"op":"add","set":"mgmt_v4","address":"2001:db8::1"}'; do
  r=$(req "$bad"); [[ $r == '{"ok":false,'* ]] || fail "accepted: $bad -> $r"
done
[[ "$(rules)" == "$before" ]] || fail "rules changed"

# Reboot: sets emptied, helper restarts and restores the saved state.
kill %1; wait || true
nft flush ruleset && nft -f /fwd/testdata/base.nft
start
nft list set inet qpbx mgmt_v4 | grep -q '198.51.100.0/24' || fail "not restored after restart"
nft list set inet qpbx mgmt_v6 | grep -q '2001:db8::/32' || fail "v6 not restored after restart"
echo "OK: integration test passed"
