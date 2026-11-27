#!/usr/bin/env bash
# Claude Code Stop hook: block finishing when code changed during the session
# but docs/STATUS.md did not. Exit 2 blocks the stop and shows stderr to Claude.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
id=$(jq -r '.session_id // "unknown"')
base=$(cat ".claude/state/$id.base" 2>/dev/null || git rev-parse --verify -q HEAD || echo EMPTY)
# The empty tree stands in for "before the first commit".
[ "$base" = EMPTY ] && base=$(git hash-object -t tree /dev/null)
changed=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
# Code is any changed file that is not Markdown, not under docs/, and not this hook's own state.
code=$(grep -v -E '(\.md$|^docs/|^\.claude/state/)' <<<"$changed" || true)
if [ -n "$code" ] && ! grep -qx 'docs/STATUS.md' <<<"$changed"; then
  echo "Code changed this session but docs/STATUS.md was not updated. Update it (done, in progress, next, blockers) before finishing." >&2
  exit 2
fi
exit 0
