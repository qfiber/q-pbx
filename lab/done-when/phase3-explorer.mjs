// 3-1 lab check: the API explorer at /v1/docs in a real browser. It loads the OpenAPI
// document, sends requests with a key typed into the page, shows the answers, and the page
// breaks no Content-Security-Policy rule. A greeting uploaded from the page's file input
// (binary body) shows up in the mailbox.
// usage: node lab/done-when/phase3-explorer.mjs <vm-ip>
import puppeteer from "puppeteer-core";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { reporter, sshTo } from "./lib.mjs";

const vm = process.argv[2];
const ssh = sshTo(vm);
const { check, done } = reporter();
const run = Date.now().toString(36);
const rpc = (code) => JSON.parse(ssh(`sudo /usr/local/sbin/qpbx rpc '${code.replace(/'/g, "'\\''")}'`).match(/JSON(.*)$/m)[1]);
const cleanup = `for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "apix-"), do: QPBX.Repo.delete!(t)`;

const { token, wtoken, ext } = rpc(`${cleanup}
a = {:system, "lab"}
{:ok, t} = QPBX.Core.create_tenant(%{name: "apix", slug: "apix-${run}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(QPBX.Core.list_plans()).id}, a)
{:ok, u} = QPBX.Core.create_user(t, %{email: "apix-${run}@x.test", name: "X"}, "tenant_admin", a)
s = QPBX.Core.scope_for(u)
{:ok, e} = QPBX.Core.create_extension(s, %{number: "101", name: "Explorer"}, a)
{:ok, _} = QPBX.Telephony.save_mailbox(s, e.id, %{pin: "4831"}, u)
{:ok, _, tok} = QPBX.Core.create_api_key(s, %{name: "x", scopes: ["read"]}, a)
{:ok, _, wtok} = QPBX.Core.create_api_key(s, %{name: "w", scopes: ["read", "write"]}, a)
IO.puts("JSON" <> Jason.encode!(%{token: tok, wtoken: wtok, ext: e.id}))`);

// One second of a 440 Hz tone, 8 kHz 16-bit mono WAV.
const wav = (() => {
  const n = 8000, b = Buffer.alloc(44 + n * 2);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n * 2, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(8000, 24); b.writeUInt32LE(16000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(8000 * Math.sin((2 * Math.PI * 440 * i) / 8000)), 44 + i * 2);
  const f = join(mkdtempSync(join(tmpdir(), "qpbx-x-")), "greeting.wav");
  writeFileSync(f, b);
  return f;
})();

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  args: [`--host-resolver-rules=MAP portal.pbx.lab.test ${vm}`, "--ignore-certificate-errors"],
});
const csp = [];
try {
  const page = await browser.newPage();
  page.on("console", (m) => /Content Security Policy|Refused to/.test(m.text()) && csp.push(m.text()));
  await page.goto("https://portal.pbx.lab.test/v1/docs", { waitUntil: "networkidle0" });
  const ops = await page.$$eval("#operations details", (ds) => ds.map((d) => d.querySelector("summary").textContent));
  check("explorer lists the operations from the document", ops.some((o) => o.includes("/v1/extensions")) && ops.length >= 5, ops.length);

  await page.type("#api-key", token);
  const send = async (match, params = {}, file = null) => {
    // The summary text follows the path: an exact path, not one that merely starts the same.
    const i = ops.findIndex((o) => o.startsWith(match) && /^[A-Z]/.test(o.slice(match.length)));
    const d = (await page.$$("#operations details"))[i];
    await d.evaluate((el) => (el.open = true));
    await d.$eval("pre", (p) => (p.textContent = ""));
    for (const [name, value] of Object.entries(params)) await (await d.$(`input[placeholder="${name}"]`)).type(value);
    if (file) await (await d.$('input[type="file"]')).uploadFile(file);
    await (await d.$("button")).click();
    await page.waitForFunction((el) => el.querySelector("pre").textContent.length > 0, {}, d);
    return d.$eval("pre", (p) => p.textContent);
  };
  const me = await send("GET/v1/me");
  check("GET /v1/me from the page answers 200 with the key", me.startsWith("200") && me.includes('"kind": "tenant"'), me.slice(0, 40));
  const list = await send("GET/v1/extensions");
  check("GET /v1/extensions shows the tenant's extension", list.startsWith("200") && list.includes("Explorer"));
  const post = await send("POST/v1/extensions");
  check("a read-only key's POST shows the 403 error", post.startsWith("403") && post.includes("missing_scope"));

  // Binary body: a greeting from the file input, with a key that may write.
  await page.$eval("#api-key", (i) => (i.value = ""));
  await page.type("#api-key", wtoken);
  const put = await send("PUT/v1/extensions/{extension_id}/greetings/{kind}", { extension_id: ext, kind: "unavailable" }, wav);
  check("a greeting uploaded from the file input is accepted", /^2\d\d/.test(put), put.slice(0, 80));
  const greetings = await send("GET/v1/extensions/{extension_id}/greetings", { extension_id: ext });
  check("…and the mailbox lists it", greetings.startsWith("200") && greetings.includes("unavailable"), greetings.slice(0, 120));
  check("no CSP violations", csp.length === 0, csp.join(" | ").slice(0, 200));
} finally {
  await browser.close();
  rpc(`${cleanup}\nIO.puts("JSON{}")`);
}
process.exit(done());
