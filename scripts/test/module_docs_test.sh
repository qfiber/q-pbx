#!/usr/bin/env bash
# Tests for scripts/check_module_docs.sh, each in a throwaway git repo.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
check() { # name expected_exit actual_exit
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 (expected $2, got $3)"; fail=$((fail+1)); fi
}
repo() {
  d=$(mktemp -d); cd "$d"; git init -q -b main; git config user.email t@t; git config user.name t
  mkdir -p lib/qpbx/fax; echo d > lib/qpbx/fax/README.md; echo a > lib/qpbx/fax/fax.ex
  git add -A; git commit -qm init; git checkout -qb f
}
run() { "$root/scripts/check_module_docs.sh" main >/dev/null 2>&1; echo $?; }

repo; echo b > lib/qpbx/fax/fax.ex; git commit -qam api
check "API change without module README fails" 1 "$(run)"
echo d2 > lib/qpbx/fax/README.md; git commit -qam doc
check "API change with module README passes" 0 "$(run)"

repo; echo y > lib/qpbx/fax/inner.ex; git add -A; git commit -qm internal
check "internal change passes" 0 "$(run)"

echo "$pass passed, $fail failed"; [ $fail = 0 ]
