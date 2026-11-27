// Phase 2 (2-2e) checks against the lab: the telephony configuration pages work end to end.
// A platform admin adds a carrier trunk and a number; a tenant admin (Arabic portal) creates
// an extension and a device, and the device's one-time password registers over SIP.
// Usage: node phase2-config.mjs <vm-ip>
import puppeteer from "puppeteer-core";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { fill, reporter, sleep, sshTo, submit, totp } from "./lib.mjs";

const vm = process.argv[2] ?? "192.168.10.25";
const domain = process.env.QPBX_LAB_DOMAIN ?? "pbx.lab.test";
const base = `https://portal.${domain}`;
const run = Date.now().toString(36);
const password = "lab-password-" + run;
const shots = new URL("./screenshots/phase2/", import.meta.url).pathname;
mkdirSync(shots, { recursive: true });
const ssh = sshTo(vm);
const { check, done } = reporter();
const register = (...args) =>
  execFileSync("python3", [new URL("../tools/sip_register.py", import.meta.url).pathname, vm, ...args], { encoding: "utf8" }).trim();

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  args: [`--host-resolver-rules=MAP *.${domain} ${vm}, MAP ${domain} ${vm}`, "--ignore-certificate-errors"],
});
const cspViolations = [];
const newPage = async (ctx) => {
  const p = await ctx.newPage();
  p.on("console", (m) => /Content Security Policy|Refused to/.test(m.text()) && cspViolations.push(m.text()));
  return p;
};

async function completeSetup(page, url) {
  await page.goto(url.replace(/^https?:\/\/[^/]+/, base), { waitUntil: "networkidle0" });
  await fill(page, { "account[password]": password, "account[password_confirmation]": password });
  await submit(page, "#setup-form");
  const secret = await page.$eval("#totp-secret", (e) => e.textContent.trim());
  await fill(page, { "totp[code]": totp(secret) });
  await submit(page, "#totp-setup-form");
}

const text = (page, sel) => page.$eval(sel, (e) => e.textContent);
const waitText = (page, sel, t) => page.waitForFunction((s, x) => document.querySelector(s)?.textContent.includes(x), { timeout: 15000 }, sel, t);
const shot = (page, name) => page.screenshot({ path: `${shots}/${name}.png`, fullPage: true });

