#!/usr/bin/env python3
"""Lab tool: REGISTER over UDP with digest auth; prints the final response line.
usage: sip_register.py <server-ip> <user> <domain> <password> [<auth-user>]
<auth-user> lets a test authenticate as one user while registering another."""
import hashlib, random, re, socket, sys

server, user, domain, password = sys.argv[1:5]
auth_user = sys.argv[5] if len(sys.argv) > 5 else user
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect((server, 5060))
lip, lport = s.getsockname()
s.settimeout(3)
call_id, tag, cseq = f"{random.getrandbits(64):x}@lab", f"{random.getrandbits(32):x}", 0

def md5(x): return hashlib.md5(x.encode()).hexdigest()

def register(auth=""):
    global cseq
    cseq += 1
    ruri = f"sip:{domain}"
    s.send((f"REGISTER {ruri} SIP/2.0\r\nVia: SIP/2.0/UDP {lip}:{lport};rport;branch=z9hG4bK{random.getrandbits(40):x}\r\n"
            f"Max-Forwards: 70\r\nFrom: <sip:{user}@{domain}>;tag={tag}\r\nTo: <sip:{user}@{domain}>\r\nCall-ID: {call_id}\r\n"
            f"CSeq: {cseq} REGISTER\r\nContact: <sip:{user}@{lip}:{lport}>\r\nExpires: 60\r\n{auth}Content-Length: 0\r\n\r\n").encode())
    return s.recv(65535).decode(errors="replace")

reply = register()
if reply.startswith("SIP/2.0 401"):
    realm = re.search(r'realm="([^"]+)"', reply).group(1)
    nonce = re.search(r'nonce="([^"]+)"', reply).group(1)
    qop = "qop=" in reply
    ruri = f"sip:{domain}"
    ha1, ha2, nc, cnonce = md5(f"{auth_user}:{realm}:{password}"), md5(f"REGISTER:{ruri}"), "00000001", f"{random.getrandbits(32):x}"
    resp = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}") if qop else md5(f"{ha1}:{nonce}:{ha2}")
    extra = f', qop=auth, nc={nc}, cnonce="{cnonce}"' if qop else ""
    reply = register(f'Authorization: Digest username="{auth_user}", realm="{realm}", nonce="{nonce}", uri="{ruri}", response="{resp}", algorithm=MD5{extra}\r\n')
print(reply.split("\r\n", 1)[0])
