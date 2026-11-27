#!/usr/bin/env python3
"""Phase 2 (2-7) checks: voicemail with real calls.

Extension 101 calls 102, which rings and is not answered: 102's mailbox answers, the caller
talks (a tone) and hangs up. Then the message is checked (encrypted on disk, nothing left in
tmpfs, the email built with the audio, 102's voicemail light on), 102 dials *97 (wrong PIN
three times: hung up, message kept; then the right PIN: hears it and deletes it with 7, light
off), and a custom greeting is played from a decrypted temporary copy that is removed again.

usage: phase2-voicemail.py <vm-ip>
"""
import json, os, re, shlex, subprocess, sys, time

VM = sys.argv[1]
LAB = os.path.expanduser("~/.local/share/qpbx-lab")
SSH = ["ssh", "-o", "IdentitiesOnly=yes", "-i", f"{LAB}/id_ed25519", "-o", f"UserKnownHostsFile={LAB}/known_hosts", f"debian@{VM}"]
RUN = format(int(time.time()), "x")
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""), flush=True)


def ssh(cmd):
    return subprocess.run(SSH + [cmd], capture_output=True, text=True).stdout


def app(code):
    p = subprocess.run(SSH + ["sudo /usr/local/sbin/qpbx rpc " + shlex.quote(code)], capture_output=True, text=True)
    out = p.stdout + p.stderr
    m = re.search(r"JSON(.*)$", out, re.M)
    if not m:
        raise SystemExit("app call failed:\n" + out)
    return json.loads(m.group(1))


