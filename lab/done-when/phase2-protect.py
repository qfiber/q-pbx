#!/usr/bin/env python3
"""Phase 2 (2-4) checks: SIP edge protection on the lab server.

The attacks run on the server itself, from loopback addresses (127.0.0.2 ... 127.0.0.9) to
Kamailio on 127.0.0.1:5060, so each scenario has its own source address and none of them is
on the management allowlist. This host (a management IP) checks that the allowlist is never
limited. nftables does not filter loopback traffic, so for the firewall side the checks read
the block sets instead.

usage: phase2-protect.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
results = []
TEST_IPS = [f"127.0.0.{i}" for i in range(2, 10)]


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


def kamailio(method, *params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": list(params), "id": 1})
    return json.loads(ssh(f"curl -s -d {shlex.quote(body)} http://127.0.0.1:5071/RPC") or "{}")


# Sends SIP from a given source address and port, prints one status per request ("-" = no answer).
SIPSEND = r'''
import hashlib, random, socket, sys
src, port, count, mode, domain, ua = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
md5 = lambda x: hashlib.md5(x.encode()).hexdigest()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((src, port))
s.settimeout(0.5 if mode == "flood" else 1.5)
def send(method, uri, user, extra=""):
    m = (f"{method} {uri} SIP/2.0\r\nVia: SIP/2.0/UDP {src}:{port};rport;branch=z9hG4bK{random.getrandbits(48):x}\r\n"
         f"Max-Forwards: 70\r\nFrom: <sip:{user}@{domain}>;tag={random.getrandbits(32):x}\r\nTo: <sip:{user}@{domain}>\r\n"
         f"Call-ID: {random.getrandbits(64):x}\r\nCSeq: 1 {method}\r\nContact: <sip:{user}@{src}:{port}>\r\nUser-Agent: {ua}\r\n"
         f"{extra}Content-Length: 0\r\n\r\n")
    s.sendto(m.encode(), ("127.0.0.1", 5060))
    if mode == "flood":
        return "sent"
    try:
        while True:
            r = s.recv(65535).decode(errors="replace")
            if not r.split(" ")[1].startswith("1"):
                return r
    except socket.timeout:
        return None
out = []
for i in range(count):
    if mode in ("options", "flood"):
        r = send("OPTIONS", "sip:127.0.0.1", "probe")
    elif mode == "register":
        r = send("REGISTER", f"sip:{domain}", "999")
    else:  # badauth: answer the challenge with a wrong password (unknown user 999)
        r = send("REGISTER", f"sip:{domain}", "999")
        if r and r.startswith("SIP/2.0 401"):
            realm = r.split('realm="')[1].split('"')[0]; nonce = r.split('nonce="')[1].split('"')[0]
            resp = md5(f"{md5(f'999:{realm}:wrong')}:{nonce}:{md5(f'REGISTER:sip:{domain}')}")
            r = send("REGISTER", f"sip:{domain}", "999",
                     f'Authorization: Digest username="999", realm="{realm}", nonce="{nonce}", uri="sip:{domain}", response="{resp}"\r\n')
    out.append("sent" if r == "sent" else (r.split("\r\n")[0].split(" ", 2)[1] if r else "-"))
print(" ".join(out))
'''
ssh("cat > /tmp/qpbx-sipsend.py", SIPSEND)


def send(src, mode, count=1, port=0, ua="lab"):
    return ssh(f"python3 /tmp/qpbx-sipsend.py {src} {port} {count} {mode} {DOMAIN} {shlex.quote(ua)}").split()


def wait(pred, secs):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(1)
    return False


def nft_block(ip):
    return ssh("sudo nft list set inet qpbx block_sip_v4")


def clean():
    """Removes this script's bans (Kamailio and firewall) and office IP."""
    for ip in TEST_IPS:
        kamailio("htable.delete", "ipban", ip)
        kamailio("htable.delete", "edgealert", ip)
        for key in ("authfail", "rate"):
            kamailio("htable.delete", key, ip)
    for t in ("ipban", "authfail", "rate"):
        for item in [i for s in kamailio("htable.dump", t).get("result", []) for i in s.get("slot", [])]:
            if item["name"].split("|")[0] in TEST_IPS or "|127.0.0." in item["name"]:
                kamailio("htable.delete", t, item["name"])
    app('''
for e <- QPBX.Firewall.list_entries(), String.starts_with?(e.cidr, "127.0.0."), do: QPBX.Firewall.delete_entry(e, {:system, "lab"})
IO.puts("JSON{}")
''')


DOMAIN = app('''
t = Enum.find(QPBX.Core.list_tenants(), &String.starts_with?(&1.slug, "edge-")) || hd(QPBX.Core.list_tenants())
IO.puts("JSON" <> Jason.encode!(t.sip_domain))
''')
clean()

# Allowlisted (this host, a management IP): many failures, never limited.
host = subprocess.run(["python3", os.path.join(os.path.dirname(__file__), "..", "tools", "sip_register.py"), VM, "999", DOMAIN, "wrong"],
                      capture_output=True, text=True)
for _ in range(12):
    subprocess.run(["python3", os.path.join(os.path.dirname(__file__), "..", "tools", "sip_register.py"), VM, "999", DOMAIN, "wrong"], capture_output=True)
