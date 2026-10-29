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
//    meanwhile, then saved in the editor), shown in the conflict view and
//    ended with "Take theirs"; search; the export downloaded
//    from the administration, a user and a group made there; a page
//    exported as a Word document from its "Export" menu; a space made
//    public in its permissions, which a visitor who is not signed in sees,
//    and only that, with no way to the administration; and a fresh browser,
//    signed in, finding all of it there; a comment and who is editing,
//    across two tabs of two users over the WebSocket, and a save shown in
//    the other tab; a comment that mentions the other user, told under the
//    bell in their tab.
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
//    a real one, added in the administration's "Server" section while the
//    server runs (WP4.4), with the wiki's public address, and checked there;
//    "Sign in with Fake" in the header's form goes there and back, and
//    lands signed in, as a new account, on the page it left. That account
//    has no password to set (WP5.6), in its panel or the administration's,
//    until the administration disconnects its provider and types it one.
// 6. (Within 2.) Backups turned on in the Server section (WP4.9), one made
//    by hand, and the console's restore of it: refused the running server's
//    data directory, done into a fresh one.
// 7. (Within 5.) Account hygiene (WP4.11): her sessions in the panel under
//    her name, this browser's marked, and "Sign out everywhere" ending the
//    other; a second factor set up there from the QR code's secret, which
//    the next sign-in with her password then asks for.
// 8. Reading offline (WP4.17): a browser that lets the service worker in
//    reads a few pages, goes offline and reloads one, which is shown from
//    what the worker kept, saying "You are reading an offline copy from …"
//    with the offline notice; a page followed by a link offline is shown
//    from the API's answers kept; a page never read gets the worker's
//    offline page; back online, the page is the live one again; and
//    signing out lets go of what was kept. Every other part runs with
//    service workers blocked, so that what it holds back or counts
//    (app.wasm, the API's requests) passes through Playwright's routes,
//    which a worker's requests and its cache's answers do not.
//
// On PostgreSQL (toolchain/smoke-test.sh runs it so when one is at hand),
// the server and the console find their database in WIKI_DATABASE_URL, which
// wiki-server reads when no option names one, and the restore's fresh data
// directory takes the database WIKI_SMOKE_RESTORE_DATABASE_URL names.
//
// Needs the native builds of wiki-server and wiki-app-prerender (npm run
// build-native; WIKI_SERVER and WIKI_PRERENDER name other binaries), the
// Chromium Playwright launches, and no network.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, createHmac } from "node:crypto";
import { createServer } from "node:http";
import { cp, mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join, normalize, resolve } from "node:path";
import { chromium } from "playwright";

const started = Date.now();
const built = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
const timeout = 30_000;
const failures = [];

// A native binary of this repository, by its cabal target, unless named.
const binary = (variable, target) =>
  process.env[variable] ?? execFileSync("cabal", ["list-bin", "-v0", target, "--builddir=dist-newstyle/native"], { encoding: "utf8" }).trim();

// The server's build: the demo's files but its pages (the worker's offline
// page is not one of them), and the server's page.
const work = await mkdtemp(join(tmpdir(), "wiki-smoke-server-"));
const app = join(work, "app");
const data = join(work, "data");
await cp(built, app, {
  recursive: true,
  filter: (source) => {
    const rel = source.slice(built.length).replace(/^[/\\]/, "");
    return !(rel.endsWith(".html") && !rel.includes("/") && rel !== "offline.html") && !/^(s|search)([/\\]|$)/.test(rel);
  },
});
// At the root, whatever base path the demo's build was made for (the CI's
// is GitHub Pages', /blog/), since the server below is served at its root.
execFileSync(binary("WIKI_PRERENDER", "wiki-app:exe:wiki-app-prerender"), ["--server", "web/index.html", app], {
  stdio: "inherit",
  env: { ...process.env, HALOGEN_BASE_PATH: "/" },
});
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
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
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

// A page that reports what goes wrong in it; app.wasm and the API wait for
// their gates when they are set.
// Signed in as the administrator, unless told it is someone who is not.
async function newPage({ anonymous = false } = {}) {
  const context = await browser.newContext({ acceptDownloads: true, serviceWorkers: "block" });
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
  page.wasmGate = null;
  page.apiGate = null;
  page.apiAsked = [];
  await page.route("**/app.wasm", async (route) => {
    await page.wasmGate;
    await route.continue();
  });
  await page.route("**/api/v1/**", async (route) => {
    // What the program asks, not what the page shows from the API's
    // addresses (a space's icon, an attached image), which is the page's.
    if (route.request().resourceType() === "fetch") page.apiAsked.push(route.request().url());
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
// What the browser fills in from what it keeps itself, after the first
// render, whatever the server sent: the directory's spaces visited last,
// which this browser's local storage holds (Wiki.App.Recent), and the
// editor's bubbles of the writing assistant, which come with the settings
// this browser's IndexedDB keeps for the user (Wiki.App.Assistant). Neither
// they nor what is in them is a repair.
const browsers = ".recent-spaces, .editor-providers";

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
  await page.evaluate(({ unadopted, browsers }) => {
    const app = document.querySelector("#app");
    app.querySelector(".wiki").dataset.prerendered = "true";
    const marks = new Map();
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      if (node.parentElement?.closest(unadopted)) continue;
      if ((node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)?.closest(browsers)) continue;
      marks.set(node, node.nodeType === Node.TEXT_NODE ? node.data : [...node.attributes].map((a) => `${a.name}=${a.value}`).join(" "));
    }
    window.smokePrerendered = marks;
  }, { unadopted, browsers });
  releaseWasm();
  page.wasmGate = null;
  await eventually(async () => assert.ok(await programStarted(page), "no listener yet"), `${path}: the program starting`);
  // A moment for anything the adoption would change to be changed.
  await page.waitForTimeout(300);
  const repairs = await page.evaluate(({ unadopted, browsers }) => {
    const app = document.querySelector("#app");
    const found = [];
    for (const [node, was] of window.smokePrerendered) {
      if (!app.contains(node)) {
        if (node.nodeType !== Node.TEXT_NODE || was.trim() !== "") found.push(`gone: ${was}`);
      } else {
        const now = node.nodeType === Node.TEXT_NODE ? node.data : [...node.attributes].filter((a) => !["data-prerendered", "data-stuck", "data-current"].includes(a.name)).map((a) => `${a.name}=${a.value}`).join(" ");
        const before = node.nodeType === Node.TEXT_NODE ? was : was.replace(/ ?data-prerendered=true/, "");
        if (now !== before) found.push(`changed: ${before} -> ${now}`);
      }
    }
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      if (node.parentElement?.closest(unadopted)) continue;
      if ((node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)?.closest(browsers)) continue;
      if (!window.smokePrerendered.has(node) && !(node.nodeType === Node.TEXT_NODE && node.data === "")) found.push(`built: ${node.nodeName}`);
    }
    return found;
  }, { unadopted, browsers });
  const asked = [...page.apiAsked];
  releaseApi();
  page.apiGate = null;
  return { status: response.status(), repairs, shown, asked };
}

