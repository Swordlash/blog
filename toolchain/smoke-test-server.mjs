// Drive the server's build of the wiki in headless Chromium, served by a real
// wiki-server: the smoke test's second mode (toolchain/smoke-test.mjs is the
// first, the serverless demo's).
//
//   npm run smoke-test                            # both modes, after npm run build-wasm
//   node toolchain/smoke-test-server.mjs [dir]    # default dist-newstyle/wasm/public/app
//   SMOKE_DEBUG=<dir> ...                         # on failure, screenshot the open pages into <dir>
//
// The build in [dir] is the demo's; its app.wasm is the server's too, since
// the backend is chosen by the page (<meta name="wiki-backend">). So this
// copies it into a temporary directory, without the demo's pages, and writes
// the server's there with wiki-app-prerender --server, as
// WIKI_BACKEND=server toolchain/build-wasm.sh would. It makes an
// administrator with the console, as an owner makes the first one
// (`wiki-server users add LOGIN --admin`, the password on standard input),
// starts wiki-server on a temporary data directory and free ports of
// 127.0.0.1, and drives the application end to end against it:
//
// 1. The front page as the server renders it to someone not signed in, with
//    its content before app.wasm runs, adopted by the program with nothing
//    to repair and without asking the API anything, from what the page
//    carries; then signing in through the header's form, as the
//    administrator.
// 2. A space and a page made through the forms; typing and saving (Ctrl+S,
//    "Saved"); a draft kept as the typing stops and restored after a reload;
//    a file attached and served; a conflict (the page saved through the API
//    meanwhile, then saved in the editor); search; the export downloaded
//    from the administration, a user and a group made there; a space made
//    public in its permissions, which a visitor who is not signed in sees,
//    and only that, with no way to the administration; and a fresh browser,
//    signed in, finding all of it there.
// 3. Every route the walk went through, loaded afresh: each served with its
//    status and its content before app.wasm runs, adopted with nothing to
//    repair and no request to the API; and a page read with JavaScript off.
// 4. The demo's pages brought into the server, as its owner would: the
//    demo's build served at the server's address (so that the demo leaves
//    its wiki in this origin's IndexedDB, as it does when the server takes
//    the demo's address and port) and exported; then the server's
//    administration imports that export through "What to migrate", with a
//    page left out and a conflict (a page the server made first) resolved
//    "take the imported"; then imports again, from the demo's data in this
//    browser, and finds everything merged, nothing twice.
// 5. (Within 2.) Signing in with a provider (WP3.6): a fake OpenID Connect
//    provider on localhost, another site than the wiki's 127.0.0.1, so that
//    the browser applies its rules for cookies across sites as it does with
//    a real one; "Sign in with Fake" in the header's form goes there and
//    back, and lands signed in, as a new account, on the page it left.
//
// Needs the native builds of wiki-server and wiki-app-prerender (npm run
// build-native; WIKI_SERVER and WIKI_PRERENDER name other binaries), the
// Chromium Playwright launches, and no network (the WASI shim index.js loads
// from jsDelivr is served from node_modules).
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { cp, mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const started = Date.now();
const built = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
const shimDir = dirname(fileURLToPath(import.meta.resolve("@bjorn3/browser_wasi_shim")));
const timeout = 30_000;
const failures = [];

// A native binary of this repository, by its cabal target, unless named.
const binary = (variable, target) =>
  process.env[variable] ?? execFileSync("cabal", ["list-bin", "-v0", target, "--builddir=dist-newstyle/native"], { encoding: "utf8" }).trim();

// The server's build: the demo's files but its pages, and the server's page.
const work = await mkdtemp(join(tmpdir(), "wiki-smoke-server-"));
const app = join(work, "app");
const data = join(work, "data");
await cp(built, app, {
  recursive: true,
  filter: (source) => {
    const rel = source.slice(built.length).replace(/^[/\\]/, "");
    return !(rel.endsWith(".html") && !rel.includes("/")) && !/^(s|search)([/\\]|$)/.test(rel);
  },
});
execFileSync(binary("WIKI_PRERENDER", "wiki-app:exe:wiki-app-prerender"), ["--server", "web/index.html", app], { stdio: "inherit" });
const page404 = await readFile(join(app, "404.html"), "utf8");
assert.match(page404, /<meta name="wiki-backend" content="server">/, "the server's page does not say so");

// The first administrator, made with the console before the server starts,
// the password read from standard input.
const wikiServer = binary("WIKI_SERVER", "wiki-server:exe:wiki-server");
const adminLogin = "ada";
const adminName = "Ada Admin";
const adminPassword = "the smoke test's password";
execFileSync(wikiServer, ["users", "add", "--data", data, adminLogin, "--display-name", adminName, "--admin"], {
  input: `${adminPassword}\n`,
  stdio: ["pipe", "inherit", "inherit"],
});

// A provider to sign in with: OpenID Connect's discovery, an authorization
// endpoint that signs Olive in at once and sends the browser straight back,
// and a token endpoint that checks the client's secret and the PKCE verifier
// and issues an ID token for the round trip (unsigned: the server reads it
// from the token endpoint and checks its claims, not a signature).
const listenOn = (server, host) => new Promise((ready) => server.listen(0, host, () => ready(server.address().port)));
const oidcSecret = "the smoke test's client secret";
const oidcGrants = new Map();
const oidcIssued = [];
const provider = createServer(async (request, response) => {
  const at = new URL(request.url, providerOrigin);
  const json = (status, body) => response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
  if (at.pathname === "/.well-known/openid-configuration") {
    json(200, { issuer: providerOrigin, authorization_endpoint: `${providerOrigin}/authorize`, token_endpoint: `${providerOrigin}/token` });
  } else if (at.pathname === "/authorize") {
    const code = `code-${oidcIssued.length}-${Math.random().toString(36).slice(2)}`;
    oidcIssued.push(code);
    oidcGrants.set(code, { nonce: at.searchParams.get("nonce"), challenge: at.searchParams.get("code_challenge") });
    const back = new URL(at.searchParams.get("redirect_uri"));
    back.searchParams.set("code", code);
    back.searchParams.set("state", at.searchParams.get("state"));
    response.writeHead(302, { location: back.toString() }).end();
  } else if (at.pathname === "/token" && request.method === "POST") {
    let body = "";
    for await (const chunk of request) body += chunk;
    const form = new URLSearchParams(body);
    const grant = oidcGrants.get(form.get("code"));
    oidcGrants.delete(form.get("code"));
    const verified = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
    // The secret as HTTP's Basic, since the discovery document does not say
    // that the form may carry it.
    const basic = Buffer.from((request.headers.authorization ?? "").replace(/^Basic /, ""), "base64").toString();
    const [id, secret] = basic.split(":").map((part) => decodeURIComponent(part.replace(/\+/g, " ")));
    if (!grant || id !== "smoke-client" || secret !== oidcSecret || verified !== grant.challenge) {
      json(400, { error: "invalid_grant" });
      return;
    }
    const part = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
    const now = Math.floor(Date.now() / 1000);
    const idToken = `${part({ alg: "none" })}.${part({ iss: providerOrigin, sub: "olive-1", aud: "smoke-client", exp: now + 300, iat: now, nonce: grant.nonce, email: "olive@example.org", email_verified: true, name: "Olive Oidc", preferred_username: "olive" })}.`;
    oidcIssued.push(idToken);
    json(200, { access_token: "not used", token_type: "Bearer", id_token: idToken });
  } else {
    response.writeHead(404).end();
  }
});
// localhost, not 127.0.0.1: another site than the wiki's.
const providerOrigin = `http://localhost:${await listenOn(provider, undefined)}`;
// The wiki's port, chosen first, since its address is the redirect URI's.
const probe = createServer();
const wikiPort = await listenOn(probe, "127.0.0.1");
await new Promise((done) => probe.close(done));

// The server, on free ports, its log read for the addresses it took.
const server = spawn(
  wikiServer,
  [
    "serve", "--data", data, "--static", app, "--listen", `127.0.0.1:${wikiPort}`, "--admin-listen", "127.0.0.1:0",
    "--public-url", `http://127.0.0.1:${wikiPort}/`, "--oidc", `fake=oidc,smoke-client,${providerOrigin}`,
  ],
  { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, WIKI_OIDC_FAKE_SECRET: oidcSecret } },
);
let log = "";
const listening = new Promise((ready, fail) => {
  const read = (chunk) => {
    log += chunk;
    const match = log.match(/listener=public address="?(http:\/\/[^\s"]+?)\/?"?(\s|$)/m);
    if (match) ready(match[1]);
  };
  server.stdout.on("data", read);
  server.stderr.on("data", read);
  server.on("exit", (code) => fail(new Error(`wiki-server exited (${code}):\n${log}`)));
});
const origin = await Promise.race([listening, new Promise((_, fail) => setTimeout(() => fail(new Error(`wiki-server did not start:\n${log}`)), timeout))]);
const url = (path) => `${origin}${path}`;
const here = (page) => new URL(page.url()).pathname;
console.log(`note: wiki-server at ${origin}, data in ${data}, administrator ${adminLogin}`);

