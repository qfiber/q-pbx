#!/usr/bin/env python3
"""Lab SIP endpoints, driven by JSON lines on stdin (one reply line each on stdout).

Phones register with digest auth, place calls (answering 401/407), and answer incoming calls in
a chosen way; carriers answer OPTIONS and treat incoming INVITEs the same way. Every endpoint
records the INVITEs it receives. Runs on the lab server so each endpoint can have its own
loopback address (Kamailio tells carriers from phones by source address).

Commands:
  {"cmd": "phone", "name": N, "ip": IP, "user": U, "domain": D, "password": P, "mode": M}
  {"cmd": "carrier", "name": N, "ip": IP, "port": PORT, "mode": M}
  {"cmd": "unregister", "name": N}                REGISTER with Expires: 0
  {"cmd": "mode", "name": N, "mode": M}          M: answer | busy | ring | 503
  {"cmd": "call", "from": N, "to": NUMBER, "hold": bool, "wait": SECONDS}
  {"cmd": "bye", "dialog": ID}
  {"cmd": "seen", "name": N}                     INVITEs received since the last "seen"
  {"cmd": "subscribe", "from": N, "target": EXT, "event": dialog|presence|message-summary}
  {"cmd": "notifies", "name": N}                 NOTIFYs received (event, state) since the last call
  {"cmd": "audio", "dialog": ID, "seconds": S}   sends a 400 Hz tone (PCMU) on an answered call
  {"cmd": "dtmf", "dialog": ID, "digits": "12#"} sends keypad digits (RFC 4733 telephone-events)
"""
import hashlib, json, math, queue, random, re, socket, struct, sys, threading, time

KAMAILIO = ("127.0.0.1", 5060)
md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
rnd = lambda bits=32: format(random.getrandbits(bits), "x")
endpoints, dialogs, media = {}, {}, {}


def hdr(msg, name):
    m = re.search(rf"^{name}:\s*(.*?)\r?$", msg, re.M | re.I)
    return m.group(1).strip() if m else None


def all_hdr(msg, name):
    return [v.strip() for v in re.findall(rf"^{name}:\s*(.*?)\r?$", msg, re.M | re.I)]


CODECS = {"opus": ("96", "opus/48000/2"), "pcmu": ("0", "PCMU/8000"), "pcma": ("8", "PCMA/8000"), "g722": ("9", "G722/8000")}


def sdp(ip, port, codecs=("pcmu", "pcma"), crypto=False):
    pts = " ".join(CODECS[c][0] for c in codecs)
    maps = "".join(f"a=rtpmap:{CODECS[c][0]} {CODECS[c][1]}\r\n" for c in codecs)
    key = "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:" + "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNk\r\n" if crypto else ""
    return (f"v=0\r\no=- 1 1 IN IP4 {ip}\r\ns=-\r\nc=IN IP4 {ip}\r\nt=0 0\r\n"
            f"m=audio {port} RTP/AVP {pts} 101\r\n{maps}a=rtpmap:101 telephone-event/8000\r\n"
            f"a=fmtp:101 0-16\r\na=sendrecv\r\n{key}")


def ulaw(sample):
    """16-bit linear sample to G.711 mu-law."""
    sign = 0x80 if sample < 0 else 0
    sample = min(abs(sample), 32635) + 132
    exp = max(0, min(7, int(math.log2(sample >> 7)) if sample >> 7 else 0))
    mant = (sample >> (exp + 3)) & 0x0F
    return ~(sign | (exp << 4) | mant) & 0xFF


TONE = bytes(ulaw(int(8000 * math.sin(2 * math.pi * 400 * n / 8000))) for n in range(160))


class Rtp:
    """Our side of a call's media: sequence, timestamp, SSRC; sends to the far end's address."""
    def __init__(self, sock, addr):
        self.sock, self.addr = sock, addr
        self.seq, self.ts, self.ssrc = random.randint(0, 9999), random.randint(0, 99999), random.getrandbits(32)

    def packet(self, pt, payload, marker=False, advance=True):
        hdr_ = struct.pack("!BBHII", 0x80, (0x80 if marker else 0) | pt, self.seq & 0xFFFF, self.ts & 0xFFFFFFFF, self.ssrc)
        self.sock.sendto(hdr_ + payload, self.addr)
        self.seq += 1
        if advance:
            self.ts += 160

    def audio(self, seconds):
        for _ in range(int(seconds * 50)):
            self.packet(0, TONE)
            time.sleep(0.02)

    def dtmf(self, digits):
        codes = {**{str(d): d for d in range(10)}, "*": 10, "#": 11}
        for d in digits:
            self.audio(0.2)
            ev = codes[d]
            for i in range(1, 9):  # 160 ms of the key, then three end packets
                self.packet(101, struct.pack("!BBH", ev, 10, i * 160), marker=(i == 1), advance=False)
                time.sleep(0.02)
            for _ in range(3):
                self.packet(101, struct.pack("!BBH", ev, 0x80 | 10, 9 * 160), advance=False)
            self.ts += 9 * 160
        self.audio(0.3)


