#!/usr/bin/env python3
"""Phase 2 (2-5) checks: real calls through Kamailio, FreeSWITCH and Elixir call control.

Phones (101, 102, 103 on 127.0.0.20-22) and two carriers (A on 127.0.0.30:5090, B on
127.0.0.31:5091) run on the lab server (lab/tools/sipua_daemon.py, driven over ssh); this
script sets up a tenant through the app, changes extension features between calls, and checks
what every endpoint received.

usage: phase2-calls.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
DID = "+9722" + str(int(time.time()))[-7:]
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh(cmd, stdin=None):
    return subprocess.run(SSH + [cmd], input=stdin, capture_output=True, text=True).stdout


def app(code):
    out = ssh("sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code))
    m = re.search(r"JSON(.*)$", out, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + out)
    return json.loads(m.group(1))


subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(os.path.dirname(__file__), "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def seen(name):
    return do(cmd="seen", name=name)["seen"]


def ext(number, **changes):
    """Changes extension features through the app (Core), as the portal would."""
    attrs = ", ".join(f"{k}: {'nil' if v is None else json.dumps(v)}" for k, v in changes.items())
    app(f'''
alias QPBX.Core
t = Enum.find(Core.list_tenants(), &(&1.slug == "calls-{RUN}"))
u = hd(Core.list_users(%Core.Scope{{kind: :platform}}, t))
s = Core.scope_for(u)
e = Enum.find(Core.list_extensions(s), &(&1.number == "{number}"))
{{:ok, _}} = Core.update_extension(s, e, %{{{attrs}}}, {{:system, "lab"}})
IO.puts("JSON{{}}")
''')
    time.sleep(0.5)


# Setup: tenant, extensions 101-103 with a desk phone each, carriers A and B (IP trunks on
# the platform), a route for +972 through A then B, a number to 102, emergency 100 through A.
setup = app(f'''
alias QPBX.Core
a = {{:system, "lab"}}
p = %Core.Scope{{kind: :platform}}
{{:ok, plan}} = Core.create_plan(%{{name: "calls-{RUN}", max_extensions: 10}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "Calls {RUN}", slug: "calls-{RUN}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "calls-{RUN}@x.test", name: "C"}}, "tenant_admin", a)
s = Core.scope_for(u)
pw = for n <- ~w(101 102 103), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n, no_answer_seconds: 5}}, a)
  {{:ok, _d, pw}} = Core.add_device(s, e, %{{label: "desk", kind: "desk_phone"}}, a)
  {{n, pw}}
end
for old <- Core.list_trunks(p), String.starts_with?(old.name, "calls-") do
  for e <- Core.list_emergency_routes(), e.trunk_id == old.id, do: Core.delete_emergency_route(p, e.id, a)
  for d <- Core.list_dids(p), d.trunk_id == old.id, do: Core.delete_did(p, d, a)
  for ten <- Core.list_tenants(), us <- Core.list_users(p, ten), QPBX.Core.User.role(us) == "tenant_admin", sc = Core.scope_for(us), r <- Core.list_routes(sc), old.id in r.trunk_ids, do: Core.delete_route(sc, r, a)
  Core.delete_trunk(p, old, a)
end
{{:ok, ta}} = Core.create_trunk(p, %{{name: "calls-A-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.30", port: 5090}}]}}, a)
{{:ok, tb}} = Core.create_trunk(p, %{{name: "calls-B-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.31", port: 5091}}]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "IL", prefixes: ["+972"], destination_class: "local", trunk_ids: [ta.id, tb.id]}}, a)
{{:ok, did}} = Core.create_did(p, %{{number: "{DID}", trunk_id: ta.id, tenant_id: t.id}}, a)
e102 = Enum.find(Core.list_extensions(s), &(&1.number == "102"))
{{:ok, _}} = Core.set_did_destination(s, Core.get_did!(s, did.id), %{{destination_type: "extension", destination_id: e102.id}}, a)
for e <- Core.list_emergency_routes(), e.number == "100", do: Core.delete_emergency_route(p, e.id, a)
{{:ok, _}} = Core.create_emergency_route(p, %{{number: "100", trunk_id: ta.id}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw}}))
''')
DOMAIN = setup["domain"]
time.sleep(8)  # Kamailio reloads credentials, domains and trunks (at most one reload per 5 s)

try:
    for i, n in enumerate(["101", "102", "103"]):
        r = do(cmd="phone", name=f"p{n}", ip=f"127.0.0.{20 + i}", user=f"{n}-desk", domain=DOMAIN, password=setup["pw"][n])
        check(f"phone {n} registers", r["status"] == "200", r["status"])
    do(cmd="carrier", name="A", ip="127.0.0.30", port=5090, mode="busy")
    do(cmd="carrier", name="B", ip="127.0.0.31", port=5091, mode="busy")

    # Extension to extension.
    r = do(cmd="call", **{"from": "p101", "to": "102"})
    got = seen("p102")
    check("101 calls 102: answered", r["status"] == "200", r["status"])
    check("…102 sees the caller as extension 101", got and "<sip:101@" in got[0]["from"], got[0]["from"] if got else "nothing")

    do(cmd="mode", name="p102", mode="busy")
    r = do(cmd="call", **{"from": "p101", "to": "102"})
    check("102 busy: the caller hears busy (486)", r["status"] == "486", r["status"])

    # Do not disturb.
    do(cmd="mode", name="p102", mode="answer")
    seen("p102")
    ext("102", dnd=True)
    r = do(cmd="call", **{"from": "p101", "to": "102"})
    check("do not disturb: busy, and 102's phone does not ring", r["status"] == "486" and seen("p102") == [], r["status"])
    ext("102", dnd=False)

    # Forward always.
    ext("102", forward_always="103")
    seen("p103")
    r = do(cmd="call", **{"from": "p101", "to": "102"})
    check("forward always 102 -> 103: answered by 103", r["status"] == "200" and len(seen("p103")) == 1, r["status"])
    ext("102", forward_always=None)

    # No answer -> forward on no answer.
    do(cmd="mode", name="p102", mode="ring")
    ext("102", forward_no_answer="103")
    seen("p103")
    started = time.time()
    r = do(cmd="call", **{"from": "p101", "to": "102", "wait": 30})
    took = time.time() - started
    check("102 does not answer for 5 s: forwarded to 103, answered", r["status"] == "200" and len(seen("p103")) == 1 and took >= 4.5, f"{r['status']} after {took:.1f}s")
    ext("102", forward_no_answer=None)

    # Follow-me.
    ext("102", follow_me_enabled=True, follow_me_numbers=["103"])
    seen("p103")
    r = do(cmd="call", **{"from": "p101", "to": "102", "wait": 30})
    check("follow-me: after 102's devices, 103 rings and answers", r["status"] == "200" and len(seen("p103")) == 1, r["status"])
    ext("102", follow_me_enabled=False, follow_me_numbers=[])
    do(cmd="mode", name="p102", mode="answer")

    # Call waiting off: 102 on a call is busy.
    ext("102", call_waiting=False)
    held = do(cmd="call", **{"from": "p103", "to": "102", "hold": True})
    time.sleep(1)
    r = do(cmd="call", **{"from": "p101", "to": "102"})
    check("call waiting off: 102 already on a call is busy", held["status"] == "200" and r["status"] == "486", f"{held['status']} / {r['status']}")
    if held.get("dialog"):
        do(cmd="bye", dialog=held["dialog"])
    ext("102", call_waiting=True)

    # Outbound: the national number reaches carrier A in E.164, with the tenant's number.
    seen("A"), seen("B")
    r = do(cmd="call", **{"from": "p101", "to": "02-765-4321"})
    a = seen("A")
    check("outbound: carrier A gets +97227654321", a and "+97227654321@" in a[0]["ruri"], a[0]["ruri"] if a else "nothing")
    check("…with the tenant's number as caller ID and name, and no Q-PBX headers",
          a and f'"{DID}" <sip:{DID}@' in a[0]["from"] and not any(h.startswith("X-QPBX") for h in a[0]["headers"]), a[0]["from"] if a else "")
    check("…busy at the carrier is final: no failover to B, caller hears busy", r["status"] == "486" and seen("B") == [], r["status"])

    # Carrier failover: A out of service -> B.
    do(cmd="mode", name="A", mode="503")
    do(cmd="mode", name="B", mode="answer")
    r = do(cmd="call", **{"from": "p101", "to": "0501234567"})
    b = seen("B")
    check("carrier A fails (503): the call goes out through B and is answered", r["status"] == "200" and b and "+972501234567@" in b[0]["ruri"], r["status"])

    # Emergency.
    do(cmd="mode", name="A", mode="answer")
    seen("A")
    r = do(cmd="call", **{"from": "p101", "to": "100"})
    a = seen("A")
    check("emergency 100 goes out through its trunk", r["status"] == "200" and a and "100@" in a[0]["ruri"], a[0]["ruri"] if a else r["status"])

    # Inbound from a carrier, number in national form.
    seen("p102")
    national = "0" + DID[4:]
    r = do(cmd="call", **{"from": "A", "to": national})
    got = seen("p102")
    check("inbound: carrier A calls the number (national form): 102 answers", r["status"] == "200" and len(got) == 1, r["status"])
    r = do(cmd="call", **{"from": "A", "to": "+97299999999"})
    check("inbound to an unknown number: refused (404)", r["status"] == "404", r["status"])

    # Elixir down: the static fallback answers 503 so a carrier fails over to its backup.
    ssh("sudo systemctl stop qpbx")
    r = do(cmd="call", **{"from": "A", "to": national, "wait": 15})
    # FreeSWITCH answers 503; Kamailio, as a proxy, passes it on as 500 (RFC 3261 16.7).
    check("with the app stopped, a carrier call gets a 5xx (static fallback: the carrier fails over)", r["status"].startswith("5"), r["status"])
    ssh("sudo systemctl start qpbx")
    ok = False
    for _ in range(40):
        time.sleep(2)
        if ssh("curl -s http://127.0.0.1:4000/health").startswith('{"status"'):
            r = do(cmd="call", **{"from": "A", "to": national})
            if r["status"] == "200":
                ok = True
                break
    check("…and calls work again once it is back", ok)
finally:
    ua.stdin.close()
    ua.terminate()
    app('''
alias QPBX.Core
a = {:system, "lab"}
p = %Core.Scope{kind: :platform}
for old <- Core.list_trunks(p), String.starts_with?(old.name, "calls-") do
  for e <- Core.list_emergency_routes(), e.trunk_id == old.id, do: Core.delete_emergency_route(p, e.id, a)
  for d <- Core.list_dids(p), d.trunk_id == old.id, do: Core.delete_did(p, d, a)
  for ten <- Core.list_tenants(), us <- Core.list_users(p, ten), QPBX.Core.User.role(us) == "tenant_admin", sc = Core.scope_for(us), r <- Core.list_routes(sc), old.id in r.trunk_ids, do: Core.delete_route(sc, r, a)
  Core.delete_trunk(p, old, a)
end
IO.puts("JSON{}")
''')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
