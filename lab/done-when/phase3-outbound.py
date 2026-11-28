#!/usr/bin/env python3
"""3-4 lab check: requests to tenant-chosen addresses from the lab server, through the app's
one outbound client with the installation's settings (the lab allows plain HTTP and the
backup VM's address, where a test receiver runs). Real DNS and real certificates: a public
HTTPS site works, a bad certificate is refused, names and addresses that point inside are
refused, and so is a redirect from the receiver to an inside address.

usage: phase3-outbound.py <vm-ip> <receiver-vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM, RX = sys.argv[1], sys.argv[2]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
HERE = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts"]
PORT = 18080
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


subprocess.run(SSH + [f"debian@{RX}", "cat > /tmp/qpbx-receiver.py"], input=open(os.path.join(HERE, "..", "tools", "http_receiver.py")).read(), text=True)
rx = subprocess.Popen(SSH + [f"debian@{RX}", f"exec python3 -u /tmp/qpbx-receiver.py {PORT}"])
time.sleep(1.5)
base = f"http://{RX}:{PORT}"

try:
    r = fetch("get", "https://example.com/")
    check("public HTTPS site, real certificate: answered", r.get("ok") == 200, r.get("ok") or r.get("error"))
    r = fetch("get", "https://expired.badssl.com/")
    check("expired certificate: refused", "error" in r and "connect" in r["error"], r.get("error", r.get("ok")))
    r = fetch("get", "https://wrong.host.badssl.com/")
    check("certificate for another name: refused", "error" in r and "connect" in r["error"], r.get("error", r.get("ok")))

    r = fetch("post", base + "/hook")
    check("allowed receiver (plain HTTP, the operator's network): reached", r.get("ok") == 200 and '"POST"' in r.get("body", ""), r.get("ok") or r.get("error"))

    for url in ["http://127.0.0.1:4000/health", "http://localhost:4000/", "http://2130706433:4000/", "http://[::1]:4000/",
                "http://[::ffff:127.0.0.1]:4000/", "http://169.254.169.254/latest/meta-data/", f"http://{VM}/",
                "http://192.168.10.1/", "http://localtest.me:4000/"]:
        r = fetch("get", url)
        check(f"refused: {url}", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))

    to = "http://127.0.0.1:4000/health"
    r = fetch("get", f"{base}/redirect?to={to}")
    check("receiver redirects to the server's loopback: refused", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))
    r = fetch("get", f"{base}/redirect?to=http://169.254.169.254/")
    check("receiver redirects to the metadata address: refused", "blocked_address" in r.get("error", ""), r.get("error", r.get("ok")))
finally:
    rx.terminate()
    subprocess.run(SSH + [f"debian@{RX}", "pkill -f qpbx-receiver.py"], capture_output=True)

passed = sum(results)
print(f"\n{passed} passed, {len(results) - passed} failed")
sys.exit(0 if all(results) else 1)
