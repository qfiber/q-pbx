// Phase 1b (security) checks against the lab server. The browser goes through an SSH SOCKS
// proxy on the VM, so the portal sees a client that is NOT on the management allowlist: the
// human check and the login limits apply as for any visitor.
// Usage: node phase1b.mjs <vm-ip>   (the server should run with qpbx_session_idle_timeout=60)
import puppeteer from "puppeteer-core";
import { spawn } from "node:child_process";
import { connect } from "node:net";
import { mkdirSync } from "node:fs";
import { fill, lab, nextWindow, reporter, sleep, sshArgs, sshTo, submit, totp } from "./lib.mjs";
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
const started = new Date().toISOString().replace("T", " ").slice(0, 19);

// Chrome resolves names on the proxy side with socks5, so the VM needs the lab names for the run.
ssh(`echo "${vm} portal.${domain} # qpbx-lab-check" | sudo tee -a /etc/hosts >/dev/null`);
const proxy = spawn("ssh", [...sshArgs, "-N", "-D", "1081", `debian@${vm}`], { stdio: "ignore" });
// Wait until the SOCKS port accepts connections.
for (let i = 0; i < 30; i++) {
  const up = await new Promise((r) => {
    const s = connect(1081, "127.0.0.1", () => { s.end(); r(true); });
    s.on("error", () => r(false));
  });
  if (up) break;
  await sleep(500);
}

const browser = await puppeteer.launch({
  // A desktop window: below 1024 px the menu is the phone's slide-in panel.
  defaultViewport: { width: 1280, height: 900 },
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  args: [
    "--proxy-server=socks5://127.0.0.1:1081",
    `--host-resolver-rules=MAP *.${domain} ${vm}, MAP ${domain} ${vm}`,
    "--ignore-certificate-errors",
  ],
});

// Any Content-Security-Policy violation on any page is a failure.
const cspViolations = [];
const watch = (page) =>
  page.on("console", (m) => /Content Security Policy|Refused to/.test(m.text()) && cspViolations.push(m.text()));

async function newPage(ctx) {
  const page = await ctx.newPage();
  watch(page);
  return page;
}

async function login(page, email, secret) {
  await page.goto(`${base}/platform/login`, { waitUntil: "networkidle0" });
  await fill(page, { "login[email]": email, "login[password]": password });
  await submit(page, "#login-form"); // the proof of work runs inside the submit
  await nextWindow();
  await fill(page, { "totp[code]": totp(secret) });
  await submit(page, "#totp-form");
}

const waitForPath = async (page, path, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (new URL(page.url()).pathname === path) return true;
    await sleep(1000);
  }
  return false;
};

try {
  // Proof of work on the setup and login pages, solved by the real browser.
  const email = `sec-${run}@${domain}`;
  const link = ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.create_platform_admin("${email}", "Sec")'`).trim().split("\n").pop();
  const a = await browser.createBrowserContext();
  const pa = await newPage(a);
  await pa.goto(link.replace(/^https?:\/\/[^/]+/, base), { waitUntil: "networkidle0" });
  check("setup page carries a proof-of-work challenge (client not allowlisted)", (await pa.$("input[data-pow-challenge]")) !== null);
  await fill(pa, { "account[password]": password, "account[password_confirmation]": password });
  await submit(pa, "#setup-form");
  const secret = await pa.$eval("#totp-secret", (e) => e.textContent.trim());
  await fill(pa, { "totp[code]": totp(secret) });
  await submit(pa, "#totp-setup-form");
  check("browser solved the proof of work; account set up with 2FA", new URL(pa.url()).pathname === "/platform", pa.url());

  // Revocation from the portal: B signs out every other session, A's open page closes.
  const b = await browser.createBrowserContext();
  const pb = await newPage(b);
  await login(pb, email, secret);
  check("second login with proof of work and 2FA", new URL(pb.url()).pathname === "/platform", pb.url());
  await pa.goto(`${base}/platform`, { waitUntil: "networkidle0" });
  await pb.goto(`${base}/platform/account`, { waitUntil: "networkidle0" });
  await pb.click("#revoke-others");
  check("'sign out everywhere else' sends the other browser's open page to login at once", await waitForPath(pa, "/platform/login", 10000), pa.url());

  // Revocation from the CLI (no broadcast reaches the app): the 30 s check catches it.
  ssh(`sudo /usr/local/sbin/qpbx eval 'QPBX.Release.revoke_sessions("${email}")'`);
  check("CLI revocation ends the open page within 40 s", await waitForPath(pb, "/platform/login", 40000), pb.url());

  // Idle timeout (lab runs with 60 s): the warning shows, then the session ends.
  const c = await browser.createBrowserContext();
  const pc = await newPage(c);
  await login(pc, email, secret);
  await pc.goto(`${base}/platform`, { waitUntil: "networkidle0" });
  await sleep(2000);
  const warning = await pc.$eval("#idle-warning", (e) => !e.classList.contains("hidden"));
  check("idle warning is shown before the session ends", warning);
  await pc.screenshot({ path: `${shots}/idle-warning.png` });
  check("an idle session ends and its page goes to login", await waitForPath(pc, "/platform/login", 120000), pc.url());

  check("no Content-Security-Policy violations in the browser", cspViolations.length === 0, cspViolations.slice(0, 2).join(" | "));
} catch (e) {
  check("browser part ran to the end", false, e.message);
} finally {
  await browser.close();
  proxy.kill();
  ssh("sudo sed -i '/# qpbx-lab-check$/d' /etc/hosts");
}

