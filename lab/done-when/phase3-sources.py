#!/usr/bin/env python3
"""3-9 lab check: alert sources with real failures on the lab server, read through the API.

- A shared trunk whose test carrier stops answering OPTIONS: "trunk down" (platform),
  resolved when it answers again.
- FreeSWITCH stopped: "FreeSWITCH is not answering" (critical); started again: resolved.
- Real outbound calls crossing 50% of a tenant's monthly outbound minutes: the usage alert,
  with the minutes used and left.
- Repeated wrong SIP passwords from one phone: Kamailio bans it, the tenant gets a brute-force
  alert naming its domain.

usage: phase3-sources.py <vm-ip>   (takes about five minutes)
"""
import json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
BASE = "https://portal.pbx.lab.test"
RUN = format(int(time.time()), "x")
SLUG = f"src-{RUN}"
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


def api(key, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={"authorization": "Bearer " + key, "content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as res:
            raw = res.read()
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, None


def alerts(key, **f):
    q = "&".join(f"{k}={v}" for k, v in f.items())
    st, body = api(key, "GET", "/v1/alerts?" + q)
    return (body or {}).get("data", []) if st == 200 else []


def wait(fun, secs, every=5):
    end = time.time() + secs
    while time.time() < end:
        v = fun()
        if v:
            return v
        time.sleep(every)
    return fun()


CLEANUP = '''
alias QPBX.Core
p = %Core.Scope{kind: :platform}
for t <- Core.list_tenants(), String.starts_with?(t.slug, "src-"), do: QPBX.Repo.delete!(t)
for tr <- Core.list_trunks(p), String.starts_with?(tr.name, "src-"), do: Core.delete_trunk(p, tr, {:system, "lab"})
for pl <- Core.list_plans(), String.starts_with?(pl.name, "src-"), do: QPBX.Repo.delete!(pl)
for k <- Core.list_api_keys(p), k.name == "src", do: Core.revoke_api_key(p, k.id, {:system, "lab"})
'''

S = app(CLEANUP + f'''
a = {{:system, "lab"}}
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}", outbound_minutes_per_month: 1, usage_thresholds: [50, 100], allowed_destination_classes: ["local", "mobile"]}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@acme.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
{{:ok, e}} = Core.create_extension(s, %{{number: "101", name: "Ext 101"}}, a)
{{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "src-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.37", port: 5097}}]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
{{:ok, _, tk}} = Core.create_api_key(s, %{{name: "src", scopes: ["read"]}}, a)
{{:ok, _, pk}} = Core.create_api_key(p, %{{name: "src", scopes: ["read"]}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw, trunk: trunk.id, tkey: tk, pkey: pk}}))
''')

subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(HERE, "..", "tools", "sipua_daemon.py")).read(), text=True)


def agent():
    p = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def do(**cmd):
        p.stdin.write(json.dumps(cmd) + "\n")
        p.stdin.flush()
        return json.loads(p.stdout.readline())

    return p, do


carrier, cdo = agent()
ua, do = agent()
try:
    cdo(cmd="carrier", name="carrier", ip="127.0.0.37", port=5097, mode="answer")
    do(cmd="phone", name="p101", ip="127.0.0.100", user="101", domain=S["domain"], password=S["pw"])
    time.sleep(60)  # the dispatcher marks the new carrier active (OPTIONS every 20 s)

    # Usage: two real calls of about 20 s each cross 50% of the 1-minute allowance.
    for _ in range(2):
        r = do(cmd="call", **{"from": "p101", "to": "+97221234567", "wait": 10, "hold": True})
        time.sleep(20)
        if r.get("dialog"):
            do(cmd="bye", dialog=r["dialog"])
        time.sleep(1)
    found = wait(lambda: [a for a in alerts(S["tkey"]) if a["kind"] == "usage_threshold"], 20)
    check("real calls crossed 50% of the monthly outbound minutes: the usage alert", found and "50%" in found[0]["title"] and "used this month" in found[0]["message"], found[0]["message"] if found else "none")

    # Trunk down: the carrier stops answering.
    carrier.terminate()
    t0 = time.time()
    down = wait(lambda: [a for a in alerts(S["pkey"], state="open") if a["key"] == f"trunk:{S['trunk']}"], 150)
    check("the carrier stopped answering: trunk down alert (platform)", down and down[0]["severity"] == "critical", f"after {time.time() - t0:.0f} s")
    carrier, cdo = agent()
    cdo(cmd="carrier", name="carrier", ip="127.0.0.37", port=5097, mode="answer")
    t0 = time.time()
    back = wait(lambda: [a for a in alerts(S["pkey"], state="resolved") if a["key"] == f"trunk:{S['trunk']}"], 150)
    check("the carrier answers again: the trunk alert is resolved", back, f"after {time.time() - t0:.0f} s")

    # FreeSWITCH stopped and started.
    subprocess.run(SSH + ["sudo systemctl stop freeswitch"])
    t0 = time.time()
    fs = wait(lambda: [a for a in alerts(S["pkey"], state="open") if a["key"] == "health:freeswitch"], 90)
    check("FreeSWITCH stopped: 'FreeSWITCH is not answering', critical", fs and fs[0]["severity"] == "critical", f"after {time.time() - t0:.0f} s")
    subprocess.run(SSH + ["sudo systemctl start freeswitch"])
    t0 = time.time()
    fs_ok = wait(lambda: [a for a in alerts(S["pkey"], state="resolved") if a["key"] == "health:freeswitch"], 90)
    check("FreeSWITCH started: resolved", fs_ok, f"after {time.time() - t0:.0f} s")

    # Brute force on an extension: one phone, wrong password, ten times.
    do(cmd="phone", name="bad", ip="127.0.0.101", user="101", domain=S["domain"], password="wrong-password")
    for _ in range(12):
        do(cmd="register", name="bad")
    bf = wait(lambda: [a for a in alerts(S["tkey"]) if a["key"] == "sip_auth:127.0.0.101"], 30)
    check("wrong SIP passwords: Kamailio bans the phone, the tenant gets a brute-force alert", bf and S["domain"] in bf[0]["message"], bf[0]["message"] if bf else "none")
finally:
    subprocess.run(SSH + ["sudo systemctl start freeswitch"])
    for p in (ua, carrier):
        p.terminate()
    app('''for b <- QPBX.Edge.list_bans(), String.starts_with?(b.key, "127.0.0.101"), do: QPBX.Edge.lift_ban(b.key, {:system, "lab"})
''' + CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