// The demo's build, served at the server's own address in place of the
// server, as a static host serves it: what the owner had there before the
// server took its address. It is served under the base path it was built
// for, which its pages' <base href> says (/ for a build for the root,
// GitHub Pages' /blog/ in CI); IndexedDB is the origin's whatever the path,
// so the server finds the demo's wiki all the same.
const demoBase = (await readFile(join(built, "index.html"), "utf8")).match(/<base href="([^"]*)">/)?.[1] ?? "/";
const demoTypes = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf" };
async function serveTheDemo(route) {
  const address = decodeURIComponent(new URL(route.request().url()).pathname);
  const path = `/${address.slice(demoBase.length)}`;
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
// A page at a top-level path of a space, body and all: the list of a
// space's pages has no bodies.
const pageAt = async (spacePath, slug) => {
  const space = await api(`spaces/at/${spacePath}`);
  assert.equal(space.status, 200, `no space at ${spacePath}`);
  const found = await api(`spaces/${encodeURIComponent(space.body.id)}/pages/at/${slug}`);
  assert.equal(found.status, 200, `no page at ${spacePath}/${slug}`);
  return found.body;
};

async function migrateTheDemo() {
  const page = await newPage();
  // The demo's photograph and video, answered here, as the network may be
  // out of reach.
  await page.route("https://upload.wikimedia.org/**", (route) => route.fulfill({ status: 204 }));

  // The demo, at the server's address: it keeps its wiki in this origin's
  // IndexedDB, and its administration exports it.
  const demoAddress = `${origin}${demoBase}**`;
  await page.route(demoAddress, serveTheDemo);
  await page.goto(url(demoBase));
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
  for (const line of ["3 spaces created", "1 space merged with the server's", "9 pages created", "1 page replaced by the imported one", "1 page left out"]) {
    assert.ok(told.includes(line), `the summary does not say "${line}": ${told}`);
  }
  // The shell has reloaded the tree of spaces, with the demo's in it.
  await page.locator("#app .wiki-sidebar a", { hasText: "Docs" }).waitFor({ timeout });
  const hello = await pageAt("blog", "hello-world");
  assert.ok(hello && !hello.body.includes("Written on the server."), "the server's Hello, world was not replaced");
  // The server's Blog was made with its home page.
  assert.deepEqual((await pagesOf("blog")).map((p) => p.slug), ["hello-world", "home"], "Notes on Haskell was imported though left out");
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
  for (const line of ["4 spaces merged with the server's", "1 page created", "10 pages kept as the server had them"]) {
    assert.ok(again.includes(line), `the second summary does not say "${line}": ${again}`);
  }
  const spaces = (await api("spaces")).body;
  const paths = spaces.map((s) => s.slug).sort();
  assert.deepEqual(paths, [...new Set(paths)], "a space is there twice");
  assert.deepEqual((await pagesOf("blog")).map((p) => p.slug).sort(), ["hello-world", "home", "notes-on-haskell"]);
  let total = 0;
  for (const space of ["blog", "docs", "team", "team/projects"]) {
    const slugs = (await pagesOf(space)).map((p) => `${p.parent ?? ""}/${p.slug}`);
    assert.deepEqual(slugs, [...new Set(slugs)], `a page of ${space} is there twice`);
    total += slugs.length;
  }
  assert.equal(total, 12, "the demo's eleven pages, once each, and the server's Blog's home page");
  // The team's template came in as one: listed apart, and offered.
  assert.deepEqual(
    (await pagesOf("team")).filter((p) => p.template).map((p) => p.slug),
    ["weekly-sync"],
    "the demo's template is not one on the server",
  );
  await page.context().close();
  console.log("ok: imported again from the demo's data in this browser, everything is merged and nothing is there twice");

  // A long page with its "Contents" panel, and a page with [[toc]], as the
  // server renders them: adopted with nothing to repair or ask, while the
  // section being read is marked by the script alone.
  const reader = await newPage();
  for (const [path, expected] of [
    ["/s/docs/p/markdown-guide/", "Contents"],
    ["/s/team/p/team-handbook/", "Before your first day"],
  ]) {
    const loaded = await loadAdopted(reader, path);
    assert.equal(loaded.status, 200, `${path}: the status`);
    assert.ok(loaded.shown.includes(expected), `${path}: "${expected}" is not there before app.wasm`);
    assert.deepEqual(loaded.repairs, [], `${path}: adopting it repaired it`);
    assert.deepEqual(loaded.asked, [], `${path}: the program asked the API for what the page carries`);
  }
  assert.equal(await reader.locator("#app .page-body nav.toc").count(), 1, "the handbook's [[toc]]");
  assert.equal(await reader.locator("#app .page-contents").count(), 0, "a panel beside a page with [[toc]]");
  await reader.goto(url("/s/docs/p/markdown-guide/#mathematics"));
  await reader.locator("#app .page-contents .toc-list a[href='#mathematics'][data-current]").waitFor({ timeout });
  await reader.context().close();
  console.log("ok: the server renders a page's contents and [[toc]], adopted with nothing to repair, and an address's #heading is scrolled to and marked");
}

const editorText = "#app .editor-cm .cm-content";
const markdownIn = (page) => page.evaluate((selector) => document.querySelector(selector)?.wikiEditor?.text() ?? null, editorText);
const content = (page) => page.locator("#app .wiki-content").textContent();

try {
  // ---- 1. The server's page, adopted -----------------------------------------

  const front = await fetch(url("/"));
  assert.equal(front.status, 200);
  const frontHtml = await front.text();
  assert.match(frontHtml, /<section class="directory">.*<h1>Spaces<\/h1>/s, "the front page, the directory of spaces, is not rendered");
  assert.ok(!frontHtml.includes("Loading…"), "the front page is the application loading");
  assert.match(frontHtml, /<script type="application\/json" id="wiki-preload">/, "the front page carries nothing for the program");
  // The page's Content Security Policy (Wiki.Api.ContentPolicy): sent as a
  // header, and the same text in the page's meta element, but for
  // frame-ancestors, which only a header can carry. Every page below runs
  // under it, and a violation is a console error, which fails the test.
  {
    const header = front.headers.get("content-security-policy") ?? "";
    const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]*)"/.exec(frontHtml)?.[1] ?? "";
    assert.ok(meta.includes("script-src 'self' 'wasm-unsafe-eval'"), `the front page's policy: ${meta}`);
    assert.equal(header, `${meta}; frame-ancestors 'none'`, "the policy's header and its meta element differ");
    assert.equal(front.headers.get("referrer-policy"), "same-origin");
    assert.equal(front.headers.get("permissions-policy"), "camera=(), microphone=(), geolocation=()");
    const wasm = await fetch(url("/app.wasm"));
    assert.equal(wasm.headers.get("content-security-policy"), null, "app.wasm has a policy of its own");
    console.log("ok: every page is sent with its Content Security Policy, the same in its header and its meta element");
  }
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
  // It opens at its home page, made with it, in a sidebar of its own.
  await page.locator("#app .sidebar-space-name", { hasText: "Smoke space" }).waitFor({ timeout });
  await page.locator("#app .page-view .page-title", { hasText: "Home" }).waitFor({ timeout });
  // The router changes the address a moment after the view renders.
  await eventually(() => assert.equal(here(page), "/s/smoke-space/"), "the new space's address");
  // A page, from its title, from the space's list of pages.
  await page.locator("#app .space-pages-link").click();
  await page.locator("#app .space-view h1", { hasText: "Smoke space" }).waitFor({ timeout });
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
  // The first save's "Saved" may still be showing: this save is waited for
  // by its answer, so that what is typed next is typed after it.
  const savedAgain = page.waitForResponse((r) => r.request().method() === "PUT" && /\/api\/v1\/pages\/[^/]+$/.test(new URL(r.url()).pathname), { timeout });
  await editor.press("Control+s");
  assert.equal((await savedAgain).status(), 200, "the save with the attachment's reference");
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
  // save is then a conflict, shown in the conflict view with their version
  // beside the work, which is kept until "Take theirs" is chosen.
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
  await page.locator("#app .editor .editor-conflict", { hasText: `${adminName} saved this page` }).waitFor({ timeout });
  await page.locator("#app .editor-conflict-pane .diff-added", { hasText: "Saved by someone else." }).waitFor({ timeout });
  assert.ok((await markdownIn(page)).endsWith("Not saved yet."), "the conflict lost the work");
  await page.locator("#app .editor-conflict button", { hasText: "Take theirs" }).click();
  await eventually(async () => assert.ok((await markdownIn(page)).endsWith("Saved by someone else."), "not yet"), "their version taken after the conflict");
  assert.equal(await page.locator("#app .editor-conflict-pane").count(), 0, "the conflict view, after Take theirs");
  console.log("ok: a save over someone else's newer one opens the conflict view, their version diffed beside the work, which takes theirs on request");

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

  // The server's settings, from the administration while the server runs:
  // the wiki's public address, and the fake provider with its secret, typed
  // once, never shown again, and checked against the provider.
  const serverSection = "#app .admin-view .admin-server";
  await page.locator(`${serverSection} .server-url-edit`).click();
  await page.locator(`${serverSection} .server-url-form input[name=url]`).fill(`http://127.0.0.1:${wikiPort}/`);
  await page.locator(`${serverSection} .server-url-form button[type=submit]`).click();
  await page.locator(`${serverSection} .server-url-value`, { hasText: `http://127.0.0.1:${wikiPort}/` }).waitFor({ timeout });
  await page.locator(`${serverSection} .server-provider-add`).click();
  await page.locator(`${serverSection} .server-provider-form input[name=name]`).fill("fake");
  await page.locator(`${serverSection} .server-provider-form select[name=kind]`).selectOption("oidc");
  await page.locator(`${serverSection} .server-provider-form input[name=client-id]`).fill("smoke-client");
  await page.locator(`${serverSection} .server-provider-form input[name=issuer]`).fill(providerOrigin);
  await page.locator(`${serverSection} .server-provider-form input[name=secret]`).fill(oidcSecret);
  await page.locator(`${serverSection} .server-provider-form button[type=submit]`).click();
  const fakeRow = `${serverSection} .server-provider[data-name=fake]`;
  await page.locator(`${fakeRow} .server-provider-secret`, { hasText: "set" }).waitFor({ timeout });
  assert.equal(await page.locator(`${fakeRow} .server-provider-redirect`).textContent(), `http://127.0.0.1:${wikiPort}/auth/fake/callback`, "the redirect URI to register");
  await page.locator(`${fakeRow} .server-provider-check`).click();
  await page.locator(`${fakeRow} .server-provider-checked`, { hasText: "It answered" }).waitFor({ timeout });
  assert.ok(!(await page.locator(serverSection).textContent()).includes(oidcSecret), "the provider's secret is shown");
  const settings = await api("admin/server");
  assert.equal(settings.status, 200, "the server's settings");
  assert.deepEqual(settings.body.providers.map((p) => [p.name, p.secret]), [["fake", "set"]], "the server's providers");
  assert.ok(!JSON.stringify(settings.body).includes(oidcSecret), "the API gives the provider's secret back");
  console.log("ok: the administration sets the public address and adds a provider, which answers its check, its secret never shown");

  // Backups (WP4.9): none until they are turned on in the Server section's
  // "Backups"; then the first is made at once, and another by hand, each
  // shown with its size. And the console's restore: refused the data
  // directory of the running server, and done into a fresh one, with the
  // attachments' files brought from the data directory's.
  const backupsPart = `${serverSection} .server-backups`;
  await page.locator(`${backupsPart} .backups-state`, { hasText: "Off" }).waitFor({ timeout });
  assert.equal((await api("admin/server/backups")).body.last, null, "a backup before they were turned on");
  await page.locator(`${backupsPart} .backups-edit`).click();
  await page.locator(`${backupsPart} .backups-form input[name=enabled]`).check();
  await page.locator(`${backupsPart} .backups-form select[name=schedule]`).selectOption("hours");
  await page.locator(`${backupsPart} .backups-form button[type=submit]`).click();
  await page.locator(`${backupsPart} .backups-state`, { hasText: "On: every 6 hours" }).waitFor({ timeout });
  await eventually(async () => {
    const made = await api("admin/server/backups");
    assert.equal(made.body.last?.failure, null, "the first backup failed");
    assert.ok(made.body.last?.file, "no backup made yet");
  }, "the first backup, made when they are turned on");
  await page.locator(`${backupsPart} .backups-now`).click();
  await page.locator(`${backupsPart} .backups-last`, { hasText: "by hand: made" }).waitFor({ timeout });
  const backedUp = await api("admin/server/backups");
  assert.equal(backedUp.body.last.trigger, "Manual", "the backup by hand");
  const backupFile = join(data, "backups", backedUp.body.last.file);
  assert.equal((await stat(backupFile)).size, backedUp.body.last.size, "the backup's size");
  const restoring = (target) =>
    execFileSync(wikiServer, ["restore", backupFile, "--data", target, "--attachments", join(data, "attachments")], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      // On PostgreSQL the fresh data directory has a database of its own.
      env: target === data || !process.env.WIKI_SMOKE_RESTORE_DATABASE_URL ? process.env : { ...process.env, WIKI_DATABASE_URL: process.env.WIKI_SMOKE_RESTORE_DATABASE_URL },
    });
  assert.throws(() => restoring(data), (error) => /A server is running on/.test(String(error.stderr)), "a restore into the running server's data directory");
  const restored = restoring(join(work, "restored"));
  assert.ok(restored.includes("Restored") && !restored.includes("Warning"), `the restore said: ${restored}`);
  console.log("ok: backups are made once turned on in the administration, and by hand, and one restores into a fresh data directory, not under the running server");

  // A second space, made public in its permissions; the first stays
  // private.
  const publicSpace = await api("spaces", { method: "POST", body: JSON.stringify({ parent: null, name: "Smoke public" }) });
  assert.equal(publicSpace.status, 201, "the public space");
  await page.goto(url("/s/smoke-public/pages/"));
  await page.locator("#app .space-view h1", { hasText: "Smoke public" }).waitFor({ timeout });
  await page.locator("#app .space-view .space-settings-toggle").click();
  await page.locator("#app .space-permissions .public-switch[aria-checked=false]").click();
  await page.locator("#app .space-view .badge", { hasText: "Public" }).waitFor({ timeout });
  console.log("ok: a space is made public in its settings' permissions");
  // Its profile: a description and an emoji, and an image uploaded for its
  // icon, which the server serves.
  await page.locator("#app .space-settings .space-description-field").fill("Where the smoke test writes in public.");
  await page.locator("#app .icon-kind-emoji input").check();
  await page.locator("#app .icon-emoji").fill("🔥");
  await page.locator("#app .space-profile-form button.primary").click();
  await page.locator("#app .settings-saved", { hasText: "Saved" }).waitFor({ timeout });
  await page.locator("#app .sidebar-space .space-icon-emoji", { hasText: "🔥" }).waitFor({ timeout });
  const pixel = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");
  await page.locator("#app .space-settings .icon-upload input[type=file]").setInputFiles({ name: "smoke.png", mimeType: "image/png", buffer: pixel });
  const icon = page.locator("#app .sidebar-space img.space-icon-image");
  await icon.waitFor({ timeout });
  const iconSrc = await icon.getAttribute("src");
  assert.match(iconSrc, /^api\/v1\/spaces\/[^/]+\/icon\/[0-9a-f]{64}$/, "the icon's address");
  // Relative to the page's base, as the browser fetched it.
  const iconAddress = await page.evaluate((src) => new URL(src, document.baseURI).href, iconSrc);
  const iconServed = await fetch(iconAddress, { headers: { Cookie: sessionCookie } });
  assert.equal(iconServed.status, 200, "the icon, served");
  assert.ok(Buffer.from(await iconServed.arrayBuffer()).equals(pixel), "the icon's bytes");
  await eventually(async () => assert.equal(await icon.evaluate((img) => img.complete && img.naturalWidth), 1, "not yet"), "the icon drawn");
  console.log("ok: a space's settings give it a description, an emoji, and an uploaded image the server serves");
  // Shown as a blog, from the same settings, with a post of its own.
  await page.locator("#app .space-settings .space-blog").check();
  await page.locator("#app .space-profile-form button.primary").click();
  await page.locator("#app .settings-saved", { hasText: "Saved" }).waitFor({ timeout });
  const post = await api(`spaces/${encodeURIComponent(publicSpace.body.id)}/pages`, {
    method: "POST",
    body: JSON.stringify({ parent: null, title: "Smoke post", body: "The smoke test's *first* post." }),
  });
  assert.equal(post.status, 201, "the post");
  await page.context().close();

  // Someone who is not signed in sees the public space only, and no way to
  // the administration, which the server refuses them too.
  const visitor = await newPage({ anonymous: true });
  await visitor.goto(url("/"));
  await eventually(async () => assert.ok(await programStarted(visitor), "no listener yet"), "the visitor's program starting");
  await visitor.locator("#app .wiki-sidebar a", { hasText: "Smoke public" }).waitFor({ timeout });
  assert.deepEqual(await visitor.locator("#app .directory .space-card-name").allTextContents(), ["Smoke public"], "the spaces a visitor sees");
  assert.equal(
    await visitor.locator("#app .directory .space-card-description").textContent(),
    "Where the smoke test writes in public.",
    "the public space's description, to a visitor",
  );
  assert.equal(await visitor.locator("#app .admin-link").count(), 0, "the way to the administration, to a visitor");
  await visitor.locator("#app .sign-in-toggle").waitFor({ timeout });
  assert.equal((await fetch(url("/s/smoke-space/"))).status, 404, "the private space, to a visitor, as if it were not there");
  assert.equal((await fetch(url("/api/v1/admin/directory"))).status, 403, "the administration's API, to a visitor");
  console.log("ok: a visitor who is not signed in sees the public space and nothing else, and no administration");

  // The public blog, as a visitor and a feed reader find it: its page
  // adopted with nothing to repair, the head announcing its feeds and
  // describing it, its Atom and RSS feeds with the post whole, the sitemap
  // with its pages and nothing private.
  const blogVisit = await loadAdopted(visitor, "/s/smoke-public/");
  assert.equal(blogVisit.status, 200, "the public blog, to a visitor");
  assert.ok(blogVisit.shown.includes("Smoke post") && blogVisit.shown.includes("No comments"), `the blog's posts: ${blogVisit.shown}`);
  assert.deepEqual(blogVisit.repairs, [], "adopting the blog's page repaired it");
  assert.deepEqual(blogVisit.asked, [], "the program asked the API for what the blog's page carries");
  await visitor.locator("#app .post-link", { hasText: "Smoke post" }).click();
  await visitor.locator("#app .post-date", { hasText: "Posted" }).waitFor({ timeout });
  const postPage = await (await fetch(url("/s/smoke-public/p/smoke-post/"))).text();
  for (const tag of [
    '<meta property="og:title" content="Smoke post">',
    '<meta name="description" content="The smoke test\'s first post.">',
    '<link rel="alternate" type="application/atom+xml" title="Smoke public (Atom)" href="/s/smoke-public/feed.xml">',
  ]) {
    assert.ok(postPage.includes(tag), `the post's head has no ${tag}`);
  }
  const atom = await fetch(url("/s/smoke-public/feed.xml"));
  assert.equal(atom.status, 200, "the public blog's Atom feed");
  assert.match(atom.headers.get("content-type"), /^application\/atom\+xml/, "the Atom feed's type");
  const atomText = await atom.text();
  assert.ok(atomText.includes("<title>Smoke post</title>") && atomText.includes("&lt;em&gt;first&lt;/em&gt;"), `the Atom feed: ${atomText}`);
  const rss = await fetch(url("/s/smoke-public/feed.rss"));
  assert.equal(rss.status, 200, "the public blog's RSS feed");
  assert.ok((await rss.text()).includes("<guid isPermaLink=\"true\">"), "the RSS feed's items");
  assert.equal((await fetch(url("/s/smoke-space/feed.xml"))).status, 404, "a private space's feed");
  const sitemap = await (await fetch(url("/sitemap.xml"))).text();
  assert.ok(sitemap.includes("/s/smoke-public/p/smoke-post/</loc>"), `the sitemap: ${sitemap}`);
  assert.ok(!sitemap.includes("smoke-space"), "the sitemap lists a private space");
  await visitor.context().close();
  console.log("ok: a public blog lists its posts, describes them to link previews, and has feeds and a sitemap, nothing private in them");

  // A closed wiki: someone who is not signed in is shown the way to sign in
  // and nothing else, rendered so by the server and adopted with nothing to
  // repair; an invitation's link makes them an account, and the wiki opens
  // again for everyone.
  const closing = await api("admin/settings", { method: "PUT", body: JSON.stringify({ access: "Closed", newAccountsCreateSpaces: false, adminCreatesPasswordAccounts: true }) });
  assert.equal(closing.status, 200, "closing the wiki");
  assert.equal((await fetch(url("/api/v1/spaces"))).status, 401, "the spaces of a closed wiki, to a visitor");
  assert.equal((await fetch(url("/s/smoke-public/feed.xml"))).status, 404, "a closed wiki's feed");
  assert.equal((await fetch(url("/sitemap.xml"))).status, 404, "a closed wiki's sitemap");
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
  const opening = await api("admin/settings", { method: "PUT", body: JSON.stringify({ access: "Open", newAccountsCreateSpaces: false, adminCreatesPasswordAccounts: true }) });
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
  // The page she lands on is the server's, there before the program: a
  // click on her name before the program has adopted it opens nothing.
  await eventually(async () => assert.ok(await programStarted(olive), "no listener yet"), "Olive's program starting");
  await olive.locator("#app .account-toggle").click();
  await olive.locator("#app .identity .identity-provider", { hasText: "Fake" }).waitFor({ timeout });
  assert.equal(await olive.locator("#app .identity-disconnect").getAttribute("disabled"), "", "her only way in may be disconnected");
  // She signs in with a provider and has no password: none to set (WP5.6),
  // in the panel or through the API, nor from the administration.
  assert.equal(await olive.locator("#app .password-change-toggle").count(), 0, "a password to set, for an account that signs in with a provider");
  // Asked outside her page, whose console would report the refusal.
  const oliveSession = (await olive.context().cookies()).find((c) => c.name === "wiki_session");
  assert.ok(oliveSession, "no session cookie for Olive");
  const ownRefused = await fetch(url("/api/v1/account/password"), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: `wiki_session=${oliveSession.value}` },
    body: JSON.stringify({ current: null, new: "olive's own password" }),
  });
  assert.equal(ownRefused.status, 400, "her own password, set while she signs in with a provider");
  const oliveId = landed.user.id;
  assert.ok((await api("admin/directory")).body.providerOnly.includes(oliveId), "the directory says she has no password to set");
  const administration = await newPage();
  await administration.goto(url("/admin/"));
  await eventually(async () => assert.ok(await programStarted(administration), "no listener yet"), "the administration's program starting");
  await administration.locator("#app .admin-view .user-row[data-login=olive] .identity-unlink", { hasText: "Disconnect Fake" }).waitFor({ timeout });
  assert.equal(await administration.locator("#app .admin-view .user-row[data-login=olive] .password-ask").count(), 0, "a password offered for her by the administration");
  // Disconnected there, she has no way in (her session ends with it), and
  // the administration gives her a password, typed since this server sends
  // no mail, which the button says.
  await administration.locator("#app .admin-view .user-row[data-login=olive] .identity-unlink").click();
  await administration.locator("#app .admin-view .user-row[data-login=olive] .password-hint", { hasText: "The server sends no mail" }).waitFor({ timeout });
  await administration.locator("#app .admin-view .user-row[data-login=olive] .password-ask", { hasText: "Set password" }).click();
  await administration.locator("#app .admin-view .user-row[data-login=olive] .password-new").fill("olive's own password");
  await administration.locator("#app .admin-view .user-row[data-login=olive] .password-form button.primary").click();
  await administration.locator("#app .admin-view .user-row[data-login=olive] .account-state", { hasText: "Signs in with a password" }).waitFor({ timeout });
  await administration.context().close();
  // She signs in with it in her browser, from the header's form.
  await olive.reload();
  await eventually(async () => assert.ok(await programStarted(olive), "no listener yet"), "Olive's program starting again");
  await olive.locator("#app .sign-in-toggle").click();
  await olive.locator("#app .sign-in-form input[name=login]").fill("olive");
  await olive.locator("#app .sign-in-form input[name=password]").fill("olive's own password");
  await olive.locator("#app .sign-in-form button[type=submit]").click();
  await olive.locator("#app .account .account-toggle", { hasText: "Olive Oidc" }).waitFor({ timeout });
  await olive.locator("#app .account-toggle").click();
  await olive.locator("#app .account-password", { hasText: "With your password" }).waitFor({ timeout });
  await olive.locator("#app .password-change-toggle", { hasText: "Change password" }).waitFor({ timeout });
  const withPassword = await fetch(url("/api/v1/session"), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
    body: JSON.stringify({ login: "olive", password: "olive's own password" }),
  });
  assert.equal(withPassword.status, 200, "signing in with the password she set");
  // Her sessions: this browser's, marked, and the one just signed in from
  // outside it, which "Sign out everywhere" ends while hers stays.
  const outside = (withPassword.headers.get("set-cookie") ?? "").split(";")[0];
  assert.ok(outside.startsWith("wiki_session="), "no session cookie for the password's sign-in");
  await olive.locator("#app .account-toggle").click();
  await olive.locator("#app .account-toggle").click();
  await olive.locator("#app .session-item").nth(1).waitFor({ timeout });
  assert.equal(await olive.locator("#app .session-item").count(), 2, "her two sessions are listed");
  await olive.locator("#app .session-current .session-this", { hasText: "This browser" }).waitFor({ timeout });
  await olive.locator("#app .sessions-end-others").click();
  await olive.locator("#app .session-item").nth(1).waitFor({ state: "detached", timeout });
  const ended = await (await fetch(url("/api/v1/session"), { headers: { Cookie: outside } })).json();
  assert.equal(ended.user, null, "the session signed out everywhere still signs in");
  // A second factor, from the QR code's secret as text, confirmed with a
  // code computed here as her application would; then her password alone
  // no longer signs her in.
  await olive.locator("#app .second-factor-start").click();
  // Her password first: a browser left signed in does not set one up.
  await olive.locator("#app .totp-password-form input[name=password]").fill("olive's own password");
  await olive.locator("#app .totp-password-form button[type=submit]").click();
  const secret = ((await olive.locator("#app .totp-secret code").textContent()) ?? "").replace(/\s/g, "");
  assert.ok((await olive.locator("#app .totp-qr rect").count()) > 50, "the QR code is drawn");
  await olive.locator("#app .totp-confirm input[name=code]").fill(totp(secret, Date.now()));
  await olive.locator("#app .totp-confirm button[type=submit]").click();
  await olive.locator("#app .recovery-code-list li").nth(9).waitFor({ timeout });
  await olive.locator("#app .recovery-kept").click();
  await olive.locator("#app .second-factor-on").waitFor({ timeout });
  const halfWay = await fetch(url("/api/v1/session"), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
    body: JSON.stringify({ login: "olive", password: "olive's own password" }),
  });
  assert.equal(halfWay.status, 401, "her password alone signed her in");
  assert.equal((await halfWay.json()).error, "SecondFactorRequired", "the second factor was not asked for");
  await olive.context().close();
  for (const secret of [oidcSecret, ...oidcIssued]) assert.ok(!log.includes(secret), "a provider's code, token or secret is in the server's log");
  console.log("ok: signing in with a provider goes there and back, and lands signed in, as a new account, on the page it left");
  console.log("ok: a user who signs in with a provider has no password to set, until the administration disconnects it and gives her one, which she signs in with");
  console.log("ok: her sessions are listed in the panel and signed out everywhere but here; a second factor set up there is asked for after her password");

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

  // The page as a Word document, from its "Export" menu: made by the pandoc
  // linked into the server, and downloaded under the page's title.
  await fresh.locator("#app .page-view .export-menu summary").click();
  const [docxDownload] = await Promise.all([fresh.waitForEvent("download"), fresh.locator("#app .export-formats a.export-docx").click()]);
  assert.equal(docxDownload.suggestedFilename(), "first-page.docx");
  const docx = await readFile(await docxDownload.path());
  assert.equal(docx.subarray(0, 2).toString("latin1"), "PK", "the exported document is not a zip");
  assert.ok(docx.includes("word/document.xml"), "the exported document has no word/document.xml");
  console.log("ok: the page exports as a Word document from its Export menu");

  // Comments, live over the server's WebSocket: a second tab on the page
  // subscribes to it, the first comments on the page, and the second shows
  // the comment without being reloaded.
  const watcher = await newPage();
  const sockets = [];
  const subscribed = new Promise((done) =>
    watcher.on("websocket", (socket) => {
      sockets.push(socket.url());
      socket.on("framesent", (frame) => sockets.push(`sent ${frame.payload}`));
      // The server's answer, with the page's threads: from here on every
      // comment on the page is told to this tab.
      socket.on("framereceived", (frame) => {
        sockets.push(`received ${frame.payload}`);
        if (String(frame.payload).includes('"subscribed"')) done();
      });
      socket.on("socketerror", (error) => sockets.push(`error ${error}`));
      socket.on("close", () => sockets.push("closed"));
    }),
  );
  await watcher.goto(url("/s/smoke-space/p/first-page/"));
  await eventually(async () => assert.ok(await programStarted(watcher), "no listener yet"), "the second tab's program starting");
  await watcher.locator("#app .page-comments").waitFor({ timeout });
  await Promise.race([subscribed, new Promise((_, fail) => setTimeout(() => fail(new Error(`no subscription on the WebSocket: ${JSON.stringify(sockets)}`)), timeout))]);
  assert.ok(sockets[0].endsWith("/api/v1/events"), `a WebSocket at ${sockets[0]}`);
  await fresh.locator("#app .page-comments .comment-new textarea").fill("Live from the *smoke* test.");
  await fresh.locator("#app .page-comments .comment-new button", { hasText: "Comment" }).click();
  await fresh.locator("#app .page-comments .comment-body em", { hasText: "smoke" }).waitFor({ timeout });
  await watcher.locator("#app .page-comments .comment-body em", { hasText: "smoke" }).waitFor({ timeout });
  assert.equal((await fetch(url("/api/v1/events"))).status, 426, "the channel's address, asked for without a WebSocket");
  await watcher.context().close();
  console.log("ok: a comment made in one tab is shown in another on the same page, over the WebSocket");

  // Who is editing, over the same WebSocket, between two users: Sam, given
  // Edit on the space, shows the page while Ada opens its editor in another
  // tab. Sam's page says that she is editing, and Sam's editor names her and
  // asks before starting; her closing the editor ends it, and so does her
  // tab going away. A save of hers shows in Sam's tab without a reload.
  const smokeSpace = await api("spaces/at/smoke-space");
  const samUser = (await api("admin/directory")).body.users.find((u) => u.login === "sam");
  const grantedSam = await api(`spaces/${encodeURIComponent(smokeSpace.body.id)}/grants`, {
    method: "PUT",
    body: JSON.stringify({ subject: { tag: "SubjectUser", contents: samUser.id }, permission: "Edit", granted: true }),
  });
  assert.equal(grantedSam.status, 204, "Sam's grant to edit the smoke space");
  const samSession = await fetch(url("/api/v1/session"), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1" },
    body: JSON.stringify({ login: "sam", password: "sam's password" }),
  });
  const samToken = /wiki_session=([^;]+)/.exec(samSession.headers.get("set-cookie") ?? "")?.[1];
  assert.ok(samToken, "no session cookie for Sam");
  const samTab = await newPage({ anonymous: true });
  await samTab.context().addCookies([{ name: "wiki_session", value: samToken, url: origin }]);
  await samTab.goto(url("/s/smoke-space/p/first-page/"));
  await eventually(async () => assert.ok(await programStarted(samTab), "no listener yet"), "Sam's tab's program starting");
  await samTab.locator("#app .user-name", { hasText: "Sam Smoke" }).waitFor({ timeout });
  await samTab.locator("#app .page-view .page-body").waitFor({ timeout });
  const adaTab = await newPage();
  await adaTab.goto(url("/s/smoke-space/p/first-page/edit/"));
  await eventually(async () => assert.ok(await programStarted(adaTab), "no listener yet"), "Ada's tab's program starting");
  await adaTab.locator(editorText).waitFor({ timeout });
  await samTab.locator("#app .page-actions .page-editors", { hasText: `${adminName} is editing this page.` }).waitFor({ timeout });
  // Sam's editor, opened, names Ada and asks before starting.
  await samTab.locator("#app .page-actions a[href$='/first-page/edit/']").click();
  await samTab.locator("#app .editor-presence-warning", { hasText: `${adminName} is editing this page. Open the editor anyway?` }).waitFor({ timeout });
  await samTab.locator("#app .editor-presence-warning button", { hasText: "Back to the page" }).click();
  await samTab.locator("#app .page-actions .page-editors", { hasText: `${adminName} is editing this page.` }).waitFor({ timeout });
  // Ada closes her editor: the presence ends.
  await adaTab.locator("#app .editor-cancel").click();
  await adaTab.locator("#app .page-view .page-body").waitFor({ timeout });
  await samTab.locator("#app .page-live").waitFor({ state: "detached", timeout });
  // She opens it again, and her tab goes away without a word: so does the
  // presence, with the connection.
  await adaTab.locator("#app .page-actions a[href$='/first-page/edit/']").click();
  await adaTab.locator(editorText).waitFor({ timeout });
  await samTab.locator("#app .page-actions .page-editors", { hasText: `${adminName} is editing this page.` }).waitFor({ timeout });
  await adaTab.context().close();
  await samTab.locator("#app .page-live").waitFor({ state: "detached", timeout });
  // A save of hers, made elsewhere, shows in Sam's tab without a reload.
  const firstPage = await fetch(url(`/api/v1/spaces/${encodeURIComponent(smokeSpace.body.id)}/pages/at/first-page`), { headers: { Cookie: sessionCookie } });
  const shownPage = await firstPage.json();
  const savedLive = await fetch(url(`/api/v1/pages/${encodeURIComponent(shownPage.id)}`), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: sessionCookie, "If-Match": firstPage.headers.get("etag") },
    body: JSON.stringify({ title: "First page", body: `${shownPage.body}\n\nSaved while Sam reads.` }),
  });
  assert.equal(savedLive.status, 200, "the save Sam's tab shows");
  await samTab.locator("#app .page-view .page-body", { hasText: "Saved while Sam reads." }).waitFor({ timeout });
  console.log("ok: two users' tabs on a page: one's editor is named in the other's page and editor, until it closes or its tab goes; a save shows in the other tab live");
  // A mention (WP4.13): Ada's comment names Sam, who is told at once under
  // the bell in his tab, over the WebSocket, and sees the mention as a link.
  const mentioned = await fetch(url(`/api/v1/pages/${encodeURIComponent(shownPage.id)}/threads`), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: sessionCookie },
    body: JSON.stringify({ anchor: null, body: "Over to you, @sam." }),
  });
  assert.equal(mentioned.status, 201, "the comment that mentions Sam");
  await samTab.locator("#app .notifications-count", { hasText: "1" }).waitFor({ timeout });
  await samTab.locator("#app .notifications-toggle").click();
  await samTab.locator("#app .notification-list .notification-what", { hasText: `${adminName} mentioned you` }).waitFor({ timeout });
  await samTab.locator("#app .page-comments a.mention", { hasText: "@sam" }).waitFor({ timeout });
  await samTab.context().close();
  console.log("ok: a comment that mentions a user is told under the bell in their tab, over the WebSocket, and links to them");

  // ---- 3. Every route of the walk, rendered by the server --------------------

  const walked = [
    ["/", 200, "Smoke space"],
    ["/s/smoke-public/", 200, "Smoke public"],
    ["/s/smoke-public/pages/", 200, "Where the smoke test writes in public."],
    ["/s/smoke-space/", 200, "Welcome to Smoke space."],
    ["/s/smoke-space/pages/", 200, "Space settings"],
    ["/s/smoke-space/p/first-page/", 200, "Saved by someone else."],
    ["/s/smoke-space/p/first-page/source/", 200, "(attachment:notes.txt)"],
    ["/s/smoke-space/p/first-page/history/", 200, "Version 1"],
    ["/s/smoke-space/p/first-page/slides/", 200, "1 / 1"],
    ["/s/smoke-space/p/first-page/edit/", 200, "Editing First page"],
    ["/s/smoke-space/new-page/", 200, "New page"],
    ["/new-space/", 200, "New space"],
    ["/search/?q=smoke", 200, "First page"],
    ["/admin/", 200, "Smoke testers"],
    ["/unsubscribe/not-a-secret/", 200, "Stop the mail"],
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

  // ---- 5. What the server says of itself -------------------------------------

  // Its health on both listeners; its metrics on the admin one only, by
  // route pattern; and the audit log of what the walk changed in the
  // administration, newest first.
  const adminRoot = /listener=admin address="?(http:\/\/[^\s"]+?)\/admin\/?"?(\s|$)/m.exec(log)?.[1];
  assert.ok(adminRoot, `the admin listener's address is not in the log:\n${log}`);
  for (const root of [origin, adminRoot]) {
    const health = await fetch(`${root}/healthz`);
    assert.equal(health.status, 200, `${root}/healthz`);
    const said = await health.json();
    assert.equal(said.status, "ok", `${root}/healthz: ${JSON.stringify(said)}`);
    assert.ok(Number.isInteger(said.schemaVersion) && said.schemaVersion >= 1, `${root}/healthz: ${JSON.stringify(said)}`);
  }
  const metrics = await fetch(`${adminRoot}/metrics`);
  assert.equal(metrics.status, 200, "the metrics on the admin listener");
  assert.ok((metrics.headers.get("content-type") ?? "").startsWith("text/plain; version=0.0.4"), metrics.headers.get("content-type"));
  const scraped = await metrics.text();
  assert.ok(scraped.includes('wiki_http_requests_total{listener="public",route="/api/v1/session",method="POST",status="2xx"}'), "signing in is counted by its route");
  assert.ok(/^wiki_users \d+$/m.test(scraped) && /^wiki_database_bytes \d+$/m.test(scraped), "the gauges");
  assert.ok(!scraped.includes(sessionToken), "a session's secret in the metrics");
  assert.equal((await fetch(url("/metrics"))).status, 404, "the metrics on the public listener");
  const logged = await (await fetch(`${adminRoot}/admin/api/v1/admin/activity`)).json();
  assert.ok(logged.available && logged.entries.length > 0, `the activity: ${JSON.stringify(logged)}`);
  assert.ok(logged.entries.some((e) => e.action === "group.create"), `no group made in the activity: ${JSON.stringify(logged.entries.map((e) => e.action))}`);
  console.log("ok: /healthz on both listeners, /metrics on the admin one only by route pattern, and the walk's administration in the activity");

  // ---- 8. Reading offline, through the service worker ------------------------

  // In a block of its own: its names are its own.
  {
    // A browser that lets the worker in, as a reader's does, signed in as the
    // administrator. Offline, what the worker has not kept fails to load (the
    // bell, the live channel), as it would without one: that is what offline
    // is, and the page says so.
    const offlineContext = await browser.newContext();
    await offlineContext.addCookies([{ name: "wiki_session", value: sessionToken, url: origin }]);
    const reader = await offlineContext.newPage();
    reader.on("pageerror", (error) => failures.push(`page error at ${reader.url()}: ${error.message}`));
    reader.on("console", (message) => {
      if (message.type() === "error" && !/ERR_INTERNET_DISCONNECTED|Failed to load resource|WebSocket|\b(401|404|409)\b/.test(message.text())) {
        failures.push(`console error at ${reader.url()}: ${message.text()}`);
      }
    });
    reader.on("dialog", (dialog) => dialog.accept());
    // What the worker keeps of this wiki: each answer's address (a path) and
    // when it was kept, by the kind of cache ("pages", "answers").
    const kept = () =>
      reader.evaluate(async () => {
        const found = {};
        for (const name of await caches.keys()) {
          const kind = name.split(" ")[0].replace(/^wiki-/, "");
          const cache = await caches.open(name);
          for (const request of await cache.keys()) {
            (found[kind] ??= []).push({ path: new URL(request.url).pathname, at: (await cache.match(request)).headers.get("X-Wiki-Kept-At") });
          }
        }
        return found;
      });
    const keptPaths = async (kind) => ((await kept())[kind] ?? []).map((entry) => entry.path);
    const firstPage = "/s/smoke-space/p/first-page/";
    await reader.goto(url("/s/smoke-space/"));
    await reader.locator("#app .sidebar-space-name", { hasText: "Smoke space" }).waitFor({ timeout });
    await eventually(async () => assert.ok(await reader.evaluate(() => navigator.serviceWorker.controller !== null), "no worker"), "the service worker taking the page over");
    // The page that installed the worker, which the worker did not serve, is
    // kept when the page asks; one loaded since, as it is served.
    await eventually(async () => assert.ok((await keptPaths("pages")).includes("/s/smoke-space/"), "not kept"), "the first page kept");
    await reader.goto(url(firstPage));
    await reader.locator("#app .page-body", { hasText: "Saved by someone else." }).waitFor({ timeout });
    await eventually(async () => assert.ok(await programStarted(reader), "no listener yet"), "the program starting");
    await eventually(async () => assert.ok((await keptPaths("pages")).includes(firstPage), "not kept"), "a page kept");
    // A link followed to another space: what the program reads for it is
    // kept, but for what is never kept (who is asking, the administration,
    // the account, notifications).
    const toPublic = async () => {
      await reader.locator("#app .space-switcher-toggle").click();
      await reader.locator("#app .space-switcher-option", { hasText: "Smoke public" }).click();
      await reader.locator("#app .sidebar-space-name", { hasText: "Smoke public" }).waitFor({ timeout });
      await reader.locator("#app .wiki-content :is(.page-view, .space-view, .blog-view)").first().waitFor({ timeout });
      assert.equal(await reader.locator("#app .wiki-content .error").count(), 0, "the public space, failed");
    };
    await toPublic();
    await eventually(async () => assert.ok((await keptPaths("answers")).length > 0, "nothing kept"), "the API's answers kept");
    const answers = await keptPaths("answers");
    assert.ok(answers.every((path) => !/\/api\/v1\/(session|admin|account|notifications)(\/|$)/.test(path)), `kept what is never kept: ${answers}`);
    console.log(`note: the worker kept ${(await keptPaths("pages")).length} pages and ${answers.length} answers of the API`);

    // Offline: the page reloaded is the copy kept, saying so, with the
    // offline notice, and the program starts on it from the files kept.
    await offlineContext.setOffline(true);
    await reader.goto(url(firstPage));
    const copyLine = reader.locator("#app .wiki-content > .offline-copy");
    await copyLine.waitFor({ timeout });
    await reader.locator("#app .offline-notice", { hasText: "You are offline" }).waitFor({ timeout });
    await reader.locator("#app .page-body", { hasText: "Saved by someone else." }).waitFor({ timeout });
    await eventually(async () => assert.ok(await programStarted(reader), "no listener yet"), "the program starting offline");
    // The time, in the reader's zone and language, once the island has it.
    await eventually(async () => assert.match(await copyLine.textContent(), /^\s*You are reading an offline copy from \S.*\.\s*$/s), "the offline copy's line");
    // A link followed offline: shown from the API's answers kept, and the
    // line goes, which was about the page served.
    await toPublic();
    assert.equal(await reader.locator("#app .offline-copy").count(), 0, "the offline copy's line, on another route");
    // A page never read here: the worker's offline page, with the pages it
    // has.
    await reader.goto(url("/s/smoke-public/pages/"));
    await reader.locator(".offline-page h1", { hasText: "This page is not available offline" }).waitFor({ timeout });
    await reader.locator(".offline-page .offline-pages a").first().waitFor({ timeout });
    console.log("ok: offline, a page read here is the copy the worker kept, saying since when, with the offline notice; a link followed shows what was kept; a page never read gets the offline page");

    // Back online: the live page.
    await offlineContext.setOffline(false);
    await reader.goto(url(firstPage));
    await reader.locator("#app .page-body", { hasText: "Saved by someone else." }).waitFor({ timeout });
    await eventually(async () => assert.ok(await programStarted(reader), "no listener yet"), "the program starting online");
    assert.equal(await reader.locator("#app .offline-copy").count(), 0, "the offline copy's line, online");
    assert.equal(await reader.locator("#app .offline-notice").count(), 0, "the offline notice, online");
    // Signing out lets go of every page and answer kept as the administrator;
    // what is read after, as nobody, is kept again.
    const signingOut = await reader.evaluate(() => new Date().toISOString());
    await reader.locator("#app .sign-out").click();
    await reader.locator("#app .sign-in-toggle").waitFor({ timeout });
    await eventually(async () => {
      const after = await kept();
      const older = [...(after.pages ?? []), ...(after.answers ?? [])].filter((entry) => entry.at < signingOut);
      assert.deepEqual(older, [], "kept from before signing out");
      assert.ok((after.app ?? []).length > 0, "the application's files let go of");
    }, "what was kept let go of on signing out");
    await offlineContext.close();
    console.log("ok: back online the page is the live one, and signing out lets go of the pages and answers kept");
  }
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

// The code of an authenticator application for a base32 secret at a moment
// (RFC 6238: HMAC-SHA-1 of the 30-second step, six digits), as the smoke
// test's own second, independent implementation of the server's.
function totp(base32, millis) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of base32.toUpperCase().replace(/=+$/, "")) bits += alphabet.indexOf(c).toString(2).padStart(5, "0");
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(millis / 1000 / 30)));
  const mac = createHmac("sha1", key).update(counter).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const value = (mac.readUInt32BE(offset) & 0x7fffffff) % 1000000;
  return value.toString().padStart(6, "0");
}
