#!/usr/bin/env python3
"""3-3 lab check: call and registration events for real SIP traffic on the lab server.

A collector subscribed inside the running app records the events of a test tenant while lab
phones register, call and unregister: an answered call (started, ringing, answered, ended),
an unanswered one (started, ringing, ended, missed), a phone that unregisters, and one that
stops renewing its registration (expired, which takes up to two minutes).

usage: phase3-events.py <vm-ip> [--skip-expiry]
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
SLUG = f"ev-{RUN}"
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def app(code):
    p = subprocess.run(SSH + ["sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], capture_output=True, text=True)
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + p.stdout + p.stderr)
    return json.loads(m.group(1))


def collector(tid, seconds):
    """Starts a subscriber in the app for `seconds`; .result() gives the tenant's events."""
    code = f'''
tid = "{tid}"
QPBX.Events.subscribe(QPBX.Events.CallEvent)
QPBX.Events.subscribe(QPBX.Events.ExtensionRegistration)
deadline = System.monotonic_time(:millisecond) + {seconds * 1000}
loop = fn loop, acc ->
  receive do
    {{:event, %{{tenant_id: ^tid}} = e}} -> loop.(loop, [Map.take(e, [:type, :call_id, :device, :reason, :disposition, :extension_ids, :target, :to]) | acc])
  after max(deadline - System.monotonic_time(:millisecond), 0) -> Enum.reverse(acc)
  end
end
IO.puts("JSON" <> Jason.encode!(loop.(loop, [])))
'''
    p = subprocess.Popen(SSH + ["sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(4)  # subscribed before anything happens

    def result():
        out, err = p.communicate(timeout=seconds + 60)
        m = re.search(r"JSON(.*)$", out, re.M)
        return json.loads(m.group(1)) if m else SystemExit("collector failed:\n" + out + err)

    return result


CLEANUP = f'for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "ev-"), do: QPBX.Repo.delete!(t)'

S = app(CLEANUP + f'''
alias QPBX.Core
a = {{:system, "lab"}}
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(Core.list_plans()).id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
pw = for n <- ~w(101 102 103 104), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
  {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
  {{n, %{{pw: pw, id: e.id}}}}
end
IO.puts("JSON" <> Jason.encode!(%{{tid: t.id, domain: t.sip_domain, ext: pw}}))
''')

subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(HERE, "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def of(events, call_id):
    return [e["type"] for e in events if e.get("call_id") == call_id]


try:
    done = collector(S["tid"], 60)
    for name, ip, user, mode in [("p101", "127.0.0.70", "101", "answer"), ("p102", "127.0.0.71", "102", "answer"), ("p103", "127.0.0.72", "103", "ring")]:
        r = do(cmd="phone", name=name, ip=ip, user=user, domain=S["domain"], password=S["ext"][user]["pw"], mode=mode)
        check(f"phone {user} registers", r["status"] == "200", r["status"])

    # Answered, then hung up after a second (the agent's BYE).
    r = do(cmd="call", **{"from": "p101", "to": "102", "wait": 10})
    check("101 calls 102: answered", r.get("status") == "200", r.get("status"))
    time.sleep(2)
    r = do(cmd="call", **{"from": "p101", "to": "103", "wait": 35})
    check("101 calls 103, which rings and is not answered", r.get("status") not in ("200",), r.get("status"))
    time.sleep(1)
    check("102 unregisters", do(cmd="unregister", name="p102")["status"] == "200")
    events = done()

    regs = [(e["type"], e["device"], e.get("reason")) for e in events if "device" in e and e.get("device")]
    check("registered: 101, 102, 103", {("registered", d, None) for d in ("101", "102", "103")} <= set(regs), regs)
    check("unregistered: 102 (it said so)", ("unregistered", "102", "unregister") in regs, regs)

    calls = []
    for e in events:
        if e.get("call_id") and e["call_id"] not in calls:
            calls.append(e["call_id"])
    answered = of(events, calls[0]) if calls else []
    missed = of(events, calls[1]) if len(calls) > 1 else []
    check("answered call: started, ringing, answered, ended in order", answered == ["started", "ringing", "answered", "ended"], answered)
    first = [e for e in events if e.get("call_id") == (calls[0] if calls else None)]
    check("answered call: target 102, ended answered",
          first and first[2]["target"]["number"] == "102" and first[3]["disposition"] == "answered", first[-1:] if first else "")
    check("unanswered call: started, ringing, ended, missed", missed == ["started", "ringing", "ended", "missed"], missed)
    last = [e for e in events if e.get("call_id") == (calls[1] if len(calls) > 1 else None)]
    check("missed by 103", last and last[-1]["extension_ids"] == [S["ext"]["103"]["id"]], last[-1:] if last else "")

    if "--skip-expiry" not in sys.argv:
        done = collector(S["tid"], 150)
        reg = subprocess.run(["python3", os.path.join(HERE, "..", "tools", "sip_register.py"), VM, "104", S["domain"], S["ext"]["104"]["pw"]],
                             capture_output=True, text=True).stdout.strip()
        check("104 registers for 60 seconds and does not renew", "200" in reg, reg)
        t0 = time.time()
        events = done()
        regs = [(e["type"], e["device"], e.get("reason")) for e in events]
        check("104 expired: unregistered (expired)", ("unregistered", "104", "expired") in regs, regs)
finally:
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
