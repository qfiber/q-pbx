// Screenshots of the portal for design review: the sign-in page and the main pages of a
// platform admin and a tenant admin, at desktop and phone widths, light and dark, English and
// Arabic. Accounts are made for the run and removed after.
// usage: node lab/done-when/portal-shots.mjs <vm-ip> [out-dir]   (default ~/.local/share/qpbx-lab/work/shots)
import puppeteer from "puppeteer-core";
import { mkdirSync } from "node:fs";
import { fill, lab, sshTo, submit, totp } from "./lib.mjs";

const vm = process.argv[2] ?? "192.168.10.25";
const out = process.argv[3] ?? `${lab}/work/shots`;
const domain = "pbx.lab.test";
const base = `https://portal.${domain}`;
const run = Date.now().toString(36);
const password = "shots-password-" + run;
mkdirSync(out, { recursive: true });
const ssh = sshTo(vm);
const rpc = (code) => JSON.parse(ssh(`sudo /usr/local/sbin/qpbx rpc '${code.replace(/'/g, "'\\''")}'`).match(/JSON(.*)$/m)[1]);
const cleanup = `
for t <- QPBX.Core.list_tenants(), String.starts_with?(t.slug, "shots-"), do: QPBX.Repo.delete!(t)
for a <- QPBX.Repo.all(QPBX.Core.PlatformAdmin), String.starts_with?(a.email, "shots-"), do: QPBX.Repo.delete!(a)`;

const S = rpc(`${cleanup}
a = {:system, "lab"}
{:ok, t} = QPBX.Core.create_tenant(%{name: "Acme Dental", slug: "shots-${run}", timezone: "Asia/Jerusalem", locale: "en", plan_id: hd(QPBX.Core.list_plans()).id}, a)
{:ok, u} = QPBX.Core.create_user(t, %{email: "shots-${run}@acme.test", name: "Dana Levi"}, "tenant_admin", a)
s = QPBX.Core.scope_for(u)
for {n, name} <- [{"101", "Reception"}, {"102", "Dr. Cohen"}, {"103", "Billing"}, {"104", "Lab"}],
    do: {:ok, _} = QPBX.Core.create_extension(s, %{number: n, name: name}, a)
IO.puts("JSON" <> Jason.encode!(%{email: u.email, tenant: t.id}))`);
const adminLink = ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.create_platform_admin("shots-${run}@${domain}", "Sam Ops")'`).trim().split("\n").pop();
const userLink = ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.setup_link("${S.email}")'`).trim().split("\n").pop();

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  args: [`--host-resolver-rules=MAP *.${domain} ${vm}`, "--ignore-certificate-errors"],
});
const sizes = { desktop: { width: 1440, height: 900 }, phone: { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 } };

async function shot(page, name, size, theme) {
  await page.setViewport(sizes[size]);
  await page.evaluate((t) => document.documentElement.setAttribute("data-theme", t), theme);
  await new Promise((r) => setTimeout(r, 300));
  // Full-page captures of right-to-left pages come out shifted in headless Chrome: window only.
  const rtl = await page.evaluate(() => document.documentElement.dir === "rtl");
  await page.screenshot({ path: `${out}/${name}-${size}-${theme}.png`, fullPage: size === "desktop" && !rtl });
}

async function signIn(link) {
  const page = await (await browser.createBrowserContext()).newPage();
  await page.goto(link.replace(/^https?:\/\/[^/]+/, base), { waitUntil: "networkidle0" });
  await fill(page, { "account[password]": password, "account[password_confirmation]": password });
  await submit(page, "#setup-form");
  const secret = await page.$eval("#totp-secret", (e) => e.textContent.trim());
  await fill(page, { "totp[code]": totp(secret) });
  await submit(page, "#totp-setup-form");
  return page;
}

try {
  const anon = await browser.newPage();
  // A dark system with the light theme chosen by hand: the page must be light.
  await anon.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "dark" }]);
  await anon.goto(`${base}/login`, { waitUntil: "networkidle0" });
  await anon.evaluate(() => document.documentElement.setAttribute("data-theme", "light"));
  const bg = await anon.evaluate(() => getComputedStyle(document.body.firstElementChild).backgroundColor);
  console.log(`light theme on a dark system: ${bg === "rgb(238, 242, 245)" ? "light" : "NOT light (" + bg + ")"}`);
  await anon.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
  await anon.goto(`${base}/login`, { waitUntil: "networkidle0" });
  for (const size of ["desktop", "phone"]) for (const theme of ["light", "dark"]) await shot(anon, "login", size, theme);
  await anon.goto(`${base}/locale/ar`, { waitUntil: "networkidle0" });
  await anon.goto(`${base}/login`, { waitUntil: "networkidle0" });
  await shot(anon, "login-ar", "desktop", "light");

  const admin = await signIn(adminLink);
  for (const path of ["/platform", "/platform/health", "/platform/tenants", "/platform/tenants/new", `/platform/tenants/${S.tenant}`, "/platform/numbers", "/platform/numbering", "/platform/trunks", "/platform/plans", "/platform/admins", "/platform/protection", "/platform/alerts"]) {
    await admin.goto(base + path, { waitUntil: "networkidle0" });
    const name = "platform" + path.replace("/platform", "").replace(S.tenant, "one").replace(/\//g, "-");
    await shot(admin, name, "desktop", "light");
  }
  await shot(admin, "platform-plans", "desktop", "dark");
  await admin.goto(`${base}/platform/alerts`, { waitUntil: "networkidle0" });
  const open = await admin.$("[id^=open-]");
  if (open) {
    await open.click();
    await admin.waitForSelector("#deliveries", { timeout: 5000 }).catch(() => {});
    await shot(admin, "platform-alerts-details", "desktop", "light");
  }

  const user = await signIn(userLink);
  for (const path of ["/app", "/app/extensions", "/app/users", "/app/me", "/app/routes", "/app/calls", "/app/api-keys"]) {
    await user.goto(base + path, { waitUntil: "networkidle0" });
    const name = "tenant" + path.replace("/app", "").replace(/\//g, "-");
    await shot(user, name, "desktop", "light");
    await shot(user, name, "phone", "light");
  }
  await user.goto(`${base}/app/extensions`, { waitUntil: "networkidle0" });
  await user.setViewport(sizes.phone);
  await user.click("#menu-button");
  await shot(user, "tenant-menu", "phone", "dark");
  await user.goto(`${base}/locale/ar`, { waitUntil: "networkidle0" });
  await user.goto(`${base}/app/extensions`, { waitUntil: "networkidle0" });
  await shot(user, "tenant-extensions-ar", "desktop", "light");
  console.log(out);
} finally {
  await browser.close();
  rpc(`${cleanup}\nIO.puts("JSON{}")`);
}