// The administrator's session, for what the walk asks the API itself and for
// the browsers that start signed in: signed in as the application does,
// with the header its requests carry.
const signedIn = await fetch(url("/api/v1/session"), {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
  body: JSON.stringify({ login: adminLogin, password: adminPassword }),
});
assert.equal(signedIn.status, 200, "signing in through the API");
const sessionToken = /wiki_session=([^;]+)/.exec(signedIn.headers.get("set-cookie") ?? "")?.[1];
assert.ok(sessionToken, "no session cookie");
const sessionCookie = `wiki_session=${sessionToken}`;

const browser = await chromium.launch();

async function eventually(check, what) {
  let last;
  for (const deadline = Date.now() + timeout; Date.now() < deadline; await new Promise((later) => setTimeout(later, 100))) {
    try {
      return await check();
    } catch (error) {
      last = error;
    }
  }
  throw new Error(`${what}: ${last?.message ?? last}`);
}

// A page that reports what goes wrong in it, with the shim answered
// locally; app.wasm and the API wait for their gates when they are set.
// Signed in as the administrator, unless told it is someone who is not.
async function newPage({ anonymous = false } = {}) {
  const context = await browser.newContext({ acceptDownloads: true });
  if (!anonymous) await context.addCookies([{ name: "wiki_session", value: sessionToken, url: origin }]);
  const page = await context.newPage();
  page.on("pageerror", (error) => failures.push(`page error at ${page.url()}: ${error.message}`));
  page.on("console", (message) => {
    // An address that is not there is served with a 404 (the walk loads
    // some on purpose); a conflict is a 409; a closed wiki's page, to a
    // visitor, a 401.
    if (message.type() === "error" && !/\b(401|404|409)\b/.test(message.text())) {
      failures.push(`console error at ${page.url()}: ${message.text()}`);
    }
  });
  // Leaving the editor with unsaved work asks; the walk says leave.
  page.on("dialog", (dialog) => dialog.accept());
  await page.route("https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@*/dist/**", async (route) => {
    const file = new URL(route.request().url()).pathname.replace(/^.*\/dist\//, "");
    await route.fulfill({ contentType: "text/javascript", body: await readFile(join(shimDir, normalize(file))) });
  });
  page.wasmGate = null;
  page.apiGate = null;
  page.apiAsked = [];
  await page.route("**/app.wasm", async (route) => {
    await page.wasmGate;
    await route.continue();
  });
  await page.route("**/api/v1/**", async (route) => {
    page.apiAsked.push(route.request().url());
    await page.apiGate;
    await route.continue();
  });
  return page;
}

// Whether the program has adopted the page: the brand's link has the click
// listener the program attaches (only the DevTools protocol sees listeners).
async function programStarted(page) {
  page.devtools ??= await page.context().newCDPSession(page);
  const { result } = await page.devtools.send("Runtime.evaluate", { expression: 'document.querySelector("#app .wiki-brand")' });
  if (result.objectId === undefined) return false;
  const { listeners } = await page.devtools.send("DOMDebugger.getEventListeners", { objectId: result.objectId });
  await page.devtools.send("Runtime.releaseObject", { objectId: result.objectId });
  return listeners.some((listener) => listener.type === "click");
}

// What the program does not adopt: what is inside an island (a library
// fills it, or the browser writes a time in the reader's zone) and inside
// the editor's host, where CodeMirror goes in place of the textarea.
const unadopted = ".wiki-math, .wiki-mermaid, .wiki-tikz, .wiki-code, .wiki-time, .editor-cm";

// Load an address with app.wasm and the API held back: mark every node of
// the page as the server sent it, and what its content says, let the
// program adopt it, and say what adopting it changed and what it asked the
// API for before the server has answered anything. Then let the API answer.
async function loadAdopted(page, path) {
  let releaseWasm;
  let releaseApi;
  page.wasmGate = new Promise((go) => (releaseWasm = go));
  page.apiGate = new Promise((go) => (releaseApi = go));
  page.apiAsked = [];
  const response = await page.goto(url(path), { waitUntil: "commit" });
  await page.locator("#app .wiki").waitFor({ timeout });
  const shown = await page.locator("#app .wiki-content").textContent();
  await page.evaluate((unadopted) => {
    const app = document.querySelector("#app");
    app.querySelector(".wiki").dataset.prerendered = "true";
    const marks = new Map();
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      if (node.parentElement?.closest(unadopted)) continue;
      marks.set(node, node.nodeType === Node.TEXT_NODE ? node.data : [...node.attributes].map((a) => `${a.name}=${a.value}`).join(" "));
    }
    window.smokePrerendered = marks;
  }, unadopted);
  releaseWasm();
  page.wasmGate = null;
  await eventually(async () => assert.ok(await programStarted(page), "no listener yet"), `${path}: the program starting`);
  // A moment for anything the adoption would change to be changed.
  await page.waitForTimeout(300);
  const repairs = await page.evaluate((unadopted) => {
    const app = document.querySelector("#app");
    const found = [];
    for (const [node, was] of window.smokePrerendered) {
      if (!app.contains(node)) {
        if (node.nodeType !== Node.TEXT_NODE || was.trim() !== "") found.push(`gone: ${was}`);
      } else {
        const now = node.nodeType === Node.TEXT_NODE ? node.data : [...node.attributes].filter((a) => a.name !== "data-prerendered").map((a) => `${a.name}=${a.value}`).join(" ");
        const before = node.nodeType === Node.TEXT_NODE ? was : was.replace(/ ?data-prerendered=true/, "");
        if (now !== before) found.push(`changed: ${before} -> ${now}`);
      }
    }
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      if (node.parentElement?.closest(unadopted)) continue;
      if (!window.smokePrerendered.has(node) && !(node.nodeType === Node.TEXT_NODE && node.data === "")) found.push(`built: ${node.nodeName}`);
    }
    return found;
  }, unadopted);
  const asked = [...page.apiAsked];
  releaseApi();
  page.apiGate = null;
  return { status: response.status(), repairs, shown, asked };
}

