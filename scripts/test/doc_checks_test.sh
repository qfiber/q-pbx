#!/usr/bin/env bash
# Tests for the Stop hook and the module-doc CI check, each in a throwaway git repo.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
check() { # name expected_exit actual_exit
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 (expected $2, got $3)"; fail=$((fail+1)); fi
}
repo() {
  d=$(mktemp -d); cd "$d"; git init -q -b master; git config user.email t@t; git config user.name t
  mkdir -p docs lib/qpbx/fax; echo s > docs/STATUS.md; echo d > lib/qpbx/fax/CLAUDE.md
  echo a > lib/qpbx/fax/fax.ex; git add -A; git commit -qm init
}
hook() { echo '{"session_id":"s1"}' | CLAUDE_PROJECT_DIR=$PWD "$root/scripts/hooks/$1" 2>/dev/null; echo $?; }

repo; hook session_start.sh >/dev/null
check "no changes passes" 0 "$(hook require_status_update.sh)"
echo x > lib/qpbx/fax/new.ex
check "untracked code without STATUS blocks" 2 "$(hook require_status_update.sh)"
echo s2 > docs/STATUS.md
check "code with STATUS passes" 0 "$(hook require_status_update.sh)"

repo; hook session_start.sh >/dev/null
echo b > lib/qpbx/fax/fax.ex; git commit -qam code
check "committed code without STATUS blocks" 2 "$(hook require_status_update.sh)"

repo; hook session_start.sh >/dev/null
echo note >> lib/qpbx/fax/CLAUDE.md
check "docs-only change passes" 0 "$(hook require_status_update.sh)"

repo; git checkout -qb f; echo b > lib/qpbx/fax/fax.ex; git commit -qam api
"$root/scripts/check_module_docs.sh" master >/dev/null 2>&1; check "API change without module doc fails" 1 $?
echo d2 > lib/qpbx/fax/CLAUDE.md; git commit -qam doc
"$root/scripts/check_module_docs.sh" master >/dev/null 2>&1; check "API change with module doc passes" 0 $?

repo; git checkout -qb f; echo y > lib/qpbx/fax/inner.ex; git add -A; git commit -qm internal
"$root/scripts/check_module_docs.sh" master >/dev/null 2>&1; check "internal change passes" 0 $?

echo "$pass passed, $fail failed"; [ $fail = 0 ]
