#!/usr/bin/env bash
# Call tests end to end: a fresh Debian 12 systemd container, the real playbook against it
# (inventory ansible/inventories/ci, packages from out/), then the SIPp tests (run.py).
# Needs podman, ansible-core with the collections in ansible/requirements.yml, and the
# packages in out/ (app, qpbx-fwd, qpbx-sounds, qpbx-freeswitch).
# On failure the services' logs go to ci/calls/logs/. KEEP=1 leaves the container running.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
name=${QPBX_CI_CONTAINER:-qpbx-ci}
work=$(mktemp -d)
trap 'rm -rf "$work"; [[ ${KEEP:-0} == 1 ]] || podman rm -f "$name" >/dev/null 2>&1 || true' EXIT

ssh-keygen -q -t ed25519 -N "" -f "$work/key"
podman build -q -t qpbx-ci-server "$here" >/dev/null
podman rm -f "$name" >/dev/null 2>&1 || true
# Privileged and with systemd: nftables, the services' sandboxing and FreeSWITCH need it.
podman run -d --name "$name" --privileged --systemd=always -p 127.0.0.1:2222:22 qpbx-ci-server >/dev/null
for _ in $(seq 30); do podman exec "$name" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 1; done
podman cp "$work/key.pub" "$name:/home/debian/.ssh/authorized_keys"
podman exec "$name" bash -c "chown debian: /home/debian/.ssh/authorized_keys && chmod 600 /home/debian/.ssh/authorized_keys"

ssh_opts=(-p 2222 -i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
status=0
(cd "$root/ansible" && QPBX_CI_KEY="$work/key" ANSIBLE_DEPRECATION_WARNINGS=False ansible-playbook -i inventories/ci site.yml) || status=$?
if [[ $status == 0 ]]; then
  python3 "$here/run.py" debian@127.0.0.1 "${ssh_opts[@]}" || status=$?
fi
if [[ $status != 0 ]]; then
  mkdir -p "$here/logs"
  for unit in qpbx kamailio freeswitch nginx postgresql@16-main qpbx-fwd; do
    podman exec "$name" journalctl -u "$unit" --no-pager > "$here/logs/$unit.log" 2>&1 || true
  done
  echo "Logs in ci/calls/logs/"
fi
exit $status
