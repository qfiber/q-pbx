#!/usr/bin/env python3
"""Phase 3 done-when: runs every phase 3 lab check against the lab server and prints the
spec's four conditions with the checks behind each.

  1. every resource so far is manageable through the API
  2. call.* webhooks arrive signed within 1 second
  3. a tenant crossing 80% of its minutes gets the email and the alert webhook with minutes remaining
  4. a webhook aimed at an internal address is refused

usage: phase3.py <vm-ip> <receiver-vm-ip>   (about 20 minutes)
"""
import os, re, subprocess, sys, time

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

CHECKS = [
    # name, command, done-when conditions it proves
    ("api", ["python3", f"{HERE}/phase3-api.py", VM], [1]),
    ("webhooks", ["python3", f"{HERE}/phase3-webhooks.py", VM, RX], [2]),
    ("usage", ["python3", f"{HERE}/phase3-usage.py", VM, RX], [3]),
    ("outbound", ["python3", f"{HERE}/phase3-outbound.py", VM, RX], [4]),
    ("alerts", ["python3", f"{HERE}/phase3-alerts.py", VM, RX], [4]),
    # The rest of phase 3, run with it so the whole phase is verified at once.
    ("explorer", ["node", f"{HERE}/phase3-explorer.mjs", VM], []),
    ("events", ["python3", f"{HERE}/phase3-events.py", VM], []),
    ("stream", ["node", f"{HERE}/phase3-stream.mjs", VM], []),
    ("click", ["python3", f"{HERE}/phase3-click.py", VM], []),
    ("sources", ["python3", f"{HERE}/phase3-sources.py", VM], []),
    ("sipp", ["python3", f"{ROOT}/ci/calls/run.py", f"debian@{VM}", "-i", f"{LAB}/id_ed25519",
              "-o", f"UserKnownHostsFile={LAB}/known_hosts"], []),
]

CONDITIONS = {
    1: "Every resource so far is manageable through the API",
    2: "call.* webhooks arrive signed within 1 second",
    3: "A tenant crossing 80% of its minutes gets the email and the alert webhook with minutes remaining",
    4: "A webhook aimed at an internal address is refused",
}

results = {}
for name, cmd, _ in CHECKS:
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    out = p.stdout + p.stderr
    open(f"{LAB}/work/phase3-{name}.log", "w").write(out)
    m = re.search(r"(\d+) passed, (\d+) failed", out)
    passed, failed = (int(m.group(1)), int(m.group(2))) if m else (0, 1)
    latency = re.search(r"Webhook delivery time.*", out)
    results[name] = {"ok": p.returncode == 0 and failed == 0, "passed": passed, "failed": failed,
                     "secs": time.time() - t0, "note": latency.group(0) if latency else None}
    r = results[name]
    print(f"{'PASS' if r['ok'] else 'FAIL'}  {name}: {passed} passed, {failed} failed ({r['secs'] / 60:.1f} min)", flush=True)

print("\nPhase 3 done-when:")
all_ok = True
for n, text in CONDITIONS.items():
    names = [c[0] for c in CHECKS if n in c[2]]
    ok = all(results[x]["ok"] for x in names) and names
    all_ok = all_ok and bool(ok)
    counts = ", ".join(f"{x} {results[x]['passed']}/{results[x]['passed'] + results[x]['failed']}" for x in names)
    print(f"  {'MET    ' if ok else 'NOT MET'}  {n}. {text}  ({counts})")
    for x in names:
        if results[x]["note"]:
            print(f"           {results[x]['note']}")
others_ok = all(r["ok"] for r in results.values())
print(f"\nEvery check: {'all pass' if others_ok else 'some failed (logs in ~/.local/share/qpbx-lab/work/phase3-*.log)'}")
sys.exit(0 if all_ok and others_ok else 1)
