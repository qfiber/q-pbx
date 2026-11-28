#!/usr/bin/env python3
"""3-8 lab check: the notification service end to end on the lab server.

Through the API (nginx): a tenant adds two alert webhooks on the HTTPS receiver (generic and
Alertmanager format, both signed) and a shared recipient, then sends a test alert. Checked:
the tenant admin's portal notification (the bell's count), the real emails (SMTP to the lab's
catcher on the backup VM) to the admin and the shared recipient, a hard bounce, the signed
webhooks in both formats; the email's acknowledge link opened through nginx (a page, then the
button) acknowledges the alert and tells the generic webhook; resolving through the API sends
"back to normal" by email and both webhooks.

usage: phase3-alerts.py <vm-ip> <receiver-vm-ip>
"""
import email, hashlib, hmac, html, json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from http.cookiejar import CookieJar

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts"]
BASE = "https://portal.pbx.lab.test"
PORT, SMTP, MAILDIR = 18443, 2525, "/tmp/qpbx-mail"
RUN = format(int(time.time()), "x")
SLUG = f"al-{RUN}"
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
        raw = e.read()
        return e.code, json.loads(raw) if raw else None


def rx(cmd):
    return subprocess.run(SSH + [f"debian@{RX}", cmd], capture_output=True, text=True).stdout


def hooks():
    out = rx(f"curl -s --cacert /tmp/qpbx-receiver.pem https://{RX}:{PORT}/_seen")
    return json.loads(out or "[]")


def mails():
    names = rx(f"ls {MAILDIR} 2>/dev/null").split()
    out = []
    for n in names:
        raw = rx(f"cat {MAILDIR}/{n}")
        rcpt, _, rest = raw.partition("\n")
        msg = email.message_from_string(rest)
        body = msg.get_payload(decode=True)
        out.append({"to": rcpt.split(": ", 1)[1], "subject": str(email.header.make_header(email.header.decode_header(msg["Subject"]))), "body": (body or b"").decode(errors="replace")})
    rx(f"rm -f {MAILDIR}/*")
    return out


def wait(fun, secs=20):
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


CLEANUP = 'for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "al-"), do: QPBX.Repo.delete!(t)'
S = app(CLEANUP + f'''
alias QPBX.Core
a = {{:system, "lab"}}
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(Core.list_plans()).id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "admin-{RUN}@acme.test", name: "Admin"}}, "tenant_admin", a)
{{:ok, _, key}} = Core.create_api_key(Core.scope_for(u), %{{name: "al", scopes: ["read", "write", "admin"]}}, a)
IO.puts("JSON" <> Jason.encode!(%{{key: key, user: u.id, email: u.email}}))
''')

subprocess.run(["sh", os.path.join(HERE, "..", "tools", "lab-ca.sh"), RX], capture_output=True, check=True)
for name, src in [("qpbx-receiver.py", os.path.join(HERE, "..", "tools", "http_receiver.py")), ("qpbx-smtp-sink.py", os.path.join(HERE, "..", "tools", "smtp_sink.py")),
                  ("qpbx-receiver.pem", f"{LAB}/lab-ca/receiver.pem"), ("qpbx-receiver.key", f"{LAB}/lab-ca/receiver.key")]:
    subprocess.run(SSH + [f"debian@{RX}", f"umask 077; cat > /tmp/{name}"], input=open(src).read(), text=True)
rx("pkill -f qpbx-receiver.py; pkill -f qpbx-smtp-sink.py")  # leftovers of an interrupted run
web = subprocess.Popen(SSH + [f"debian@{RX}", f"exec python3 -u /tmp/qpbx-receiver.py {PORT} /tmp/qpbx-receiver.pem /tmp/qpbx-receiver.key"])
smtp = subprocess.Popen(SSH + [f"debian@{RX}", f"rm -rf {MAILDIR}; exec python3 -u /tmp/qpbx-smtp-sink.py {SMTP} {MAILDIR}"])

