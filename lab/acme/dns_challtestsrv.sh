#!/usr/bin/env sh
# Lab-only acme.sh DNS plugin: sets DNS-01 TXT records on Pebble's challtestsrv
# (CHALLTESTSRV_URL, e.g. http://192.168.10.236:8055). Never used in production.

dns_challtestsrv_add() {
  _post "{\"host\":\"$1.\",\"value\":\"$2\"}" "${CHALLTESTSRV_URL}/set-txt" >/dev/null
}

dns_challtestsrv_rm() {
  _post "{\"host\":\"$1.\"}" "${CHALLTESTSRV_URL}/clear-txt" >/dev/null
}
