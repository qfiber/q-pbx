// Phase 1 "Done when" checks against the lab server, through a real headless Chrome:
//   1. a platform admin creates a tenant with a plan,
//   2. a tenant admin logs in with 2FA in either language (both are checked),
//   3. an allowlist change reaches nftables through the helper.
// Usage: node phase1.mjs <vm-ip>   (domain pbx.lab.test, SSH key from lab/create-vm.sh)
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { fill, nextWindow, reporter, sshTo, submit, totp } from "./lib.mjs";
import { dropPlatformAdmins } from "./lib.mjs";

const vm = process.argv[2] ?? "192.168.10.25";
const domain = process.env.QPBX_LAB_DOMAIN ?? "pbx.lab.test";
const base = `https://portal.${domain}`;
const run = Date.now().toString(36);
const password = "lab-password-" + run;
const shots = new URL("./screenshots/", import.meta.url).pathname;
mkdirSync(shots, { recursive: true });
const ssh = sshTo(vm);
const { check, done } = reporter();

const browser = await puppeteer.launch({
  // A desktop window: below 1024 px the menu is the phone's slide-in panel.
  defaultViewport: { width: 1280, height: 900 },
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  // Lab only: names resolve to the VM, and the certificate comes from a test CA.
  args: [`--host-resolver-rules=MAP *.${domain} ${vm}, MAP ${domain} ${vm}`, "--ignore-certificate-errors"],
});

// Setup link -> password -> 2FA enrolment. Returns the TOTP secret.
async function completeSetup(page, url, label) {
  await page.goto(url, { waitUntil: "networkidle0" });
  await fill(page, { "account[password]": password, "account[password_confirmation]": password });
  await submit(page, "#setup-form");
  const secret = await page.$eval("#totp-secret", (e) => e.textContent.trim());
  await page.screenshot({ path: `${shots}/${label}-2fa-setup.png` });
  await fill(page, { "totp[code]": totp(secret) });
  await submit(page, "#totp-setup-form");
  return secret;
}