// The demo's build, served at the server's own address in place of the
// server, as a static host serves it: what the owner had there before the
// server took its address.
const demoTypes = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf" };
async function serveTheDemo(route) {
  const path = decodeURIComponent(new URL(route.request().url()).pathname);
  const file = join(built, normalize(path.endsWith("/") ? `${path}index.html` : path));
  const headers = { "Cache-Control": "no-store" };
  try {
    if (!(await stat(file)).isDirectory()) {
      await route.fulfill({ status: 200, headers, contentType: demoTypes[extname(file)] ?? "application/octet-stream", body: await readFile(file) });
      return;
    }
  } catch {
    // No such file: the demo's 404.html, as a static host answers.
  }
  await route.fulfill({ status: 404, headers, contentType: "text/html", body: await readFile(join(built, "404.html")) });
}

// What the API says, to the administrator's session. A write carries the
// header the application's own requests carry, without which the server
// refuses it (another site's page cannot send it).
const api = async (path, init = {}) => {
  const response = await fetch(url(`/api/v1/${path}`), {
    ...init,
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: sessionCookie, ...init.headers },
  });
  return { status: response.status, body: response.status === 204 ? null : await response.json() };
};
const pagesOf = async (spacePath) => {
  const space = await api(`spaces/at/${spacePath}`);
  assert.equal(space.status, 200, `no space at ${spacePath}`);
  return (await api(`spaces/${encodeURIComponent(space.body.id)}/pages`)).body;
};

