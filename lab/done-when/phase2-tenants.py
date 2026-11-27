#!/usr/bin/env python3
"""Phase 2 done-when: two tenants with the same extension numbers call internally and
externally with no crossover, and changes apply without a reload.

Tenants A and B both have extensions 101 and 102 (phones on the lab server's loopback
addresses) and their own number at the same carrier. Checked: each internal call rings its
own tenant's 102 only; outbound calls reach the carrier with their own tenant's number; the
carrier's call to each number rings that tenant's 102 only. Then, with Kamailio's and
FreeSWITCH's start times noted: a new forwarding and a new extension with a device work on
the very next call and registration, and neither service was restarted.

usage: phase2-tenants.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
STAMP = str(int(time.time()))[-6:]
DID_A, DID_B = "+97231" + STAMP, "+97232" + STAMP
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


def call(frm, to):
    return do(cmd="call", **{"from": frm, "to": to})["status"]


def rang(*names):
    """Which of these endpoints got an INVITE since the last look."""
    return [n for n in names if do(cmd="seen", name=n)["seen"]]


def started():
    # One value per unit, separated by blank lines.
    return [l for l in ssh("systemctl show -p ActiveEnterTimestamp --value kamailio freeswitch").split("\n") if l.strip()]


CLEANUP = '''
alias QPBX.Core
a = {:system, "lab"}
p = %Core.Scope{kind: :platform}
for d <- Core.list_dids(p), t = d.tenant_id && QPBX.Repo.get(Core.Tenant, d.tenant_id), t && String.starts_with?(t.slug, "xover-"), do: Core.delete_did(p, d, a)
for t <- Core.list_tenants(), String.starts_with?(t.slug, "xover-"), do: QPBX.Repo.delete!(t)
for old <- Core.list_trunks(p), String.starts_with?(old.name, "xover-"), do: Core.delete_trunk(p, old, a)
for pl <- Core.list_plans(), String.starts_with?(pl.name, "xover-"), do: QPBX.Repo.delete!(pl)
'''

S = app(CLEANUP + f'''
{{:ok, plan}} = Core.create_plan(%{{name: "xover-{RUN}"}}, a)
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "xover-T-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.33", port: 5093}}]}}, a)
make = fn slug, did_number ->
  {{:ok, t}} = Core.create_tenant(%{{name: slug, slug: slug, timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
  {{:ok, u}} = Core.create_user(t, %{{email: slug <> "@x.test", name: "A"}}, "tenant_admin", a)
  s = Core.scope_for(u)
  pw = for n <- ~w(101 102), into: %{{}} do
    {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
    {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
    {{n, pw}}
  end
  {{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
  {{:ok, did}} = Core.create_did(p, %{{number: did_number, trunk_id: trunk.id, tenant_id: t.id}}, a)
  e102 = Enum.find(Core.list_extensions(s), &(&1.number == "102"))
  {{:ok, _}} = Core.set_did_destination(s, Core.get_did!(s, did.id), %{{destination_type: "extension", destination_id: e102.id}}, a)
  %{{domain: t.sip_domain, pw: pw, tenant: t.id}}
end
IO.puts("JSON" <> Jason.encode!(%{{a: make.("xover-a-{RUN}", "{DID_A}"), b: make.("xover-b-{RUN}", "{DID_B}")}}))
''')
time.sleep(8)  # Kamailio reloads domains, credentials and trunks

try:
    for t, base in [("a", 70), ("b", 80)]:
        for i, user in enumerate(["101", "102"]):
            r = do(cmd="phone", name=f"{t}{user}", ip=f"127.0.0.{base + i}", user=user, domain=S[t]["domain"], password=S[t]["pw"][user])
            check(f"tenant {t.upper()}: {user} registers", r["status"] == "200", r["status"])
    do(cmd="carrier", name="C", ip="127.0.0.33", port=5093, mode="answer")
    rang("a101", "a102", "b101", "b102", "C")

    # Internal: the same number in each tenant rings that tenant's phone only.
    for t, other in [("a", "b"), ("b", "a")]:
        r = call(f"{t}101", "102")
        check(f"internal: {t.upper()} 101 calls 102: only {t.upper()}'s 102 rings",
              r == "200" and rang(f"{t}102", f"{other}102") == [f"{t}102"], r)

    # Outbound: each tenant's own number goes to the carrier.
    for t, did in [("a", DID_A), ("b", DID_B)]:
        r = call(f"{t}101", "02-765-4321")
        seen = do(cmd="seen", name="C")["seen"]
        frm = seen[0]["from"] if seen else ""
        check(f"outbound: {t.upper()}'s call carries {t.upper()}'s number", r == "200" and did in frm, f"{r}, From {frm}")

    # Inbound: each number rings its own tenant's 102.
    for t, other, did in [("a", "b", DID_A), ("b", "a", DID_B)]:
        r = call("C", "0" + did[4:])
        check(f"inbound: the carrier's call to {t.upper()}'s number rings only {t.upper()}'s 102",
              r == "200" and rang(f"{t}102", f"{other}102") == [f"{t}102"], r)

    # Changes without a reload: note when Kamailio and FreeSWITCH started.
    before = started()
    app(f'''
t = QPBX.Core.get_tenant!("{S['a']['tenant']}")
s = QPBX.Core.scope_for(hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t)))
e = Enum.find(QPBX.Core.list_extensions(s), &(&1.number == "102"))
{{:ok, _}} = QPBX.Core.update_extension(s, e, %{{forward_always: "101"}}, {{:system, "lab"}})
IO.puts("JSON{{}}")''')
    r = call("C", "0" + DID_A[4:])
    check("a new forwarding (A's 102 to 101) applies to the very next call", r == "200" and rang("a101", "a102") == ["a101"], r)

    new = app(f'''
t = QPBX.Core.get_tenant!("{S['b']['tenant']}")
s = QPBX.Core.scope_for(hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t)))
{{:ok, e}} = QPBX.Core.create_extension(s, %{{number: "103", name: "New"}}, {{:system, "lab"}})
{{:ok, _, pw}} = QPBX.Core.add_device(s, e, %{{label: "", kind: "softphone"}}, {{:system, "lab"}})
IO.puts("JSON" <> Jason.encode!(pw))''')
    time.sleep(2)
    r = do(cmd="phone", name="b103", ip="127.0.0.82", user="103", domain=S["b"]["domain"], password=new)
    check("a new extension's device registers at once", r["status"] == "200", r["status"])
    r = call("b101", "103")
    check("…and is called at once", r == "200" and rang("b103") == ["b103"], r)
    after = started()
    check("Kamailio and FreeSWITCH were not restarted for any of it", before == after and len(before) == 2, f"{before} / {after}")
finally:
    ua.stdin.close()
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
