// Drive the built application in headless Chromium, as a static host serves
// it: every route of the demo is a page of its own with the application
// prerendered into it, app.wasm loads and mounts the application in its
// place, and from then on the application routes by itself.
//
//   npm run smoke-test                      # after: npm run build-wasm
//   node toolchain/smoke-test.mjs [dir]     # default dist-newstyle/wasm/public/app
//
// This is what the unit tests cannot see: the size-optimised app.wasm loading
// in a real browser from a deep link, its links followed without loading a
// page, the back button and a reload arriving where they should, and the
// islands bundle (web/bundle.sh) loading next to it and drawing into the
// page. Needs the Chromium that Playwright's version in package-lock.json
// launches (toolchain/bootstrap.sh installs it). index.js loads
// @bjorn3/browser_wasi_shim from jsDelivr; the test serves it from
// node_modules instead, the same version, so that it needs no network.
import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
// The directory of the shim's index.js, which index.js imports from the CDN.
const shimDir = dirname(fileURLToPath(import.meta.resolve("@bjorn3/browser_wasi_shim")));

// instantiateStreaming refuses a .wasm served without its media type, so the
// server has to get these right.
const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
};

// A static server, as Pages is: a directory's address serves its index.html,
// a directory's address without its slash is redirected to the one with it,
// and an address with no file serves 404.html.
const server = createServer(async (request, response) => {
  const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
  const file = join(root, normalize(path.endsWith("/") ? `${path}index.html` : path));
  try {
    if ((await stat(file)).isDirectory()) {
      response.writeHead(301, { location: `${path}/` }).end();
      return;
    }
    const body = await readFile(file);
    response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/html" });
    response.end(await readFile(join(root, "404.html")).catch(() => ""));
  }
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const origin = `http://127.0.0.1:${server.address().port}`;
const url = (path) => `${origin}${path}`;

const timeout = 30_000;
const browser = await chromium.launch();
const failures = [];

// A page that reports what goes wrong in it, with the shim served locally.
async function newPage() {
  const page = await browser.newPage();
  page.on("pageerror", (error) => failures.push(`page error: ${error.message}`));
  page.on("console", (message) => {
    // An address with no file of its own is served 404.html with a 404,
    // which Chromium reports; that is how it is meant to work.
    if (message.type() === "error" && !message.text().includes("404")) {
      failures.push(`console error: ${message.text()}`);
    }
  });
  await page.route("https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@*/dist/**", async (route) => {
    const file = new URL(route.request().url()).pathname.replace(/^.*\/dist\//, "");
    await route.fulfill({
      contentType: "text/javascript",
      body: await readFile(join(shimDir, normalize(file))),
    });
  });
  return page;
}

// The heading of what the content area shows, once the program shows it.
async function heading(page) {
  const h1 = page.locator("#app .wiki-content h1").first();
  await h1.waitFor({ timeout });
  return (await h1.textContent()).trim();
}

async function headingBecomes(page, text) {
  await page.locator("#app .wiki-content h1", { hasText: text }).first().waitFor({ timeout });
}

// A page at an address, once app.wasm has mounted the application in place of
// the prerendered one: app.wasm is held back until the prerendered shell is
// marked, so that a shell without the mark is the program's.
async function mounted(path) {
  const page = await newPage();
  let releaseWasm;
  const wasmHeld = new Promise((release) => (releaseWasm = release));
  await page.route("**/app.wasm", async (route) => {
    await wasmHeld;
    await route.continue();
  });
  await page.goto(url(path), { waitUntil: "commit" });
  const prerendered = page.locator("#app .wiki");
  await prerendered.waitFor({ timeout });
  await prerendered.evaluate((shell) => (shell.dataset.prerendered = "true"));
  releaseWasm();
  await page.locator("#app .wiki:not([data-prerendered])").waitFor({ timeout });
  return page;
}

try {
  // The pages as a server sends them, before any script runs: each route's
  // has the application in it already, for that route.
  const front = await (await fetch(url("/"))).text();
  assert.match(front, /<base href="\/">/, "index.html has no <base href>");
  assert.match(front, /<div id="app"><div class="wiki">/, "index.html is not prerendered");
  assert.match(front, />Take the tour<\/a>/, "index.html does not invite to the tour");
  const maths = await (await fetch(url("/s/docs/p/markdown-guide/mathematics/"))).text();
  assert.match(maths, /<title>Mathematics · Markdown guide · Wiki<\/title>/, "the page has no title of its own");
  assert.match(maths, /<h1 id="mathematics">Mathematics<\/h1>/, "the page is not prerendered");
  // Natively there is nothing to draw the islands with: they arrive as their
  // sources.
  assert.match(maths, /<span class="wiki-math wiki-math-inline">/, "the page has no formula's source");
  console.log("ok: every route's page arrives with the application prerendered for it");

  const page = await newPage();
  // app.wasm is held back until the prerendered shell is marked, so that the
  // shell found afterwards without the mark is the one the program rendered.
  let releaseWasm;
  const wasmHeld = new Promise((release) => (releaseWasm = release));
  await page.route("**/app.wasm", async (route) => {
    await wasmHeld;
    await route.continue();
  });
  await page.goto(url("/"), { waitUntil: "commit" });
  const prerendered = page.locator("#app .wiki");
  await prerendered.waitFor({ timeout });
  await prerendered.evaluate((shell) => (shell.dataset.prerendered = "true"));
  releaseWasm();
  await page.locator("#app .wiki:not([data-prerendered])").waitFor({ timeout });
  assert.equal(await page.locator("#app .wiki").count(), 1, "the prerendered shell was not replaced");
  assert.equal(await heading(page), "Welcome to the wiki");
  console.log("ok: app.wasm mounts the application in place of the prerendered one");

  // From here on no click may load a page: a mark on the window would go.
  await page.evaluate(() => (window.stillTheSamePage = true));
  await page.locator("#app a", { hasText: "Take the tour" }).click();
  await headingBecomes(page, "Tour");
  assert.equal(new URL(page.url()).pathname, "/s/docs/p/tour/");
  await page.locator("#app .page-body a", { hasText: "diagrams" }).first().click();
  await headingBecomes(page, "Diagrams");
  assert.equal(new URL(page.url()).pathname, "/s/docs/p/markdown-guide/diagrams/");
  await page.locator("#app .wiki-mermaid > svg").first().waitFor({ timeout });
  assert.ok(await page.evaluate(() => window.stillTheSamePage), "following a link loaded a page");
  console.log("ok: links in the shell and in a page's Markdown are followed without loading a page");

  await page.goBack();
  await headingBecomes(page, "Tour");
  assert.equal(new URL(page.url()).pathname, "/s/docs/p/tour/");
  assert.ok(await page.evaluate(() => window.stillTheSamePage), "going back loaded a page");
  console.log("ok: the back button goes back to the page before");

  await page.reload();
  await page.locator("#app .wiki").waitFor({ timeout });
  await page.waitForFunction(() => document.querySelector("#app .page-body") !== null && window.stillTheSamePage === undefined, null, { timeout });
  await headingBecomes(page, "Tour");
  console.log("ok: a reload arrives at the same page");

  // Deep links: a page and a private space, each opened straight away.
  const guide = await newPage();
  await guide.goto(url("/s/docs/p/markdown-guide/"));
  await headingBecomes(guide, "Markdown guide");
  // Mermaid's own bundle is fetched for the first diagram, so allow it time.
  await guide.locator("#app .wiki-math-inline .katex").first().waitFor({ timeout });
  await guide.locator("#app .wiki-math-display .katex-display").first().waitFor({ timeout });
  await guide.locator("#app .wiki-mermaid > svg").first().waitFor({ timeout });
  await guide.locator("#app .wiki-code code.hljs.language-haskell .hljs-type").first().waitFor({ timeout });
  // A font KaTeX's stylesheet names that did not load would leave the formula
  // in a fallback font; the request for it would also have failed above.
  assert.ok(
    await guide.evaluate(() => document.fonts.check('16px "KaTeX_Main"')),
    "KaTeX's fonts did not load",
  );
  console.log("ok: a deep link to a page draws its islands: KaTeX, Mermaid, highlight.js");

  const team = await newPage();
  await team.goto(url("/s/team"));
  await team.locator("#app .wiki-content .error-forbidden").waitFor({ timeout });
  assert.equal(new URL(team.url()).pathname, "/s/team/");
  console.log("ok: a deep link to a private space says, in place, that it is private");

  // Search from the keyboard: "/" to the box, words, an arrow and Enter.
  const searching = await mounted("/");
  await searching.evaluate(() => (window.stillTheSamePage = true));
  await searching.keyboard.press("/");
  await searching.keyboard.type("mermaid diagrams");
  await searching.locator("#app .search-results .search-hit", { hasText: "Diagrams" }).first().waitFor({ timeout });
  assert.equal(await searching.locator("#app .search-input").inputValue(), "mermaid diagrams");
  // Diagrams has a word of the query in its title, so it comes first.
  assert.equal(await searching.locator("#app .search-results .search-hit-title").first().textContent(), "Diagrams");
  await searching.keyboard.press("ArrowDown");
  await searching.keyboard.press("Enter");
  await headingBecomes(searching, "Diagrams");
  assert.equal(new URL(searching.url()).pathname, "/s/docs/p/markdown-guide/diagrams/");
  assert.ok(await searching.evaluate(() => window.stillTheSamePage), "opening a search's hit loaded a page");
  console.log("ok: / focuses the search box, and a hit chosen with the keyboard opens its page");

  // A search's address: the prerendered page of results, searched once loaded.
  const results = await mounted("/search/?q=mermaid&space=docs");
  await headingBecomes(results, "Search");
  await results.locator("#app .search-view a.search-hit[href='/s/docs/p/markdown-guide/diagrams/']").waitFor({ timeout });
  assert.match(await results.locator("#app .search-summary").textContent(), /for “mermaid” in Docs and its subspaces\./);
  console.log("ok: a search's address shows its results");

  // The editor, as someone who may edit: switched to in the header, since
  // the demo has no passwords.
  const editor = await newPage();
  await editor.goto(url("/s/docs/p/tour/"));
  await headingBecomes(editor, "Tour");
  await editor.locator("#app .user-switcher-toggle").click();
  await editor.locator("#app .user-menu button[data-login=admin]").click();
  await editor.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await headingBecomes(editor, "Editing Tour");
  await editor.waitForURL((address) => address.pathname === "/s/docs/p/tour/edit/", { timeout });
  const textarea = editor.locator("#app .editor-text");
  await textarea.press("Control+End");
  await textarea.pressSequentially("\n\n## Smoke test\n\nWritten by $x^2$.");
  await editor.locator("#app .editor-preview h2", { hasText: "Smoke test" }).waitFor({ timeout });
  await editor.locator("#app .editor-preview .wiki-math-inline .katex").last().waitFor({ timeout });
  await editor.locator("#app .editor-form button.primary").click();
  await editor.locator("#app .page-view .page-body h2", { hasText: "Smoke test" }).waitFor({ timeout });
  // The shell shows the page first and then tells the router.
  await editor.waitForURL((address) => address.pathname === "/s/docs/p/tour/", { timeout });
  console.log("ok: the editor previews what is typed, with its formulas, and saves it");

  const nowhere = await newPage();
  await nowhere.goto(url("/no/such/address/"));
  await headingBecomes(nowhere, "Not found");
  console.log("ok: an address the wiki does not have shows that it is not found");
} catch (error) {
  // What the page reported is usually why it did not get there.
  failures.push(String(error.stack ?? error));
} finally {
  await browser.close();
  server.close();
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("Smoke test passed.");