async function migrateTheDemo() {
  const page = await newPage();
  // The demo's photograph and video, answered here, as the network may be
  // out of reach.
  await page.route("https://upload.wikimedia.org/**", (route) => route.fulfill({ status: 204 }));

  // The demo, at the server's address: it keeps its wiki in this origin's
  // IndexedDB, and its administration exports it.
  const demoAddress = `${origin}/**`;
  await page.route(demoAddress, serveTheDemo);
  await page.goto(url("/"));
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  await eventually(async () => assert.ok(await programStarted(page), "no listener yet"), "the demo's program starting");
  await page.locator("#app .wiki-header a.admin-link").click();
  const [exported] = await Promise.all([page.waitForEvent("download", { timeout }), page.locator("#app .admin-view .demo-export").click()]);
  const demoExport = await readFile(await exported.path());
  await page.unroute(demoAddress, serveTheDemo);
  console.log(`ok: the demo, served at the server's address, keeps its wiki in this browser and exports it as ${exported.suggestedFilename()}`);

  // A write without the application's header is another site's, and
  // refused even with the administrator's cookie.
  const forged = await fetch(url("/api/v1/spaces"), {
    method: "POST",
    headers: { "Content-Type": "application/json", Cookie: sessionCookie },
    body: JSON.stringify({ parent: null, name: "Forged" }),
  });
  assert.equal(forged.status, 403, "a write without the application's header");

  // A page the server has at a path the demo's export has too: a conflict.
  const blog = await api("spaces", { method: "POST", body: JSON.stringify({ parent: null, name: "Blog" }) });
  assert.equal(blog.status, 201, "the server's Blog");
  const made = await api(`spaces/${encodeURIComponent(blog.body.id)}/pages`, {
    method: "POST",
    body: JSON.stringify({ parent: null, title: "Hello, world", body: "Written on the server." }),
  });
  assert.equal(made.status, 201, "the server's Hello, world");
  assert.equal(made.body.slug, "hello-world");

  // The server's administration offers both sources: a zip file, and the
  // demo's data, since the demo left it in this origin.
  await page.goto(url("/"));
  await page.locator("#app .user-name", { hasText: adminName }).waitFor({ timeout });
  await page.locator("#app .sign-out").waitFor({ timeout });
  await page.locator("#app .wiki-header a.admin-link").click();
  await page.locator("#app .admin-view .import-sources .import-demo").waitFor({ timeout });

  // The export first: Notes on Haskell left out, and the demo's Hello,
  // world taken over the server's.
  await page.locator("#app .import-file input[type=file]").setInputFiles({ name: "demo-export.zip", mimeType: "application/zip", buffer: demoExport });
  const dialog = page.locator("#app .import-dialog");
  await dialog.locator("h3", { hasText: "What to migrate" }).waitFor({ timeout });
  const spaceRow = (path) => dialog.locator(`.import-space[data-path='${path}'] > .import-row`);
  const pageItem = (space, path) => dialog.locator(`.import-space[data-path='${space}'] .import-page[data-path='${path}']`);
  assert.equal((await spaceRow("blog").locator(".badge").textContent()).trim(), "Already here: merged");
  assert.equal((await spaceRow("docs").locator(".badge").textContent()).trim(), "New");
  assert.equal((await pageItem("blog", "hello-world").locator(".badge").first().textContent()).trim(), "In conflict");
  assert.equal(await dialog.locator("input.import-check:not(:checked)").count(), 0, "not everything is checked");
  await pageItem("blog", "notes-on-haskell").locator("input.import-check").uncheck();
  await pageItem("blog", "hello-world").locator("input.import-take").check();
  await dialog.locator(".import-apply").click();
  const summary = page.locator("#app .import-summary");
  await summary.waitFor({ timeout });
  const told = await summary.textContent();
  for (const line of ["3 spaces created", "1 space merged with the server's", "8 pages created", "1 page replaced by the imported one", "1 page left out"]) {
    assert.ok(told.includes(line), `the summary does not say "${line}": ${told}`);
  }
  // The shell has reloaded the tree of spaces, with the demo's in it.
  await page.locator("#app .wiki-sidebar a", { hasText: "Docs" }).waitFor({ timeout });
  const hello = (await pagesOf("blog")).find((p) => p.slug === "hello-world");
  assert.ok(hello && !hello.body.includes("Written on the server."), "the server's Hello, world was not replaced");
  assert.deepEqual((await pagesOf("blog")).map((p) => p.slug), ["hello-world"], "Notes on Haskell was imported though left out");
  await page.goto(url("/s/docs/p/tour/"));
  await page.locator("#app .page-view h1", { hasText: "Tour" }).waitFor({ timeout });
  console.log("ok: the demo's export is imported through the dialog, a page left out and a conflict taking the imported page, and its summary shown");

  // Again, from the demo's data in this browser: everything is merged, and
  // nothing is there twice; the page left out comes in now.
  await page.locator("#app .wiki-header a.admin-link").click();
  await page.locator("#app .admin-view .import-demo").click();
  await dialog.locator("h3", { hasText: "What to migrate" }).waitFor({ timeout });
  assert.match(await dialog.locator(".import-from").textContent(), /^From this browser's demo data: 4 spaces \(4 already here\)/);
  assert.equal(await dialog.locator(".import-space.import-new").count(), 0, "a space is new again");
  assert.equal(await dialog.locator(".import-choice").count(), 0, "a page is in conflict again");
  assert.equal((await pageItem("blog", "notes-on-haskell").locator(".badge").first().textContent()).trim(), "New");
  await dialog.locator(".import-apply").click();
  await summary.waitFor({ timeout });
  const again = await summary.textContent();
  for (const line of ["4 spaces merged with the server's", "1 page created", "9 pages kept as the server had them"]) {
    assert.ok(again.includes(line), `the second summary does not say "${line}": ${again}`);
  }
  const spaces = (await api("spaces")).body;
  const paths = spaces.map((s) => s.slug).sort();
  assert.deepEqual(paths, [...new Set(paths)], "a space is there twice");
  assert.deepEqual((await pagesOf("blog")).map((p) => p.slug).sort(), ["hello-world", "notes-on-haskell"]);
  let total = 0;
  for (const space of ["blog", "docs", "team", "team/projects"]) {
    const slugs = (await pagesOf(space)).map((p) => `${p.parent ?? ""}/${p.slug}`);
    assert.deepEqual(slugs, [...new Set(slugs)], `a page of ${space} is there twice`);
    total += slugs.length;
  }
  assert.equal(total, 10, "the demo's ten pages, once each");
  await page.context().close();
  console.log("ok: imported again from the demo's data in this browser, everything is merged and nothing is there twice");
}

const editorText = "#app .editor-cm .cm-content";
const markdownIn = (page) => page.evaluate((selector) => document.querySelector(selector)?.wikiEditor?.text() ?? null, editorText);
const content = (page) => page.locator("#app .wiki-content").textContent();

try {
  // ---- 1. The server's page, adopted -----------------------------------------

  const front = await fetch(url("/"));
  assert.equal(front.status, 200);
  const frontHtml = await front.text();
  assert.match(frontHtml, /<h1>Welcome to the wiki<\/h1>/, "the front page is not rendered");
  assert.ok(!frontHtml.includes("Loading…"), "the front page is the application loading");
  assert.match(frontHtml, /<script type="application\/json" id="wiki-preload">/, "the front page carries nothing for the program");
  const page = await newPage({ anonymous: true });
  const atFront = await loadAdopted(page, "/");
  assert.deepEqual(atFront.repairs, [], "adopting the front page repaired it");
  assert.deepEqual(atFront.asked, [], "the program asked the API for what the front page carries");
  assert.ok(atFront.shown.includes("There are no spaces you can see."), `the front page before app.wasm: ${atFront.shown}`);
  assert.equal(await page.locator("#app .user-switcher").count(), 0, "a server's wiki offers the demo's user switcher");
  assert.equal(await page.locator("#app .admin-link").count(), 0, "the way to the administration, to nobody");
  console.log("ok: the server renders the front page, which the program adopts with nothing to repair and nothing asked");

  // Signing in, through the header's form, as the administrator the console
  // made: the shell reloads as them, with the way to the administration.
  await page.locator("#app .sign-in-toggle").click();
  await page.locator("#app .sign-in-form input[name=login]").fill(adminLogin);
  await page.locator("#app .sign-in-form input[name=password]").fill(adminPassword);
  await page.locator("#app .sign-in-form button[type=submit]").click();
  await page.locator("#app .user-name", { hasText: adminName }).waitFor({ timeout });
  await page.locator("#app .sign-out").waitFor({ timeout });
  await page.locator("#app .wiki-header a.admin-link").waitFor({ timeout });
  console.log(`ok: signs in through the header as ${adminLogin}, the administrator made on the console`);

  // ---- 2. A walk through the wiki --------------------------------------------

  // A space, from the sidebar's link.
  await page.locator("#app .wiki-sidebar .new-space-link").click();
  await page.locator("#app .new-space-view input").fill("Smoke space");
  await page.locator("#app .new-space-view button.primary").click();
  await page.locator("#app .space-view h1", { hasText: "Smoke space" }).waitFor({ timeout });
  assert.equal(here(page), "/s/smoke-space/");
  // A page, from its title.
  await page.locator("#app .space-view .actions a", { hasText: "New page" }).click();
  await page.locator("#app .new-page-title").pressSequentially("First page");
  await page.locator("#app .new-page-view button.primary").click();
  const editor = page.locator(editorText);
  await editor.waitFor({ timeout });
  assert.equal(here(page), "/s/smoke-space/p/first-page/edit/");
  // Typed and saved with Ctrl+S, which stays.
  await editor.pressSequentially("Hello from the server's smoke test.");
  await editor.press("Control+s");
  await page.locator("#app .editor-saved-notice", { hasText: "Saved" }).waitFor({ timeout });
  console.log("ok: a space and a page made through the forms, the page typed and saved with Ctrl+S");

  // A file attached, and served by the server.
  await page.locator("#app .editor-attach input[type=file]").setInputFiles({
    name: "notes.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("attached by the smoke test\n"),
  });
  const attachment = page.locator("#app .editor-attachments a", { hasText: "notes.txt" });
  await attachment.waitFor({ timeout });
  const served = await fetch(new URL(await attachment.getAttribute("href"), url("/")), { headers: { Cookie: sessionCookie } });
  assert.equal(served.status, 200);
  assert.equal(await served.text(), "attached by the smoke test\n", "the attachment's bytes");
  await eventually(async () => assert.ok((await markdownIn(page)).includes("(attachment:notes.txt)"), "no reference yet"), "the attachment's reference");
  await editor.press("Control+s");
  await page.locator("#app .editor-saved-notice", { hasText: "Saved" }).waitFor({ timeout });
  console.log("ok: a file attached in the editor is uploaded, served at its address and referred to in the page");

  // A draft, kept once the typing stops, and restored after a reload.
  await editor.press("Control+End");
  await editor.pressSequentially(" Not saved yet.");
  await page.locator("#app .editor-draft-status", { hasText: "Draft saved" }).waitFor({ timeout });
  const reloaded = await loadAdopted(page, "/s/smoke-space/p/first-page/edit/");
  assert.equal(reloaded.status, 200, "the editor's address");
  assert.deepEqual(reloaded.repairs, [], "adopting the server's page at the editor's address repaired it");
  assert.deepEqual(reloaded.asked, [], "the program asked the API for what the editor's page carries");
  assert.ok(reloaded.shown.includes("Restored your unsaved draft"), `the editor before app.wasm: ${reloaded.shown}`);
  await page.locator("#app .editor-draft-found", { hasText: "Restored your unsaved draft" }).waitFor({ timeout });
  await eventually(async () => assert.ok((await markdownIn(page)).endsWith("Not saved yet."), "not yet"), "the draft restored");
  console.log("ok: a draft is kept as the typing stops, and restored by the editor after a reload, which adopts the page with nothing to repair");

  // Someone else saves the page meanwhile, through the API; the editor's
  // save is then a conflict, said in place, with the work kept.
  const space = await (await fetch(url("/api/v1/spaces/at/smoke-space"), { headers: { Cookie: sessionCookie } })).json();
  const atPath = await fetch(url(`/api/v1/spaces/${encodeURIComponent(space.id)}/pages/at/first-page`), { headers: { Cookie: sessionCookie } });
  const current = await atPath.json();
  const saved = await fetch(url(`/api/v1/pages/${encodeURIComponent(current.id)}`), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: sessionCookie, "If-Match": atPath.headers.get("etag") },
    body: JSON.stringify({ title: "First page", body: `${current.body}\n\nSaved by someone else.` }),
  });
  assert.equal(saved.status, 200, "the API's save");
  const stale = await fetch(url(`/api/v1/pages/${encodeURIComponent(current.id)}`), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: sessionCookie, "If-Match": atPath.headers.get("etag") },
    body: JSON.stringify({ title: "First page", body: "stale" }),
  });
  assert.equal(stale.status, 409, "a save with a stale version through the API");
  await editor.press("Control+s");
  await page.locator("#app .editor .error-conflict").waitFor({ timeout });
  assert.ok((await markdownIn(page)).endsWith("Not saved yet."), "the conflict lost the work");
  await page.locator("#app .error-conflict button", { hasText: "Reload" }).click();
  await eventually(async () => assert.ok((await markdownIn(page)).endsWith("Saved by someone else."), "not yet"), "the page reloaded after the conflict");
  console.log("ok: a save over someone else's newer one is a conflict, said in the editor, which reloads the page on request");

  // Search, from the keyboard.
  await page.locator("#app .editor-save-close").click();
  await page.locator("#app .page-view .page-body", { hasText: "Saved by someone else." }).waitFor({ timeout });
  await page.evaluate(() => document.activeElement?.blur());
  await page.keyboard.press("/");
  await page.keyboard.type("smoke");
  await page.locator("#app .search-results .search-hit", { hasText: "First page" }).first().waitFor({ timeout });
  await page.keyboard.press("Enter");
  await page.locator("#app .search-view .search-hit", { hasText: "First page" }).waitFor({ timeout });
  console.log("ok: search finds the page, in the box and on the page of results");

  // The page's history: every save a version, the latest first; version 2
  // (the first text typed) restored, which the page then shows, then the
  // version that was the latest restored in turn, so the page ends as it
  // was, two versions on.
  await page.locator("#app .search-view .search-hit", { hasText: "First page" }).click();
  await page.locator("#app .page-view h1", { hasText: "First page" }).waitFor({ timeout });
  await page.locator("#app .page-view .actions a", { hasText: "History" }).click();
  await page.locator("#app .history-view h1", { hasText: "First page" }).waitFor({ timeout });
  assert.equal(here(page), "/s/smoke-space/p/first-page/history/");
  const versionNames = () => page.locator("#app .version-list li > a").allTextContents();
  const versions = await versionNames();
  assert.ok(versions.length >= 4, `the history lists ${versions.length} versions`);
  assert.equal(versions[0], `Version ${versions.length} (current)`, "the latest is not first");
  assert.ok((await content(page)).includes(`by ${adminName}`), "the versions' author");
  const restore = async (n, shows, lacks) => {
    await page.locator("#app .version-list li > a", { hasText: new RegExp(`^Version ${n}$`) }).click();
    await page.locator("#app .version-detail h2", { hasText: `Version ${n}` }).waitFor({ timeout });
    await page.locator("#app button.restore").click();
    await page.locator("#app .restore-confirm button", { hasText: "Restore" }).click();
    await page.locator("#app .page-view .page-body", { hasText: shows }).waitFor({ timeout });
    if (lacks) assert.ok(!(await page.locator("#app .page-view .page-body").textContent()).includes(lacks), `the restored version has "${lacks}" in it`);
    await page.locator("#app .page-view .actions a", { hasText: "History" }).click();
    await page.locator("#app .history-view h1").waitFor({ timeout });
  };
  await restore(2, "Hello from the server's smoke test.", "Saved by someone else.");
  assert.equal((await versionNames()).length, versions.length + 1, "the restore made no new version");
  await restore(versions.length, "Saved by someone else.");
  assert.equal((await versionNames())[0], `Version ${versions.length + 2} (current)`);
  console.log(`ok: the page's ${versions.length} versions are listed, version 2 restored and then the latest again, each a version on top`);

  // The export, from the administration.
  await page.locator("#app .wiki-header a.admin-link").click();
  await page.locator("#app .admin-view .import-sources .import-file").waitFor({ timeout });
  const [exported] = await Promise.all([page.waitForEvent("download", { timeout }), page.locator("#app .admin-view .demo-export").click()]);
  assert.match(exported.suggestedFilename(), /^wiki-\d{4}-\d{2}-\d{2}\.zip$/, "the export's name");
  assert.equal((await readFile(await exported.path())).subarray(0, 2).toString(), "PK", "the export is not a zip file");
  console.log(`ok: the administration downloads the server's export, ${exported.suggestedFilename()}`);

  // A user, made in the administration's people with a password, who signs
  // in; and a group, which the server keeps.
  await page.locator(`#app .admin-view .user-row[data-login=${adminLogin}] .administrator-self`).waitFor({ timeout });
  await page.locator("#app .admin-view .user-create-login").fill("sam");
  await page.locator("#app .admin-view .user-create-name").fill("Sam Smoke");
  await page.locator("#app .admin-view .user-create-password").fill("sam's password");
  await page.locator("#app .admin-view .user-create button.primary").click();
  await page.locator("#app .admin-view .user-row[data-login=sam] .account-state", { hasText: "Signs in with a password" }).waitFor({ timeout });
  const sam = await fetch(url("/api/v1/session"), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
    body: JSON.stringify({ login: "sam", password: "sam's password" }),
  });
  assert.equal(sam.status, 200, "the user made in the administration signing in");
  assert.equal((await sam.json()).user.displayName, "Sam Smoke");
  await page.locator("#app .admin-view .group-create-name").fill("Smoke testers");
  await page.locator("#app .admin-view .group-create button.primary").click();
  await page.locator("#app .admin-view .group-name", { hasText: "Smoke testers" }).waitFor({ timeout });
  const people = await api("admin/directory");
  assert.equal(people.status, 200, "the directory");
  assert.deepEqual(people.body.groups.map((g) => g.name), ["Smoke testers"], "the server's groups");
  console.log("ok: the administration makes a user with a password, who signs in, and a group, which the server keeps");

  // A second space, made public in its permissions; the first stays
  // private.
  const publicSpace = await api("spaces", { method: "POST", body: JSON.stringify({ parent: null, name: "Smoke public" }) });
  assert.equal(publicSpace.status, 201, "the public space");
  await page.goto(url("/s/smoke-public/"));
  await page.locator("#app .space-view h1", { hasText: "Smoke public" }).waitFor({ timeout });
  await page.locator("#app .space-view .permissions-toggle").click();
  await page.locator("#app .space-permissions .public-switch[aria-checked=false]").click();
  await page.locator("#app .space-view .badge", { hasText: "Public" }).waitFor({ timeout });
  console.log("ok: a space is made public in its permissions");
  await page.context().close();

  // Someone who is not signed in sees the public space only, and no way to
  // the administration, which the server refuses them too.
  const visitor = await newPage({ anonymous: true });
  await visitor.goto(url("/"));
  await eventually(async () => assert.ok(await programStarted(visitor), "no listener yet"), "the visitor's program starting");
  await visitor.locator("#app .wiki-sidebar a", { hasText: "Smoke public" }).waitFor({ timeout });
  assert.deepEqual(await visitor.locator("#app .wiki-sidebar .space-tree a").allTextContents(), ["Smoke public"], "the spaces a visitor sees");
  assert.equal(await visitor.locator("#app .admin-link").count(), 0, "the way to the administration, to a visitor");
  await visitor.locator("#app .sign-in-toggle").waitFor({ timeout });
  assert.equal((await fetch(url("/s/smoke-space/"))).status, 403, "the private space, to a visitor");
  assert.equal((await fetch(url("/api/v1/admin/directory"))).status, 403, "the administration's API, to a visitor");
  await visitor.context().close();
  console.log("ok: a visitor who is not signed in sees the public space and nothing else, and no administration");

  // A closed wiki: someone who is not signed in is shown the way to sign in
  // and nothing else, rendered so by the server and adopted with nothing to
  // repair; an invitation's link makes them an account, and the wiki opens
  // again for everyone.
  const closing = await api("admin/settings", { method: "PUT", body: JSON.stringify({ access: "Closed", newAccountsCreateSpaces: false }) });
  assert.equal(closing.status, 200, "closing the wiki");
  assert.equal((await fetch(url("/api/v1/spaces"))).status, 401, "the spaces of a closed wiki, to a visitor");
  const outsider = await newPage({ anonymous: true });
  const shut = await loadAdopted(outsider, "/s/smoke-public/");
  assert.equal(shut.status, 401, "a page of a closed wiki, to a visitor");
  assert.ok(shut.shown.includes("Sign in to read this wiki"), `a closed wiki's page: ${shut.shown}`);
  assert.ok(!shut.shown.includes("Smoke public"), "a closed wiki's page shows its spaces");
  assert.deepEqual(shut.repairs, [], "adopting a closed wiki's page repaired it");
  assert.deepEqual(shut.asked, [], "the program asked the API for what the page carries");
  assert.equal(await outsider.locator("#app .wiki-sidebar").count(), 0, "a closed wiki's sidebar, to a visitor");
  const invited = await api("admin/invitations", { method: "POST", body: JSON.stringify({ email: "ivy@example.org" }) });
  assert.equal(invited.status, 201, "the invitation");
  const invitedPage = await loadAdopted(outsider, `/invite/${invited.body.token}/`);
  assert.equal(invitedPage.status, 200, "the invitation's page");
  assert.deepEqual(invitedPage.repairs, [], "adopting the invitation's page repaired it");
  await outsider.locator("#app .invitation-form input[name=login]").fill("ivy");
  await outsider.locator("#app .invitation-form input[name=name]").fill("Ivy Invited");
  await outsider.locator("#app .invitation-form input[name=password]").fill("ivy's password");
  await outsider.locator("#app .invitation-form button[type=submit]").click();
  await outsider.locator("#app .account .user-name", { hasText: "Ivy Invited" }).waitFor({ timeout });
  await outsider.locator("#app .wiki-sidebar a", { hasText: "Smoke public" }).waitFor({ timeout });
  await outsider.context().close();
  assert.ok(!log.includes(invited.body.token), "the invitation's secret is in the server's log");
  const opening = await api("admin/settings", { method: "PUT", body: JSON.stringify({ access: "Open", newAccountsCreateSpaces: false }) });
  assert.equal(opening.status, 200, "opening the wiki");
  assert.equal((await fetch(url("/api/v1/spaces"))).status, 200, "the spaces of an open wiki, to a visitor");
  console.log("ok: a closed wiki shows a visitor only the way to sign in, an invitation makes them an account, and it opens again");

  // Signing in with a provider, from a page, lands back on it signed in.
  const olive = await newPage({ anonymous: true });
  await olive.goto(url("/s/smoke-public/"));
  await olive.locator("#app .sign-in-toggle").click();
  await olive.locator("#app .sign-in-form .provider-link", { hasText: "Sign in with Fake" }).click();
  await olive.locator("#app .account .account-toggle", { hasText: "Olive Oidc" }).waitFor({ timeout });
  assert.equal(here(olive), "/s/smoke-public/", "signing in with a provider came back elsewhere");
  // The server rendered that page for her session: the cookie came with it.
  const landed = await olive.evaluate(async () => (await fetch("api/v1/session")).json());
  assert.equal(landed.user?.login, "olive", "signed in as someone else");
  await olive.locator("#app .account-toggle").click();
  await olive.locator("#app .identity .identity-provider", { hasText: "Fake" }).waitFor({ timeout });
  assert.equal(await olive.locator("#app .identity-disconnect").getAttribute("disabled"), "", "her only way in may be disconnected");
  await olive.context().close();
  for (const secret of [oidcSecret, ...oidcIssued]) assert.ok(!log.includes(secret), "a provider's code, token or secret is in the server's log");
  console.log("ok: signing in with a provider goes there and back, and lands signed in, as a new account, on the page it left");

  // Everything is there for a browser that has seen nothing.
  const fresh = await newPage();
  const pageLoad = await loadAdopted(fresh, "/s/smoke-space/p/first-page/");
  assert.deepEqual(pageLoad.repairs, [], "adopting the server's page at a page's address repaired it");
  await fresh.locator("#app .page-view h1", { hasText: "First page" }).waitFor({ timeout });
  const text = await content(fresh);
  for (const expected of ["Hello from the server's smoke test.", "Saved by someone else.", "notes.txt"]) {
    assert.ok(text.includes(expected), `the page lacks "${expected}"`);
  }
  await fresh.locator("#app .wiki-sidebar a", { hasText: "Smoke space" }).waitFor({ timeout });
  console.log("ok: a fresh browser finds the space, the page, its edits and its attachment on the server");

  // ---- 3. Every route of the walk, rendered by the server --------------------

  const walked = [
    ["/", 200, "Smoke space"],
    ["/s/smoke-public/", 200, "Smoke public"],
    ["/s/smoke-space/", 200, "First page"],
    ["/s/smoke-space/p/first-page/", 200, "Saved by someone else."],
    ["/s/smoke-space/p/first-page/source/", 200, "(attachment:notes.txt)"],
    ["/s/smoke-space/p/first-page/history/", 200, "Version 1"],
    ["/s/smoke-space/p/first-page/slides/", 200, "1 / 1"],
    ["/s/smoke-space/p/first-page/edit/", 200, "Editing First page"],
    ["/s/smoke-space/new-page/", 200, "New page"],
    ["/new-space/", 200, "New space"],
    ["/search/?q=smoke", 200, "First page"],
    ["/admin/", 200, "Smoke testers"],
    ["/s/smoke-space/p/no-such-page/", 404, "There is nothing here"],
    ["/no/such/address", 404, "Not found"],
  ];
  for (const [path, status, expected] of walked) {
    const loaded = await loadAdopted(fresh, path);
    assert.equal(loaded.status, status, `${path}: the status`);
    assert.ok(loaded.shown.includes(expected), `${path}: "${expected}" is not there before app.wasm: ${loaded.shown}`);
    assert.deepEqual(loaded.repairs, [], `${path}: adopting it repaired it`);
    assert.deepEqual(loaded.asked, [], `${path}: the program asked the API for what the page carries`);
  }
  await fresh.context().close();
  console.log(`ok: ${walked.length} addresses of the walk are rendered by the server, with their content before app.wasm, and adopted with nothing to repair or ask`);

  // Without JavaScript, the page is there all the same.
  const noScript = await browser.newContext({ javaScriptEnabled: false });
  await noScript.addCookies([{ name: "wiki_session", value: sessionToken, url: origin }]);
  const reader = await noScript.newPage();
  const read = await reader.goto(url("/s/smoke-space/p/first-page/"));
  assert.equal(read.status(), 200);
  const readable = await reader.locator("#app .page-body").textContent();
  assert.ok(readable.includes("Hello from the server's smoke test.") && readable.includes("Saved by someone else."), `the page without JavaScript: ${readable}`);
  await noScript.close();
  console.log("ok: with JavaScript off, a page reads as the server rendered it");

  // ---- 4. The demo's pages brought into the server ---------------------------

  await migrateTheDemo();
} catch (error) {
  failures.push(String(error.stack ?? error));
  if (process.env.SMOKE_DEBUG) {
    for (const [i, context] of browser.contexts().entries()) {
      for (const [j, p] of context.pages().entries()) {
        await p.screenshot({ path: `${process.env.SMOKE_DEBUG}/server-failure-${i}-${j}.png` }).catch(() => {});
      }
    }
  }
} finally {
  await browser.close();
  provider.close();
  server.kill("SIGTERM");
  await new Promise((done) => (server.exitCode !== null ? done() : server.on("exit", done)));
  await rm(work, { recursive: true, force: true });
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  console.error(`wiki-server's log:\n${log}`);
  process.exit(1);
}
console.log(`Smoke test of the server's build passed in ${Math.round((Date.now() - started) / 1000)} s (${basename(built)}).`);
