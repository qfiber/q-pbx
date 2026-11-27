#!/usr/bin/env python3
"""Phase 2 (2-8) checks: call records with real calls.

Calls between phones (answered, busy), out through a carrier and in from one, then a call while
the app is stopped (FreeSWITCH refuses it, its record waits in the spool); every one must show
up in `cdrs` with the right direction, numbers, outcome and talk time, and the spool must be
empty afterwards.

usage: phase2-cdrs.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
SLUG = f"cdr-{RUN}"
DID = "+9723" + str(int(time.time()))[-7:]
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh(cmd):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True).stdout


def app(code):
    p = subprocess.run(SSH + ["sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], capture_output=True, text=True)
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + p.stdout + p.stderr)
    return json.loads(m.group(1))


subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(os.path.dirname(__file__), "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def call(frm, to, talk=0, **kw):
    r = do(cmd="call", **{"from": frm, "to": to}, hold=True, **kw)
    if r.get("dialog"):
        time.sleep(talk)
        do(cmd="bye", dialog=r["dialog"])
    return r["status"]


CLEANUP = '''
alias QPBX.Core
a = {:system, "lab"}
p = %Core.Scope{kind: :platform}
for d <- Core.list_dids(p), String.starts_with?(d.number, "+9723"), t = d.tenant_id && QPBX.Repo.get(Core.Tenant, d.tenant_id), t && String.starts_with?(t.slug, "cdr-"), do: Core.delete_did(p, d, a)
for t <- Core.list_tenants(), String.starts_with?(t.slug, "cdr-"), do: QPBX.Repo.delete!(t)
for old <- Core.list_trunks(p), String.starts_with?(old.name, "cdr-"), do: Core.delete_trunk(p, old, a)
for pl <- Core.list_plans(), String.starts_with?(pl.name, "cdr-"), do: QPBX.Repo.delete!(pl)
'''

setup = app(CLEANUP + f'''
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}"}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
pw = for n <- ~w(101 102), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
  {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
  {{n, pw}}
end
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "cdr-A-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.32", port: 5092}}]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
{{:ok, did}} = Core.create_did(p, %{{number: "{DID}", trunk_id: trunk.id, tenant_id: t.id}}, a)
e102 = Enum.find(Core.list_extensions(s), &(&1.number == "102"))
{{:ok, _}} = Core.set_did_destination(s, Core.get_did!(s, did.id), %{{destination_type: "extension", destination_id: e102.id}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw, tid: t.id, trunk: trunk.id}}))
''')
time.sleep(8)

ROWS = f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{SLUG}"))
u = hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))
rows = QPBX.Telephony.search_cdrs(QPBX.Core.scope_for(u), %{{"leg" => "all"}}, t.timezone, limit: 100)
IO.puts("JSON" <> Jason.encode!(Enum.map(rows, &Map.take(&1, [:leg, :direction, :caller_number, :destination, :disposition, :billsec, :trunk_id, :call_uuid]))))
'''

try:
    for name, ip, user in [("p101", "127.0.0.60", "101"), ("p102", "127.0.0.61", "102")]:
        r = do(cmd="phone", name=name, ip=ip, user=user, domain=setup["domain"], password=setup["pw"][user])
        check(f"phone {user} registers", r["status"] == "200", r["status"])
    do(cmd="carrier", name="A", ip="127.0.0.32", port=5092, mode="answer")

    check("101 calls 102, answered, 3 s", call("p101", "102", talk=3) == "200")
    do(cmd="mode", name="p102", mode="busy")
    check("101 calls 102, busy", call("p101", "102") == "486")
    do(cmd="mode", name="p102", mode="answer")
    check("101 calls out (02-765-4321), answered, 2 s", call("p101", "02-765-4321", talk=2) == "200")
    check("the carrier calls the number, 102 answers, 2 s", call("A", "0" + DID[4:], talk=2) == "200")
    time.sleep(6)  # spool files must be 2 s old; the importer runs every 2 s

    rows = app(ROWS)
    a_legs = [r for r in rows if r["leg"] == "a"]
    by_dest = {(r["direction"], r["destination"], r["disposition"]): r for r in a_legs}
    internal = by_dest.get(("internal", "102", "answered"))
    check("internal answered call: from 101 to 102, about 3 s", internal and internal["caller_number"] == "101" and 2 <= internal["billsec"] <= 5, str(internal))
    check("internal busy call: busy", ("internal", "102", "busy") in by_dest, str(sorted(by_dest)))
    out_a = [r for r in a_legs if r["direction"] == "outbound"]
    check("outbound call: one call, answered", len(out_a) == 1 and out_a[0]["disposition"] == "answered", str(out_a))
    out_b = [r for r in rows if r["leg"] == "b" and r["direction"] == "outbound"]
    check("…its carrier leg names the trunk and the E.164 number", out_b and out_b[0]["trunk_id"] == setup["trunk"] and out_b[0]["destination"] == "+97227654321", str(out_b))
    inbound = [r for r in a_legs if r["direction"] == "inbound"]
    check("inbound call: from the carrier, answered, trunk known", len(inbound) == 1 and inbound[0]["disposition"] == "answered" and inbound[0]["trunk_id"] == setup["trunk"], str(inbound))
    ib_b = [r for r in rows if r["leg"] == "b" and inbound and r["call_uuid"] == inbound[0]["call_uuid"]]
    check("…its leg to the phone says 102", ib_b and ib_b[0]["destination"] == "102", str(ib_b))
    check("the spool is empty after the import", ssh("sudo find /var/lib/qpbx/cdr-spool -maxdepth 1 -name '*.cdr.json' | wc -l").strip() == "0")

    # The app stopped: FreeSWITCH answers from its static fallback; the record waits in the spool.
    before = len(a_legs)
    ssh("sudo systemctl stop qpbx")
    status = call("p101", "102")
    time.sleep(3)
    waiting = ssh("sudo find /var/lib/qpbx/cdr-spool -maxdepth 1 -name '*.cdr.json' | wc -l").strip()
    ssh("sudo systemctl start qpbx")
    for _ in range(30):
        if ssh("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4000/health") == "200":
            break
        time.sleep(2)
    time.sleep(6)
    check("while the app is down a call is refused, and its record waits in the spool", status.startswith("5") and int(waiting) >= 1, f"{status}, {waiting} file(s)")
    after = [r for r in app(ROWS) if r["leg"] == "a"]
    check("…and is imported once the app is back", len(after) == before + 1, f"{before} -> {len(after)}")
    usage = app(f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{SLUG}"))
u = hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))
IO.puts("JSON" <> Jason.encode!(Enum.map(QPBX.Telephony.usage_daily(QPBX.Core.scope_for(u)), &Map.take(&1, [:direction, :calls, :answered, :seconds]))))
''')
    totals = {u["direction"]: u for u in usage}
    check("daily totals: 3 internal (1 answered), 1 outbound, 1 inbound", totals.get("internal", {}).get("calls") == 3 and totals.get("internal", {}).get("answered") == 1
          and totals.get("outbound", {}).get("calls") == 1 and totals.get("inbound", {}).get("calls") == 1, str(usage))
finally:
    ua.stdin.close()
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
