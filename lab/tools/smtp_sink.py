#!/usr/bin/env python3
"""Lab mail catcher: accepts every message on <port> and saves it as a file in <dir> (one
.eml each), refusing recipients at bounce.test with 550 (a hard bounce). Lab only (Python 3.11's
smtpd).

usage: smtp_sink.py <port> <dir>
"""
import asyncore, os, smtpd, sys, time, warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)
PORT, DIR = int(sys.argv[1]), sys.argv[2]
os.makedirs(DIR, exist_ok=True)


class Sink(smtpd.SMTPServer):
    def process_message(self, peer, mailfrom, rcpttos, data, **kwargs):
        if any(r.endswith("@bounce.test") for r in rcpttos):
            return "550 5.1.1 no such user"
        name = os.path.join(DIR, f"{time.time():.6f}.eml")
        with open(name, "wb") as f:
            f.write(b"X-Rcpt-To: " + ",".join(rcpttos).encode() + b"\n" + (data if isinstance(data, bytes) else data.encode()))
        return None


Sink(("0.0.0.0", PORT), None, decode_data=False)
asyncore.loop()
