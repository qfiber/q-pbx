#!/usr/bin/env bash
# Runs a local test ACME server (Pebble) and its DNS server (challtestsrv) on this machine, so
# both certificate modes can be tested for real in the lab. Every name resolves to the lab VM.
#   lab/acme/pebble.sh <lab-vm-ip>     start      lab/acme/pebble.sh stop
set -euo pipefail
engine=$(command -v podman || command -v docker)
if [[ ${1:-} == stop ]]; then "$engine" rm -f qpbx-pebble qpbx-challtestsrv >/dev/null 2>&1; "$engine" network rm qpbx-acme >/dev/null 2>&1 || true; exit 0; fi
vm=${1:?usage: $0 <lab-vm-ip>}
"$engine" network exists qpbx-acme || "$engine" network create qpbx-acme >/dev/null
"$engine" rm -f qpbx-pebble qpbx-challtestsrv >/dev/null 2>&1 || true
"$engine" run -d --name qpbx-challtestsrv --network qpbx-acme -p 8055:8055 \
  ghcr.io/letsencrypt/pebble-challtestsrv:latest -defaultIPv4 "$vm" -defaultIPv6 "" -management :8055 -dnsserver :8053 -http01 "" -https01 "" -tlsalpn01 "" >/dev/null
# Pebble gets the DNS server by IP: container-name DNS is not available on every podman setup.
dns_ip=$("$engine" inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qpbx-challtestsrv)
cfg=$(mktemp -d)
cat > "$cfg/pebble.json" <<JSON
{"pebble": {"listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
  "certificate": "test/certs/localhost/cert.pem", "privateKey": "test/certs/localhost/key.pem",
  "httpPort": 80, "tlsPort": 443, "ocspResponderURL": "", "externalAccountBindingRequired": false}}
JSON
"$engine" run -d --name qpbx-pebble --network qpbx-acme -p 14000:14000 -e PEBBLE_VA_NOSLEEP=1 \
  -v "$cfg:/cfg:ro,Z" ghcr.io/letsencrypt/pebble:latest -config /cfg/pebble.json -dnsserver "$dns_ip:8053" >/dev/null
sleep 2
echo "ACME directory: https://$(hostname -I | awk '{print $1}'):14000/dir   challtestsrv: http://<this host>:8055"
