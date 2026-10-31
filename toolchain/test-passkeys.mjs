// The assistant's keys across devices end to end (WP5.21 of docs/PLAN.md):
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

const signedIn = await fetch(`${origin}/api/v1/session`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
  body: JSON.stringify({ login: "ada", password }),
});
assert.equal(signedIn.status, 200, "signing in through the API");
const token = /wiki_session=([^;]+)/.exec(signedIn.headers.get("set-cookie") ?? "")?.[1];
const api = (path) => fetch(`${origin}/api/v1/${path}`, { headers: { Cookie: `wiki_session=${token}`, "X-Wiki-Request": "1" } });

const failures = [];
const browser = await chromium.launch();
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
  const first = await devtools.send("WebAuthn.addVirtualAuthenticator", { options: authenticator });

  await page.goto(`${origin}/assistant/`);
  const anthropic = page.locator(".assistant-provider-settings[data-provider='anthropic']");
  await anthropic.locator(".assistant-key").fill("a-test-key-for-anthropic");
  await anthropic.locator(".assistant-key-form button").click();
  await anthropic.locator(".assistant-key-kept").waitFor({ timeout });

  await page.locator(".assistant-sync-on-button").click();
  await page.locator(".assistant-sync-on").waitFor({ timeout });
  const vault = await (await api("assistant/vault")).json();
  assert.equal(Object.keys(vault.vault.wrapped).length, 1, "the vault key is wrapped for the passkey");
  assert.ok(!JSON.stringify(vault).includes("a-test-key-for-anthropic"), "the server holds the key in the clear");
  console.log("ok: a real passkey with the PRF extension turns syncing on, and the server keeps the keys sealed");

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
    await devtools.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId: first.authenticatorId });
    await devtools.send("WebAuthn.addVirtualAuthenticator", { options: { ...authenticator, transport: "usb" } });
  };
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

  await page.locator(".assistant-sync-off").click();
  await page.locator(".assistant-sync-off-state").waitFor({ timeout });
  assert.equal((await api("assistant/vault")).status, 404, "the vault is still on the server");
  await anthropic.locator(".assistant-key-kept").waitFor({ timeout });
  const kept = await (await api("account/passkeys")).json();
  assert.deepEqual(kept.map((p) => p.unlocks), [false, false], "the passkeys stay, unlocking nothing");
  console.log("ok: turned off, the vault is gone from the server, the key stays in the browser, and the passkeys stay");

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
