#!/usr/bin/env python3
"""Phase 2 (2-6) checks: call admission and fraud protection with real calls.

Two tenants: "strict" (plan: local and mobile only, one outbound and one inbound call at a
time, 1 local minute per hour) and "open" (default plan) for the velocity rules. Phones and a
carrier run on the lab server (lab/tools/sipua_daemon.py); this script sets up through the app.

usage: phase2-admission.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
DID = "+9723" + str(int(time.time()))[-7:]
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


def call(frm, to, **kw):
    return do(cmd="call", **{"from": frm, "to": to}, **kw)


CLEANUP = '''
alias QPBX.Core
a = {:system, "lab"}
p = %Core.Scope{kind: :platform}
for old <- Core.list_trunks(p), String.starts_with?(old.name, "adm-") do
  for e <- Core.list_emergency_routes(), e.trunk_id == old.id, do: Core.delete_emergency_route(p, e.id, a)
  for d <- Core.list_dids(p), d.trunk_id == old.id, do: Core.delete_did(p, d, a)
  for ten <- Core.list_tenants(), us <- Core.list_users(p, ten), QPBX.Core.User.role(us) == "tenant_admin", sc = Core.scope_for(us), r <- Core.list_routes(sc), old.id in r.trunk_ids, do: Core.delete_route(sc, r, a)
  Core.delete_trunk(p, old, a)
end
for c <- Core.list_number_classes(), c.note == "adm-lab", do: Core.delete_number_class(p, c.id, a)
for b <- QPBX.Telephony.list_fraud_blocks(), do: QPBX.Telephony.lift_fraud_block(b.id, a)
{:ok, _} = QPBX.Telephony.update_fraud_settings(%{international_spike_calls: 20, block_on_spike: true, quiet_start_hour: 22, quiet_end_hour: 6, block_in_quiet_hours: false, block_hours: 24}, a)
'''

setup = app(CLEANUP + f'''
{{:ok, strict}} = Core.create_plan(%{{name: "adm-strict-{RUN}", allowed_destination_classes: ["local", "mobile"],
  max_concurrent_calls_outbound: 1, max_concurrent_calls_inbound: 1, minutes_local_per_hour: 1}}, a)
{{:ok, open}} = Core.create_plan(%{{name: "adm-open-{RUN}"}}, a)
make = fn slug, plan, numbers ->
  {{:ok, t}} = Core.create_tenant(%{{name: slug, slug: slug, timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
  {{:ok, u}} = Core.create_user(t, %{{email: slug <> "@x.test", name: "A"}}, "tenant_admin", a)
  s = Core.scope_for(u)
  pw = for n <- numbers, into: %{{}} do
    {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
    {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
    {{n, pw}}
  end
  {{t, s, pw}}
end
{{t1, s1, pw1}} = make.("adm-strict-{RUN}", strict, ~w(101 102))
{{t2, s2, pw2}} = make.("adm-open-{RUN}", open, ~w(201))
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "adm-A-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.30", port: 5090}}]}}, a)
for s <- [s1, s2], do: {{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
{{:ok, _}} = Core.create_number_class(p, %{{prefix: "+9725", class: "mobile", note: "adm-lab"}}, a)
{{:ok, _}} = Core.create_number_class(p, %{{prefix: "+97259", class: "premium", note: "adm-lab"}}, a)
for e <- Core.list_emergency_routes(), e.number == "100", do: Core.delete_emergency_route(p, e.id, a)
{{:ok, _}} = Core.create_emergency_route(p, %{{number: "100", trunk_id: trunk.id}}, a)
{{:ok, did}} = Core.create_did(p, %{{number: "{DID}", trunk_id: trunk.id, tenant_id: t1.id}}, a)
e102 = Enum.find(Core.list_extensions(s1), &(&1.number == "102"))
{{:ok, _}} = Core.set_did_destination(s1, Core.get_did!(s1, did.id), %{{destination_type: "extension", destination_id: e102.id}}, a)
{{:ok, _}} = QPBX.Telephony.update_fraud_settings(%{{international_spike_calls: 3, quiet_start_hour: 0, quiet_end_hour: 0, block_hours: 1}}, a)
IO.puts("JSON" <> Jason.encode!(%{{d1: t1.sip_domain, d2: t2.sip_domain, t1: t1.id, t2: t2.id, pw1: pw1, pw2: pw2}}))
''')
time.sleep(8)  # Kamailio reloads credentials, domains and trunks

try:
    for name, ip, user, dom, pw in [("p101", "127.0.0.40", "101", setup["d1"], setup["pw1"]["101"]),
                                     ("p102", "127.0.0.41", "102", setup["d1"], setup["pw1"]["102"]),
                                     ("p201", "127.0.0.42", "201", setup["d2"], setup["pw2"]["201"])]:
        r = do(cmd="phone", name=name, ip=ip, user=user, domain=dom, password=pw)
        check(f"phone {user} registers", r["status"] == "200", r["status"])
    do(cmd="carrier", name="A", ip="127.0.0.30", port=5090, mode="answer")

    # Destination classes.
    r = call("p101", "0591234567")
    check("strict tenant: a premium (high-cost) number is refused (403)", r["status"] == "403", r["status"])
    r = call("p101", "00442079460000")
    check("strict tenant: international is not in its plan: refused (403)", r["status"] == "403", r["status"])
    do(cmd="seen", name="A")
    r = call("p101", "0501234567")
    check("strict tenant: mobile is allowed and goes out", r["status"] == "200" and len(do(cmd="seen", name="A")["seen"]) == 1, r["status"])

    # Concurrent outbound and inbound caps (1 each). (The previous call frees its slot when its
    # bridge ends, a moment after its BYE.) A refusal is 503, which Kamailio as a proxy passes
    # on as 500.
    time.sleep(1)
    held = call("p101", "0501234567", hold=True)
    r = call("p102", "0507654321")
    check("a second outbound call while one is up: refused (5xx)", held["status"] == "200" and r["status"].startswith("5"), f"{held['status']} / {r['status']}")
    if held.get("dialog"):
        do(cmd="bye", dialog=held["dialog"])
    held = call("A", "0" + DID[4:], hold=True)
    r = call("A", "0" + DID[4:])
    check("a second inbound call while one is up: refused (5xx to the carrier)", held["status"] == "200" and r["status"].startswith("5"), f"{held['status']} / {r['status']}")
    if held.get("dialog"):
        do(cmd="bye", dialog=held["dialog"])
    time.sleep(1)

    # Emergency calls pass every limit.
    do(cmd="seen", name="A")
    held = call("p101", "02-111-1111", hold=True)  # uses the one outbound slot
    r = call("p102", "100")
    a_seen = do(cmd="seen", name="A")["seen"]
    check("emergency 100 goes out even with the outbound slot taken", r["status"] == "200" and any("100@" in s["ruri"] for s in a_seen), r["status"])
    if held.get("dialog"):
        do(cmd="bye", dialog=held["dialog"])

    # Minute cap: 1 local minute per hour; a call is cut off when it runs out, then refused.
    used = app(f'IO.puts("JSON" <> Jason.encode!(QPBX.Telephony.Usage.used("{setup["t1"]}", "Asia/Jerusalem")))')
    held = call("p101", "02-765-4321", hold=True)
    started = time.time()
    time.sleep(max(0, 66 - (used.get("local", {}).get("hour", 0) or 0)))
    bye = do(cmd="bye", dialog=held["dialog"])["status"] if held.get("dialog") else "none"
    check("a local call is cut off when the hour's minute runs out (our BYE finds no call)", held["status"] == "200" and bye != "200", f"BYE after {time.time() - started:.0f}s: {bye}")
    r = call("p101", "02-765-4321")
    check("…and the next local call is refused (403)", r["status"] == "403", r["status"])
    check("…while mobile (its own cap: none) still goes out", call("p101", "0501234567")["status"] == "200")
    used = app(f'IO.puts("JSON" <> Jason.encode!(QPBX.Telephony.Usage.used("{setup["t1"]}", "Asia/Jerusalem")))')
    check("talk time is recorded per class", (used.get("local") or {}).get("hour", 0) >= 55, str(used))

    # Velocity: a spike of international calls (threshold 3 in 10 minutes) blocks the tenant.
    do(cmd="mode", name="A", mode="busy")
    statuses = [call("p201", "00442079460000")["status"] for _ in range(4)]
    check("open tenant: 3 international calls reach the carrier, the 4th is blocked (403)", statuses == ["486", "486", "486", "403"], " ".join(statuses))
    blocks = app('IO.puts("JSON" <> Jason.encode!(Enum.map(QPBX.Telephony.list_fraud_blocks(), &%{t: &1.tenant_id, r: &1.reason})))')
    check("…the tenant is listed as blocked (international spike)", {"t": setup["t2"], "r": "international_spike"} in blocks, str(blocks))
    check("…international stays blocked", call("p201", "00442079460000")["status"] == "403")
    check("…local calls still go out", call("p201", "02-765-4321")["status"] == "486")
    do(cmd="mode", name="A", mode="answer")
    check("…and emergency calls too", call("p201", "100")["status"] == "200")
    alerts = app(f'IO.puts("JSON" <> Jason.encode!(Enum.count(QPBX.Core.list_audit_logs(limit: 200), &(&1.action == "fraud.international_spike" and &1.changes["tenant_id"] == "{setup["t2"]}"))))')
    check("…one fraud alert was raised (audited)", alerts == 1, str(alerts))
    app(f'for b <- QPBX.Telephony.list_fraud_blocks(), b.tenant_id == "{setup["t2"]}", do: QPBX.Telephony.lift_fraud_block(b.id, {{:system, "lab"}})\nIO.puts("JSON{{}}")')
    check("…lifted by an admin: international works again", call("p201", "00442079460000")["status"] == "200")

    refused = app(f'IO.puts("JSON" <> Jason.encode!(Enum.count(QPBX.Core.list_audit_logs(limit: 300), &(&1.action == "call.refused" and &1.changes["tenant_id"] == "{setup["t1"]}"))))')
    check("refusals are audited (LimitReached)", refused >= 4, str(refused))
finally:
    ua.stdin.close()
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