r = subprocess.run(["python3", os.path.join(os.path.dirname(__file__), "..", "tools", "sip_register.py"), VM, "999", DOMAIN, "wrong"], capture_output=True, text=True).stdout.strip()
check("the management allowlist is never limited (13 failed logins, still answered)", r.startswith("SIP/2.0 401"), r)

# Scanner user agent: dropped, the whole address banned, and the ban reaches nftables.
r = send("127.0.0.2", "options", ua="friendly-scanner")
check("a scanner user agent gets no answer", r == ["-"], " ".join(r))
check("…and its address gets no answer to anything after that", send("127.0.0.2", "options") == ["-"])
ok = wait(lambda: "127.0.0.2 timeout" in nft_block("127.0.0.2"), 20)
check("…and is blocked in nftables with a timeout (expires on its own)", ok, re.sub(r"\s+", " ", nft_block("x"))[-160:])
entry = app('''
e = Enum.find(QPBX.Firewall.list_entries(level: "platform"), &(&1.cidr == "127.0.0.2"))
IO.puts("JSON" <> Jason.encode!(%{reason: e && e.reason, secs: e && DateTime.diff(e.expires_at, DateTime.utc_now())}))
''')
check("…recorded as an automatic firewall entry for one hour", entry["reason"] == "auto: scanner" and 3500 < (entry["secs"] or 0) <= 3600, str(entry))

# Failed logins from one phone (address and port): that port is banned, the address is not.
r = send("127.0.0.3", "badauth", count=10, port=5091)
check("10 failed logins from one address and port: answered until the ban", r[:9] == ["401"] * 9, " ".join(r))
check("…then that address and port gets no answer", send("127.0.0.3", "register", port=5091) == ["-"])
check("…while another port on the same address still works", send("127.0.0.3", "register", port=5092) == ["401"])
check("…and the address is not blocked in nftables", not wait(lambda: "127.0.0.3" in nft_block("x"), 8))

# Many failures across ports from one address: the whole address is banned.
for p in range(6000, 6004):
    send("127.0.0.4", "badauth", count=8, port=p)
check("30 failed logins from one address across ports: the whole address is banned", send("127.0.0.4", "options", port=6100) == ["-"])
check("…and blocked in nftables", wait(lambda: "127.0.0.4" in nft_block("x"), 20))

# Rate limit on REGISTER (30 a minute per address and port).
r = send("127.0.0.5", "register", count=31, port=5093)
check("the 31st REGISTER within a minute is refused (503 Rate Limited)", r[:30] == ["401"] * 30 and r[30] == "503", " ".join(r[-3:]))

# Flood: hundreds of requests in a second.
send("127.0.0.6", "flood", count=400)
time.sleep(1)
check("a flood bans the address", send("127.0.0.6", "options") == ["-"])
check("…and it is blocked in nftables", wait(lambda: "127.0.0.6" in nft_block("x"), 20))

# Office IP: higher per-phone limit, never banned as a whole: an alert instead.
app('''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.sip_domain == "''' + DOMAIN + '''"))
{:ok, _} = QPBX.Firewall.create_entry(%{level: "tenant", tenant_id: t.id, kind: "allow", scope: "sip", cidr: "127.0.0.8", reason: "lab office"}, {:system, "lab"})
IO.puts("JSON{}")
''')
check("the office IP reaches Kamailio's allow list", wait(lambda: "127.0.0.8" in json.dumps(kamailio("permissions.addressDump")), 20))
r = send("127.0.0.8", "badauth", count=12, port=5094)
check("an office IP gets more failed logins per phone (12 > 10, still answered)", r == ["401"] * 12, " ".join(r))
for p in range(7000, 7003):
    send("127.0.0.8", "badauth", count=10, port=p)
check("an office IP is not banned as a whole after 40 failures", send("127.0.0.8", "register", port=7100) == ["401"])
send("127.0.0.8", "flood", count=400)
check("…nor after a flood (offices skip flood detection)", send("127.0.0.8", "register", port=7101) == ["401"])
ok = wait(lambda: app('''
IO.puts("JSON" <> Jason.encode!(Enum.any?(QPBX.Core.list_audit_logs(limit: 50), &(&1.action == "edge.office_ip_alert" and &1.changes["ip"] == "127.0.0.8"))))
'''), 15)
check("…instead an alert is raised (audited, EdgeAlert event)", ok)
check("…and the office IP is not in nftables", "127.0.0.8" not in nft_block("x"))

# A ban placed before an address became an office IP is lifted within seconds.
send("127.0.0.9", "flood", count=400)
time.sleep(1)
banned = send("127.0.0.9", "options") == ["-"]
app('''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.sip_domain == "''' + DOMAIN + '''"))
{:ok, _} = QPBX.Firewall.create_entry(%{level: "tenant", tenant_id: t.id, kind: "allow", scope: "sip", cidr: "127.0.0.9", reason: "lab office 2"}, {:system, "lab"})
IO.puts("JSON{}")
''')
check("a banned address that becomes an office IP is answered again within seconds", banned and wait(lambda: send("127.0.0.9", "options") == ["200"], 20))

clean()
time.sleep(2)
check("clean-up: no test address left blocked", not any(ip in nft_block("x") for ip in TEST_IPS))

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
