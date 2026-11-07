// The assistant's keys across devices end to end (WP5.21 of docs/PLAN.md),
// in the user's vault, which the first sign-in with a password makes
// (WP5.74b1):
// the server's build of the wiki, served by a real wiki-server, in headless
// Chromium with a virtual authenticator (Chromium's own WebAuthn, through
// DevTools' WebAuthn domain), which makes and uses real passkeys with the
// PRF extension. So the browser's navigator.credentials, its PRF output,
// WebCrypto and the server's checks of real attestation objects and ES256
// signatures (Wiki.Server.WebAuthn) all take part, which the browser tests'
// stub of navigator.credentials leaves out. What a person sees in the
// browser's own passkey dialog is not tested here: the virtual
// authenticator answers in its place.
//
//   node toolchain/test-passkeys.mjs [dir]    # default dist-newstyle/wasm/public/app
//
// WebAuthn takes no IP address as the relying party, so the wiki is
// reached at localhost, which is a secure context over plain HTTP.
//
// Needs the native builds of wiki-server and wiki-app-prerender, and the
// Chromium Playwright launches.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { cp, mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { chromium } from "playwright";

const built = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
const timeout = 30_000;
const binary = (variable, target) =>
  process.env[variable] ?? execFileSync("cabal", ["list-bin", "-v0", target, "--builddir=dist-newstyle/native"], { encoding: "utf8" }).trim();

// The server's build: the demo's files and the server's page.
const work = await mkdtemp(join(tmpdir(), "wiki-passkeys-"));
const app = join(work, "app");
const data = join(work, "data");
await cp(built, app, {
  recursive: true,
  filter: (source) => {
    const rel = source.slice(built.length).replace(/^[/\\]/, "");
    return !(rel.endsWith(".html") && !rel.includes("/") && rel !== "offline.html") && !/^(s|search)([/\\]|$)/.test(rel);
  },
});
execFileSync(binary("WIKI_PRERENDER", "wiki-app:exe:wiki-app-prerender"), ["--server", "web/index.html", app], {
  stdio: "inherit",
  env: { ...process.env, HALOGEN_BASE_PATH: "/" },
});
const wikiServer = binary("WIKI_SERVER", "wiki-server:exe:wiki-server");
const password = "the passkeys test's password";
execFileSync(wikiServer, ["users", "add", "--data", data, "ada", "--display-name", "Ada", "--admin"], {
  input: `${password}\n`,
  stdio: ["pipe", "inherit", "inherit"],
});

const probe = createServer();
const port = await new Promise((ready) => probe.listen(0, "127.0.0.1", () => ready(probe.address().port)));
await new Promise((done) => probe.close(done));
const server = spawn(wikiServer, ["serve", "--data", data, "--static", app, "--listen", `127.0.0.1:${port}`, "--no-admin-listen"], {
  stdio: ["ignore", "pipe", "pipe"],
});
let log = "";
await new Promise((ready, fail) => {
  const read = (chunk) => {
    log += chunk;
    if (/listener=public/.test(log)) ready();
  };
  server.stdout.on("data", read);
  server.stderr.on("data", read);
  server.on("exit", (code) => fail(new Error(`wiki-server exited (${code}):\n${log}`)));
  // Bound startup without keeping a completed smoke test process alive.
  setTimeout(() => fail(new Error(`wiki-server did not start:\n${log}`)), timeout).unref();
});
const origin = `http://localhost:${port}`;

