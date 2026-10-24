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
// WIKI_BACKEND=server toolchain/build-wasm.sh would. It then starts
// wiki-server --trust-network (everyone on the public listener is the
// administrator) on a temporary data directory and free ports of 127.0.0.1,
// and drives the application end to end against it:
//
// 1. The server's page, at the front page and at a page's address (which the
//    server answers with 404.html), adopted by the program with nothing to
//    repair, before the server has answered anything; then what it loads.
// 2. A space and a page made through the forms; typing and saving (Ctrl+S,
//    "Saved"); a draft kept as the typing stops and restored after a reload;
//    a file attached and served; a conflict (the page saved through the API
//    meanwhile, then saved in the editor); search; the export downloaded
//    from the administration; and a fresh browser finding all of it there.
//
// Needs the native builds of wiki-server and wiki-app-prerender (npm run
// build-native; WIKI_SERVER and WIKI_PRERENDER name other binaries), the
// Chromium Playwright launches, and no network (the WASI shim index.js loads
// from jsDelivr is served from node_modules).
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, normalize, resolve } from "node:path";
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

// The server, on free ports, its log read for the addresses it took.
const server = spawn(
  binary("WIKI_SERVER", "wiki-server:exe:wiki-server"),
  ["serve", "--data", data, "--static", app, "--listen", "127.0.0.1:0", "--admin-listen", "127.0.0.1:0", "--trust-network"],
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
console.log(`note: wiki-server --trust-network at ${origin}, data in ${data}`);

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
async function newPage() {
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  page.on("pageerror", (error) => failures.push(`page error at ${page.url()}: ${error.message}`));
  page.on("console", (message) => {
    // Every address but the front page is served 404.html with a 404 until
    // the server renders each page itself (WP2.6); a conflict is a 409.
    if (message.type() === "error" && !/\b(404|409)\b/.test(message.text())) {
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
  await page.route("**/app.wasm", async (route) => {
    await page.wasmGate;
    await route.continue();
  });
  await page.route("**/api/v1/**", async (route) => {
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

// Load an address with app.wasm and the API held back: mark every node of
// the page as the server sent it, let the program adopt it, and say what
// adopting it changed before the server has answered anything. Then let the
// API answer.
async function loadAdopted(page, path) {
  let releaseWasm;
  let releaseApi;
  page.wasmGate = new Promise((go) => (releaseWasm = go));
  page.apiGate = new Promise((go) => (releaseApi = go));
  const response = await page.goto(url(path), { waitUntil: "commit" });
  await page.locator("#app .wiki").waitFor({ timeout });
  await page.evaluate(() => {
    const app = document.querySelector("#app");
    app.querySelector(".wiki").dataset.prerendered = "true";
    const marks = new Map();
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      marks.set(node, node.nodeType === Node.TEXT_NODE ? node.data : [...node.attributes].map((a) => `${a.name}=${a.value}`).join(" "));
    }
    window.smokePrerendered = marks;
  });
  releaseWasm();
  page.wasmGate = null;
  await eventually(async () => assert.ok(await programStarted(page), "no listener yet"), `${path}: the program starting`);
  // A moment for anything the adoption would change to be changed.
  await page.waitForTimeout(300);
  const repairs = await page.evaluate(() => {
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
      if (!window.smokePrerendered.has(node) && !(node.nodeType === Node.TEXT_NODE && node.data === "")) found.push(`built: ${node.nodeName}`);
    }
    return found;
  });
  releaseApi();
  page.apiGate = null;
  return { status: response.status(), repairs };
}

const editorText = "#app .editor-cm .cm-content";
const markdownIn = (page) => page.evaluate((selector) => document.querySelector(selector)?.wikiEditor?.text() ?? null, editorText);
const content = (page) => page.locator("#app .wiki-content").textContent();

try {
  // ---- 1. The server's page, adopted -----------------------------------------

  const front = await fetch(url("/"));
  assert.equal(front.status, 200);
  const frontHtml = await front.text();
  assert.match(frontHtml, /<p class="loading">Loading…<\/p>/, "the front page is not the application loading");
  assert.ok(!/<ol>.+<\/ol>/.test(frontHtml), "the server's page names a route");
  const page = await newPage();
  const atFront = await loadAdopted(page, "/");
  assert.deepEqual(atFront.repairs, [], "adopting the front page repaired it");
  await page.locator("#app .home h1", { hasText: "Welcome to the wiki" }).waitFor({ timeout });
  await page.locator("#app .user-name", { hasText: "Administrator" }).waitFor({ timeout });
  await page.locator("#app .home .empty", { hasText: "There are no spaces you can see." }).waitFor({ timeout });
  assert.equal(await page.locator("#app .user-switcher").count(), 0, "a server's wiki offers the demo's user switcher");
  console.log("ok: the server's front page is adopted with nothing to repair, then shows the empty wiki to its administrator");

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
  const served = await fetch(new URL(await attachment.getAttribute("href"), url("/")));
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
  assert.equal(reloaded.status, 404, "the editor's address has a page of its own");
  assert.deepEqual(reloaded.repairs, [], "adopting the server's page at the editor's address repaired it");
  await page.locator("#app .editor-draft-found", { hasText: "Restored your unsaved draft" }).waitFor({ timeout });
  await eventually(async () => assert.ok((await markdownIn(page)).endsWith("Not saved yet."), "not yet"), "the draft restored");
  console.log("ok: a draft is kept as the typing stops, and restored by the editor after a reload, which adopts the page with nothing to repair");

  // Someone else saves the page meanwhile, through the API; the editor's
  // save is then a conflict, said in place, with the work kept.
  const space = await (await fetch(url("/api/v1/spaces/at/smoke-space"))).json();
  const atPath = await fetch(url(`/api/v1/spaces/${encodeURIComponent(space.id)}/pages/at/first-page`));
  const current = await atPath.json();
  const saved = await fetch(url(`/api/v1/pages/${encodeURIComponent(current.id)}`), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "If-Match": atPath.headers.get("etag") },
    body: JSON.stringify({ title: "First page", body: `${current.body}\n\nSaved by someone else.` }),
  });
  assert.equal(saved.status, 200, "the API's save");
  const stale = await fetch(url(`/api/v1/pages/${encodeURIComponent(current.id)}`), {
    method: "PUT",
    headers: { "Content-Type": "application/json", "If-Match": atPath.headers.get("etag") },
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

  // The export, from the administration.
  await page.locator("#app .wiki-header a.admin-link").click();
  await page.locator("#app .admin-view .admin-note", { hasText: "Importing" }).waitFor({ timeout });
  const [exported] = await Promise.all([page.waitForEvent("download", { timeout }), page.locator("#app .admin-view .demo-export").click()]);
  assert.match(exported.suggestedFilename(), /^wiki-\d{4}-\d{2}-\d{2}\.zip$/, "the export's name");
  assert.equal((await readFile(await exported.path())).subarray(0, 2).toString(), "PK", "the export is not a zip file");
  console.log(`ok: the administration downloads the server's export, ${exported.suggestedFilename()}`);
  await page.context().close();

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
  await fresh.context().close();
  console.log("ok: a fresh browser finds the space, the page, its edits and its attachment on the server");
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