class Endpoint(threading.Thread):
    def __init__(self, name, ip, port, mode, user=None, domain=None, password=None):
        super().__init__(daemon=True)
        self.name, self.ip, self.mode = name, ip, mode
        self.user, self.domain, self.password = user, domain, password
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((ip, port))
        self.port = self.sock.getsockname()[1]
        self.rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rtp.bind((ip, 0))
        self.responses, self.seen, self.ringing, self.notifies = queue.Queue(), [], {}, []

    def send(self, msg, addr=KAMAILIO):
        self.sock.sendto(msg.encode(), addr)

    def reply(self, req, addr, code, reason, extra="", body=""):
        vias = "".join(f"Via: {v}\r\n" for v in all_hdr(req, "Via"))
        rr = "".join(f"Record-Route: {v}\r\n" for v in all_hdr(req, "Record-Route"))
        to = hdr(req, "To")
        if code > 100 and ";tag=" not in to:
            to += ";tag=" + self.tag_for(hdr(req, "Call-ID"))
        ctype = "Content-Type: application/sdp\r\n" if body else ""
        self.send(f"SIP/2.0 {code} {reason}\r\n{vias}{rr}From: {hdr(req, 'From')}\r\nTo: {to}\r\nCall-ID: {hdr(req, 'Call-ID')}\r\n"
                  f"CSeq: {hdr(req, 'CSeq')}\r\n{extra}{ctype}Content-Length: {len(body)}\r\n\r\n{body}", addr)

    def tag_for(self, call_id):
        return md5(call_id + self.name)[:10]

    def run(self):
        while True:
            data, addr = self.sock.recvfrom(65535)
            msg = data.decode(errors="replace")
            if msg.startswith("SIP/2.0"):
                self.responses.put(msg)
                continue
            method = msg.split(" ", 1)[0]
            if method == "INVITE":
                self.on_invite(msg, addr)
            elif method == "CANCEL":
                self.reply(msg, addr, 200, "OK")
                inv = self.ringing.pop(hdr(msg, "Call-ID"), None)
                if inv:
                    self.reply(inv, addr, 487, "Request Terminated")
            elif method == "NOTIFY":
                self.notifies.append(summarize(msg))
                self.reply(msg, addr, 200, "OK")
            elif method in ("OPTIONS", "BYE"):
                self.reply(msg, addr, 200, "OK")

    def on_invite(self, msg, addr):
        if ";tag=" in (hdr(msg, "To") or ""):  # re-INVITE inside a dialog
            self.reply(msg, addr, 200, "OK", f"Contact: <sip:{self.name}@{self.ip}:{self.port}>\r\n", sdp(self.ip, self.rtp.getsockname()[1]))
            return
        self.seen.append({"ruri": msg.split(" ")[1], "from": hdr(msg, "From"), "headers": [l for l in msg.split("\r\n") if l.startswith("X-")],
                          "pai": hdr(msg, "P-Asserted-Identity")})
        self.reply(msg, addr, 100, "Trying")
        if self.mode == "busy":
            self.reply(msg, addr, 486, "Busy Here")
        elif self.mode == "503":
            self.reply(msg, addr, 503, "Service Unavailable")
        elif self.mode == "ring":
            self.reply(msg, addr, 180, "Ringing", f"Contact: <sip:{self.name}@{self.ip}:{self.port}>\r\n")
            self.ringing[hdr(msg, "Call-ID")] = msg
        else:
            self.reply(msg, addr, 180, "Ringing", f"Contact: <sip:{self.name}@{self.ip}:{self.port}>\r\n")
            self.reply(msg, addr, 200, "OK", f"Contact: <sip:{self.name}@{self.ip}:{self.port}>\r\n", sdp(self.ip, self.rtp.getsockname()[1]))

    # Outgoing requests: wait for the final response to this transaction.
    def final(self, call_id, cseq, wait):
        end = time.time() + wait
        while time.time() < end:
            try:
                r = self.responses.get(timeout=0.2)
            except queue.Empty:
                continue
            if hdr(r, "Call-ID") == call_id and hdr(r, "CSeq").startswith(f"{cseq} ") and int(r.split(" ")[1]) >= 200:
                return r
        return None

    def request(self, method, uri, call_id, cseq, from_tag, to, extra="", body="", branch=None):
        ctype = "Content-Type: application/sdp\r\n" if body else ""
        user = self.user or self.name
        frm = f"<sip:{user}@{self.domain or self.ip}>;tag={from_tag}"
        self.send(f"{method} {uri} SIP/2.0\r\nVia: SIP/2.0/UDP {self.ip}:{self.port};rport;branch={branch or 'z9hG4bK' + rnd(48)}\r\n"
                  f"Max-Forwards: 70\r\nFrom: {frm}\r\nTo: {to}\r\nCall-ID: {call_id}\r\nCSeq: {cseq} {method}\r\n"
                  f"Contact: <sip:{user}@{self.ip}:{self.port}>\r\n{extra}{ctype}Content-Length: {len(body)}\r\n\r\n{body}")
        return frm

    def auth_header(self, resp, method, uri):
        chal = hdr(resp, "WWW-Authenticate") or hdr(resp, "Proxy-Authenticate")
        realm, nonce = re.search(r'realm="([^"]+)"', chal).group(1), re.search(r'nonce="([^"]+)"', chal).group(1)
        ha1, ha2, cn = md5(f"{self.user}:{realm}:{self.password}"), md5(f"{method}:{uri}"), rnd()
        r = md5(f"{ha1}:{nonce}:00000001:{cn}:auth:{ha2}")
        name = "Authorization" if resp.startswith("SIP/2.0 401") else "Proxy-Authorization"
        return (f'{name}: Digest username="{self.user}", realm="{realm}", nonce="{nonce}", uri="{uri}", response="{r}", '
                f'algorithm=MD5, qop=auth, nc=00000001, cnonce="{cn}"\r\n')

    def register(self, expires=600):
        uri, call_id, tag = f"sip:{self.domain}", rnd(64), rnd()
        to = f"<sip:{self.user}@{self.domain}>"
        self.request("REGISTER", uri, call_id, 1, tag, to, f"Expires: {expires}\r\n")
        r = self.final(call_id, 1, 5)
        if r and r.split(" ")[1] in ("401", "407"):
            self.request("REGISTER", uri, call_id, 2, tag, to, f"Expires: {expires}\r\n" + self.auth_header(r, "REGISTER", uri))
            r = self.final(call_id, 2, 5)
        return r.split(" ")[1] if r else "timeout"

    def call(self, to_number, hold, wait, codecs=("pcmu", "pcma"), crypto=False):
        domain = self.domain or "127.0.0.1"
        uri, call_id, tag = f"sip:{to_number}@{domain}", rnd(64), rnd()
        body = sdp(self.ip, self.rtp.getsockname()[1], codecs, crypto)
        self.last_answer = None
        branch = "z9hG4bK" + rnd(48)
        self.request("INVITE", uri, call_id, 1, tag, f"<{uri}>", body=body, branch=branch)
        r = self.final(call_id, 1, wait)
        cseq = 1
        if r and r.split(" ")[1] in ("401", "407"):
            self.ack_negative(r, uri, call_id, tag, branch)
            cseq, branch = 2, "z9hG4bK" + rnd(48)
            self.request("INVITE", uri, call_id, 2, tag, f"<{uri}>", self.auth_header(r, "INVITE", uri), body, branch=branch)
            r = self.final(call_id, 2, wait)
        if not r:
            return {"status": "timeout"}
        code = r.split(" ")[1]
        self.last_answer = "\r\n".join(l for l in r.split("\r\n") if l.startswith(("m=", "a=rtpmap", "a=crypto")))
        if code != "200":
            self.ack_negative(r, uri, call_id, tag, branch)
            return {"status": code}
        # 2xx: ACK (and later BYE) along the route set, to the far end's Contact.
        routes = "".join(f"Route: {v}\r\n" for v in all_hdr(r, "Record-Route"))
        target = re.search(r"<([^>]+)>", hdr(r, "Contact")).group(1)
        to = hdr(r, "To")
        self.request("ACK", target, call_id, cseq, tag, to, routes)
        dialog = rnd()
        dialogs[dialog] = (self, target, call_id, cseq + 1, tag, to, routes)
        c_ip = re.search(r"^c=IN IP4 (\S+)", r, re.M)
        m_port = re.search(r"^m=audio (\d+)", r, re.M)
        if c_ip and m_port:
            media[dialog] = Rtp(self.rtp, (c_ip.group(1), int(m_port.group(1))))
        if not hold:
            time.sleep(1)
            self.bye(dialog)
        return {"status": "200", "dialog": dialog, "answer": self.last_answer}

    def subscribe(self, target, event):
        accept = {"dialog": "application/dialog-info+xml", "presence": "application/pidf+xml",
                  "message-summary": "application/simple-message-summary"}[event]
        uri, call_id, tag = f"sip:{target}@{self.domain}", rnd(64), rnd()
        extra = f"Event: {event}\r\nAccept: {accept}\r\nExpires: 600\r\n"
        self.request("SUBSCRIBE", uri, call_id, 1, tag, f"<{uri}>", extra)
        r = self.final(call_id, 1, 5)
        if r and r.split(" ")[1] in ("401", "407"):
            self.request("SUBSCRIBE", uri, call_id, 2, tag, f"<{uri}>", extra + self.auth_header(r, "SUBSCRIBE", uri))
            r = self.final(call_id, 2, 5)
        return r.split(" ")[1] if r else "timeout"

    def ack_negative(self, r, uri, call_id, tag, branch):
        self.request("ACK", uri, call_id, int(hdr(r, "CSeq").split()[0]), tag, hdr(r, "To"), branch=branch)

    def bye(self, dialog):
        _, target, call_id, cseq, tag, to, routes = dialogs.pop(dialog)
        self.request("BYE", target, call_id, cseq, tag, to, routes)
        r = self.final(call_id, cseq, 5)
        return r.split(" ")[1] if r else "timeout"


