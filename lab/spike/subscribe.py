#!/usr/bin/env python3
"""Spike subscriber (lab only): SUBSCRIBE with digest auth, then print every NOTIFY body.
usage: subscribe.py <server-ip> <user> <password> <target-user> <event> <seconds>"""
import hashlib, random, re, socket, sys, time

server, user, password, target, event, seconds = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], float(sys.argv[6])
domain = "pbx.lab.test"
accept = {"dialog": "application/dialog-info+xml", "presence": "application/pidf+xml", "message-summary": "application/simple-message-summary"}[event]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((server, 5060))
lip, lport = s.getsockname()
s.settimeout(1.0)
call_id, tag = f"{random.getrandbits(64):x}@spike", f"{random.getrandbits(32):x}"
cseq = 0

def md5(x): return hashlib.md5(x.encode()).hexdigest()

def subscribe(auth=""):
    global cseq
    cseq += 1
    ruri = f"sip:{target}@{domain}"
    msg = (f"SUBSCRIBE {ruri} SIP/2.0\r\nVia: SIP/2.0/UDP {lip}:{lport};rport;branch=z9hG4bK{random.getrandbits(40):x}\r\n"
           f"Max-Forwards: 70\r\nFrom: <sip:{user}@{domain}>;tag={tag}\r\nTo: <{ruri}>\r\nCall-ID: {call_id}\r\nCSeq: {cseq} SUBSCRIBE\r\n"
           f"Contact: <sip:{user}@{lip}:{lport}>\r\nEvent: {event}\r\nAccept: {accept}\r\nExpires: 300\r\n{auth}Content-Length: 0\r\n\r\n")
    s.send(msg.encode())

def answer(msg):
    hdrs = msg.split("\r\n\r\n", 1)[0].split("\r\n")
    keep = [h for h in hdrs[1:] if re.match(r"(?i)^(via|from|to|call-id|cseq):", h)]
    s.send(("SIP/2.0 200 OK\r\n" + "\r\n".join(keep) + "\r\nContent-Length: 0\r\n\r\n").encode())

subscribe()
end = time.time() + seconds
while time.time() < end:
    try:
        data = s.recv(65535).decode(errors="replace")
    except socket.timeout:
        continue
    first = data.split("\r\n", 1)[0]
    if first.startswith("SIP/2.0 401") or first.startswith("SIP/2.0 407"):
        header = "Authorization" if first.startswith("SIP/2.0 401") else "Proxy-Authorization"
        realm, nonce = re.search(r'realm="([^"]+)"', data).group(1), re.search(r'nonce="([^"]+)"', data).group(1)
        ruri = f"sip:{target}@{domain}"
        resp = md5(f"{md5(f'{user}:{realm}:{password}')}:{nonce}:{md5(f'SUBSCRIBE:{ruri}')}")
        subscribe(f'{header}: Digest username="{user}", realm="{realm}", nonce="{nonce}", uri="{ruri}", response="{resp}", algorithm=MD5\r\n')
    elif first.startswith("SIP/2.0"):
        print(f"[{time.strftime('%H:%M:%S')}] {first}", flush=True)
    elif first.startswith("NOTIFY"):
        answer(data)
        state = re.search(r"(?im)^Subscription-State:\s*(.*)$", data)
        body = data.split("\r\n\r\n", 1)[1].strip()
        print(f"[{time.strftime('%H:%M:%S')}] NOTIFY ({state.group(1) if state else '?'})\n{body}\n", flush=True)
