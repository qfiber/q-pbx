#!/usr/bin/env python3
"""Call tests with SIPp against a real Q-PBX (Kamailio, FreeSWITCH, the app): the CI container
(ci/calls/) or the lab VM. SIPp runs on the server, on loopback addresses, so Kamailio tells
phones from carriers by source address as it does in production. Setup and checks go through
`qpbx rpc`.

Covers: registration (right and wrong password), a call between extensions, two tenants with
the same extension numbers, an outbound call with carrier failover, a barred destination,
an inbound call to a number (DID), voicemail, and the call records of all of it.

usage: run.py <ssh destination> [ssh options...]
  CI:  run.py debian@127.0.0.1 -p 2222 -i KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
"""
import json, os, re, shlex, subprocess, sys, time

SSH = ["ssh", "-o", "IdentitiesOnly=yes", *sys.argv[2:], sys.argv[1]]
HERE = os.path.dirname(os.path.abspath(__file__))
RUN = format(int(time.time()), "x")
DID = "+9723" + str(int(time.time()))[-7:]
WORK = f"/tmp/qpbx-sipp-{RUN}"
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh(cmd, **kw):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True, **kw)


def app(code):
    p = ssh("sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code))
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + p.stdout + p.stderr)
    return json.loads(m.group(1))


def sipp(scenario, ip, port, service, sets=None, extra="", timeout=30, calls=1):
    """SIPp command line on the server (`calls` calls; 0: until the scenario stops itself)."""
    s = " ".join(f"-set {k} {shlex.quote(str(v))}" for k, v in (sets or {}).items())
    # -aa: answer Kamailio's OPTIONS pings (carriers) instead of taking them for a call.
    # The audio scenario plays a pcap through a raw socket, which needs root.
    sudo = "sudo " if scenario.endswith("_audio") else ""
    return (f"cd {WORK} && timeout {timeout + 10} {sudo}sipp 127.0.0.1:5060 -aa -sf {scenario}.xml -i {ip} -p {port} "
            f"-mi {ip} -s {shlex.quote(service)} {s} {f'-m {calls}' if calls else ''} -timeout {timeout}s -timeout_error -nostdin "
            f"-trace_logs -log_file {WORK}/{service}-{ip}.log -trace_msg -message_file {WORK}/{service}-{ip}.msg "
            f"{extra} >/dev/null 2>&1; echo EXIT $?")


def messages(name, ip):
    """First lines of the SIP messages a SIPp instance sent and received (for failures)."""
    out = ssh(f"grep -E '^(SIP/2.0 [0-9]|[A-Z]+ sip:)' {WORK}/{name}-{ip}.msg 2>/dev/null | head -20").stdout
    return " | ".join(out.split("\n")).strip(" |")


def exit_code(out):
    m = re.search(r"EXIT (\d+)", out)
    return int(m.group(1)) if m else -1


def register(ip, port, user, password, domain):
    return exit_code(ssh(sipp("register", ip, port, user, {"domain": domain}, f"-au {user} -ap {shlex.quote(password)}", 10)).stdout)


def answer(ip, port, name, code=200, timeout=30):
    """Starts an answering SIPp in the background (it answers, or refuses with 503, one call
    and stops); `done/1` says whether it did."""
    scenario = "answer" if code == 200 else "refuse"
    p = subprocess.Popen(SSH + [sipp(scenario, ip, port, name, {}, "", timeout, calls=0)], stdout=subprocess.PIPE, text=True)
    p.qpbx = (name, ip, "ANSWERED" if code == 200 else "REFUSED")
    return p


