#!/usr/bin/env bash
# Proves the boundary check fails the build: compiles once with a forbidden
# reference (core -> web) and expects failure, then once clean and expects success.
set -u
cd "$(dirname "$0")/.."
probe=lib/qpbx/core/zz_boundary_probe.ex
trap 'rm -f "$probe"' EXIT
cat > "$probe" <<'PROBE'
defmodule QPBX.Core.ZzBoundaryProbe do
  @moduledoc false
  def x, do: QPBX.Web.Endpoint.url()
end
PROBE
if mix compile --force --warnings-as-errors >/dev/null 2>&1; then
  echo "FAIL: forbidden cross-boundary reference compiled"; exit 1
fi
rm -f "$probe"
mix compile --force --warnings-as-errors >/dev/null 2>&1 || { echo "FAIL: clean tree does not compile"; exit 1; }
echo "OK: boundary violations fail the build"