try {
  // 1. Platform admin: created with the CLI, sets password and 2FA in the portal.
  const adminEmail = `ops-${run}@${domain}`;
  const adminLink = ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.create_platform_admin("${adminEmail}", "Lab Ops")'`).trim().split("\n").pop();
  const admin = await browser.createBrowserContext();
  const ap = await admin.newPage();
  await completeSetup(ap, adminLink.replace(/^https?:\/\/[^/]+/, base), "platform-admin");
  check("platform admin enrolled 2FA and reached /platform", new URL(ap.url()).pathname === "/platform", ap.url());

  // Create a plan, then a tenant with that plan and its first tenant admin.
  await ap.goto(`${base}/platform/plans/new`, { waitUntil: "networkidle0" });
  const planName = `Lab plan ${run}`;
  await fill(ap, { "plan[name]": planName, "plan[max_extensions]": "25" });
  await ap.click("#plan-form button");
  await ap.waitForFunction((n) => document.querySelector("#plans")?.textContent.includes(n), {}, planName);

  await ap.goto(`${base}/platform/tenants/new`, { waitUntil: "networkidle0" });
  const planId = await ap.$eval(`select[name="tenant[plan_id]"]`, (s, n) => [...s.options].find((o) => o.text === n).value, planName);
  const slug = `lab-${run}`;
  const tenantAdminEmail = `boss-${run}@${domain}`;
  await fill(ap, {
    "tenant[name]": `Lab Tenant ${run}`, "tenant[slug]": slug, "tenant[plan_id]": planId,
    "tenant[timezone]": "Asia/Jerusalem", "tenant[locale]": "ar",
    "tenant[admin_name]": "Lab Boss", "tenant[admin_email]": tenantAdminEmail,
  });
  await ap.click("#tenant-form button");
  await ap.waitForSelector("#setup-link code");
  const tenantLink = await ap.$eval("#setup-link code", (e) => e.textContent.trim());
  await ap.screenshot({ path: `${shots}/tenant-created.png`, fullPage: true });
  const listed = await ap.$eval("#tenants", (t) => t.textContent);
  check("platform admin created a tenant with a plan", listed.includes(`${slug}.${domain}`) && listed.includes(planName), `${slug}.${domain} on ${planName}`);

  // 2. Tenant admin: setup link, then log in with password + 2FA, in Arabic and in English.
  const tenant = await browser.createBrowserContext();
  const tp = await tenant.newPage();
  const tenantSecret = await completeSetup(tp, tenantLink.replace(/^https?:\/\/[^/]+/, base), "tenant-admin");
  check("tenant admin enrolled 2FA and reached /app", new URL(tp.url()).pathname === "/app", tp.url());

  for (const lang of ["ar", "en"]) {
    await tp.goto(`${base}/app`, { waitUntil: "networkidle0" });
    await Promise.all([tp.waitForNavigation({ waitUntil: "networkidle0" }), tp.click("#logout")]);
    await tp.goto(`${base}/login`, { waitUntil: "networkidle0" });
    await tp.setExtraHTTPHeaders({ referer: `${base}/login` });
    await tp.goto(`${base}/locale/${lang}`, { waitUntil: "networkidle0" });
    await fill(tp, { "login[email]": tenantAdminEmail, "login[password]": password });
    await submit(tp, "#login-form");
    const askedForCode = new URL(tp.url()).pathname === "/2fa";
    await nextWindow();
    await fill(tp, { "totp[code]": totp(tenantSecret) });
    await submit(tp, "#totp-form");
    const html = await tp.evaluate(() => ({ lang: document.documentElement.lang, dir: document.documentElement.dir, text: document.body.innerText }));
    await tp.screenshot({ path: `${shots}/tenant-admin-home-${lang}.png` });
    const expected = lang === "ar" ? "المصادقة الثنائية مفعّلة" : "Two-factor authentication is on.";
    check(`tenant admin logged in with 2FA in ${lang === "ar" ? "Arabic (RTL)" : "English"}`,
      askedForCode && new URL(tp.url()).pathname === "/app" && html.lang === lang && html.dir === (lang === "ar" ? "rtl" : "ltr") && html.text.includes(expected),
      `asked for code: ${askedForCode}, lang=${html.lang}, dir=${html.dir}`);
  }

  // 3. Allowlist change in the portal reaches nftables through qpbx-fwd.
  const testIp = "203.0.113.77";
  const stepStart = Date.now() - 2000;
  await ap.goto(`${base}/platform/firewall`, { waitUntil: "networkidle0" });
  await fill(ap, { "entry[cidr]": testIp, "entry[kind]": "allow", "entry[scope]": "ssh", "entry[reason]": `lab check ${run}` });
  await ap.click("#firewall-form button");
  await ap.waitForFunction((ip) => document.querySelector("#firewall-entries")?.textContent.includes(ip), {}, testIp);
  await ap.screenshot({ path: `${shots}/firewall.png`, fullPage: true });
  const leftover = await ap.$eval(`#firewall-form [name="entry[cidr]"]`, (e) => e.value);
  check("firewall form is empty again after the add", leftover === "", `address field: "${leftover}"`);
  let inSet = false;
  for (let i = 0; i < 10 && !inSet; i++) {
    inSet = ssh("sudo nft list set inet qpbx allow_ssh_v4").includes(testIp);
    if (!inSet) await new Promise((r) => setTimeout(r, 1000));
  }
  // Each sync replaces all 12 sets; look for the allow_ssh_v4 replace that carried the new entry.
  const fwdLog = ssh(`sudo journalctl -u qpbx-fwd --since "${new Date(stepStart).toISOString().replace("T", " ").slice(0, 19)} UTC" -o cat --no-pager`);
  const viaHelper = /replace allow_ssh_v4 \((\d+) elements\)/.test(fwdLog);
  check("allowlist change reached nftables through qpbx-fwd", inSet && viaHelper, `${testIp} in allow_ssh_v4; qpbx-fwd logged the replace: ${viaHelper}`);

  // Clean up the test entry through the portal (the original management IP stays).
  await ap.evaluate(() => { window.confirm = () => true; });
  const del = await ap.$$eval("#firewall-entries tr", (rows, ip) => rows.find((r) => r.textContent.includes(ip))?.querySelector("[id^=delete-]")?.id, testIp);
  if (del) { await ap.click(`#${del}`); await new Promise((r) => setTimeout(r, 2000)); }
  check("removing the test entry also leaves nftables", !ssh("sudo nft list set inet qpbx allow_ssh_v4").includes(testIp));
} catch (e) {
  check("script ran to the end", false, e.message);
} finally {
  await browser.close();
}

dropPlatformAdmins(ssh, `ops-${run}@`);
process.exit(done(shots));