const failures = [];
const browser = await chromium.launch();
// Ada's session, signed in through the header's form in a browser of its
// own: a password signs in through OPAQUE (WP5.74a), which the application
// runs and which never sends the password, and the cookie is taken from it.
const signInContext = await browser.newContext({ serviceWorkers: "block" });
const signInPage = await signInContext.newPage();
await signInPage.goto(`${origin}/`);
await signInPage.locator("#app .sign-in-toggle").click();
await signInPage.locator("#app .sign-in-form input[name=login]").fill("ada");
await signInPage.locator("#app .sign-in-form input[name=password]").fill(password);
await signInPage.locator("#app .sign-in-form button[type=submit]").click();
await signInPage.locator("#app .sign-out").waitFor({ timeout });
// The first sign-in with a password makes Ada's vault (WP5.74b1): her key
// pair, the vault's key wrapped for her password, and her public key.
const signedInApi = async (path) => (await signInContext.request.get(`${origin}/api/v1/${path}`, { headers: { "X-Wiki-Request": "1" } })).json();
const first = await (async () => {
  for (let tries = 0; tries < 60; tries++) {
    const answer = await signInContext.request.get(`${origin}/api/v1/assistant/vault`, { headers: { "X-Wiki-Request": "1" } });
    if (answer.status() === 200) return answer.json();
    await new Promise((later) => setTimeout(later, 500));
  }
  return null;
})();
assert.ok(first?.vault.items.identity && first.vault.wraps.password, "the first sign-in made no vault with the key pair and the password's wrap");
const ownKey = await signedInApi("account/public-keys/" + encodeURIComponent((await signedInApi("session")).user.id));
assert.equal(ownKey.keyId, first.vault.items.identity.keyId, "the directory names another key pair than the vault's");
console.log("ok: the first sign-in with a password makes the key pair, wrapped for the password, and the public key");
const token = (await signInContext.cookies()).find((c) => c.name === "wiki_session")?.value;
assert.ok(token, "no session cookie");
await signInContext.close();
const api = (path) => fetch(`${origin}/api/v1/${path}`, { headers: { Cookie: `wiki_session=${token}`, "X-Wiki-Request": "1" } });

