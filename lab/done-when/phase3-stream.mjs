// 3-6 lab check: the live event stream through nginx (wss://portal.pbx.lab.test/v1/socket).
// Two tenants' keys stream at once while tenant A's phones register and call: A's stream gets
// A's events in order, B's gets nothing of A's. A stream filtered to one type gets only that
// type. Revoking A's key closes its stream at once.
// usage: node lab/done-when/phase3-stream.mjs <vm-ip>
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { readFileSync } from "node:fs";
import { reporter, sleep, sshArgs, sshTo } from "./lib.mjs";

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"; // the lab portal's self-signed certificate
const vm = process.argv[2];
const ssh = sshTo(vm);
const { check, done } = reporter();
const run = Date.now().toString(36);
const rpc = (code) => JSON.parse(ssh(`sudo /usr/local/sbin/qpbx rpc '${code.replace(/'/g, "'\\''")}'`).match(/JSON(.*)$/m)[1]);
const cleanup = `for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "st-"), do: QPBX.Repo.delete!(t)`;

const S = rpc(`${cleanup}
alias QPBX.Core
a = {:system, "lab"}
mk = fn slug ->
  {:ok, t} = Core.create_tenant(%{name: slug, slug: slug, timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(Core.list_plans()).id}, a)
  {:ok, u} = Core.create_user(t, %{email: slug <> "@x.test", name: "A"}, "tenant_admin", a)
  {t, Core.scope_for(u)}
end
{ta, sa} = mk.("st-a-${run}")
{_tb, sb} = mk.("st-b-${run}")
pw = for n <- ~w(101 102), into: %{} do
  {:ok, e} = Core.create_extension(sa, %{number: n, name: "Ext " <> n}, a)
  {:ok, _, pw} = Core.add_device(sa, e, %{label: "", kind: "softphone"}, a)
  {n, pw}
end
key = fn s -> {:ok, k, tok} = Core.create_api_key(s, %{name: "st", scopes: ["read"]}, a); %{id: k.id, token: tok} end
IO.puts("JSON" <> Jason.encode!(%{domain: ta.sip_domain, tid: ta.id, pw: pw, a: key.(sa), a2: key.(sa), b: key.(sb)}))`);

function stream(token, types) {
  const b64 = Buffer.from(token).toString("base64").replace(/=+$/, "");
  const ws = new WebSocket("wss://portal.pbx.lab.test/v1/socket/websocket?vsn=2.0.0", ["phoenix", `base64url.bearer.phx.${b64}`]);
  const s = { ws, events: [], joined: null, closed: false };
  ws.onopen = () => ws.send(JSON.stringify(["1", "1", "events", "phx_join", types ? { types } : {}]));
  ws.onmessage = (m) => {
    const [, , , event, payload] = JSON.parse(m.data);
    if (event === "phx_reply") s.joined = payload.status;
    if (event === "event") s.events.push(payload);
  };
  ws.onclose = () => (s.closed = Date.now());
  return s;
}

execFileSync("ssh", [...sshArgs, `debian@${vm}`, "cat > /tmp/qpbx-sipua.py"], { input: readFileSync(new URL("../tools/sipua_daemon.py", import.meta.url)) });
const ua = spawn("ssh", [...sshArgs, `debian@${vm}`, "python3 -u /tmp/qpbx-sipua.py"]);
const lines = createInterface({ input: ua.stdout });
const replies = [];
lines.on("line", (l) => replies.push(JSON.parse(l)));
const sipua = async (cmd) => {
  const n = replies.length;
  ua.stdin.write(JSON.stringify(cmd) + "\n");
  while (replies.length === n) await sleep(50);
  return replies[n];
};

try {
  const a = stream(S.a.token);
  const filtered = stream(S.a2.token, ["call.answered"]);
  const b = stream(S.b.token);
  const nokey = new WebSocket("wss://portal.pbx.lab.test/v1/socket/websocket?vsn=2.0.0");
  let refused = null;
  nokey.onerror = () => (refused = "error");
  nokey.onclose = () => (refused = refused || "closed");
  await sleep(2000);
  check("streams joined through nginx", a.joined === "ok" && filtered.joined === "ok" && b.joined === "ok", `${a.joined} ${filtered.joined} ${b.joined}`);
  check("a connection without a key is refused", refused !== null, refused);

  for (const [name, ip, user] of [["s101", "127.0.0.90", "101"], ["s102", "127.0.0.91", "102"]])
    await sipua({ cmd: "phone", name, ip, user, domain: S.domain, password: S.pw[user] });
  const r = await sipua({ cmd: "call", from: "s101", to: "102", wait: 10 });
  check("a real call 101 -> 102, answered", r.status === "200", r.status);
  await sleep(3000);

  const calls = a.events.filter((e) => e.type.startsWith("call.")).map((e) => e.type);
  const regs = a.events.filter((e) => e.type === "extension.registered").map((e) => e.data.device).sort();
  check("tenant A's stream: registrations of 101 and 102", JSON.stringify(regs) === '["101","102"]', regs.join(","));
  check("tenant A's stream: started, ringing, answered, ended in order", JSON.stringify(calls) === '["call.started","call.ringing","call.answered","call.ended"]', calls.join(","));
  check("every message is tenant A's, with an id", a.events.every((e) => e.tenant_id === S.tid && e.id));
  check("the filtered stream got only call.answered", filtered.events.length === 1 && filtered.events[0].type === "call.answered", filtered.events.map((e) => e.type).join(","));
  check("tenant B's stream got nothing of tenant A's", b.events.length === 0, b.events.length);

  const t0 = Date.now();
  rpc(`{:ok, k} = QPBX.Core.authenticate_api_key("${S.a.token}")
{:ok, _} = QPBX.Core.revoke_api_key(QPBX.Core.scope_for(k), k.id, {:system, "lab"})
IO.puts("JSON{}")`);
  for (let i = 0; i < 40 && !a.closed; i++) await sleep(50);
  check("revoking tenant A's key closes its stream at once", a.closed && !b.closed, a.closed ? `${a.closed - t0} ms after the revoke call started` : "still open");
  for (const s of [filtered, b]) s.ws.close();
} finally {
  ua.kill();
  rpc(`${cleanup}\nIO.puts("JSON{}")`);
}
process.exit(done());
