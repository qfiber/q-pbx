#!/usr/bin/env python3
"""3-5 lab check: webhooks for real calls and registrations, over HTTPS to a receiver on the
backup VM (certificate from the lab CA, lab/tools/lab-ca.sh). Endpoints are made through the
API (nginx); one aimed at an internal address is refused. Each delivery's signature is
checked with the endpoint's secret, and its delivery time measured: the receiver's arrival
time minus the event's time, with the two machines' clock difference taken out.
A second endpoint answers 500: its delivery is retried and logged.

usage: phase3-webhooks.py <vm-ip> <receiver-vm-ip>
"""
import hashlib, hmac, json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request
from datetime import datetime

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts"]
BASE = "https://portal.pbx.lab.test"
PORT = 18443
RUN = format(int(time.time()), "x")
SLUG = f"wh-{RUN}"
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE  # the portal's self-signed lab certificate
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def app(code):
    p = subprocess.run(SSH + [f"debian@{VM}", "sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], capture_output=True, text=True)
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + p.stdout + p.stderr)
    return json.loads(m.group(1))


def api(method, path, key, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method,
                               headers={"authorization": "Bearer " + key, "content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def clock(host):
    """The host's clock minus this machine's, from the midpoint of a round trip (best of 3)."""
    best = None
    for _ in range(3):
        t1 = time.time()
        there = float(subprocess.run(SSH + [f"debian@{host}", "date +%s.%N"], capture_output=True, text=True).stdout)
        t2 = time.time()
        if best is None or t2 - t1 < best[0]:
            best = (t2 - t1, there - (t1 + t2) / 2)
    return best[1]


CLEANUP = 'for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "wh-"), do: QPBX.Repo.delete!(t)'
S = app(CLEANUP + f'''
alias QPBX.Core
a = {{:system, "lab"}}
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(Core.list_plans()).id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
pw = for n <- ~w(101 102), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n}}, a)
  {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
  {{n, pw}}
end
{{:ok, _, key}} = Core.create_api_key(s, %{{name: "wh", scopes: ["read", "write", "admin"]}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw, key: key}}))
''')

subprocess.run(["sh", os.path.join(HERE, "..", "tools", "lab-ca.sh"), RX], capture_output=True, check=True)
for name, src in [("qpbx-receiver.py", os.path.join(HERE, "..", "tools", "http_receiver.py")),
                  ("qpbx-receiver.pem", f"{LAB}/lab-ca/receiver.pem"), ("qpbx-receiver.key", f"{LAB}/lab-ca/receiver.key")]:
    subprocess.run(SSH + [f"debian@{RX}", f"umask 077; cat > /tmp/{name}"], input=open(src).read(), text=True)
rx = subprocess.Popen(SSH + [f"debian@{RX}", f"exec python3 -u /tmp/qpbx-receiver.py {PORT} /tmp/qpbx-receiver.pem /tmp/qpbx-receiver.key"])
subprocess.run(SSH + [f"debian@{VM}", "cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(HERE, "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + [f"debian@{VM}", "python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def seen():
    out = subprocess.run(SSH + [f"debian@{RX}", f"curl -s --cacert /tmp/qpbx-receiver.pem https://{RX}:{PORT}/_seen"], capture_output=True, text=True).stdout
    return json.loads(out or "[]")


try:
    time.sleep(1)
    K = S["key"]
    status, body = api("POST", "/v1/webhooks", K, {"url": "https://127.0.0.1/hook", "event_types": ["call.started"]})
    check("an endpoint aimed at an internal address is refused", status == 422 and "internal" in json.dumps(body), status)
    status, body = api("POST", "/v1/webhooks", K, {"url": f"http://{RX}:{PORT}/hook", "event_types": ["call.started"]})
    check("an http:// endpoint is refused", status == 422 and "https" in json.dumps(body), status)

    types = ["call.started", "call.ringing", "call.answered", "call.ended", "extension.registered"]
    status, body = api("POST", "/v1/webhooks", K, {"url": f"https://{RX}:{PORT}/hook", "event_types": types})
    check("HTTPS endpoint on the receiver added through the API", status == 201, status)
    secret, hook = body.get("secret", ""), body.get("data", {}).get("id")
    status, body = api("POST", "/v1/webhooks", K, {"url": f"https://{RX}:{PORT}/fail", "event_types": ["call.started"]})
    fail = body.get("data", {}).get("id")
    seen()

    offset = clock(RX) - clock(VM)  # receiver's clock minus the server's
    for name, ip, user in [("w101", "127.0.0.80", "101"), ("w102", "127.0.0.81", "102")]:
        do(cmd="phone", name=name, ip=ip, user=user, domain=S["domain"], password=S["pw"][user])
    r = do(cmd="call", **{"from": "w101", "to": "102", "wait": 10})
    check("a real call 101 -> 102, answered", r.get("status") == "200", r.get("status"))
    time.sleep(3)

    got = [x for x in seen() if x["path"] == "/hook"]
    events = [(json.loads(x["body"]), x) for x in got]
    calls = [e["type"] for e, _ in events if e["type"].startswith("call.")]
    regs = [e["data"]["device"] for e, _ in events if e["type"] == "extension.registered"]
    check("registrations delivered: extension.registered for 101 and 102", sorted(regs) == ["101", "102"], regs)
    check("call events delivered in order: started, ringing, answered, ended", calls == ["call.started", "call.ringing", "call.answered", "call.ended"], calls)

    def valid(x):
        h = {k.lower(): v for k, v in x["headers"].items()}
        mac = hmac.new(secret.encode(), f'{h["x-qpbx-timestamp"]}.{x["body"]}'.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest("v1=" + mac, h["x-qpbx-signature"]) and h["x-qpbx-event-id"] == json.loads(x["body"])["id"]

    check("every delivery signed with the endpoint's secret", got and all(valid(x) for x in got), len(got))

    latencies = [x["at"] - offset - datetime.fromisoformat(e["created_at"].replace("Z", "+00:00")).timestamp() for e, x in events]
    worst = max(latencies) if latencies else 99
    check("each delivered within 1 second of its event", worst < 1.0,
          f"min {min(latencies) * 1000:.0f} ms, max {worst * 1000:.0f} ms, clock offset {offset * 1000:.0f} ms" if latencies else "none")

    status, body = api("GET", f"/v1/webhooks/{fail}/deliveries", K)
    d = (body or {}).get("data", [{}])[0] if status == 200 and body.get("data") else {}
    check("the 500 endpoint's delivery is kept for retry, its attempt logged",
          d.get("status") == "pending" and d.get("attempts") and d["attempts"][0].get("status") == 500, d.get("status"))
    status, body = api("GET", f"/v1/webhooks/{hook}/deliveries?limit=50", K)
    check("the receiver's deliveries are logged delivered", status == 200 and body["data"] and all(x["status"] == "delivered" for x in body["data"]), status)
    print(f"\nWebhook delivery time (event to receiver): min {min(latencies) * 1000:.0f} ms, max {worst * 1000:.0f} ms over {len(latencies)} deliveries")
finally:
    ua.terminate()
    rx.terminate()
    subprocess.run(SSH + [f"debian@{RX}", "pkill -f qpbx-receiver.py; rm -f /tmp/qpbx-receiver.*"], capture_output=True)
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
