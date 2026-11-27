#!/usr/bin/env bash
# CI check: a change to an area's public API module (lib/qpbx/<area>/<area>.ex)
# must come with a change to that area's lib/qpbx/<area>/README.md.
# Usage: scripts/check_module_docs.sh <base-ref>
set -euo pipefail
base=${1:?usage: $0 <base-ref>}
changed=$(git diff --name-only "$base"...HEAD)
fail=0
for api in $(grep -E '^lib/qpbx/([a-z_]+)/\1\.ex$' <<<"$changed" || true); do
  doc="$(dirname "$api")/README.md"
  if ! grep -qx "$doc" <<<"$changed"; then
    echo "::error file=$api::public API changed without an update to $doc"
    fail=1
  fi
done
exit $fail
