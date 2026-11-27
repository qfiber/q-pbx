#!/usr/bin/env bash
# Claude Code SessionStart hook: remember the commit the session started from,
# so the Stop hook can see every change made during the session.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
id=$(jq -r '.session_id // "unknown"')
mkdir -p .claude/state
git rev-parse --verify -q HEAD > ".claude/state/$id.base" || echo EMPTY > ".claude/state/$id.base"