try:
    time.sleep(1.5)
    hooks()
    st, b1 = api("POST", "/v1/alert-channels", {"kind": "webhook", "address": f"https://{RX}:{PORT}/generic", "categories": ["security"]})
    st2, b2 = api("POST", "/v1/alert-channels", {"kind": "webhook", "address": f"https://{RX}:{PORT}/am", "categories": ["security"], "format": "alertmanager"})
    st3, _ = api("POST", "/v1/alert-channels", {"kind": "email", "address": f"it-{RUN}@acme.test", "categories": ["security"]})
    st4, _ = api("POST", "/v1/alert-channels", {"kind": "email", "address": f"gone-{RUN}@bounce.test", "categories": ["security"]})
    check("two alert webhooks and two shared recipients added through the API", [st, st2, st3, st4] == [201] * 4, [st, st2, st3, st4])
    st, body = api("POST", "/v1/alert-channels", {"kind": "webhook", "address": "https://127.0.0.1/x", "categories": ["security"]})
    check("an alert webhook aimed at an internal address is refused", st == 422 and "internal" in json.dumps(body), st)
    g_secret, am_secret = b1["secret"], b2["secret"]

    # A test alert, critical so email goes out.
    st, body = api("POST", "/v1/alerts/test", {"category": "security"})
    alert_id = (body or {}).get("data", {}).get("id")
    check("test alert raised", st == 201 and alert_id, st)

    got = wait(lambda: (lambda h: h if len(h) >= 2 else None)(hooks()))
    gen = [x for x in got or [] if x["path"] == "/generic"]
    am = [x for x in got or [] if x["path"] == "/am"]
    gbody = json.loads(gen[0]["body"]) if gen else {}
    ambody = json.loads(am[0]["body"]) if am else {}
    check("generic webhook: alert.raised, signed", gen and gbody.get("type") == "alert.raised" and gbody["alert"]["id"] == alert_id and signed(gen[0], g_secret))
    check("Alertmanager webhook: firing, signed, its labels", am and ambody.get("status") == "firing" and ambody["alerts"][0]["labels"]["category"] == "security" and signed(am[0], am_secret))

    unread = app(f'IO.puts("JSON" <> Jason.encode!(QPBX.Notify.unread_count(QPBX.Core.get_user("{S["user"]}"))))')
    check("the tenant admin's bell shows the notification", unread >= 1, unread)

    # The test alert is info by default; send a critical one so people get email too.
    app(f'''{{:ok, _}} = QPBX.Notify.raise_alert(%{{kind: "fraud_block", key: "lab-{RUN}", tenant_id: QPBX.Core.get_user("{S["user"]}").tenant_id, title: "Outbound calls blocked", message: "A fraud rule blocked outbound calls (lab test)."}})
IO.puts("JSON{{}}")''')
    inbox = wait(lambda: (lambda m: m if len(m) >= 2 else None)(mails()), 30) or []
    to_admin = [m for m in inbox if m["to"] == S["email"]]
    to_it = [m for m in inbox if m["to"].startswith("it-")]
    check("real email to the tenant admin, with an acknowledge link", to_admin and to_admin[0]["subject"] == "[Critical] Outbound calls blocked" and "/alerts/ack/" in to_admin[0]["body"], [m["subject"] for m in inbox])
    check("real email to the shared recipient it@", len(to_it) >= 1, len(to_it))
    st, alerts = api("GET", "/v1/alerts?severity=critical")
    crit = (alerts or {}).get("data", [{}])[0]
    st, log = api("GET", f"/v1/alerts/{crit.get('id')}/notifications")
    statuses = sorted((n["channel"], n["status"], (n["address"] or "")[:5]) for n in (log or {}).get("data", []))
    bounced = [n for n in (log or {}).get("data", []) if (n["address"] or "").endswith("@bounce.test")]
    check("the hard bounce is caught and logged", bounced and bounced[0]["status"] == "bounced", statuses)
    check("the delivery log shows the emails sent and the webhooks", ("email", "sent", "admin") in statuses and ("webhook", "sent", "https") in statuses, statuses)

    # Acknowledge from the email: the page, then its button (a POST with the page's form token).
    hooks()
    link = re.search(r"(https://\S+/alerts/ack/\S+)", to_admin[0]["body"]).group(1) if to_admin else ""
    path = urllib.parse.urlparse(link).path
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()), urllib.request.HTTPSHandler(context=CTX))
    page = opener.open(BASE + path, timeout=10).read().decode()
    token = re.search(r'name="_csrf_token"[^>]*value="([^"]+)"', page)
    done = opener.open(urllib.request.Request(BASE + path, data=urllib.parse.urlencode({"_csrf_token": html.unescape(token.group(1)) if token else ""}).encode(), method="POST"), timeout=10).read().decode()
    st, a = api("GET", f"/v1/alerts/{crit.get('id')}")
    ad = (a or {}).get("data") or {}
    check("acknowledged from the email link through nginx", 'id="ack-done"' in done and ad.get("state") == "acknowledged" and (ad.get("acknowledged_by") or "").startswith("email:"),
          f"{st} {ad.get('state') or a} {'done' if 'ack-done' in done else done[-300:]}")
    got = wait(lambda: hooks() or None, 15) or []
    check("the generic webhook hears alert.acknowledged", any(json.loads(x["body"]).get("type") == "alert.acknowledged" for x in got if x["path"] == "/generic"))

    st, _ = api("POST", f"/v1/alerts/{crit.get('id')}/resolve")
    got = wait(lambda: (lambda h: h if len(h) >= 2 else None)(hooks()), 20) or []
    inbox = wait(lambda: mails() or None, 30) or []
    check("resolved: back to normal by email", any(m["subject"] == "Back to normal: Outbound calls blocked" and m["to"] == S["email"] for m in inbox), [m["subject"] for m in inbox])
    check("resolved: alert.resolved (generic) and status resolved (Alertmanager)",
          any(json.loads(x["body"]).get("type") == "alert.resolved" for x in got if x["path"] == "/generic")
          and any(json.loads(x["body"]).get("status") == "resolved" for x in got if x["path"] == "/am"))
finally:
    web.terminate()
    smtp.terminate()
    rx(f"pkill -f qpbx-receiver.py; pkill -f qpbx-smtp-sink.py; rm -rf /tmp/qpbx-receiver.* /tmp/qpbx-smtp-sink.py {MAILDIR}")
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
