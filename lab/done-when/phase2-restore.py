#!/usr/bin/env python3
"""Phase 2 (2-10) check: restore the lab server from its backups onto a fresh VM, timed.

1. On the lab server: a tenant with an extension (its device password kept here), a voicemail
   with known audio; a files backup; then one more row written after it, which only the
   archived WAL holds (proves point-in-time replay to the latest state).
2. A fresh VM (QPBX_LAB_NAME=qpbx-restore lab/create-vm.sh) and restore.yml onto it, timed.
3. On the restored VM: health, the tenant and the late row, the voicemail audio decrypted
   byte for byte, and the device registering with its old password.
The restored copy makes no backups of its own (qpbx_restore_test), and is destroyed at the
end unless KEEP=1.

usage: phase2-restore.py <lab-vm-ip>
"""
import hashlib, json, os, re, shlex, subprocess, sys, tempfile, time

SRC = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN = format(int(time.time()), "x")
results = []


def check(name, ok, detail=""):
    ok = bool(ok)
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh_args(ip):
    return ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts",
            "-o", "StrictHostKeyChecking=accept-new", f"debian@{ip}"]


def ssh(ip, cmd):
    return subprocess.run(ssh_args(ip) + [cmd], capture_output=True, text=True)


def app(ip, code):
    p = ssh(ip, "sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code))
    m = re.search(r"JSON(.*)$", p.stdout, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + p.stdout + p.stderr)
    return json.loads(m.group(1))


AUDIO_HEX = hashlib.sha256(RUN.encode()).hexdigest() * 40  # known bytes, as hex
SLUG = f"restore-{RUN}"

# 1. Data, then backups.
src = app(SRC, f'''
alias QPBX.Core
a = {{:system, "lab"}}
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}"}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
{{:ok, e}} = Core.create_extension(s, %{{number: "101", name: "Kept"}}, a)
{{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
{{:ok, _}} = QPBX.Telephony.save_mailbox(s, e.id, %{{pin: "4831"}}, u)
mb = QPBX.Telephony.Voicemail.mailbox_system(t.id, e.id)
{{:ok, v}} = QPBX.Telephony.Voicemail.store_system(mb, "ID3" <> Base.decode16!("{AUDIO_HEX}", case: :lower), %{{duration: 7, format: "mp3"}})
IO.puts("JSON" <> Jason.encode!(%{{tenant: t.id, domain: t.sip_domain, password: pw, voicemail: v.id}}))
''')
r = ssh(SRC, "sudo /usr/local/sbin/qpbx-backup files >/dev/null; echo $?")
check("source: files backup", r.stdout.strip() == "0", r.stdout.strip())
late = app(SRC, f'''
{{:ok, e}} = QPBX.Core.create_extension(QPBX.Core.scope_for(hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, QPBX.Core.get_tenant!("{src['tenant']}")))), %{{number: "102", name: "After the file backup"}}, {{:system, "lab"}})
IO.puts("JSON" <> Jason.encode!(e.id))
''')
# `check` switches to a new WAL segment and waits until it is archived.
r = ssh(SRC, "sudo runuser -u postgres -- pgbackrest --stanza=qpbx check >/dev/null 2>&1; echo $?")
check("source: the latest changes are archived", r.stdout.strip() == "0", r.stdout.strip())

# 2. A fresh VM and the restore.
env = dict(os.environ, QPBX_LAB_NAME="qpbx-restore")
subprocess.run([f"{ROOT}/lab/create-vm.sh", "destroy"], env=env, capture_output=True)
t0 = time.time()
vm = subprocess.run([f"{ROOT}/lab/create-vm.sh"], env=env, capture_output=True, text=True)
ip = (vm.stdout.strip().splitlines() or [""])[-1]
vm_secs = time.time() - t0
check("a fresh Debian 12 VM", re.match(r"^\d+\.\d+\.\d+\.\d+$", ip), f"{ip} in {vm_secs:.0f} s")

inv = tempfile.mkdtemp(prefix="qpbx-restore-inv-")
os.symlink(f"{ROOT}/ansible/inventories/lab/group_vars", f"{inv}/group_vars")
src_hosts = open(f"{ROOT}/ansible/inventories/lab/hosts.yml").read()
open(f"{inv}/hosts.yml", "w").write(src_hosts.replace("qpbx-lab:\n          ansible_host: 192.168.10.25",
                                                       f"qpbx-restore:\n          ansible_host: {ip}"))
t0 = time.time()
play = subprocess.run(["ansible-playbook", "-i", inv, "restore.yml", "-e", "qpbx_restore_confirm=yes", "-e", "qpbx_restore_test=true"],
                      cwd=f"{ROOT}/ansible", capture_output=True, text=True, env=dict(os.environ, ANSIBLE_DEPRECATION_WARNINGS="False"))
restore_secs = time.time() - t0
open(f"{LAB}/work/restore-play.log", "w").write(play.stdout + play.stderr)
recap = [l for l in play.stdout.splitlines() if "ok=" in l]
check("restore.yml onto the fresh VM", play.returncode == 0, f"{restore_secs / 60:.1f} min; " + " | ".join(recap))

# 3. The restored server.
try:
    health = ssh(ip, "curl -s http://127.0.0.1:4000/health").stdout
    check("restored: health ok", '"ok"' in health, health)
    got = app(ip, f'''
t = QPBX.Core.get_tenant!("{src['tenant']}")
s = QPBX.Core.scope_for(hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t)))
{{:ok, audio, _}} = QPBX.Telephony.voicemail_audio(s, "{src['voicemail']}")
IO.puts("JSON" <> Jason.encode!(%{{exts: Enum.map(QPBX.Core.list_extensions(s), & &1.id), sha: Base.encode16(:crypto.hash(:sha256, audio), case: :lower)}}))
''')
    want_sha = hashlib.sha256(b"ID3" + bytes.fromhex(AUDIO_HEX)).hexdigest()
    check("restored: the tenant and the row written after the file backup (WAL replay)", late in got["exts"], f"{len(got['exts'])} extensions")
    check("restored: the voicemail decrypts byte for byte (master key and file keys back)", got["sha"] == want_sha)
    time.sleep(5)
    reg = subprocess.run(["python3", f"{ROOT}/lab/tools/sip_register.py", ip, "101", src["domain"], src["password"]], capture_output=True, text=True)
    check("restored: the device registers with its old password", "200" in reg.stdout, reg.stdout.strip())
    print(f"\nRestore time: {restore_secs / 60:.1f} minutes (restore.yml), plus {vm_secs / 60:.1f} minutes to create the VM.")
finally:
    # The test VM's key stays authorized on the backup target only while the VM exists.
    pub = ssh(ip, "sudo cat /etc/qpbx-backup/id_ed25519.pub").stdout.split()
    if os.environ.get("KEEP") != "1" and len(pub) >= 2:
        ssh("192.168.10.84", f"sudo sed -i '\\|{pub[1]}|d' /etc/ssh/qpbx-backup.authorized_keys")
    if os.environ.get("KEEP") != "1":
        subprocess.run([f"{ROOT}/lab/create-vm.sh", "destroy"], env=env, capture_output=True)
    app(SRC, f'''
for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "restore-"), do: QPBX.Repo.delete!(t)
for p <- QPBX.Core.list_plans(), String.starts_with?(p.name, "restore-"), do: QPBX.Repo.delete!(p)
IO.puts("JSON{{}}")''')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
