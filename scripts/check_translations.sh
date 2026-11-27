#!/usr/bin/env bash
# Fails when a translation file has fuzzy entries (gettext guessed a translation from a
# similar text, often wrong) or, for languages other than English, untranslated texts.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
for po in priv/gettext*/*/LC_MESSAGES/*.po; do
  if grep -q '^#,.*fuzzy' "$po"; then
    echo "::error file=$po::fuzzy entries: check and fix the translation, then remove the fuzzy flag"; fail=1
  fi
  case $po in */en/*) continue ;; esac
  # An empty msgstr right after a non-empty msgid (the header entry has an empty msgid).
  missing=$(awk '/^msgid "/ {id=$0} /^msgstr ""$/ && id != "msgid \"\"" {n++} END {print n+0}' "$po")
  if [ "$missing" -gt 0 ]; then echo "::error file=$po::$missing untranslated texts"; fail=1; fi
done
[ $fail = 0 ] && echo "OK: translations complete"
exit $fail
