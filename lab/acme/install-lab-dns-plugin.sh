#!/usr/bin/env bash
# Copies the lab-only DNS plugin into acme.sh on the lab VM (for testing wildcard mode with Pebble).
set -euo pipefail
ip=${1:?usage: $0 <lab-vm-ip>}
key=~/.local/share/qpbx-lab/id_ed25519
ssh_opts=(-o IdentitiesOnly=yes -i "$key" -o UserKnownHostsFile=~/.local/share/qpbx-lab/known_hosts)
scp -q "${ssh_opts[@]}" "$(dirname "$0")/dns_challtestsrv.sh" "debian@$ip:/tmp/"
ssh "${ssh_opts[@]}" "debian@$ip" 'sudo install -m 0644 /tmp/dns_challtestsrv.sh /opt/acme.sh/dnsapi/'
