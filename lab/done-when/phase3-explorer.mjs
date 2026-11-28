// 3-1 lab check: the API explorer at /v1/docs in a real browser. It loads the OpenAPI
// document, sends requests with a key typed into the page, shows the answers, and the page
// breaks no Content-Security-Policy rule.
// usage: node lab/done-when/phase3-explorer.mjs <vm-ip>
import puppeteer from "puppeteer-core";
import { reporter, sshTo } from "./lib.mjs";

const vm = process.argv[2];
const ssh = sshTo(vm);
const { check, done } = reporter();
const run = Date.now().toString(36);
const rpc = (code) => JSON.parse(ssh(`sudo /usr/local/sbin/qpbx rpc '${code.replace(/'/g, "'\\''")}'`).match(/JSON(.*)$/m)[1]);
const cleanup = `for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "apix-"), do: QPBX.Repo.delete!(t)`;

const { token } = rpc(`${cleanup}
a = {:system, "lab"}
{:ok, t} = QPBX.Core.create_tenant(%{name: "apix", slug: "apix-${run}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(QPBX.Core.list_plans()).id}, a)
{:ok, u} = QPBX.Core.create_user(t, %{email: "apix-${run}@x.test", name: "X"}, "tenant_admin", a)
s = QPBX.Core.scope_for(u)
{:ok, _} = QPBX.Core.create_extension(s, %{number: "101", name: "Explorer"}, a)
{:ok, _, tok} = QPBX.Core.create_api_key(s, %{name: "x", scopes: ["read"]}, a)
IO.puts("JSON" <> Jason.encode!(%{token: tok}))`);

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
  const send = async (match) => {
    // The summary text follows the path: an exact path, not one that merely starts the same.
    const i = ops.findIndex((o) => o.startsWith(match) && /^[A-Z]/.test(o.slice(match.length)));
    const d = (await page.$$("#operations details"))[i];
    await d.evaluate((el) => (el.open = true));
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
  check("no CSP violations", csp.length === 0, csp.join(" | ").slice(0, 200));
} finally {
  await browser.close();
  rpc(`${cleanup}\nIO.puts("JSON{}")`);
}
process.exit(done());
