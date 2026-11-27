#!/usr/bin/env bash
# Integration test of qpbx-fwd against real nftables in a Debian 12 container.
# Needs podman or docker. The container gets CAP_NET_ADMIN in its own network namespace only.
set -euo pipefail
cd "$(dirname "$0")"
CGO_ENABLED=0 go build -o qpbx-fwd .
trap 'rm -f qpbx-fwd' EXIT
engine=$(command -v podman || command -v docker)
"$engine" run --rm --cap-add NET_ADMIN -v "$PWD:/fwd:ro,Z" docker.io/library/debian:12 bash /fwd/testdata/integration.sh
