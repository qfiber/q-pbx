// Helpers shared by the lab Done-when scripts.
import { execFileSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { homedir } from "node:os";

export const lab = `${homedir()}/.local/share/qpbx-lab`;
export const sshArgs = ["-o", "IdentitiesOnly=yes", "-i", `${lab}/id_ed25519`, "-o", `UserKnownHostsFile=${lab}/known_hosts`];

export const sshTo = (vm) => (cmd) => execFileSync("ssh", [...sshArgs, `debian@${vm}`, cmd], { encoding: "utf8" });

// TOTP (RFC 6238, SHA-1, 30 s, 6 digits) from a base32 secret.
export function totp(secret32, t = Date.now()) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of secret32.replace(/=+$/, "")) bits += alphabet.indexOf(c).toString(2).padStart(5, "0");
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(t / 30000)));
  const h = createHmac("sha1", key).update(counter).digest();
  const o = h[h.length - 1] & 0xf;
  return ((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).toString().padStart(6, "0");
}

// Each code is accepted once; wait for a fresh 30 s window before the next one.
export const nextWindow = () => new Promise((r) => setTimeout(r, 30000 - (Date.now() % 30000) + 1000));
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function submit(page, form) {
  await Promise.all([page.waitForNavigation({ waitUntil: "networkidle0", timeout: 60000 }).catch(() => {}), page.click(`${form} button[type=submit], ${form} button`)]);
}

export async function fill(page, values) {
  for (const [name, value] of Object.entries(values)) {
    const el = await page.$(`[name="${name}"]`);
    const tag = await el.evaluate((e) => e.tagName);
    if (tag === "SELECT") await page.select(`[name="${name}"]`, value);
    else { await el.click({ clickCount: 3 }); await el.type(value); }
  }
}

export function reporter() {
  const results = [];
  const check = (name, ok, detail = "") => {
    results.push({ name, ok, detail });
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
  };
  const done = (shots) => {
    const failed = results.filter((r) => !r.ok).length;
    console.log(`\n${results.length - failed} passed, ${failed} failed.${shots ? " Screenshots: " + shots : ""}`);
    return failed ? 1 : 0;
  };
  return { check, done };
}

// Removes the platform admins a check created (their emails start with `prefix`), so lab runs do
// not pile up admins that every platform alert then goes to.
export function dropPlatformAdmins(ssh, prefix) {
  const code = `for a <- QPBX.Repo.all(QPBX.Core.PlatformAdmin), String.starts_with?(a.email, "${prefix}"), do: QPBX.Repo.delete!(a)`;
  ssh(`sudo /usr/local/sbin/qpbx rpc '${code}'`);
}
