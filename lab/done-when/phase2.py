#!/usr/bin/env python3
"""Phase 2 done-when: runs every phase 2 lab check against the lab server and prints the
spec's five conditions with the checks behind each.

  1. two tenants with the same extension numbers call internally and externally, no crossover
  2. changes apply without a reload
  3. a simulated fraud burst is blocked automatically
  4. busy lamps and voicemail lights work
  5. the restore succeeds within a measured time

usage: phase2.py <vm-ip> <host-ip>
  MEOW_TEST=/path/to/baresip_engine_live MEOW_HOME=<scratch folder> adds the Meow client's live
  test (busy lamps and the voicemail light on a real softphone), run with that scratch home.
"""
import os, re, subprocess, sys, time

VM, HOST = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

CHECKS = [
    # name, command, done-when conditions it proves
    ("tenants", ["python3", f"{HERE}/phase2-tenants.py", VM], [1, 2]),
    ("sipp", ["python3", f"{ROOT}/ci/calls/run.py", f"debian@{VM}", "-i", f"{LAB}/id_ed25519",
              "-o", f"UserKnownHostsFile={LAB}/known_hosts"], [1]),
    ("admission", ["python3", f"{HERE}/phase2-admission.py", VM], [3]),
    ("calls", ["python3", f"{HERE}/phase2-calls.py", VM], [4]),
    ("voicemail", ["python3", f"{HERE}/phase2-voicemail.py", VM], [4]),
    ("restore", ["python3", f"{HERE}/phase2-restore.py", VM], [5]),
    # The rest of phase 2, run with it so the whole phase is verified at once.
    ("config", ["node", f"{HERE}/phase2-config.mjs", VM], []),
    ("edge", ["python3", f"{HERE}/phase2-edge.py", VM, HOST], []),
    ("protect", ["python3", f"{HERE}/phase2-protect.py", VM], []),
    ("cdrs", ["python3", f"{HERE}/phase2-cdrs.py", VM], []),
]
if os.environ.get("MEOW_TEST"):
    CHECKS.append(("meow", [os.environ["MEOW_TEST"]], [4]))

CONDITIONS = {
    1: "Two tenants with the same extension numbers, internal and external calls, no crossover",
    2: "Changes apply without a reload",
    3: "A simulated fraud burst is blocked automatically",
    4: "Busy lamps and voicemail lights work",
    5: "The restore succeeds within a measured time",
}

results = {}
for name, cmd, _ in CHECKS:
    t0 = time.time()
    env, cwd = dict(os.environ), ROOT
    if name == "meow":
        # Meow runs with its own scratch home (MEOW_HOME), never the user's real one.
        home = os.environ["MEOW_HOME"]
        env.update(HOME=home, XDG_CONFIG_HOME=f"{home}/xdg-config", XDG_DATA_HOME=f"{home}/xdg-data", XDG_CACHE_HOME=f"{home}/xdg-cache")
        cwd = home
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, env=env)
    out = p.stdout + p.stderr
    open(f"{LAB}/work/phase2-{name}.log", "w").write(out)
    if name == "meow":
        passed, failed = len(re.findall(r"^PASS", out, re.M)), len(re.findall(r"^FAIL", out, re.M))
    else:
        m = re.search(r"(\d+) passed, (\d+) failed", out)
        passed, failed = (int(m.group(1)), int(m.group(2))) if m else (0, 1)
    restore = re.search(r"Restore time: ([\d.]+) minutes", out)
    results[name] = {"ok": p.returncode == 0 and failed == 0, "passed": passed, "failed": failed,
                     "secs": time.time() - t0, "restore": restore.group(1) if restore else None}
    r = results[name]
    print(f"{'PASS' if r['ok'] else 'FAIL'}  {name}: {passed} passed, {failed} failed ({r['secs'] / 60:.1f} min)", flush=True)

print("\nPhase 2 done-when:")
all_ok = True
for n, text in CONDITIONS.items():
    names = [c[0] for c in CHECKS if n in c[2]]
    ok = all(results[x]["ok"] for x in names) and names
    all_ok = all_ok and bool(ok)
    extra = ""
    if n == 5 and results.get("restore", {}).get("restore"):
        extra = f"; restore {results['restore']['restore']} minutes"
    counts = ", ".join(f"{x} {results[x]['passed']}/{results[x]['passed'] + results[x]['failed']}" for x in names)
    print(f"  {'MET    ' if ok else 'NOT MET'}  {n}. {text}  ({counts}{extra})")
others_ok = all(r["ok"] for r in results.values())
print(f"\nEvery check: {'all pass' if others_ok else 'some failed (logs in ~/.local/share/qpbx-lab/work/phase2-*.log)'}")
sys.exit(0 if all_ok and others_ok else 1)
