#!/usr/bin/env bash
# Builds the FreeSWITCH .deb in a clean Debian 12 container; the package lands in ./out/.
# Sources are copied to a temp dir first, so SELinux relabeling (:Z) never touches the repo.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT_DIR:-$here/../../out}
mkdir -p "$out"
src=$(mktemp -d) && dst=$(mktemp -d)
trap 'rm -rf "$src" "$dst"' EXIT
cp -a "$here/." "$src/"
engine=$(command -v podman || command -v docker)
"$engine" run --rm -v "$src:/src:ro,Z" -v "$dst:/out:Z" -e FS_VERSION -e SOFIA_VERSION -e SPANDSP_REF \
  docker.io/library/debian:12 bash /src/build.sh
cp "$dst"/*.deb "$out/"
