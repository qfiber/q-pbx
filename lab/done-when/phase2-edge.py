#!/usr/bin/env python3
"""Phase 2 (2-3) checks: the Kamailio edge against the lab server.

This machine plays a phone and three carrier addresses:
  :5090  a carrier SBC that answers OPTIONS and refuses INVITEs with 486 (records them)
  :5091  a dead carrier address (nothing listens)
  :5092  a carrier registrar: digest-authenticates REGISTER and INVITE, then answers 486
FreeSWITCH places the outbound test calls (fs_cli originate); tcpdump on the server's loopback
shows what Kamailio hands FreeSWITCH.

usage: phase2-edge.py <vm-ip> <this-host-ip>
"""
import hashlib, json, os, random, re, shlex, socket, subprocess, sys, threading, time

VM, HOST = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
CARRIER_USER, CARRIER_PASS = "acct" + RUN, "carrier-pass-" + RUN
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh(cmd):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True).stdout


def rpc_app(code):
    """Runs Elixir in the running app (so its events reach the edge); returns the JSON it prints."""
    out = ssh("sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code))
    m = re.search(r"JSON(\{.*\})", out)
    if not m:
        raise SystemExit("app call failed:\n" + out)
    return json.loads(m.group(1))


def kamailio(method, *params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": list(params), "id": 1})
    return json.loads(ssh(f"curl -s -d '{body}' http://127.0.0.1:5071/RPC") or "{}")


def fs(cmd):
    return ssh(f"P=$(sudo python3 -c 'import json;print(json.load(open(\"/etc/qpbx/secrets.json\"))[\"esl_password\"])'); "
               f"/opt/qpbx-freeswitch/bin/fs_cli -p \"$P\" -x {json.dumps(cmd)}")


md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
branch = lambda: "z9hG4bK" + format(random.getrandbits(48), "x")


def header(msg, name):
    m = re.search(rf"^{name}:\s*(.*)$", msg, re.M | re.I)
    return m.group(1).strip() if m else None


def digest(challenge, method, uri, user, password):
    realm = re.search(r'realm="([^"]+)"', challenge).group(1)
    nonce = re.search(r'nonce="([^"]+)"', challenge).group(1)
    ha1, ha2, cnonce = md5(f"{user}:{realm}:{password}"), md5(f"{method}:{uri}"), format(random.getrandbits(32), "x")
    if "qop=" in challenge:
        resp = md5(f"{ha1}:{nonce}:00000001:{cnonce}:auth:{ha2}")
        return f'Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{uri}", response="{resp}", algorithm=MD5, qop=auth, nc=00000001, cnonce="{cnonce}"'
    return f'Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{uri}", response="{md5(f"{ha1}:{nonce}:{ha2}")}", algorithm=MD5'


def reply_to(sock, addr, req, code, reason, extra=""):
    vias = "".join(f"Via: {v.strip()}\r\n" for v in re.findall(r"^Via:\s*(.*)$", req, re.M | re.I))
    to = header(req, "To")
    if code > 100 and ";tag=" not in to:
        to += ";tag=" + format(random.getrandbits(32), "x")
    sock.sendto((f"SIP/2.0 {code} {reason}\r\n{vias}From: {header(req, 'From')}\r\nTo: {to}\r\n"
                 f"Call-ID: {header(req, 'Call-ID')}\r\nCSeq: {header(req, 'CSeq')}\r\n{extra}Content-Length: 0\r\n\r\n").encode(), addr)


class Carrier(threading.Thread):
    """A carrier address: answers OPTIONS; optionally digest-checks REGISTER/INVITE; records requests."""

    def __init__(self, port, auth=None):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", port))
        self.auth, self.seen, self.nonce = auth, [], format(random.getrandbits(64), "x")

    def authorized(self, req):
        cred = header(req, "Authorization") or header(req, "Proxy-Authorization")
        if not cred:
            return False
        user, realm = self.auth
        f = dict(re.findall(r'(\w+)="?([^",]+)"?', cred))
        ha1, ha2 = md5(f"{f['username']}:{realm}:{CARRIER_PASS}"), md5(f"{req.split(' ', 1)[0]}:{f['uri']}")
        expect = md5(f"{ha1}:{f['nonce']}:{f['nc']}:{f['cnonce']}:auth:{ha2}") if "qop" in f else md5(f"{ha1}:{f['nonce']}:{ha2}")
        return f["username"] == user and f["response"] == expect

    def run(self):
        while True:
            data, addr = self.sock.recvfrom(65535)
            req = data.decode(errors="replace")
            method = req.split(" ", 1)[0]
            if method.startswith("SIP/2.0"):
                continue
            self.seen.append(req)
            if method == "OPTIONS":
                reply_to(self.sock, addr, req, 200, "OK")
            elif method in ("REGISTER", "INVITE") and self.auth and not self.authorized(req):
                code, hdr = (401, "WWW-Authenticate") if method == "REGISTER" else (407, "Proxy-Authenticate")
                reply_to(self.sock, addr, req, code, "Unauthorized", f'{hdr}: Digest realm="{self.auth[1]}", nonce="{self.nonce}", qop="auth"\r\n')
            elif method == "REGISTER":
                reply_to(self.sock, addr, req, 200, "OK", f"Contact: {header(req, 'Contact')};expires=300\r\n")
            elif method == "INVITE":
                reply_to(self.sock, addr, req, 100, "Trying")
                reply_to(self.sock, addr, req, 486, "Busy Here")

    def invites(self):
        return [r for r in self.seen if r.startswith("INVITE")]


class Phone:
    """A phone: registers, places INVITEs, answers OPTIONS keepalives and incoming INVITEs (486)."""

    def __init__(self, user, domain, password):
        self.user, self.domain, self.password = user, domain, password
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("0.0.0.0", 0))
        self.port = self.sock.getsockname()[1]
        self.incoming = []

    def send(self, msg):
        self.sock.sendto(msg.encode(), (VM, 5060))

    def final(self, timeout=8, call_id=None):
        """The next final response (to call_id, if given); answers requests arriving meanwhile."""
        self.sock.settimeout(timeout)
        while True:
            data, addr = self.sock.recvfrom(65535)
            msg = data.decode(errors="replace")
            if not msg.startswith("SIP/2.0"):
                self.incoming.append(msg)
                reply_to(self.sock, addr, msg, 486 if msg.startswith("INVITE") else 200, "Busy Here" if msg.startswith("INVITE") else "OK")
                continue
            code = int(msg.split(" ", 2)[1])
            if call_id and header(msg, "Call-ID") != call_id:
                continue
            if code >= 200:
                if header(msg, "CSeq").endswith("INVITE"):
                    self.ack(msg)
                return msg

    def ack(self, resp):
        cseq = header(resp, "CSeq").split()[0]
        via = header(resp, "Via")
        self.send(f"ACK {self.last_uri} SIP/2.0\r\nVia: {via}\r\nMax-Forwards: 70\r\nFrom: {header(resp, 'From')}\r\n"
                  f"To: {header(resp, 'To')}\r\nCall-ID: {header(resp, 'Call-ID')}\r\nCSeq: {cseq} ACK\r\nContent-Length: 0\r\n\r\n")

    def request(self, method, uri, from_user=None, extra="", auth=None, call_id=None, cseq=1):
        self.last_uri = uri
        from_user = from_user or self.user
        call_id = call_id or format(random.getrandbits(64), "x")
        tag = format(random.getrandbits(32), "x")
        to = f"<sip:{self.user}@{self.domain}>" if method == "REGISTER" else f"<{uri}>"
        contact = f"Contact: <sip:{self.user}@{HOST}:{self.port}>\r\n"
        msg = (f"{method} {uri} SIP/2.0\r\nVia: SIP/2.0/UDP {HOST}:{self.port};rport;branch={branch()}\r\nMax-Forwards: 70\r\n"
               f"From: <sip:{from_user}@{self.domain}>;tag={tag}\r\nTo: {to}\r\nCall-ID: {call_id}\r\nCSeq: {cseq} {method}\r\n"
               f"{contact}{'Expires: 300' + chr(13) + chr(10) if method == 'REGISTER' else ''}{extra}{auth or ''}Content-Length: 0\r\n\r\n")
        self.send(msg)
        resp = self.final(call_id=call_id)
        if auth is None and resp.split(" ", 2)[1] in ("401", "407"):
            hdr = "Authorization" if resp.startswith("SIP/2.0 401") else "Proxy-Authorization"
            chal = header(resp, "WWW-Authenticate") or header(resp, "Proxy-Authenticate")
            return self.request(method, uri, from_user, extra, f"{hdr}: {digest(chal, method, uri, self.user, self.password)}\r\n", call_id, cseq + 1)
        return resp


def status(resp):
    return resp.split("\r\n", 1)[0]


def from_kamailio(resp):
    return header(resp, "Server") == "Q-PBX"


def wait(pred, secs):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(1)
    return False


# Carriers on this host.
sbc, registrar = Carrier(5090), Carrier(5092, auth=(CARRIER_USER, "carrier.test"))
sbc.start()
registrar.start()

# Tenant, extension 101 with device "desk" (no trunks yet: this host is a phone for now).
setup = rpc_app(f'''
alias QPBX.Core
actor = {{:system, "lab-edge"}}
platform = %Core.Scope{{kind: :platform}}
for t <- Core.list_trunks(platform), String.starts_with?(t.name, "edge-"), do: Core.delete_trunk(platform, t, actor)
{{:ok, plan}} = Core.create_plan(%{{name: "edge-{RUN}", max_extensions: 5}}, actor)
{{:ok, t}} = Core.create_tenant(%{{name: "Edge {RUN}", slug: "edge-{RUN}", timezone: "UTC", locale: "en", plan_id: plan.id}}, actor)
{{:ok, u}} = Core.create_user(t, %{{email: "edge-{RUN}@x.test", name: "E"}}, "tenant_admin", actor)
scope = Core.scope_for(u)
{{:ok, ext}} = Core.create_extension(scope, %{{number: "101", name: "Desk"}}, actor)
{{:ok, _d, pw}} = Core.add_device(scope, ext, %{{label: "desk", kind: "desk_phone"}}, actor)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, tenant: t.id, password: pw}}))
''')
domain, tenant = setup["domain"], setup["tenant"]
time.sleep(2)
phone = Phone("101-desk", domain, setup["password"])

# Watch what Kamailio hands FreeSWITCH.
PCAP = f"/tmp/qpbx-lo-{RUN}.pcap"
ssh(f"sudo setsid nohup timeout 600 tcpdump -U -i lo -s0 -n -w {PCAP} udp dst port 5080 </dev/null >/dev/null 2>&1 &")
time.sleep(2)

r = phone.request("REGISTER", f"sip:{domain}")
check("phone registers with its device login", status(r) == "SIP/2.0 200 OK", status(r))

uri = f"sip:102@{domain}"
phone.send(f"INVITE {uri} SIP/2.0\r\nVia: SIP/2.0/UDP {HOST}:{phone.port};rport;branch={branch()}\r\nMax-Forwards: 70\r\n"
           f"From: <sip:101-desk@{domain}>;tag=1\r\nTo: <{uri}>\r\nCall-ID: noauth{RUN}\r\nCSeq: 1 INVITE\r\n"
           f"Contact: <sip:101-desk@{HOST}:{phone.port}>\r\nContent-Length: 0\r\n\r\n")
phone.last_uri = uri
r = phone.final(call_id=f"noauth{RUN}")
check("an INVITE without credentials is challenged (407)", status(r).startswith("SIP/2.0 407"), status(r))

r = phone.request("INVITE", uri, from_user="102-desk")
check("a phone cannot call as another user (From must be the authenticated user)", status(r).startswith("SIP/2.0 407"), status(r))

r = phone.request("INVITE", uri, extra="X-QPBX-Tenant: 00000000-0000-0000-0000-000000000000\r\nX-QPBX-Evil: 1\r\n")
check("an authenticated INVITE goes on to FreeSWITCH (answer not from Kamailio)", not from_kamailio(r), status(r) + " / " + str(header(r, "User-Agent")))

# FreeSWITCH -> registered phone through Kamailio (location lookup).
fs(f"originate {{origination_caller_id_number=100,sip_route_uri=sip:127.0.0.1:5060}}sofia/qpbx/101-desk@{domain} &park")
end = time.time() + 10
while time.time() < end and not any(m.startswith("INVITE") for m in phone.incoming):
    try:
        phone.final(1)
    except socket.timeout:
        pass
check("a call from FreeSWITCH reaches the registered phone", any(m.startswith("INVITE") for m in phone.incoming))

# Registration trunk: Kamailio registers at the carrier with the password pushed by the app.
reg = rpc_app(f'''
alias QPBX.Core
{{:ok, t}} = Core.create_trunk(%Core.Scope{{kind: :platform}}, %{{name: "edge-reg-{RUN}", auth_mode: "registration", username: "{CARRIER_USER}", password: "{CARRIER_PASS}", addresses: [%{{host: "{HOST}", port: 5092}}]}}, {{:system, "lab-edge"}})
IO.puts("JSON" <> Jason.encode!(%{{id: t.id, edge: t.edge_id}}))
''')
# The app pushes the record at once; Kamailio's registration timer runs every 30 s.
ok = wait(lambda: any(r.startswith("REGISTER") and "Authorization" in r for r in registrar.seen), 75)
info = kamailio("uac.reg_info", "l_uuid", reg["id"]).get("result", {})
check("Kamailio registers the trunk at the carrier with digest auth", ok and (int(info.get("flags", 0)) & 4) == 4, f"flags={info.get('flags')}")
check("the carrier's password is not in any Kamailio database view",
      CARRIER_PASS not in ssh("sudo -u postgres psql -qAt qpbx -c \"select string_agg(t::text, ' ') from kamailio.uacreg t\"") + ssh("sudo -u postgres psql -qAt qpbx -c \"select string_agg(d::text, ' ') from kamailio.dispatcher d\""))

# From the server's own address, which is no trunk's: only the R-URI (the trunk id) counts.
SERVER_INVITE = r"""
import random, socket, sys
vm, user = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((vm, 0))
p = s.getsockname()[1]
m = (f"INVITE sip:{user}@{vm} SIP/2.0\r\nVia: SIP/2.0/UDP {vm}:{p};rport;branch=z9hG4bK{random.getrandbits(40):x}\r\n"
     f"Max-Forwards: 70\r\nFrom: <sip:c@carrier.test>;tag=1\r\nTo: <sip:{user}@{vm}>\r\nCall-ID: {random.getrandbits(64):x}\r\n"
     f"CSeq: 1 INVITE\r\nContact: <sip:c@{vm}:{p}>\r\nContent-Length: 0\r\n\r\n")
s.sendto(m.encode(), (vm, 5060))
s.settimeout(5)
while True:
    r = s.recv(65535).decode(errors="replace")
    if not r.split(" ")[1].startswith("1"):
        print(r)
        break
"""
subprocess.run(SSH + ["cat > /tmp/qpbx-invite.py"], input=SERVER_INVITE, text=True)


def invite_from_server(user):
    return ssh(f"python3 /tmp/qpbx-invite.py {VM} '{user}'")


r = invite_from_server(reg["id"])
check("an INVITE to the registered trunk id is taken as that carrier's call (no challenge)", r and not from_kamailio(r), status(r) if r else "no answer")
r = invite_from_server("+97221234567")
check("an INVITE from an unknown address without credentials is refused", status(r).startswith("SIP/2.0 403") if r else False, status(r) if r else "no answer")
carrier_in = Phone("carrier", "carrier.test", "")

before = len(registrar.invites())
fs(f"originate {{sip_h_X-QPBX-Trunk-Edge={reg['edge']}}}sofia/qpbx/+97221234567@127.0.0.1:5060 &park")
ok = wait(lambda: any("Proxy-Authorization" in r for r in registrar.invites()[before:]), 10)
check("an outbound call on the registration trunk answers the carrier's challenge", ok)

# IP trunk: priority 1 is dead (:5091), priority 2 answers (:5090).
ip = rpc_app(f'''
alias QPBX.Core
{{:ok, t}} = Core.create_trunk(%Core.Scope{{kind: :platform}}, %{{name: "edge-ip-{RUN}", auth_mode: "ip", addresses: [%{{host: "{HOST}", port: 5091, priority: 1}}, %{{host: "{HOST}", port: 5090, priority: 2}}]}}, {{:system, "lab-edge"}})
IO.puts("JSON" <> Jason.encode!(%{{id: t.id, edge: t.edge_id}}))
''')
time.sleep(6)  # the app reloads Kamailio's trunks (dispatcher reloads at most every 5 s)
fs(f"originate {{sip_h_X-QPBX-Trunk-Edge={ip['edge']}}}sofia/qpbx/+97221234567@127.0.0.1:5060 &park")
ok = wait(lambda: len(sbc.invites()) > 0, 15)
check("an outbound call fails over from the dead address to the next one", ok, sbc.invites()[0].split("\r\n", 1)[0] if ok else "")
check("the carrier gets the number as FreeSWITCH sent it, no Q-PBX headers",
      ok and "+97221234567" in sbc.invites()[0].split("\r\n", 1)[0] and "X-QPBX" not in sbc.invites()[0])

def dest_flags(node, uri_end):
    """FLAGS of the dispatcher destination whose URI ends with uri_end, anywhere in the dump."""
    if isinstance(node, dict):
        if str(node.get("URI", "")).endswith(uri_end):
            return node.get("FLAGS", "")
        node = list(node.values())
    if isinstance(node, list):
        for x in node:
            f = dest_flags(x, uri_end)
            if f:
                return f
    return ""

ok = wait(lambda: dest_flags(kamailio("dispatcher.list"), f"{HOST}:5091").startswith("I"), 70)
check("the dead address is marked inactive by OPTIONS pings", ok)

r = carrier_in.request("INVITE", f"sip:+97221234567@{VM}", auth="")
check("an INVITE from a trunk address is taken without a challenge", not from_kamailio(r), status(r))

# What FreeSWITCH received.
time.sleep(1)
lo = ssh(f"sudo tcpdump -A -n -r {PCAP} 2>/dev/null")
ssh(f"sudo pkill -f {PCAP}; sudo rm -f {PCAP}")
check("FreeSWITCH gets the tenant, the source and the authenticated user from Kamailio",
      f"X-QPBX-Tenant: {tenant}" in lo and "X-QPBX-Source: device" in lo and "X-QPBX-Auth-User: 101-desk" in lo)
check("headers a phone sends are never passed on (X-QPBX-* spoofing)", "X-QPBX-Evil" not in lo and "00000000-0000-0000-0000-000000000000" not in lo)
tagged = set(re.findall(r"X-QPBX-Trunk: ([0-9a-f-]{36})", lo))
check("a carrier call is tagged with its trunk (IP and registration)", {ip["id"], reg["id"]} <= tagged, f"expected {ip['id'][:8]}, {reg['id'][:8]}; saw {sorted(t[:8] for t in tagged)}")

# No relaying through Kamailio to outside addresses.
carrier_in.send(f"BYE sip:x@192.0.2.1 SIP/2.0\r\nVia: SIP/2.0/UDP {HOST}:{carrier_in.port};rport;branch={branch()}\r\nMax-Forwards: 70\r\n"
                f"Route: <sip:{VM};lr>\r\nFrom: <sip:a@{HOST}>;tag=a\r\nTo: <sip:x@192.0.2.1>;tag=b\r\nCall-ID: relay{RUN}\r\n"
                f"CSeq: 2 BYE\r\nContent-Length: 0\r\n\r\n")
r = carrier_in.final(call_id=f"relay{RUN}")
check("Kamailio refuses to relay to an outside address (in-dialog Route trick)", status(r).startswith("SIP/2.0 403"), status(r))

# Allow lists reach Kamailio within seconds.
rpc_app(f'''
{{:ok, _}} = QPBX.Firewall.create_entry(%{{level: "tenant", tenant_id: "{tenant}", kind: "allow", scope: "sip", cidr: "198.51.100.77", reason: "edge test"}}, {{:system, "lab-edge"}})
IO.puts("JSON{{}}")
''')
ok = wait(lambda: "198.51.100.77" in json.dumps(kamailio("permissions.addressDump")), 15)
check("a tenant office IP reaches Kamailio's allow list", ok)

# TLS: the tenant certificate by SNI, the main one otherwise.
cert = lambda name: subprocess.run(["sh", "-c", f"openssl s_client -connect {VM}:5061 -servername {name} </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName"], capture_output=True, text=True).stdout
with_cert = ssh("sudo sh -c 'for d in /etc/qpbx/tls/tenants/*/; do test -s $d/fullchain.pem && basename $d && break; done'").strip()
if with_cert:
    check("TLS on 5061 serves a tenant's own certificate by SNI", with_cert in cert(with_cert), cert(with_cert).replace("\n", " "))
    check("other names get the main certificate", with_cert not in cert("other.example") and cert("other.example") != "")
else:
    check("TLS SNI: a tenant certificate exists in the lab", False, "no tenant certificate")

# After a Kamailio restart: views reload by themselves; the app re-pushes registrations.
ssh("sudo systemctl restart kamailio")
ok = wait(lambda: (int(kamailio("uac.reg_info", "l_uuid", reg["id"]).get("result", {}).get("flags", 0)) & 4) == 4, 150)
check("after a Kamailio restart the trunk is registered again (app reconciles)", ok)
check("after a Kamailio restart the IP trunk is loaded again", dest_flags(kamailio("dispatcher.list"), f"{HOST}:5090") != "")

# Clean up the trunks (this host is a phone again for the next run).
rpc_app('''
alias QPBX.Core
platform = %Core.Scope{kind: :platform}
for t <- Core.list_trunks(platform), String.starts_with?(t.name, "edge-"), do: Core.delete_trunk(platform, t, {:system, "lab-edge"})
IO.puts("JSON{}")
''')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