// Server-side checks.
const out = ssh(`
set +e
echo "== ratelimit"
J=$(mktemp); U=https://portal.${domain}/login; R="--resolve portal.${domain}:443:127.0.0.1"
for i in 1 2 3 4 5 6; do
  T=$(curl -sk $R -c $J -b $J $U | grep -o 'name="_csrf_token"[^>]*value="[^"]*"' | sed 's/.*value="//; s/"$//')
  curl -sk $R -c $J -b $J -o /dev/null -w "%{http_code} " -X POST --data-urlencode "_csrf_token=$T" -d "login[email]=nobody@x.test&login[password]=wrong" $U
done; echo
curl -sk $R -o /dev/null -w "%{http_code}\\n" $U
sudo -u postgres psql -qAt qpbx -c "delete from login_failures where key = 'ip:127.0.0.1'" >/dev/null
echo "== db"
P=$(sudo python3 -c 'import json;print(json.load(open("/etc/qpbx/secrets.json"))["db_password"])')
for q in "update audit_logs set action = action" "delete from audit_logs" "create table t (i int)"; do PGPASSWORD=$P psql -h 127.0.0.1 -U qpbx -d qpbx -qAt -c "$q" 2>&1 | head -1; done
echo "== root"
ps -eo user,comm --no-headers | awk '$1=="root"{print $2}' | sort -u | grep -v -E '^(kworker|ksoftirq|migration|rcu|cpuhp|idle_inject|kthreadd|kdevtmpfs|khungtask|oom_reaper|writeback|kcompactd|ksmd|khugepaged|kintegrityd|kblockd|blkcg|edac|devfreq|watchdog|kswapd|kthrotld|acpi|ipv6|mld|scsi|jbd2|ext4|irq|ata|zswap|kauditd|cryptd|psimon|pool|inet_frag|kstrp|mm_percpu|netns|nvme|slub|quota|card|hwrng|charger|tpm|ecryptfs|dmcrypt)' | tr '\\n' ' '; echo
echo "== apparmor"
sudo journalctl -k --since "${started} UTC" --no-pager -o cat | grep -c 'apparmor="ALLOWED"'
echo "== ratings"
systemd-analyze security --no-pager 2>/dev/null | grep -E 'qpbx|freeswitch|kamailio|postgres|nginx' | awk '{print $1"="$2}' | tr '\\n' ' '; echo
echo "== secrets"
stat -c %a /etc/qpbx/secrets.json
`);
const section = (name) => out.split(`== ${name}\n`)[1].split("\n== ")[0].trim();

const [codes, after] = section("ratelimit").split("\n");
// After the block the login page itself answers 429, so a bot has no CSRF token and its next
// post is refused with 403 even before the block check: refused either way.
const c = codes.trim().split(" ");
check(
  "5 failed logins from one IP block it: HTTP 429 (no proof of work counts as a failure)",
  c.slice(0, 4).every((x) => x === "200") && c[4] === "429" && ["403", "429"].includes(c[5]) && after.trim() === "429",
  `${codes.trim()} then GET ${after.trim()}`
);
const db = section("db").split("\n");
check("app database role cannot change the audit log or the schema", db.every((l) => /permission denied/.test(l)), db.join(" | "));
const allowedRoot = ["agetty", "qemu-ga", "sshd", "systemd", "systemd-journal", "systemd-logind", "systemd-udevd", "unattended-upgr"];
const roots = section("root").split(/\s+/).filter(Boolean);
check("only base system daemons run as root", roots.every((r) => allowedRoot.includes(r)), roots.join(" "));
check("no AppArmor complaints during the run", section("apparmor") === "0", section("apparmor"));
const ratings = section("ratings").split(/\s+/).filter(Boolean).map((r) => r.split("="));
check("every Q-PBX-related unit rates OK in systemd-analyze security (< 5)", ratings.length >= 6 && ratings.every(([, v]) => parseFloat(v) < 5), section("ratings"));
check("secrets file is root-only (600)", section("secrets") === "600", section("secrets"));

dropPlatformAdmins(ssh, `sec-${run}@`);
process.exit(done(shots));
