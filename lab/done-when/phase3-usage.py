#!/usr/bin/env python3
"""Phase 3 done-when, the usage condition: a tenant crossing 80% of its minutes gets the email
and the alert webhook with minutes remaining.

A tenant on a plan of 1 outbound minute a month (thresholds 80 and 100) adds an alert webhook
for usage (signed, on the HTTPS receiver on the backup VM) and a webhook for
usage.threshold_reached, both through the API. A real outbound call of 52 seconds through a
simulated carrier crosses 80%. Checked: the real email to the tenant admin (SMTP to the lab's
catcher), the signed alert webhook and the signed usage webhook, each with the minutes left.

usage: phase3-usage.py <vm-ip> <receiver-vm-ip>   (about two minutes)
"""
import email, hashlib, hmac, json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts"]
BASE = "https://portal.pbx.lab.test"
PORT, SMTP, MAILDIR = 18443, 2525, "/tmp/qpbx-mail"
RUN = format(int(time.time()), "x")
SLUG = f"use-{RUN}"
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


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers={"authorization": "Bearer " + S["key"], "content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as res:
            raw = res.read()
            return res.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code, None


def rx(cmd):
    return subprocess.run(SSH + [f"debian@{RX}", cmd], capture_output=True, text=True).stdout


def wait(fun, secs):
    end = time.time() + secs
    while time.time() < end:
        v = fun()
        if v:
            return v
        time.sleep(1)
    return fun()


def signed(x, secret):
    h = {k.lower(): v for k, v in x["headers"].items()}
    mac = hmac.new(secret.encode(), f'{h["x-qpbx-timestamp"]}.{x["body"]}'.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest("v1=" + mac, h["x-qpbx-signature"])


CLEANUP = '''
alias QPBX.Core
p = %Core.Scope{kind: :platform}
for t <- Core.list_tenants(), String.starts_with?(t.slug, "use-"), do: QPBX.Repo.delete!(t)
for tr <- Core.list_trunks(p), String.starts_with?(tr.name, "use-"), do: Core.delete_trunk(p, tr, {:system, "lab"})
for pl <- Core.list_plans(), String.starts_with?(pl.name, "use-"), do: QPBX.Repo.delete!(pl)
'''

S = app(CLEANUP + f'''
a = {{:system, "lab"}}
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}", outbound_minutes_per_month: 1, usage_thresholds: [80, 100], allowed_destination_classes: ["local", "mobile"]}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "admin-{RUN}@acme.test", name: "Admin"}}, "tenant_admin", a)
s = Core.scope_for(u)
{{:ok, e}} = Core.create_extension(s, %{{number: "101", name: "Ext 101"}}, a)
{{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
{{:ok, trunk}} = Core.create_trunk(p, %{{name: "use-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.37", port: 5097}}]}}, a)
{{:ok, _}} = Core.create_route(s, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [trunk.id]}}, a)
{{:ok, _, key}} = Core.create_api_key(s, %{{name: "use", scopes: ["read", "write", "admin"]}}, a)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw, key: key, email: u.email}}))
''')

subprocess.run(["sh", os.path.join(HERE, "..", "tools", "lab-ca.sh"), RX], capture_output=True, check=True)
for name, src in [("qpbx-receiver.py", os.path.join(HERE, "..", "tools", "http_receiver.py")), ("qpbx-smtp-sink.py", os.path.join(HERE, "..", "tools", "smtp_sink.py")),
                  ("qpbx-receiver.pem", f"{LAB}/lab-ca/receiver.pem"), ("qpbx-receiver.key", f"{LAB}/lab-ca/receiver.key")]:
    subprocess.run(SSH + [f"debian@{RX}", f"umask 077; cat > /tmp/{name}"], input=open(src).read(), text=True)
rx("pkill -f qpbx-receiver.py; pkill -f qpbx-smtp-sink.py")  # leftovers of an interrupted run
web = subprocess.Popen(SSH + [f"debian@{RX}", f"exec python3 -u /tmp/qpbx-receiver.py {PORT} /tmp/qpbx-receiver.pem /tmp/qpbx-receiver.key"])
smtp = subprocess.Popen(SSH + [f"debian@{RX}", f"rm -rf {MAILDIR}; exec python3 -u /tmp/qpbx-smtp-sink.py {SMTP} {MAILDIR}"])
subprocess.run(SSH + [f"debian@{VM}", "cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(HERE, "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + [f"debian@{VM}", "python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


try:
    st, alert_hook = api("POST", "/v1/alert-channels", {"kind": "webhook", "address": f"https://{RX}:{PORT}/alerts", "categories": ["usage"]})
    st2, usage_hook = api("POST", "/v1/webhooks", {"url": f"https://{RX}:{PORT}/usage", "event_types": ["usage.threshold_reached"]})
    check("an alert webhook for usage and a usage webhook added through the API", st == 201 and st2 == 201, [st, st2])

    do(cmd="carrier", name="carrier", ip="127.0.0.37", port=5097, mode="answer")
    do(cmd="phone", name="p101", ip="127.0.0.100", user="101", domain=S["domain"], password=S["pw"])
    time.sleep(60)  # the dispatcher marks the new carrier active (OPTIONS every 20 s)
    rx(f"curl -s --cacert /tmp/qpbx-receiver.pem https://{RX}:{PORT}/_seen")

    r = do(cmd="call", **{"from": "p101", "to": "+97221234567", "wait": 10, "hold": True})
    time.sleep(52)
    if r.get("dialog"):
        do(cmd="bye", dialog=r["dialog"])
    t_end = time.time()
    check("a real outbound call of 52 seconds, answered by the carrier", r.get("dialog"), r)

    hooks = []
    def seen():
        hooks.extend(json.loads(rx(f"curl -s --cacert /tmp/qpbx-receiver.pem https://{RX}:{PORT}/_seen") or "[]"))
        return {x["path"] for x in hooks} >= {"/alerts", "/usage"}
    wait(seen, 20)
    alerts = [x for x in hooks if x["path"] == "/alerts"]
    usage = [x for x in hooks if x["path"] == "/usage"]
    ab = json.loads(alerts[0]["body"]) if alerts else {}
    ub = json.loads(usage[0]["body"]) if usage else {}
    check("alert webhook: alert.raised, signed, 80% with the minutes left",
          alerts and ab.get("type") == "alert.raised" and "(80%)" in ab["alert"]["message"] and "left" in ab["alert"]["message"] and signed(alerts[0], alert_hook["secret"]),
          ab.get("alert", {}).get("message"))
    check("usage webhook: usage.threshold_reached, signed, percent 80, minutes used and allowed",
          usage and ub.get("type") == "usage.threshold_reached" and ub["data"]["percent"] == 80 and ub["data"]["allowed"] == 1 and signed(usage[0], usage_hook["secret"]),
          ub.get("data"))
    if alerts:
        print(f"   alert webhook {alerts[0]['at'] - t_end:.1f} s after the call ended")

    def inbox():
        out = []
        for n in rx(f"ls {MAILDIR} 2>/dev/null").split():
            rcpt, _, rest = rx(f"cat {MAILDIR}/{n}").partition("\n")
            msg = email.message_from_string(rest)
            body = msg.get_payload(decode=True) or b""
            out.append({"to": rcpt.split(": ", 1)[1], "subject": str(email.header.make_header(email.header.decode_header(msg["Subject"]))), "body": body.decode(errors="replace")})
        return [m for m in out if m["to"] == S["email"]]
    mails = wait(inbox, 30)
    check("real email to the tenant admin: 80% of outbound minutes, with the minutes left",
          mails and "80%" in mails[0]["subject"] and "minutes are left" in mails[0]["body"],
          (mails[0]["subject"] + " | " + re.sub(r"\s+", " ", mails[0]["body"])[:200]) if mails else "none")
finally:
    for p in (ua, web, smtp):
        p.terminate()
    rx(f"pkill -f qpbx-receiver.py; pkill -f qpbx-smtp-sink.py; rm -rf /tmp/qpbx-receiver.* /tmp/qpbx-smtp-sink.py {MAILDIR}")
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
