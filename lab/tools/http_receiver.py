#!/usr/bin/env python3
"""Lab HTTP receiver (webhooks, outbound request checks): answers every request with a JSON
echo of what it got and keeps the requests; GET /_seen returns and clears them.
/redirect?to=URL[&status=302] answers a redirect to URL; /fail answers 500 (and is kept).

usage: http_receiver.py <port> [<cert.pem> <key.pem>]   (with a certificate: HTTPS)
"""
import json, ssl, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", headers=()):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self):
        url = urllib.parse.urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if url.path == "/_seen":
            global seen
            out, seen = seen, []
            return self.reply(200, json.dumps(out).encode(), [("Content-Type", "application/json")])
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/redirect":
            return self.reply(int(q.get("status", ["302"])[0]), headers=[("Location", q["to"][0])])
        record = {"at": time.time(), "method": self.command, "path": url.path, "headers": dict(self.headers), "body": body.decode(errors="replace")}
        seen.append(record)
        self.reply(500 if url.path == "/fail" else 200, json.dumps(record).encode(), [("Content-Type", "application/json")])

    do_GET = do_POST = do_PUT = do_DELETE = handle_any


server = ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Handler)
if len(sys.argv) > 3:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
