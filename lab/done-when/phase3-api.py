#!/usr/bin/env python3
"""3-1 and 3-2 lab check: the /v1 API through nginx on the lab server. API keys (scopes,
expiry, revocation), another tenant's key gets nothing, idempotent POSTs, cursor pages, the
plan's rate limit, the OpenAPI document and the explorer under the portal's CSP; then the
resources (3-2): a tenant made through the API, a number pointed at an extension, a device
added through the API that registers over SIP with the password the API returned, a greeting
upload, a voicemail played through its short-lived link, the CSV export, users, routes.

usage: phase3-api.py <vm-ip>   (portal.pbx.lab.test must resolve to the server)
"""
import json, os, re, shlex, ssl, subprocess, sys, time, urllib.error, urllib.request

VM = sys.argv[1]
BASE = "https://portal.pbx.lab.test"
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE  # the lab's self-signed certificate
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


def req(method, path, key=None, body=None, headers=None):
    h = {"accept": "application/json", **(headers or {})}
    if key:
        h["authorization"] = "Bearer " + key
    data = None
    if body is not None:
        data, h["content-type"] = json.dumps(body).encode(), "application/json"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=10) as res:
            raw = res.read()
            return res.status, res.headers, raw  # case-insensitive lookups
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def j(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return {}


CLEANUP = '''
alias QPBX.Core
for t <- Core.list_tenants(), String.starts_with?(t.slug, "api-"), do: QPBX.Repo.delete!(t)
for pl <- Core.list_plans(), String.starts_with?(pl.name, "api-"), do: QPBX.Repo.delete!(pl)
p = %Core.Scope{kind: :platform}
for k <- Core.list_api_keys(p), String.starts_with?(k.name, "api-"), do: Core.revoke_api_key(p, k.id, {:system, "lab"})
for d <- Core.list_dids(p), String.starts_with?(d.number, "+97239"), do: Core.delete_did(p, d, {:system, "lab"})
for tr <- Core.list_trunks(p), String.starts_with?(tr.name, "api-"), do: Core.delete_trunk(p, tr, {:system, "lab"})
'''

S = app(CLEANUP + f'''
a = {{:system, "lab"}}
{{:ok, open}} = Core.create_plan(%{{name: "api-open-{RUN}"}}, a)
{{:ok, tight}} = Core.create_plan(%{{name: "api-tight-{RUN}", api_rate_limit_per_minute: 3}}, a)
mk = fn slug, plan ->
  {{:ok, t}} = Core.create_tenant(%{{name: slug, slug: slug, timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
  {{:ok, u}} = Core.create_user(t, %{{email: slug <> "@x.test", name: "A"}}, "tenant_admin", a)
  Core.scope_for(u)
end
sa = mk.("api-a-{RUN}", open)
sb = mk.("api-b-{RUN}", tight)
key = fn scope, scopes -> {{:ok, _, tok}} = Core.create_api_key(scope, %{{name: "api-k", scopes: scopes}}, a); tok end
for n <- ~w(101 102 103), do: {{:ok, _}} = Core.create_extension(sa, %{{number: n, name: "A" <> n}}, a)
{{:ok, b101}} = Core.create_extension(sb, %{{number: "101", name: "B101"}}, a)
IO.puts("JSON" <> Jason.encode!(%{{a_rw: key.(sa, ["read", "write"]), a_ro: key.(sa, ["read"]),
  b: key.(sb, ["read"]), b2: key.(sb, ["read"]), plat: key.(%Core.Scope{{kind: :platform}}, ["read"]),
  a_admin: key.(sa, ["read", "write", "admin"]), plat_rw: key.(%Core.Scope{{kind: :platform}}, ["read", "write", "admin"]),
  plan_open: open.id, tid_a: sa.tenant_id, domain_a: Core.my_tenant(sa).sip_domain,
  b101: b101.id, slug_a: "api-a-{RUN}"}}))
''')

try:
    status, headers, raw = req("GET", "/v1/openapi.json")
    doc = j(raw)
    check("OpenAPI document served", status == 200 and doc.get("openapi") == "3.1.0" and "/v1/extensions" in doc.get("paths", {}), status)

    status, headers, raw = req("GET", "/v1/docs", headers={"accept": "text/html"})
    csp = headers.get("content-security-policy", "")
    src = re.search(rb'src="(/assets/js/api_explorer[^"]*)"', raw)
    check("explorer page under the CSP (scripts from this site only)", status == 200 and "script-src 'self'" in csp and src, csp[:40])
    check("explorer script served by the app", src and req("GET", src.group(1).decode())[0] == 200)

    check("no key: 401", req("GET", "/v1/me")[0] == 401)
    status, _, raw = req("GET", "/v1/me", key="qpbx_wrong")
    check("wrong key: 401 in the error format", status == 401 and j(raw).get("error", {}).get("code") == "unauthorized")
    status, _, raw = req("GET", "/v1/me", key=S["a_rw"])
    check("tenant key: /v1/me", status == 200 and j(raw)["data"]["kind"] == "tenant" and j(raw)["data"]["scopes"] == ["read", "write"])

    body = {"number": "150", "name": "Made by the API"}
    s1, h1, r1 = req("POST", "/v1/extensions", S["a_rw"], body, {"idempotency-key": "lab-" + RUN})
    s2, h2, r2 = req("POST", "/v1/extensions", S["a_rw"], body, {"idempotency-key": "lab-" + RUN})
    check("POST creates an extension (201)", s1 == 201 and j(r1)["data"]["number"] == "150", s1)
    check("same Idempotency-Key: same response, replayed", s2 == 201 and r1 == r2 and h2.get("idempotent-replayed") == "true")
    s3, _, r3 = req("POST", "/v1/extensions", S["a_rw"], {"number": "151", "name": "x"}, {"idempotency-key": "lab-" + RUN})
    check("same key, other body: refused", s3 == 422 and j(r3)["error"]["code"] == "idempotency_key_reused")

    numbers, cursor, pages = [], None, 0
    while True:
        path = "/v1/extensions?limit=1" + (f"&cursor={cursor}" if cursor else "")
        status, _, raw = req("GET", path, S["a_rw"])
        page = j(raw)
        numbers += [e["number"] for e in page.get("data", [])]
        pages += 1
        cursor = page.get("next_cursor")
        if not cursor or pages > 10:
            break
    check("cursor pages walk every extension once", sorted(numbers) == ["101", "102", "103", "150"] and pages == 4, numbers)

    status, _, raw = req("POST", "/v1/extensions", S["a_ro"], {"number": "152", "name": "x"})
    check("read-only key cannot write (403 missing_scope)", status == 403 and j(raw)["error"]["code"] == "missing_scope")
    status, _, raw = req("POST", "/v1/extensions", S["a_rw"], {"number": "0", "name": "x"})
    check("invalid fields: 422 with details", status == 422 and "number" in j(raw)["error"].get("details", {}))

    status, _, raw = req("GET", f"/v1/extensions/{S['b101']}", S["a_rw"])
    check("tenant A's key: tenant B's extension is not found", status == 404 and j(raw)["error"]["code"] == "not_found")
    status, _, raw = req("GET", "/v1/extensions", S["b"])
    check("tenant B's key lists only B's extensions", status == 200 and [e["name"] for e in j(raw)["data"]] == ["B101"])

    check("tenant key on a platform endpoint: 403", req("GET", "/v1/tenants", S["a_rw"])[0] == 403)
    status, _, raw = req("GET", "/v1/tenants?limit=200", S["plat"])
    check("platform key lists tenants", status == 200 and S["slug_a"] in [t["slug"] for t in j(raw)["data"]])
    check("platform key on a tenant endpoint: 403", req("GET", "/v1/extensions", S["plat"])[0] == 403)

    codes = [req("GET", "/v1/me", S["b2"]) for _ in range(4)]
    check("plan limit 3/min: fourth request 429 with retry-after",
          [c[0] for c in codes] == [200, 200, 200, 429] and codes[3][1].get("retry-after") and codes[0][1].get("x-ratelimit-limit") == "3",
          [c[0] for c in codes])

    # 3-2: resources
    P, A = S["plat_rw"], S["a_admin"]
    status, _, raw = req("POST", "/v1/tenants", P, {"name": "API made", "slug": f"api-c-{RUN}", "timezone": "Asia/Jerusalem", "locale": "ar",
                                                    "plan_id": S["plan_open"], "admin": {"name": "Boss", "email": f"api-c-{RUN}@x.test"}})
    tc = j(raw).get("data", {})
    check("platform: tenant created with its admin", status == 201 and tc.get("sip_domain", "").startswith(f"api-c-{RUN}."), status)
    status, _, raw = req("GET", f"/v1/tenants/{tc.get('id')}/users", P)
    check("platform: the new tenant's admin is listed", status == 200 and [u["role"] for u in j(raw)["data"]] == ["tenant_admin"])
    check("platform: tenant renamed", req("PATCH", f"/v1/tenants/{tc.get('id')}", P, {"name": "Renamed"})[0] == 200)

    status, _, raw = req("POST", "/v1/trunks", P, {"name": f"api-t-{RUN}", "auth_mode": "ip", "addresses": [{"host": "127.0.0.99"}]})
    trunk = j(raw).get("data", {})
    status, _, raw = req("POST", "/v1/numbers", P, {"number": "+97239" + str(int(time.time()))[-6:], "trunk_id": trunk.get("id")})
    num = j(raw).get("data", {})
    check("platform: trunk and number added", trunk.get("id") and status == 201, status)
    check("platform: number assigned to tenant A", req("PATCH", f"/v1/numbers/{num.get('id')}", P, {"tenant_id": S["tid_a"]})[0] == 200)

    status, _, raw = req("POST", "/v1/extensions", A, {"number": "160", "name": "Via API"})
    ext = j(raw).get("data", {})
    status, _, raw = req("PUT", f"/v1/numbers/{num.get('id')}/destination", A, {"destination_type": "extension", "destination_id": ext.get("id")})
    check("tenant: number pointed at its extension", status == 200 and j(raw)["data"]["destination_id"] == ext.get("id"))
    status, _, raw = req("PATCH", f"/v1/extensions/{ext.get('id')}", A, {"dnd": True})
    check("tenant: extension changed", status == 200 and j(raw)["data"]["dnd"] is True)

    status, _, raw = req("POST", f"/v1/extensions/{ext.get('id')}/devices", A, {"label": "", "kind": "softphone"})
    dev = j(raw)
    reg = subprocess.run(["python3", os.path.join(os.path.dirname(__file__), "..", "tools", "sip_register.py"), VM, "160", S["domain_a"], dev.get("sip_password", "")],
                         capture_output=True, text=True).stdout.strip()
    check("device added through the API registers over SIP with the returned password", status == 201 and "200" in reg, reg)
    status, _, raw = req("POST", f"/v1/devices/{dev['data']['id']}/reset-password", A)
    old = subprocess.run(["python3", os.path.join(os.path.dirname(__file__), "..", "tools", "sip_register.py"), VM, "160", S["domain_a"], dev.get("sip_password", "")],
                         capture_output=True, text=True).stdout.strip()
    check("after a reset through the API the old password is refused", status == 200 and "200" not in old, old)

    status, _, raw = req("PUT", f"/v1/extensions/{ext.get('id')}/mailbox", A, {"pin": "4831"})
    check("mailbox set up through the API", status == 200 and j(raw)["data"]["enabled"] is True and "pin_hash" not in j(raw)["data"])
    mp3 = b"ID3\x04\x00\x00\x00\x00\x00\x00" + b"\x09" * 2000
    r = urllib.request.Request(BASE + f"/v1/extensions/{ext.get('id')}/greetings/unavailable", data=mp3, method="PUT",
                               headers={"authorization": "Bearer " + A, "content-type": "audio/mpeg"})
    try:
        up = urllib.request.urlopen(r, context=CTX, timeout=10).status
    except urllib.error.HTTPError as e:
        up = e.code
    status, _, raw = req("GET", f"/v1/extensions/{ext.get('id')}/greetings", A)
    check("greeting uploaded through nginx", up == 204 and j(raw)["data"] == ["unavailable"], up)

    vm_id = app(f'''
s = %QPBX.Core.Scope{{kind: :tenant, tenant_id: "{S['tid_a']}"}}
mb = QPBX.Telephony.mailbox(s, "{ext.get('id')}")
{{:ok, m}} = QPBX.Telephony.Voicemail.store_system(mb, File.read!("/usr/share/qpbx/sounds/en/us/callie/voicemail/8000/vm-hello.wav"), %{{caller_number: "+972501111111", caller_name: "Lab", duration: 1, format: "wav"}})
IO.puts("JSON" <> Jason.encode!(%{{id: m.id}}))
''')["id"]
    status, _, raw = req("GET", f"/v1/voicemails?extension_id={ext.get('id')}", A)
    check("voicemail listed", status == 200 and [m["id"] for m in j(raw)["data"]] == [vm_id])
    status, _, raw = req("POST", f"/v1/voicemails/{vm_id}/audio-link", A)
    link = j(raw).get("url", "")
    s1, h1, audio = req("GET", link.replace(BASE, "")) if link.startswith(BASE) else (0, {}, b"")
    check("voicemail plays from its link without a key", s1 == 200 and audio[:4] == b"RIFF" and h1.get("content-type", "").startswith("audio/wav"), link[:40])
    check("a tampered link is refused", req("GET", link.replace(BASE, "") + "x")[0] == 404)
    check("voicemail marked heard", req("POST", f"/v1/voicemails/{vm_id}/save", A)[0] == 204)
    check("mailbox deleted with its files", req("DELETE", f"/v1/extensions/{ext.get('id')}/mailbox", A)[0] == 204)

    status, headers, raw = req("GET", "/v1/calls/export", A, headers={"accept": "text/csv"})
    check("call records exported as CSV through nginx", status == 200 and headers.get("content-type", "").startswith("text/csv") and raw.startswith(b"started_at,"), status)
    status, _, raw = req("GET", "/v1/calls?limit=5", A)
    check("call records listed", status == 200 and "next_cursor" in j(raw))
    check("daily usage", req("GET", "/v1/usage/daily", A)[0] == 200)

    status, _, raw = req("POST", "/v1/users", A, {"name": "Dana", "email": f"api-u-{RUN}@x.test", "extension_id": ext.get("id")})
    u = j(raw).get("data", {})
    check("user invited with their extension", status == 201 and u.get("extension_id") == ext.get("id"))
    check("user made an admin", req("PATCH", f"/v1/users/{u.get('id')}", A, {"role": "tenant_admin"})[0] == 200)
    check("user removed", req("DELETE", f"/v1/users/{u.get('id')}", A)[0] == 204)
    check("users need the admin scope", req("GET", "/v1/users", S["a_rw"])[0] == 403)

    status, _, raw = req("POST", "/v1/routes", A, {"name": "all", "prefixes": [], "destination_class": "local", "trunk_ids": [trunk.get("id")]})
    route = j(raw).get("data", {})
    check("route created with its trunk", status == 201 and route.get("trunk_ids") == [trunk.get("id")])
    check("route deleted", req("DELETE", f"/v1/routes/{route.get('id')}", A)[0] == 204)
    status, _, raw = req("GET", "/v1/audit?limit=200", A)
    check("tenant audit log through the API", status == 200 and any(e["actor_type"] == "api_key" for e in j(raw)["data"]))

    audit = app(f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{S['slug_a']}"))
e = QPBX.Core.list_audit_logs(tenant_id: t.id) |> Enum.find(&(&1.action == "extension.create" and &1.actor_type == "api_key"))
IO.puts("JSON" <> Jason.encode!(%{{found: e != nil}}))
''')
    check("audit log names the API key as the actor", audit["found"])

    app(f'''
{{:ok, k}} = QPBX.Core.authenticate_api_key("{S['a_ro']}")
QPBX.Repo.update!(Ecto.Changeset.change(k, expires_at: ~U[2020-01-01 00:00:00Z]))
{{:ok, k}} = QPBX.Core.authenticate_api_key("{S['a_rw']}")
s = QPBX.Core.scope_for(k)
{{:ok, _}} = QPBX.Core.revoke_api_key(s, k.id, {{:system, "lab"}})
IO.puts("JSON{{}}")
''')
    status, _, raw = req("GET", "/v1/me", S["a_ro"])
    check("expired key: 401 key_expired", status == 401 and j(raw)["error"]["code"] == "key_expired")
    check("revoked key: 401 on the next request", req("GET", "/v1/me", S["a_rw"])[0] == 401)
finally:
    app(CLEANUP + '\nIO.puts("JSON{}")')

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