try {
  const context = await browser.newContext({ serviceWorkers: "block" });
  await context.addCookies([{ name: "wiki_session", value: token, url: origin }]);
  // The scripted provider answers for every provider: keeping a key fetches
  // the provider's models, and this test reaches no provider.
  await context.addInitScript(() => {
    globalThis.wikiAssistantScript = { turns: [] };
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => failures.push(`page error: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("404")) failures.push(`console error: ${message.text()}`);
  });
  const devtools = await context.newCDPSession(page);
  await devtools.send("WebAuthn.enable");
  const authenticator = {
    protocol: "ctap2",
    transport: "internal",
    hasResidentKey: true,
    hasUserVerification: true,
    isUserVerified: true,
    hasPrf: true,
    automaticPresenceSimulation: true,
  };
  const firstAuthenticator = await devtools.send("WebAuthn.addVirtualAuthenticator", { options: authenticator });

  await page.goto(`${origin}/assistant/`);
  const anthropic = page.locator(".assistant-provider-settings[data-provider='anthropic']");
  await anthropic.locator(".assistant-key").fill("a-test-key-for-anthropic");
  await anthropic.locator(".assistant-key-form button").click();
  await anthropic.locator(".assistant-key-kept").waitFor({ timeout });

  // Making a passkey asks for the password: a passkey signs Ada in. The
  // vault her sign-in made opens with the password alone, which unwraps
  // its key for the new passkey to wrap.
  await page.locator(".assistant-passkey-password").fill(password);
  await page.locator(".assistant-sync-on-button").click();
  await Promise.race([
    page.locator(".assistant-sync-on").waitFor({ timeout }),
    page
      .locator(".assistant-sync-problem")
      .waitFor({ timeout })
      .then(async () => assert.fail(`turning syncing on: ${await page.locator(".assistant-sync-problem").textContent()}`)),
  ]);
  const vault = await (await api("assistant/vault")).json();
  const passkeyWraps = (v) => Object.keys(v.vault.wraps).filter((u) => u.startsWith("passkey:"));
  assert.equal(passkeyWraps(vault).length, 1, "the vault key is wrapped for the passkey");
  assert.ok(vault.vault.wraps.password, "the password's wrap is gone");
  assert.ok(vault.vault.items.assistant && vault.vault.items.identity, "the vault holds the settings and the key pair");
  assert.ok(!JSON.stringify(vault).includes("a-test-key-for-anthropic"), "the server holds the key in the clear");
  console.log("ok: a real passkey with the PRF extension turns syncing on in the vault, and the server keeps the keys sealed");

  // Asked each time: after a reload the vault is locked, and one use of the
  // passkey, whose assertion the server checks, unlocks it.
  await page.locator(".assistant-ask-each-time").click();
  await page.waitForFunction(() => document.querySelector(".assistant-ask-each-time")?.checked === true, null, { timeout });
  await page.reload();
  await page.locator(".assistant-unlock").waitFor({ timeout });
  await page.locator(".assistant-unlock").click();
  await page.locator(".assistant-sync-on").waitFor({ timeout });
  await anthropic.locator(".assistant-key-kept").waitFor({ timeout });
  const [used] = await (await api("account/passkeys")).json();
  assert.ok(used.lastUsedAt !== null, "the server checked no use of the passkey");
  console.log("ok: asked each time, the vault is locked after a reload, and a use of the passkey, checked by the server, unlocks it");

  // A second passkey, kept elsewhere (a security key): one use of the first
  // passkey gives the vault key, which is wrapped for the new one. The
  // first authenticator would refuse to make it (the server names the
  // first passkey as one to exclude), and with two at once Chromium asks
  // the wrong one for the first passkey; so the test swaps them between
  // the two calls, from a hook the page's navigator.credentials.create
  // waits on.
  let beforeCreate = async () => {};
  await page.exposeFunction("wikiTestBeforeCreate", () => beforeCreate());
  await page.evaluate(() => {
    const create = navigator.credentials.create.bind(navigator.credentials);
    navigator.credentials.create = async (options) => {
      await globalThis.wikiTestBeforeCreate();
      return create(options);
    };
  });
  beforeCreate = async () => {
    beforeCreate = async () => {};
    await devtools.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId: firstAuthenticator.authenticatorId });
    await devtools.send("WebAuthn.addVirtualAuthenticator", { options: { ...authenticator, transport: "usb" } });
  };
  await page.locator(".assistant-passkey-password").fill(password);
  await page.locator(".assistant-add-passkey").click();
  await Promise.race([
    page.locator(".assistant-passkey").nth(1).waitFor({ timeout }),
    page
      .locator(".assistant-sync-problem")
      .waitFor({ timeout })
      .then(async () => assert.fail(`adding a passkey: ${await page.locator(".assistant-sync-problem").textContent()}`)),
  ]);
  const both = await (await api("account/passkeys")).json();
  assert.deepEqual(both.map((p) => p.unlocks), [true, true], "both passkeys unlock the vault");
  console.log("ok: a second passkey is added, and unlocks the vault too");

  // Turned off, the settings leave the vault; the vault stays, holding the
  // key pair, and so do the ways it unlocks.
  await page.locator(".assistant-sync-off").click();
  await page.locator(".assistant-sync-off-state").waitFor({ timeout });
  const left = await (await api("assistant/vault")).json();
  assert.ok(!left.vault.items.assistant, "the settings are still in the vault");
  assert.ok(left.vault.items.identity, "the key pair left the vault with the settings");
  await anthropic.locator(".assistant-key-kept").waitFor({ timeout });
  const kept = await (await api("account/passkeys")).json();
  assert.deepEqual(kept.map((p) => p.unlocks), [true, true], "the passkeys stopped unlocking the vault that holds the key pair");
  console.log("ok: turned off, the settings leave the vault, which keeps the key pair, the key stays in the browser, and the passkeys stay");

  // Signed out, the passkey left on the authenticator signs Ada in alone:
  // a discoverable credential, whose user handle names her, and no code.
  await context.clearCookies();
  await page.goto(`${origin}/`);
  await page.locator(".sign-in-toggle").click();
  await page.locator(".passkey-sign-in").click();
  await page.locator(".account .user-name").waitFor({ timeout });
  assert.equal((await page.locator(".account .user-name").textContent()).trim(), "Ada", "signed in as Ada");
  const session = await page.evaluate(async () => (await fetch("/api/v1/session", { headers: { "X-Wiki-Request": "1" } })).json());
  assert.equal(session.user?.login, "ada", "the server's session is Ada's");
  console.log("ok: signed out, a real passkey signs its owner in from the sign-in form, with no password");
} catch (error) {
  failures.push(String(error?.stack ?? error));
} finally {
  await browser.close();
  server.kill();
  await rm(work, { recursive: true, force: true });
}
if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