def summarize(msg):
    """(event, state) of a NOTIFY: the dialog state, the presence basic, or Messages-Waiting."""
    body = msg.split("\r\n\r\n", 1)[1] if "\r\n\r\n" in msg else ""
    event = (hdr(msg, "Event") or "").split(";")[0]
    if event == "dialog":
        states = re.findall(r"<state[^>]*>([^<]+)</state>", body)
        direction = re.search(r'direction="([^"]+)"', body)
        state = states[0] if states else "idle"
        return {"event": event, "state": state, "direction": direction.group(1) if direction else None,
                "peer": (re.findall(r"<identity[^>]*>([^<]+)</identity>", body) or [None])[-1]}
    if event == "presence":
        basic = re.search(r"<basic>([^<]+)</basic>", body)
        return {"event": event, "state": basic.group(1) if basic else None}
    waiting = re.search(r"Messages-Waiting:\s*(\w+)", body, re.I)
    return {"event": event, "state": waiting.group(1).lower() if waiting else None}


def handle(c):
    cmd = c["cmd"]
    if cmd == "phone":
        e = Endpoint(c["name"], c["ip"], 0, c.get("mode", "answer"), c["user"], c["domain"], c["password"])
        e.start()
        endpoints[c["name"]] = e
        return {"status": e.register()}
    if cmd == "carrier":
        e = Endpoint(c["name"], c["ip"], c["port"], c.get("mode", "answer"))
        e.start()
        endpoints[c["name"]] = e
        return {"status": "ok"}
    if cmd == "unregister":
        return {"status": endpoints[c["name"]].register(0)}
    if cmd == "mode":
        endpoints[c["name"]].mode = c["mode"]
        return {"status": "ok"}
    if cmd == "call":
        return endpoints[c["from"]].call(c["to"], c.get("hold", False), c.get("wait", 30),
                                         tuple(c.get("codecs", ["pcmu", "pcma"])), c.get("crypto", False))
    if cmd == "audio":
        media[c["dialog"]].audio(c["seconds"])
        return {"status": "ok"}
    if cmd == "dtmf":
        media[c["dialog"]].dtmf(c["digits"])
        return {"status": "ok"}
    if cmd == "bye":
        return {"status": dialogs[c["dialog"]][0].bye(c["dialog"])}
    if cmd == "subscribe":
        return {"status": endpoints[c["from"]].subscribe(c["target"], c["event"])}
    if cmd == "notifies":
        e = endpoints[c["name"]]
        n, e.notifies = e.notifies, []
        return {"notifies": n}
    if cmd == "seen":
        e = endpoints[c["name"]]
        seen, e.seen = e.seen, []
        return {"seen": seen}
    return {"error": "unknown command"}


for line in sys.stdin:
    try:
        out = handle(json.loads(line))
    except Exception as ex:  # report, keep serving
        out = {"error": repr(ex)}
    print(json.dumps(out), flush=True)