try {
  // Platform admin, plan, tenant (portal in English).
  const ap = await newPage(await browser.createBrowserContext());
  await completeSetup(ap, ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.create_platform_admin("ops2-${run}@${domain}", "Ops")'`).trim().split("\n").pop());
  check("platform admin signed in", new URL(ap.url()).pathname === "/platform", ap.url());

  await ap.goto(`${base}/platform/plans`, { waitUntil: "networkidle0" });
  await fill(ap, { "plan[name]": `P2 ${run}`, "plan[max_extensions]": "5" });
  await ap.click("#plan-form button");
  await waitText(ap, "#plans", `P2 ${run}`);
  await ap.goto(`${base}/platform/tenants/new`, { waitUntil: "networkidle0" });
  const planId = await ap.$eval(`select[name="tenant[plan_id]"]`, (s, n) => [...s.options].find((o) => o.text === n).value, `P2 ${run}`);
  const slug = `p2-${run}`;
  await fill(ap, {
    "tenant[name]": `P2 Tenant ${run}`, "tenant[slug]": slug, "tenant[plan_id]": planId, "tenant[timezone]": "Asia/Jerusalem",
    "tenant[locale]": "ar", "tenant[admin_name]": "Boss", "tenant[admin_email]": `boss2-${run}@${domain}`,
  });
  await ap.click("#tenant-form button");
  await ap.waitForSelector("#setup-link code");
  const tenantLink = await text(ap, "#setup-link code");
  const sipDomain = `${slug}.${domain}`;

  // Carrier trunk with two addresses.
  await ap.goto(`${base}/platform/trunks/new`, { waitUntil: "networkidle0" });
  await fill(ap, { "trunk[name]": `Carrier ${run}`, "trunk[auth_mode]": "ip", "trunk[addresses][0][host]": `sbc1-${run}.carrier.test` });
  await ap.click("#add-address");
  await ap.waitForSelector(`[name="trunk[addresses][1][host]"]`);
  await fill(ap, { "trunk[addresses][1][host]": `sbc2-${run}.carrier.test`, "trunk[addresses][1][priority]": "2" });
  await shot(ap, "platform-trunk-form");
  await ap.click("#trunk-form button[type=submit], #trunk-form button.btn-primary");
  await ap.waitForSelector("#trunks");
  const trunks = await text(ap, "#trunks");
  check("platform admin added a trunk with two addresses", trunks.includes(`sbc1-${run}.carrier.test`) && trunks.includes(`sbc2-${run}.carrier.test`));

  // A number typed the local way, assigned to the tenant.
  const local = `03-5${run.slice(-6).replace(/\D/g, "7").padStart(6, "7")}`;
  await ap.goto(`${base}/platform/numbers`, { waitUntil: "networkidle0" });
  const trunkId = await ap.$eval(`select[name="did[trunk_id]"]`, (s, n) => [...s.options].find((o) => o.text === n).value, `Carrier ${run}`);
  const tenantId = await ap.$eval(`select[name="did[tenant_id]"]`, (s, n) => [...s.options].find((o) => o.text === n).value, `P2 Tenant ${run}`);
  await fill(ap, { "did[number]": local, "did[trunk_id]": trunkId, "did[tenant_id]": tenantId });
  await ap.click("#did-form button");
  const e164 = "+9723" + local.slice(3).replace(/-/g, "");
  await waitText(ap, "#dids", e164);
  check("a number typed as 03-… is stored in E.164", (await text(ap, "#dids")).includes(e164), e164);
  await shot(ap, "platform-numbers");

  // Tenant admin, Arabic portal: extension and device.
  const tp = await newPage(await browser.createBrowserContext());
  await completeSetup(tp, tenantLink);
  await tp.goto(`${base}/app/extensions`, { waitUntil: "networkidle0" });
  check("tenant pages are in Arabic, right to left", (await tp.$eval("html", (h) => h.dir)) === "rtl");
  await fill(tp, { "extension[number]": "101", "extension[name]": "الاستقبال" });
  await tp.click("#extension-form button");
  await tp.waitForSelector("#device-form");
  await fill(tp, { "device[label]": "desk", "device[mac]": "000b82" + Date.now().toString(16).slice(-6) });
  await tp.click("#device-form button");
  await tp.waitForSelector("#secret-password");
  const user = (await text(tp, "#secret-username")).trim();
  const devicePassword = (await text(tp, "#secret-password")).trim();
  await shot(tp, "tenant-device-password-ar");
  check("the device form is empty again after the add", (await tp.$eval(`[name="device[label]"]`, (e) => e.value)) === "");
  check("device gets SIP login 101-desk and a 24-character password", user === "101-desk" && devicePassword.length === 24, user);

  await sleep(1000);
  check("the device registers with that password", register(user, sipDomain, devicePassword) === "SIP/2.0 200 OK");
  await tp.reload({ waitUntil: "networkidle0" });
  check("the password is not shown again after a reload", !(await tp.content()).includes(devicePassword));
  await shot(tp, "tenant-extension-ar");

  // Number destination, route, office IP, number format.
  await tp.goto(`${base}/app/numbers`, { waitUntil: "networkidle0" });
  check("tenant sees its number in national form", (await text(tp, "main")).includes(local.replace(/-/g, "")));
  const form = await tp.$("form[id^=did-form-]");
  const extId = await form.$eval(`select[name="did[destination_id]"]`, (s) => [...s.options].find((o) => o.text.startsWith("101")).value);
  await form.$eval(`select[name="did[destination_type]"]`, (s) => { s.value = "extension"; });
  await form.$eval(`select[name="did[destination_id]"]`, (s, v) => { s.value = v; }, extId);
  await form.$eval("button", (b) => b.click());
  await sleep(1500);
  await shot(tp, "tenant-numbers-ar");
  const dest = ssh(`sudo -u postgres psql -qAt qpbx -c "select destination_type from dids where number = '${e164}'"`).trim();
  check("tenant pointed the number at extension 101", dest === "extension", dest);

  await tp.goto(`${base}/app/routes`, { waitUntil: "networkidle0" });
  const routeTrunk = await tp.$eval(`select[name="route[trunk_1]"]`, (s, n) => [...s.options].find((o) => o.text.startsWith(n)).value, `Carrier ${run}`);
  await fill(tp, { "route[name]": "Israel", "route[prefixes_text]": "+972", "route[trunk_1]": routeTrunk });
  await tp.click("#route-form button.btn-primary");
  await waitText(tp, "#routes", `Carrier ${run}`);
  await shot(tp, "tenant-routes-ar");
  check("the route form is empty again after the save", (await tp.$eval(`[name="route[name]"]`, (e) => e.value)) === "");
  check("tenant created an outbound route on the shared trunk", (await text(tp, "#routes")).includes(`Carrier ${run}`));

  await tp.goto(`${base}/app/office-ips`, { waitUntil: "networkidle0" });
  await fill(tp, { "entry[cidr]": "198.51.100.0/29", "entry[reason]": "HQ" });
  await tp.click("#office-ip-form button");
  await waitText(tp, "#office-ips", "198.51.100.0/29");
  await shot(tp, "tenant-office-ips-ar");
  await tp.goto(`${base}/app/number-format`, { waitUntil: "networkidle0" });
  await shot(tp, "tenant-number-format-ar");
  check("tenant added an office IP", ssh(`sudo -u postgres psql -qAt qpbx -c "select count(*) from firewall_entries where level = 'tenant' and cidr = '198.51.100.0/29' and reason = 'HQ'"`).trim() !== "0");

  // Removing the device cuts its SIP login at once.
  await tp.goto(`${base}/app/extensions`, { waitUntil: "networkidle0" });
  await tp.click("#extensions tr");
  await tp.waitForSelector("[id^=delete-device-]");
  tp.on("dialog", (d) => d.accept());
  await tp.click("[id^=delete-device-]");
  await sleep(1500);
  check("after removing the device its password is refused", register(user, sipDomain, devicePassword) === "SIP/2.0 401 Unauthorized");

  check("no Content-Security-Policy violations", cspViolations.length === 0, cspViolations.slice(0, 2).join(" | "));
} catch (e) {
  check("browser part ran to the end", false, e.message);
} finally {
  await browser.close();
}

process.exit(done(shots));
