#!/usr/bin/env python3
"""3-7 lab check: click-to-call and call control through the API (nginx) with real phones.

The API rings extension 101's phone (it answers, seeing the number it is about to call),
then calls 102 from 101; the live call is listed, transferred to 103 and hung up. A click to
an outside number reaches the test carrier from 101; one to a destination class the plan
does not allow (international) is refused by call admission after 101 answers.

usage: phase3-click.py <vm-ip>
"""
import json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
BASE = "https://portal.pbx.lab.test"
RUN = format(int(time.time()), "x")
SLUG = f"cc-{RUN}"
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE  # the portal's self-signed lab certificate
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


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                               headers={"authorization": "Bearer " + S["key"], "content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as res:
            raw = res.read()
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, json.loads(raw) if raw else None


CLEANUP = f'''
alias QPBX.Core
p = %Core.Scope{{kind: :platform}}
for t <- Core.list_tenants(), String.starts_with?(t.slug, "cc-"), do: QPBX.Repo.delete!(t)
for tr <- Core.list_trunks(p), String.starts_with?(tr.name, "cc-"), do: Core.delete_trunk(p, tr, {{:system, "lab"}})
for pl <- Core.list_plans(), String.starts_with?(pl.name, "cc-"), do: QPBX.Repo.delete!(pl)
'''

S = app(CLEANUP + f'''
a = {{:system, "lab"}}
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}", allowed_destination_classes: ["local", "mobile"]}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
ext = for n <- ~w(101 102 103), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
  {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
  {{n, %{{id: e.id, pw: pw}}}}
end
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "cc-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.34", port: 5094}}]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "intl", prefixes: ["+44"], destination_class: "international", trunk_ids: [trunk.id]}}, a)
{{:ok, _, key}} = Core.create_api_key(s, %{{name: "cc", scopes: ["read", "calls"]}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, ext: ext, key: key}}))
''')

subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(HERE, "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def froms(name):
    return [x["from"] or "" for x in do(cmd="seen", name=name)["seen"]]


def live():
    status, body = api("GET", "/v1/calls/live")
    return body["data"] if status == 200 else None


try:
    time.sleep(8)  # the new trunk reaches Kamailio's dispatcher
    for name, ip, user in [("c101", "127.0.0.95", "101"), ("c102", "127.0.0.96", "102"), ("c103", "127.0.0.97", "103")]:
        r = do(cmd="phone", name=name, ip=ip, user=user, domain=S["domain"], password=S["ext"][user]["pw"])
        check(f"phone {user} registers", r["status"] == "200", r["status"])
    do(cmd="carrier", name="carrier", ip="127.0.0.34", port=5094, mode="answer")

    status, body = api("POST", "/v1/calls", {"extension_id": S["ext"]["101"]["id"], "to": "102"})
    call_id = (body or {}).get("data", {}).get("call_id")
    check("click-to-call accepted (202, a call id)", status == 202 and call_id, status)
    time.sleep(3)
    f101, f102 = froms("c101"), froms("c102")
    check("101's phone rang first, showing 102", len(f101) == 1 and "102" in f101[0], f101)
    check("then 102 rang, called by 101", len(f102) == 1 and "101" in f102[0], f102)
    calls = live() or []
    mine = [c for c in calls if c["call_id"] == call_id]
    check("the live call is listed, answered", mine and mine[0]["answered"] and mine[0]["from"] == "101", calls)

    status, _ = api("POST", f"/v1/calls/{call_id}/transfer", {"to": "103"})
    time.sleep(3)
    f103 = froms("c103")
    check("transferred to 103 through the API: 103 rang", status == 204 and len(f103) == 1, f"{status} {f103}")
    status, _ = api("POST", f"/v1/calls/{call_id}/hangup")
    time.sleep(2)
    check("hung up through the API: no live calls", status == 204 and live() == [], status)

    status, body = api("POST", "/v1/calls", {"extension_id": S["ext"]["101"]["id"], "to": "+97221234567"})
    time.sleep(4)
    seen = do(cmd="seen", name="carrier")["seen"]
    check("click to an outside number: the carrier got it", status == 202 and any("97221234567" in x["ruri"] or "21234567" in x["ruri"] for x in seen), [x["ruri"] for x in seen])
    if (body or {}).get("data"):
        api("POST", f"/v1/calls/{body['data']['call_id']}/hangup")
    time.sleep(1)

    froms("c101")
    status, body = api("POST", "/v1/calls", {"extension_id": S["ext"]["101"]["id"], "to": "+447700900123"})
    time.sleep(4)
    seen = do(cmd="seen", name="carrier")["seen"]
    check("click to an international number (not in the plan): 101 rang, admission refused, the carrier got nothing",
          status == 202 and len(froms("c101")) == 1 and seen == [], [x["ruri"] for x in seen])
    check("and nothing is left live", live() == [])
finally:
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
