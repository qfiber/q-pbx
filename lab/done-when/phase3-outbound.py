#!/usr/bin/env python3
"""3-4 lab check: requests to tenant-chosen addresses from the lab server, through the app's
one outbound client with the installation's settings (the lab trusts the backup VM's
address, where an HTTPS test receiver runs with a certificate from the lab CA,
lab/tools/lab-ca.sh). HTTPS only: plain HTTP is refused even to that receiver. Real DNS and real certificates: a public
HTTPS site works, a bad certificate is refused, names and addresses that point inside are
refused, and so is a redirect from the receiver to an inside address.

usage: phase3-outbound.py <vm-ip> <receiver-vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts"]
PORT = 18443
CA = os.path.join(LAB, "lab-ca")
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def fetch(method, url):
    code = f'''
r = QPBX.Integrations.request(:{method}, {json.dumps(url)}, body: if(:{method} == :post, do: "{{}}"))
out = case r do
  {{:ok, %{{status: s, body: b}}}} -> %{{ok: s, body: String.slice(b, 0, 300)}}
  {{:error, e}} -> %{{error: inspect(e)}}
end
IO.puts("JSON" <> Jason.encode!(out))
'''
    p = subprocess.run(SSH + [f"debian@{VM}", "sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], capture_output=True, text=True)
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    return json.loads(m.group(1)) if m else {"error": "rpc failed: " + p.stdout + p.stderr}


subprocess.run(["sh", os.path.join(HERE, "..", "tools", "lab-ca.sh"), RX], capture_output=True, check=True)
for name, src in [("qpbx-receiver.py", os.path.join(HERE, "..", "tools", "http_receiver.py")),
                  ("qpbx-receiver.pem", f"{CA}/receiver.pem"), ("qpbx-receiver.key", f"{CA}/receiver.key")]:
    subprocess.run(SSH + [f"debian@{RX}", f"umask 077; cat > /tmp/{name}"], input=open(src).read(), text=True)
rx = subprocess.Popen(SSH + [f"debian@{RX}", f"exec python3 -u /tmp/qpbx-receiver.py {PORT} /tmp/qpbx-receiver.pem /tmp/qpbx-receiver.key"])
time.sleep(1.5)
base = f"https://{RX}:{PORT}"

try:
    r = fetch("get", "https://example.com/")
    check("public HTTPS site, real certificate: answered", r.get("ok") == 200, r.get("ok") or r.get("error"))
    r = fetch("get", "https://expired.badssl.com/")
    check("expired certificate: refused", "error" in r and "connect" in r["error"], r.get("error", r.get("ok")))
    r = fetch("get", "https://wrong.host.badssl.com/")
    check("certificate for another name: refused", "error" in r and "connect" in r["error"], r.get("error", r.get("ok")))

    r = fetch("post", base + "/hook")
    check("allowed receiver (HTTPS, lab CA, the operator's network): reached", r.get("ok") == 200 and '"POST"' in r.get("body", ""), r.get("ok") or r.get("error"))
    r = fetch("post", f"http://{RX}:{PORT}/hook")
    check("plain HTTP to the same receiver: refused", "https_required" in r.get("error", ""), r.get("error", r.get("ok")))

    for url in ["https://127.0.0.1/health", "https://localhost/", "https://2130706433/", "https://[::1]/",
                "https://[::ffff:127.0.0.1]/", "https://169.254.169.254/latest/meta-data/", f"https://{VM}/",
                "https://192.168.10.1/", "https://localtest.me/"]:
        r = fetch("get", url)
        check(f"refused: {url}", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))

    to = "https://127.0.0.1/health"
    r = fetch("get", f"{base}/redirect?to={to}")
    check("receiver redirects to the server's loopback: refused", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))
    r = fetch("get", f"{base}/redirect?to=https://169.254.169.254/")
    check("receiver redirects to the metadata address: refused", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))
finally:
    rx.terminate()
    subprocess.run(SSH + [f"debian@{RX}", "pkill -f qpbx-receiver.py; rm -f /tmp/qpbx-receiver.*"], capture_output=True)

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