subprocess.run(SSH + ["cat > /tmp/qpbx-sipua.py"], input=open(os.path.join(os.path.dirname(__file__), "..", "tools", "sipua_daemon.py")).read(), text=True)
ua = subprocess.Popen(SSH + ["python3 -u /tmp/qpbx-sipua.py"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def do(**cmd):
    ua.stdin.write(json.dumps(cmd) + "\n")
    ua.stdin.flush()
    return json.loads(ua.stdout.readline())


def call(frm, to, **kw):
    return do(cmd="call", **{"from": frm, "to": to}, **kw)


def mwi_states():
    return [n["state"] for n in do(cmd="notifies", name="p102")["notifies"] if n["event"] == "message-summary"]


SLUG = f"vm-{RUN}"
CLEANUP = '''
alias QPBX.Core
a = {:system, "lab"}
for t <- Core.list_tenants(), String.starts_with?(t.slug, "vm-"), do: QPBX.Repo.delete!(t)
for p <- Core.list_plans(), String.starts_with?(p.name, "vm-"), do: QPBX.Repo.delete!(p)
'''
COUNT = f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{SLUG}"))
IO.puts("JSON" <> Jason.encode!(Map.values(QPBX.Telephony.voicemail_counts(t.id)) |> Enum.map(&Tuple.to_list/1)))
'''

setup = app(CLEANUP + f'''
{{:ok, plan}} = Core.create_plan(%{{name: "{SLUG}"}}, a)
{{:ok, t}} = Core.create_tenant(%{{name: "{SLUG}", slug: "{SLUG}", timezone: "Asia/Jerusalem", locale: "en", plan_id: plan.id}}, a)
{{:ok, u}} = Core.create_user(t, %{{email: "{SLUG}@x.test", name: "A"}}, "tenant_admin", a)
s = Core.scope_for(u)
pw = for n <- ~w(101 102), into: %{{}} do
  {{:ok, e}} = Core.create_extension(s, %{{number: n, name: "Ext " <> n, no_answer_seconds: 5}}, a)
  {{:ok, _, pw}} = Core.add_device(s, e, %{{label: "", kind: "softphone"}}, a)
  {{n, pw}}
end
e102 = Enum.find(Core.list_extensions(s), &(&1.number == "102"))
{{:ok, _}} = QPBX.Telephony.save_mailbox(s, e102.id, %{{pin: "4831", email: "vm@x.test"}}, u)
IO.puts("JSON" <> Jason.encode!(%{{domain: t.sip_domain, pw: pw, tid: t.id, ext: e102.id}}))
''')
time.sleep(8)  # Kamailio reloads domains and credentials

try:
    for name, ip, user in [("p101", "127.0.0.50", "101"), ("p102", "127.0.0.51", "102")]:
        r = do(cmd="phone", name=name, ip=ip, user=user, domain=setup["domain"], password=setup["pw"][user], mode="ring")
        check(f"phone {user} registers", r["status"] == "200", r["status"])
    check("102 subscribes to its voicemail light", do(cmd="subscribe", **{"from": "p102"}, target="102", event="message-summary")["status"] in ("200", "202"))
    time.sleep(1)
    mwi_states()

    # Leave a message: 102 rings 5 s, then voicemail answers; 6 s of talking (greeting first).
    started = time.time()
    r = call("p101", "102", hold=True, wait=20)
    check("an unanswered call is answered by 102's mailbox", r["status"] == "200", f"{r['status']} after {time.time() - started:.0f}s")
    if r.get("dialog"):
        time.sleep(7)  # "The person at extension 1 0 2 is not available..." and the tone
        do(cmd="audio", dialog=r["dialog"], seconds=5)
        do(cmd="bye", dialog=r["dialog"])
    time.sleep(3)
    counts = app(COUNT)
    check("the message is stored (1 new)", counts == [[1, 0]], str(counts))
    left = ssh("sudo ls -A /run/qpbx-media").split()
    check("no plain audio left in tmpfs", left == [], " ".join(left))
    msg = app(f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{SLUG}"))
[{{v, _}}] = QPBX.Telephony.list_voicemails(QPBX.Core.scope_for(hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))))
import Ecto.Query
job = QPBX.Repo.one!(from(j in Oban.Job, where: j.worker == "QPBX.Notify.VoicemailEmail" and fragment("?->>'email' = 'vm@x.test'", j.args), order_by: [desc: j.id], limit: 1))
{{:ok, email}} = QPBX.Notify.VoicemailEmail.build(job.args)
[att] = email.attachments
IO.puts("JSON" <> Jason.encode!(%{{file: v.file_key, duration: v.duration, caller: v.caller_number, subject: email.subject, size: byte_size(att.data), mp3: binary_part(att.data, 0, 3) == "ID3" or :binary.first(att.data) == 0xFF}}))
''')
    head = ssh(f"sudo head -c 4 /var/lib/qpbx/{msg['file']}")
    check("on disk it is encrypted (no MP3 header)", head == "QPS1", f"header {head!r}")
    check("the message is about 5 seconds long, from 101", 3 <= msg["duration"] <= 8 and msg["caller"] == "101", str(msg))
    check("the email is built with the MP3 attached", msg["mp3"] and msg["size"] > 1000 and "101" in msg["subject"], f"{msg['subject']}, {msg['size']} bytes")
    states = mwi_states()
    check("102's voicemail light goes on", "yes" in states, str(states))

    # *97 with a wrong PIN three times: hung up, the message stays.
    r = call("p102", "*97", hold=True)
    if r.get("dialog"):
        for _ in range(3):
            time.sleep(3)
            do(cmd="dtmf", dialog=r["dialog"], digits="1111#")
        time.sleep(4)
        bye = do(cmd="bye", dialog=r["dialog"])["status"]
        check("*97: three wrong PINs and the system hangs up (our BYE finds no call)", bye != "200", bye)
    check("…and the message is still there", app(COUNT) == [[1, 0]])

    # *97 with the right PIN: hears the message and deletes it with 7.
    r = call("p102", "*97", hold=True)
    check("*97 answers", r["status"] == "200", r["status"])
    if r.get("dialog"):
        time.sleep(3)
        do(cmd="dtmf", dialog=r["dialog"], digits="4831#")
        # "You have one new messages", the message (~5 s), then the options; 7 deletes.
        for wait in (9, 3, 3):
            time.sleep(wait)
            do(cmd="dtmf", dialog=r["dialog"], digits="7")
        time.sleep(5)
        do(cmd="bye", dialog=r["dialog"])
    time.sleep(2)
    check("*97 with the right PIN: the message is deleted with 7", app(COUNT) in ([], [[0, 0]]), str(app(COUNT)))
    states = mwi_states()
    check("102's voicemail light goes off", states[-1:] == ["no"], str(states))
    gone = ssh(f"sudo test -e /var/lib/qpbx/{msg['file']} && echo yes || echo no").strip()
    check("the deleted message's file is gone", gone == "no", msg["file"])

    # A custom greeting (a WAV) is played from a temporary decrypted copy, removed afterwards.
    app(f'''
t = Enum.find(QPBX.Core.list_tenants(), &(&1.slug == "{SLUG}"))
u = hd(QPBX.Core.list_users(%QPBX.Core.Scope{{kind: :platform}}, t))
:ok = QPBX.Telephony.put_greeting(QPBX.Core.scope_for(u), "{setup['ext']}", "unavailable", File.read!("/usr/share/qpbx/sounds/en/us/callie/voicemail/8000/vm-hello.wav"), u)
IO.puts("JSON{{}}")
''')
    r = call("p101", "102", hold=True, wait=20)
    time.sleep(2)
    during = ssh("sudo ls -A /run/qpbx-media").split()
    if r.get("dialog"):
        time.sleep(3)
        do(cmd="bye", dialog=r["dialog"])
    time.sleep(2)
    after = ssh("sudo ls -A /run/qpbx-media").split()
    check("a custom greeting plays from a decrypted temporary copy", any(f.endswith(".wav") for f in during), " ".join(during))
    check("…removed when the call ends", after == [], " ".join(after))
    check("a hang-up during the greeting leaves no message", app(COUNT) in ([], [[0, 0]]), str(app(COUNT)))
finally:
    ua.stdin.close()
    ua.terminate()
    app(CLEANUP + '\nIO.puts("JSON{}")')

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