def carriers_up(ips, wait=70):
    """True once Kamailio's dispatcher lists every address as active (flags AP)."""
    for _ in range(wait // 5):
        state = app('IO.puts("JSON" <> Jason.encode!(QPBX.Edge.rpc("dispatcher.list") |> elem(1)))')
        targets = [t["DEST"] for s in (state or {}).get("RECORDS", []) for t in s["SET"]["TARGETS"]]
        if all(any(ip in d["URI"] and d["FLAGS"] == "AP" for d in targets) for ip in ips):
            return True
        time.sleep(5)
    return False


def done(p):
    """0 when the answering side handled its call, 1 when it saw none (timed out)."""
    p.communicate()
    name, ip, marker = p.qpbx
    log = ssh(f"cat {WORK}/{name}-{ip}.log 2>/dev/null; rm -f {WORK}/{name}-{ip}.log").stdout
    return 0 if marker in log else 1


def call(ip, port, user, to, domain, password=None, talk_ms=1000, audio=False):
    auth = f"-au {user} -ap {shlex.quote(password)}" if password else ""
    scenario = "call_carrier" if not password else ("call_phone_audio" if audio else "call_phone")
    out = ssh(sipp(scenario, ip, port, user, {"to": to, "domain": domain},
                   f"{auth} -d {talk_ms}", 40)).stdout
    log = ssh(f"cat {WORK}/{user}-{ip}.log 2>/dev/null; rm -f {WORK}/{user}-{ip}.log").stdout
    codes = re.findall(r"RESULT (\d{3})", log)
    return codes[-1] if codes else f"none (sipp exit {exit_code(out)})"


ssh(f"mkdir -p {WORK}")
for f in ("register.xml", "answer.xml", "refuse.xml", "call_phone.xml", "call_phone_audio.xml", "call_carrier.xml"):
    subprocess.run(SSH + [f"cat > {WORK}/{f}"], input=open(os.path.join(HERE, "scenarios", f)).read(), text=True, check=True)

CLEANUP = '''
alias QPBX.Core
a = {:system, "ci"}
p = %Core.Scope{kind: :platform}
for d <- Core.list_dids(p), t = d.tenant_id && QPBX.Repo.get(Core.Tenant, d.tenant_id), t && String.starts_with?(t.slug, "sipp-"), do: Core.delete_did(p, d, a)
for t <- Core.list_tenants(), String.starts_with?(t.slug, "sipp-"), do: QPBX.Repo.delete!(t)
for old <- Core.list_trunks(p), String.starts_with?(old.name, "sipp-"), do: Core.delete_trunk(p, old, a)
for c <- Core.list_number_classes(), c.note == "sipp", do: Core.delete_number_class(p, c.id, a)
for pl <- Core.list_plans(), String.starts_with?(pl.name, "sipp-"), do: QPBX.Repo.delete!(pl)
'''

S = app(CLEANUP + f'''
{{:ok, plan}} = Core.create_plan(%{{name: "sipp-{RUN}"}}, a)
{{:ok, t1}} = Core.create_trunk(p, %{{name: "sipp-T1-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.71", port: 5090}}]}}, a)
{{:ok, t2}} = Core.create_trunk(p, %{{name: "sipp-T2-{RUN}", auth_mode: "ip", addresses: [%{{host: "127.0.0.72", port: 5090}}]}}, a)
{{:ok, _}} = Core.create_number_class(p, %{{prefix: "+97259", class: "premium", note: "sipp"}}, a)
make = fn slug ->
  {{:ok, t}} = Core.create_tenant(%{{name: slug, slug: slug, timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
  {{:ok, u}} = Core.create_user(t, %{{email: slug <> "@x.test", name: "A"}}, "tenant_admin", a)
  s = Core.scope_for(u)
  pw = for n <- ~w(101 102), into: %{{}} do
    {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n, no_answer_seconds: 5}}, a)
    {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
    {{n, pw}}
  end
  {{t, s, u, pw}}
end
{{ta, sa, ua, pwa}} = make.("sipp-a-{RUN}")
{{tb, _sb, _ub, pwb}} = make.("sipp-b-{RUN}")
{{:ok, _}} = Core.create_route(sa, %{{name: "all", prefixes: [], destination_class: "local", trunk_ids: [t1.id, t2.id]}}, a)
{{:ok, e103}} = Core.create_extension(sa, %{{number: "103", name: "Away"}}, a)
{{:ok, _}} = QPBX.Telephony.save_mailbox(sa, e103.id, %{{pin: "4831"}}, ua)
e102 = Enum.find(Core.list_extensions(sa), &(&1.number == "102"))
{{:ok, did}} = Core.create_did(p, %{{number: "{DID}", trunk_id: t1.id, tenant_id: ta.id}}, a)
{{:ok, _}} = Core.set_did_destination(sa, Core.get_did!(sa, did.id), %{{destination_type: "extension", destination_id: e102.id}}, a)
IO.puts("JSON" <> Jason.encode!(%{{da: ta.sip_domain, db: tb.sip_domain, ta: ta.id, pwa: pwa, pwb: pwb}}))
''')
time.sleep(8)  # Kamailio reloads domains, credentials and trunks

A, B = S["da"], S["db"]
try:
    check("a phone registers", register("127.0.0.81", 5061, "101", S["pwa"]["101"], A) == 0)
    check("a wrong password is refused", register("127.0.0.89", 5061, "101", "wrong-password", A) != 0)

    # Two tenants, the same extension numbers: each call stays in its tenant.
    for ip, user, dom, pw in [("127.0.0.82", "102", A, S["pwa"]["102"]), ("127.0.0.83", "102", B, S["pwb"]["102"])]:
        register(ip, 5061, user, pw, dom)
    a102, b102 = answer("127.0.0.82", 5061, "a102", timeout=12), answer("127.0.0.83", 5061, "b102", timeout=12)
    time.sleep(1)
    r = call("127.0.0.81", 5062, "101", "102", A, S["pwa"]["101"])
    check("tenant A: 101 calls 102, answered", r == "200", r)
    ea, eb = done(a102), done(b102)
    check("…by tenant A's 102 only", ea == 0 and eb != 0, f"answer exits {ea}, {eb}")
    register("127.0.0.84", 5061, "101", S["pwb"]["101"], B)
    a102, b102 = answer("127.0.0.82", 5061, "a102", timeout=12), answer("127.0.0.83", 5061, "b102", timeout=12)
    time.sleep(1)
    r = call("127.0.0.84", 5062, "101", "102", B, S["pwb"]["101"])
    ea, eb = done(a102), done(b102)
    check("tenant B: 101 calls 102, answered by tenant B's 102 only", r == "200" and eb == 0 and ea != 0, f"{r}, answer exits {ea}, {eb}")

    # Outbound: the first carrier fails (503), the second answers. Kamailio pings carriers
    # (OPTIONS every 20 s) and marked them down while nothing listened; wait until both are up.
    c1, c2 = answer("127.0.0.71", 5090, "carrier1", code=503, timeout=90), answer("127.0.0.72", 5090, "carrier2", timeout=90)
    up = carriers_up(["127.0.0.71", "127.0.0.72"])
    check("Kamailio sees both carriers up (OPTIONS answered)", up, "" if up else "still down after 70 s")
    r = call("127.0.0.81", 5062, "101", "02-765-4321", A, S["pwa"]["101"])
    e1, e2 = done(c1), done(c2)
    ok = r == "200" and e1 == 0 and e2 == 0
    check("outbound: carrier 1 refuses (503), carrier 2 answers", ok, f"{r}, carrier exits {e1}, {e2}")
    if not ok:
        print("   carrier 1:", messages("carrier1", "127.0.0.71"), "\n   carrier 2:", messages("carrier2", "127.0.0.72"),
              "\n   caller:", messages("101", "127.0.0.81"))

    # Call admission: a premium (high-cost) number is barred, no carrier sees it.
    c1 = answer("127.0.0.71", 5090, "carrier1", timeout=6)
    r = call("127.0.0.81", 5062, "101", "0591234567", A, S["pwa"]["101"])
    check("a premium number is refused (403) and never reaches a carrier", r == "403" and done(c1) != 0, r)

    # Inbound: the carrier calls the number; tenant A's 102 answers.
    a102 = answer("127.0.0.82", 5061, "a102", timeout=12)
    time.sleep(1)
    r = call("127.0.0.71", 5090, "carrier", "0" + DID[4:], "127.0.0.1")
    ea = done(a102)
    check("inbound: a carrier call to the number rings tenant A's 102", r == "200" and ea == 0, f"{r}, answer exit {ea}")

    # Voicemail: 103 has a mailbox and no phone; the caller talks for a few seconds.
    r = call("127.0.0.81", 5062, "101", "103", A, S["pwa"]["101"], talk_ms=12000, audio=True)
    time.sleep(3)
    vm = app(f'''
t = QPBX.Core.get_tenant!("{S['ta']}")
u = hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))
IO.puts("JSON" <> Jason.encode!(Enum.map(QPBX.Telephony.list_voicemails(QPBX.Core.scope_for(u)), fn {{v, _}} -> v.duration end)))
''')
    check("voicemail: the mailbox answers and keeps the message", r == "200" and len(vm) == 1 and vm[0] >= 1, f"{r}, {vm}")

    # Call records of all of the above, in tenant A.
    time.sleep(6)
    cdrs = app(f'''
t = QPBX.Core.get_tenant!("{S['ta']}")
u = hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))
rows = QPBX.Telephony.search_cdrs(QPBX.Core.scope_for(u), %{{}}, t.timezone, limit: 50)
IO.puts("JSON" <> Jason.encode!(Enum.map(rows, &[&1.direction, &1.disposition])))
''')
    want = [["internal", "answered"], ["outbound", "answered"], ["outbound", "failed"], ["inbound", "answered"]]
    check("call records: internal, outbound, refused and inbound calls are there", all(w in cdrs for w in want) and len(cdrs) >= 5, str(cdrs))
finally:
    app(CLEANUP + '\nIO.puts("JSON{}")')
    ssh(f"rm -rf {WORK}")

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
