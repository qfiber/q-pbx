#!/usr/bin/env bash
# Builds the app and qpbx-fwd .deb packages in the Debian 12 Elixir image; output in ./out/.
# Sources are copied to a temp dir first, so SELinux relabeling (:Z) never touches the repo.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${OUT_DIR:-$root/out}
image=${ELIXIR_IMAGE:-docker.io/hexpm/elixir:1.18.4-erlang-28.4.1-debian-bookworm-20260610}
mkdir -p "$out"
src=$(mktemp -d) && dst=$(mktemp -d)
trap 'rm -rf "$src" "$dst"' EXIT
excludes=(--exclude _build --exclude deps --exclude out --exclude .git --exclude priv/plts --exclude .ansible)
# Also skip whatever this checkout excludes locally (editor and tool folders).
[[ -f $root/.git/info/exclude ]] && excludes+=(--exclude-from "$root/.git/info/exclude")
rsync -a "${excludes[@]}" "$root/" "$src/"
engine=$(command -v podman || command -v docker)
"$engine" run --rm -v "$src:/src:ro,Z" -v "$dst:/out:Z" "$image" bash /src/packaging/app/build.sh
cp "$dst"/*.deb "$out/"
