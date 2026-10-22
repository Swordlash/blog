// Drive the built demo in headless Chromium, as a static host serves it, the
// way haskell-halogen's toolchain/test-gallery.mjs drives its gallery.
//
//   npm run smoke-test                      # after: npm run build-wasm
//   node toolchain/smoke-test.mjs [dir]     # default dist-newstyle/wasm/public/app
//   SMOKE_DEBUG=<dir> npm run smoke-test    # also print what each prerendered page
//                                           # shows, and on failure screenshot the
//                                           # open pages into <dir>
//
// This is what the unit tests cannot see: the size-optimised app.wasm loading
// in a real browser on every page the build wrote, adopting the page
// prerendered into it; its links followed without loading a page; the back
// and forward buttons and a reload arriving where they should; the editor,
// search and the islands bundle (web/bundle.sh) working in the built page;
// 404.html standing in for every address with no file; and the page in a
// dark scheme and at a phone's width. Any error in a page, or on its console,
// fails it.
//
// It has three parts:
//
// 1. Every prerendered page (each index.html under the directory) is loaded
//    by its address, app.wasm held back until the prerendered page has been
//    seen and every node of it marked; then the program has to adopt it
//    (Halogen's hydrateUI) as the same route, with nothing to repair: every
//    node it arrived with kept, no text changed, nothing built that it did
//    not have, outside the islands, which their libraries fill.
// 2. One long walk in one page, as someone would take it: the front page,
//    every root space and a page in each, a page's source and back, the
//    editor as admin with a save, search, then back through the whole
//    history and forward again, each step checked by its address and what
//    is on screen. Then leaving the editor with changes by the back button
//    (Stay, then Leave), a reload on a page that keeps the edit (the demo
//    keeps its content in IndexedDB), the user menu's reset taking it away
//    for good, a reload on a page's source, and 404.html for an address
//    with no file.
// 3. The same page in a dark scheme and at a phone's width, and a page's
//    source copied to the clipboard.
//
// Needs the Chromium that Playwright's version in package-lock.json launches
// (toolchain/bootstrap.sh installs it), and no network: index.js loads
// @bjorn3/browser_wasi_shim from jsDelivr, which the test serves from
// node_modules (the same version), and the demo's NASA image and video on
// Wikimedia Commons are answered locally with stand-ins.
import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, extname, join, normalize, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const started = Date.now();
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
// and an address with no file serves 404.html, with a 404.
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
const here = (page) => {
  const address = new URL(page.url());
  return address.pathname + address.search;
};

const timeout = 30_000;
const browser = await chromium.launch();
const failures = [];

// A 32×32 PNG, standing in for the demo's photograph from Wikimedia Commons.
const standInImage = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAASklEQVR42mP48OUXTRHDCLDAJHUJHjRqwagFI8MCZFTR1ANENMzJoxbQyQKIKeShwWQBqeX+sLeAvPKAGF2jFoxaMHQsGG384kYAzNSeSHKJ2CAAAAAASUVORK5CYII=",
  "base64",
);

// A page that reports what goes wrong in it, with what it would fetch from
// elsewhere answered locally. Its app.wasm waits for `release` when a gate
// is set, so that the prerendered page can be seen before the program
// replaces it.
async function newPage(options = {}) {
  const context = await browser.newContext(options);
  const page = await context.newPage();
  // Every address the page and its workers ask for, until it is emptied.
  page.requested = [];
  context.on("request", (request) => page.requested.push(request.url()));
  page.on("pageerror", (error) => failures.push(`page error at ${page.url()}: ${error.message}`));
  page.on("console", (message) => {
    // An address with no file of its own is served 404.html with a 404,
    // which Chromium reports; that is how it is meant to work.
    if (message.type() === "error" && !message.text().includes("404")) {
      failures.push(`console error at ${page.url()}: ${message.text()}`);
    }
  });
  await page.route("https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@*/dist/**", async (route) => {
    const file = new URL(route.request().url()).pathname.replace(/^.*\/dist\//, "");
    await route.fulfill({
      contentType: "text/javascript",
      body: await readFile(join(shimDir, normalize(file))),
    });
  });
  // The video gets no answer it can play, which a page shows as a player
  // with nothing in it, as it would offline; that is not an error.
  await page.route("https://upload.wikimedia.org/**", (route) =>
    /\.webm$/.test(route.request().url())
      ? route.fulfill({ status: 204 })
      : route.fulfill({ contentType: "image/png", body: standInImage }),
  );
  page.gate = null;
  await page.route("**/app.wasm", async (route) => {
    await page.gate;
    await route.continue();
  });
  return page;
}

// What a page shows of its route: the document's title, the heading of the
// content, the view it is in, and the error shown in its place, if any.
const shown = (page) =>
  page.evaluate(() => {
    const content = document.querySelector("#app .wiki-content");
    const view = content?.querySelector(":scope > *:not(.leave-confirm)");
    return {
      title: document.title,
      heading: content?.querySelector("h1")?.textContent.trim() ?? null,
      view: view ? view.className.split(" ")[0] : null,
      error: content?.querySelector(".error")?.className ?? null,
    };
  });

// Whether the program has started on the page: the brand's link in the
// header, which the page arrives with, has the click listener the program
// attaches when it adopts it. Only the DevTools protocol can see listeners.
async function programStarted(page) {
  page.devtools ??= await page.context().newCDPSession(page);
  const { result } = await page.devtools.send("Runtime.evaluate", { expression: 'document.querySelector("#app .wiki-brand")' });
  if (result.objectId === undefined) return false;
  const { listeners } = await page.devtools.send("DOMDebugger.getEventListeners", { objectId: result.objectId });
  await page.devtools.send("Runtime.releaseObject", { objectId: result.objectId });
  return listeners.some((listener) => listener.type === "click");
}

// Mark what the server sent, before the program runs: the shell's element
// (data-prerendered, which the program leaves alone, as it does every
// attribute it does not render), and every node under #app, with its text
// or attributes, so that what the program does to the page when it adopts
// it can be told afterwards. A MutationObserver notes when the page last
// changed outside the islands, whose content their libraries write.
const islands = ".wiki-math, .wiki-mermaid, .wiki-tikz, .wiki-code";
const markPrerendered = (page) =>
  page.evaluate((islands) => {
    const app = document.querySelector("#app");
    app.querySelector(".wiki").dataset.prerendered = "true";
    const marks = new Map();
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      const text = node.nodeType === Node.TEXT_NODE;
      marks.set(node, {
        text: text ? node.data : null,
        attributes: text ? null : Object.fromEntries([...node.attributes].map((a) => [a.name, a.value])),
        parent: node.parentElement,
        island: node.parentElement?.closest(islands) != null,
      });
    }
    window.smokePrerendered = marks;
    window.smokeLastChange = Date.now();
    const inIsland = (node) => (node instanceof Element ? node : node.parentElement)?.closest(islands);
    new MutationObserver((records) => {
      if (records.some((record) => !inIsland(record.target))) window.smokeLastChange = Date.now();
    }).observe(app, { subtree: true, childList: true, characterData: true, attributes: true });
  }, islands);

// What adopting the page changed in it, once the program has started and
// the page has been still for a moment: the nodes of the page that went
// (other than comments, which only separate texts for the parser, and blank
// text around the shell), the nodes built that the page did not have (other
// than empty texts, which no HTML has), the texts set to something else, and
// the attributes. Each is HTML a page rendered on a server would get wrong
// as well. What is inside an island is not counted: its library fills it,
// adopted or not.
//
// One difference is the demo's own and set apart ('objectUrls'): an
// attachment uploaded as bytes is served from an object URL, which exists
// in the browser only. The prerender has a data: URL there instead, which a
// page's Markdown may not embed, so its image is prerendered as its
// description; the program then builds the image and gives the attachment's
// link its object URL.
async function repairsOf(page) {
  await eventually(
    async () => assert.ok(await page.evaluate(() => Date.now() - window.smokeLastChange > 300), "still changing"),
    "the page settling after the program started",
  );
  return page.evaluate((islands) => {
    const app = document.querySelector("#app");
    const describe = (node, parent = node.parentElement) => {
      if (node.nodeType === Node.TEXT_NODE) return `text ${JSON.stringify(node.data.slice(0, 60))} in <${parent?.localName ?? "?"}>`;
      const cls = node.getAttribute("class");
      return `<${node.localName}${cls ? ` class="${cls}"` : ""}>`;
    };
    const objectImage = (node) => node instanceof HTMLImageElement && node.getAttribute("src")?.startsWith("blob:");
    const removed = [];
    const changed = [];
    const attributes = [];
    const objectUrls = [];
    let islandSources = 0;
    for (const [node, mark] of window.smokePrerendered) {
      if (mark.island) {
        if (!app.contains(node)) islandSources += 1;
        continue;
      }
      if (!app.contains(node)) {
        if (mark.text !== null && node.parentNode === null && mark.text.trim() === "") continue;
        const description = describe(node, mark.parent);
        const imaged = mark.text !== null && [...(mark.parent?.children ?? [])].some((e) => objectImage(e) && e.alt === mark.text);
        (imaged ? objectUrls : removed).push(description);
      } else if (mark.text !== null) {
        if (node.data !== mark.text) changed.push(`${describe(node)} was ${JSON.stringify(mark.text.slice(0, 60))}`);
      } else {
        const now = Object.fromEntries([...node.attributes].map((a) => [a.name, a.value]));
        for (const name of new Set([...Object.keys(mark.attributes), ...Object.keys(now)])) {
          if (name === "data-prerendered" || mark.attributes[name] === now[name]) continue;
          const change = `${describe(node)} ${name}: ${JSON.stringify(mark.attributes[name]?.slice(0, 40))} -> ${JSON.stringify(now[name]?.slice(0, 40))}`;
          (mark.attributes[name]?.startsWith("data:") && now[name]?.startsWith("blob:") ? objectUrls : attributes).push(change);
        }
      }
    }
    const built = [];
    const walker = document.createTreeWalker(app, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      if (node.parentElement?.closest(islands) || window.smokePrerendered.has(node)) continue;
      if (node.nodeType === Node.TEXT_NODE && node.data === "") continue;
      (objectImage(node) ? objectUrls : built).push(describe(node));
    }
    return { removed, built, changed, attributes, objectUrls, islandSources };
  }, islands);
}

// Go to an address and wait for the program to have adopted the page
// prerendered there. What the page showed before the program ran is
// returned, with what adopting it had to repair ('repairsOf').
async function load(page, path) {
  let release;
  page.gate = new Promise((go) => (release = go));
  await page.goto(url(path), { waitUntil: "commit" });
  return adopted(page, path, release);
}

// Reload the page, and wait as 'load' does for the program to have adopted
// what the server sent.
async function reload(page) {
  let release;
  page.gate = new Promise((go) => (release = go));
  await page.reload({ waitUntil: "commit" });
  return adopted(page, here(page), release);
}

async function adopted(page, path, release) {
  await page.locator("#app .wiki").waitFor({ timeout });
  const before = await shown(page);
  await markPrerendered(page);
  release();
  page.gate = null;
  await eventually(async () => assert.ok(await programStarted(page), "no listener yet"), `${path}: the program starting`);
  assert.equal(await page.locator("#app .wiki").count(), 1, `${path}: more than one shell`);
  await stillPrerendered(page, path);
  return { before, repairs: await repairsOf(page) };
}

// The shell the page arrived with is the one on the page.
const stillPrerendered = async (page, where) =>
  assert.equal(await page.locator("#app > .wiki[data-prerendered]").count(), 1, `${where}: the prerendered shell was replaced`);

const noRepairs = (repairs) => [repairs.removed, repairs.built, repairs.changed, repairs.attributes].every((found) => found.length === 0);

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

// The footer every page ends with, prerendered or not, as the server sends
// it and as the page shows it.
const footerLink = "https://github.com/Swordlash/haskell-halogen";
const footerHtml = `<footer class="wiki-footer">Built with <a href="${footerLink}">haskell-halogen</a></footer>`;
async function footerShown(page, where) {
  const footer = page.locator("#app .wiki > footer.wiki-footer");
  assert.equal(await footer.count(), 1, `${where}: no footer`);
  assert.equal((await footer.textContent()).trim(), "Built with haskell-halogen", `${where}: the footer's text`);
  assert.equal(await footer.locator("a").getAttribute("href"), footerLink, `${where}: the footer's link`);
}

// The breadcrumb of the route shown, which names it: a space's or a page's
// name, "Edit", "Search"; the front page has none.
const crumb = (page) => page.locator("#app .breadcrumbs [aria-current=page]").textContent();

// Every index.html under the directory, as the address that serves it.
async function prerenderedPaths(dir) {
  const paths = [];
  for (const entry of await readdir(dir, { withFileTypes: true, recursive: true })) {
    if (entry.isFile() && entry.name === "index.html") {
      const rel = relative(root, entry.parentPath ?? entry.path).split(sep).join("/");
      paths.push(rel === "" ? "/" : `/${rel}/`);
    }
  }
  return paths.sort();
}

try {
  // ---- 1. Every prerendered page ---------------------------------------------

  const paths = await prerenderedPaths(root);
  let guideAndDiagrams = 0;
  assert.ok(paths.length >= 10, `only ${paths.length} pages were prerendered`);
  for (const path of ["/", "/search/", "/s/docs/", "/s/docs/p/tour/", "/s/docs/p/tour/source/", "/s/team/p/team-handbook/"]) {
    assert.ok(paths.includes(path), `${path} was not prerendered`);
  }
  const visitor = await newPage();
  const repaired = [];
  const objectUrls = [];
  let islandSources = 0;
  for (const path of paths) {
    // As a server sends it, before any script runs.
    const html = await (await fetch(url(path))).text();
    if (html.includes('<div class="wiki-tikz">')) guideAndDiagrams += 1;
    assert.match(html, /<base href="\/">/, `${path}: no <base href>`);
    assert.match(html, /<div id="app"><div class="wiki">/, `${path}: not prerendered`);
    assert.ok(html.includes(footerHtml), `${path}: no footer prerendered`);
    visitor.requested.length = 0;
    const { before, repairs } = await load(visitor, path);
    // TikZJax is fetched by a page with a picture, and by no other.
    if (!html.includes('<div class="wiki-tikz">')) {
      const tikz = visitor.requested.filter((address) => /\/(islands\/tikz\.js|tikzjax\/)/.test(address));
      assert.deepEqual(tikz, [], `${path}: a page without a TikZ picture fetched TikZJax`);
    }
    if (path !== "/") assert.notEqual(before.title, "Wiki", `${path}: no title of its own`);
    // The program shows the same route, on the same nodes.
    assert.deepEqual(await shown(visitor), before, `${path}: the program shows another page`);
    if (!noRepairs(repairs)) repaired.push(`${path}: ${JSON.stringify(repairs, null, 2)}`);
    if (repairs.objectUrls.length > 0) objectUrls.push(`${path}: ${repairs.objectUrls.join("; ")}`);
    islandSources += repairs.islandSources;
    await footerShown(visitor, path);
    if (process.env.SMOKE_DEBUG) console.log(path, JSON.stringify(before));
  }
  // Every page's repairs at once, since one cause usually shows on several.
  assert.deepEqual(repaired, [], "adopting these pages repaired them");
  // An island is rendered empty, and the prerender writes its source in, so
  // that a page reads before its libraries have loaded; the program takes
  // the source out as it adopts the island, and the library fills it.
  console.log(`note: ${islandSources} islands' prerendered sources were taken out for their libraries to fill`);
  if (objectUrls.length > 0) console.log(`note: attachments the browser serves from object URLs:\n  ${objectUrls.join("\n  ")}`);
  console.log(`ok: each of the ${paths.length} prerendered pages is adopted by the program, every node kept, footer included`);

  // A page's islands are prerendered as their sources, and drawn once the
  // program has loaded: KaTeX (with its fonts), Mermaid, highlight.js.
  const maths = await (await fetch(url("/s/docs/p/markdown-guide/mathematics/"))).text();
  assert.match(maths, /<span class="wiki-math wiki-math-inline">/, "the page has no formula's source");
  await load(visitor, "/s/docs/p/markdown-guide/");
  await visitor.locator("#app .wiki-math-inline .katex").first().waitFor({ timeout });
  await visitor.locator("#app .wiki-math-display .katex-display").first().waitFor({ timeout });
  // Mermaid's own bundle is fetched for the first diagram, so allow it time.
  await visitor.locator("#app .wiki-mermaid > svg").first().waitFor({ timeout });
  await visitor.locator("#app .wiki-code code.hljs.language-haskell .hljs-type").first().waitFor({ timeout });
  assert.ok(await visitor.evaluate(() => document.fonts.check('16px "KaTeX_Main"')), "KaTeX's fonts did not load");
  // The guide's TikZ picture, with its labels in TeX's fonts.
  const tikzLabel = visitor.locator("#app .wiki-tikz > svg text").first();
  await tikzLabel.waitFor({ timeout });
  assert.notEqual((await tikzLabel.textContent()).length, 0, "the TikZ picture's label is empty");
  await eventually(
    async () => assert.ok(await visitor.evaluate(() => document.fonts.check("10px cmr10")), "not yet"),
    "TeX's fonts loading",
  );
  console.log("ok: a page's islands are drawn: KaTeX, Mermaid, TikZ, highlight.js");
  console.log(`ok: no page without a TikZ picture fetched TikZJax (${guideAndDiagrams} pages have one)`);
  await visitor.context().close();

  // The first TikZ picture, in a browser that has fetched nothing yet: how
  // long it takes, and what it fetches (TikZJax's worker, TeX, the format,
  // the TeX files and fonts the picture uses).
  const cold = await newPage();
  const tikzBytes = new Map();
  cold.context().on("requestfinished", async (request) => {
    if (!/\/(islands\/tikz\.js|tikzjax\/)/.test(request.url())) return;
    const sizes = await request.sizes().catch(() => null);
    if (sizes) tikzBytes.set(request.url(), sizes.responseBodySize);
  });
  const asked = Date.now();
  await cold.goto(url("/s/docs/p/markdown-guide/"), { waitUntil: "commit" });
  await cold.locator("#app .wiki-tikz > svg").first().waitFor({ timeout });
  const drawn = Date.now() - asked;
  const fetchedTikz = await eventually(async () => {
    assert.ok([...tikzBytes.keys()].some((address) => address.endsWith("core.dump.gz")), "not yet");
    return [...tikzBytes.values()].reduce((a, b) => a + b, 0);
  }, "TikZJax's files being counted");
  console.log(
    `note: the first TikZ picture was drawn ${drawn} ms after the page was asked for, with nothing cached;` +
      ` TikZJax's files fetched for it: ${tikzBytes.size}, ${Math.round(fetchedTikz / 1024)} KiB`,
  );
  await cold.context().close();

  // ---- 2. A walk through the demo, in one page -------------------------------

  const page = await newPage();
  await load(page, "/");
  // No click from here on may load a page: a mark on the window would go,
  // and so would the shell the page arrived with.
  await page.evaluate(() => (window.stillTheSamePage = true));
  const samePage = async (step) => {
    assert.ok(await page.evaluate(() => window.stillTheSamePage), `${step} loaded a page`);
    await stillPrerendered(page, step);
  };

  // Every entry of the history the walk makes, and what it shows.
  const visits = [];
  const check = async (visit, step) => {
    await eventually(async () => {
      assert.equal(here(page), visit.path, "the address");
      const now = await shown(page);
      assert.equal(now.view, visit.view, "the view");
      if (visit.crumb !== undefined) assert.equal(await crumb(page), visit.crumb, "the breadcrumb");
      if (visit.text !== undefined) {
        assert.ok((await page.locator("#app .wiki-content").textContent()).includes(visit.text), `no "${visit.text}"`);
      }
    }, `${step} at ${visit.path}`);
  };
  const arrive = async (visit, step) => {
    await check(visit, step);
    await samePage(step);
    visits.push({ ...visit, step });
  };
  await arrive({ path: "/", view: "home" }, "the front page");

  // The tour, from the front page's invitation.
  await page.locator("#app .home a", { hasText: "Take the tour" }).click();
  await arrive({ path: "/s/docs/p/tour/", view: "page-view", crumb: "Tour" }, "the tour");

  // Who one is, from the menu at the top right. The demo starts as admin;
  // nobody sees no private space, and admin every one.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login='']").click();
  await page.locator("#app .user-switcher-toggle", { hasText: "Not signed in" }).waitFor({ timeout });
  assert.equal(await page.locator("#app .wiki-sidebar a[href='/s/team/']").count(), 0, "nobody sees Team");
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login=admin]").click();
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  await page.locator("#app .wiki-sidebar a[href='/s/team/']").waitFor({ timeout });
  // The spaces are clicked at once, while the shell may still be busy with
  // the switch. A link's handler then runs only once the shell is done, after
  // the browser would have followed the link; the browser is kept from it in
  // the click's listener instead, so no click here may load a page.

  // Every root space, and a page in each, from the tree of spaces.
  const roots = await page.locator("#app .wiki-sidebar > .space-tree > li > .space-row a").evaluateAll((links) =>
    links.map((a) => ({ href: a.getAttribute("href"), name: a.textContent })),
  );
  assert.deepEqual(roots.map((r) => r.name), ["Blog", "Docs", "Team"]);
  for (const space of roots) {
    await page.locator(`#app .wiki-sidebar a[href='${space.href}']`).click();
    await arrive({ path: space.href, view: "space-view", crumb: space.name }, `the space ${space.name}`);
    const first = page.locator("#app .space-view .page-tree a").first();
    const target = { href: await first.getAttribute("href"), title: await first.textContent() };
    await first.click();
    await arrive({ path: target.href, view: "page-view", crumb: target.title }, `the page ${target.title}`);
  }
  await samePage("going through the spaces");
  console.log("ok: every root space, and a page in each, by clicking");

  // The editor, as admin, with a save: Hello, world.
  await page.locator("#app .wiki-sidebar a[href='/s/blog/']").click();
  await arrive({ path: "/s/blog/", view: "space-view", crumb: "Blog" }, "Blog again");
  await page.locator("#app .space-view .page-tree a[href='/s/blog/p/hello-world/']").click();
  await arrive({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world" }, "Hello, world");

  // Its source, and back to it by the link.
  await page.locator("#app .page-view .actions a", { hasText: "View source" }).click();
  await arrive(
    { path: "/s/blog/p/hello-world/source/", view: "source-view", crumb: "Source", text: "# Hello, world" },
    "Hello, world's source",
  );
  await page.locator("#app .source-view a.source-back").click();
  await arrive({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world" }, "back from the source");
  console.log("ok: a page's source opens from the page, and its link leads back");

  await page.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await arrive({ path: "/s/blog/p/hello-world/edit/", view: "editor", crumb: "Edit" }, "the editor");
  const textarea = page.locator("#app .editor-text");
  await textarea.press("Control+End");
  await textarea.pressSequentially("\n\n## Smoke test\n\nWritten by ");
  // A toolbar shortcut, whose placeholder is selected for the typing.
  await textarea.press("Control+b");
  await textarea.pressSequentially("Ada");
  await textarea.press("End");
  await textarea.pressSequentially(" with $x^2$.");
  // The Markdown is shown alone until the preview is asked for, which
  // replaces it; Save is still there.
  assert.ok(!(await page.locator("#app .editor-preview").isVisible()), "the preview shows before it is asked for");
  await page.locator("#app .editor-show-preview").click();
  await page.locator("#app .editor-preview h2", { hasText: "Smoke test" }).waitFor({ timeout });
  await page.locator("#app .editor-preview strong", { hasText: "Ada" }).waitFor({ timeout });
  await page.locator("#app .editor-preview .wiki-math-inline .katex").last().waitFor({ timeout });
  assert.ok(!(await textarea.isVisible()), "the Markdown beside the preview shown on its own");
  await page.locator("#app .editor-form button.primary").click();
  await arrive({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text: "Smoke test" }, "the page saved");
  await samePage("editing");
  console.log("ok: the editor formats from a shortcut, previews what is typed, with its formulas, and saves it");

  // Search from the keyboard: "/" to the box, words, an arrow and Enter.
  // "/" is a character to type in a field, so nothing is focused first.
  await page.evaluate(() => document.activeElement?.blur());
  await page.keyboard.press("/");
  await page.keyboard.type("handbook");
  await page.locator("#app .search-results .search-hit", { hasText: "Team handbook" }).first().waitFor({ timeout });
  assert.equal(await page.locator("#app .search-input").inputValue(), "handbook");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await arrive({ path: "/s/team/p/team-handbook/", view: "page-view", crumb: "Team handbook" }, "a search's hit");
  // Enter with no hit chosen: the page of every result, at an address of
  // its own.
  await page.keyboard.press("/");
  await page.keyboard.type("mermaid");
  await page.locator("#app .search-results .search-hit").first().waitFor({ timeout });
  await page.keyboard.press("Enter");
  await arrive({ path: "/search/?q=mermaid", view: "search-view", crumb: "Search", text: "Diagrams" }, "the results");
  await samePage("searching");
  console.log("ok: / focuses the search box; a hit opens with the keyboard, Enter alone the page of results");

  // Back through the whole history, then forward through it again.
  for (let i = visits.length - 2; i >= 0; i--) {
    await page.goBack();
    await check(visits[i], `back to ${visits[i].step}`);
  }
  for (let i = 1; i < visits.length; i++) {
    await page.goForward();
    await check(visits[i], `forward to ${visits[i].step}`);
  }
  await samePage("going back and forward");
  console.log(`ok: back through all ${visits.length} entries of the history and forward again, each showing its route`);

  // Leaving the editor with changes by the back button asks first. Staying
  // goes back to the editor's entry, so the history is as long as before,
  // and the next back asks again; leaving then shows the page as it was.
  await page.locator("#app .search-view a.search-hit[href='/s/docs/p/markdown-guide/diagrams/']").click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/", view: "page-view", crumb: "Diagrams" }, "Diagrams");
  await page.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/edit/", view: "editor", crumb: "Edit" }, "editing Diagrams");
  await page.locator("#app .editor-text").press("Control+End");
  await page.locator("#app .editor-text").pressSequentially("\nNot to be kept.");
  const entries = await page.evaluate(() => history.length);
  await page.goBack();
  await page.locator("#app .leave-confirm").waitFor({ timeout });
  await page.locator("#app .leave-confirm button", { hasText: "Stay" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/edit/", view: "editor" }, "staying in the editor");
  assert.ok((await page.locator("#app .editor-text").inputValue()).endsWith("Not to be kept."), "staying lost the draft");
  assert.equal(await page.evaluate(() => history.length), entries, "staying added an entry to the history");
  await page.goBack();
  await page.locator("#app .leave-confirm button", { hasText: "Leave" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/", view: "page-view", crumb: "Diagrams" }, "leaving the editor");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Not to be kept."), "leaving kept the draft");
  await samePage("leaving the editor");
  console.log("ok: leaving the editor by the back button asks; Stay returns to its entry, Leave drops the draft");

  // A reload arrives at the same page, with the edit kept in the browser
  // (IndexedDB), as admin again: who one was is not kept, and the demo
  // starts as admin.
  await page.locator("#app .wiki-sidebar a[href='/s/blog/']").click();
  await page.locator("#app .space-view .page-tree a[href='/s/blog/p/hello-world/']").click();
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", text: "Smoke test" }, "the edited page");
  // The prerendered page shows the demo's own content, so adopting it
  // repairs the edited page into what the browser keeps.
  const edited = await reload(page);
  assert.ok(!noRepairs(edited.repairs), "a page edited in the browser was adopted with nothing to repair");
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text: "Smoke test" }, "the reload");
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  // Exporting the wiki downloads a zip file of it, edit and all.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu .demo-kept", { hasText: "kept in this browser" }).waitFor({ timeout });
  const [exported] = await Promise.all([page.waitForEvent("download", { timeout }), page.locator("#app .user-menu .demo-export").click()]);
  assert.match(exported.suggestedFilename(), /^wiki-\d{4}-\d{2}-\d{2}\.zip$/, "the export's name");
  const exportPath = await exported.path();
  assert.equal((await readFile(exportPath)).subarray(0, 2).toString(), "PK", "the export is not a zip file");
  // Resetting the demo's content, from the user menu and after asking,
  // takes the edit away, and a reload does not bring it back.
  await page.locator("#app .user-menu .demo-reset-ask").click();
  await page.locator("#app .demo-reset-confirm button", { hasText: "Reset" }).click();
  await eventually(async () => {
    assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Smoke test"), "the edit is still there");
  }, "resetting the demo's content");
  // The demo's own content again, which the prerendered page shows as it is.
  const reset = await reload(page);
  assert.ok(noRepairs(reset.repairs), `the page after a reset needed repairs: ${JSON.stringify(reset.repairs)}`);
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world" }, "the reload after the reset");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Smoke test"), "the edit came back after a reset");
  // Importing the export brings it back, after asking.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu .demo-import input").setInputFiles({
    name: exported.suggestedFilename(),
    mimeType: "application/zip",
    buffer: await readFile(exportPath),
  });
  await page.locator("#app .demo-import-confirm button", { hasText: "Replace" }).click();
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text: "Smoke test" }, "the import");
  await page.locator("#app .user-menu .demo-told", { hasText: "Imported" }).waitFor({ timeout });
  console.log("ok: exporting downloads a zip file of the wiki, and importing it after a reset brings the edit back");
  // And on a page's source, which a reader not signed in may read too.
  await page.locator("#app .page-view .actions a", { hasText: "View source" }).click();
  await check({ path: "/s/blog/p/hello-world/source/", view: "source-view", crumb: "Source" }, "the source");
  await reload(page);
  await check({ path: "/s/blog/p/hello-world/source/", view: "source-view", crumb: "Source", text: "# Hello, world" }, "the source reloaded");
  console.log("ok: a reload arrives at the same page with the edit kept, a reset takes it away for good, and a reload works on a page's source");

  // An address with no file: 404.html, which the program reads as its own.
  const missing = await fetch(url("/no/such/address/"));
  assert.equal(missing.status, 404);
  assert.ok((await missing.text()).includes(footerHtml), "404.html has no footer");
  const notFound = await load(page, "/no/such/address/");
  assert.ok(noRepairs(notFound.repairs), `404.html: adopting the page repaired it: ${JSON.stringify(notFound.repairs, null, 2)}`);
  await check({ path: "/no/such/address/", view: "not-found" }, "an address the wiki does not have");
  await footerShown(page, "404.html");
  // An editor's address has no page of its own either; the program opens it.
  assert.equal((await fetch(url("/s/blog/p/hello-world/edit/"))).status, 404);
  // 404.html is the page of no route, so the program repairs it into the
  // editor's: the shell is kept, what differs is built afresh.
  await load(page, "/s/blog/p/hello-world/edit/");
  await stillPrerendered(page, "an editor's address");
  await check({ path: "/s/blog/p/hello-world/edit/", view: "editor", crumb: "Edit" }, "an editor's address");
  // The demo starts as admin, who may edit it.
  await page.locator("#app .editor .editor-text").waitFor({ timeout });
  console.log("ok: 404.html stands in for an address with no file, and the program shows its route");
  await page.context().close();

  // ---- 3. A dark scheme, and a phone -----------------------------------------

  const luminance = (rgb) => {
    const [r, g, b] = rgb.match(/\d+/g).map(Number);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  };
  const colours = (p) =>
    p.evaluate(() => {
      const style = (selector) => getComputedStyle(document.querySelector(selector));
      return {
        background: style("body").backgroundColor,
        text: style("#app .page-body p").color,
        sidebar: style("#app .wiki-sidebar").backgroundColor,
      };
    });
  const dark = await newPage({ colorScheme: "dark" });
  await load(dark, "/s/docs/p/markdown-guide/");
  await dark.locator("#app .page-body p").first().waitFor({ timeout });
  const night = await colours(dark);
  assert.ok(luminance(night.background) < 0.25, `a dark scheme's background is ${night.background}`);
  assert.ok(luminance(night.text) > 0.6, `a dark scheme's text is ${night.text}`);
  assert.ok(luminance(night.sidebar) < 0.25, `a dark scheme's sidebar is ${night.sidebar}`);
  // TeX's black is drawn in the text's colour, so a picture shows on a dark page.
  await dark.locator("#app .wiki-tikz > svg").first().waitFor({ timeout });
  const ink = () =>
    dark.evaluate(() => getComputedStyle(document.querySelector('#app .wiki-tikz > svg [stroke="currentColor"]')).stroke);
  assert.ok(luminance(await ink()) > 0.6, `a dark scheme's TikZ lines are ${await ink()}`);
  await dark.emulateMedia({ colorScheme: "light" });
  const day = await colours(dark);
  assert.ok(luminance(day.background) > 0.75, `a light scheme's background is ${day.background}`);
  assert.ok(luminance(day.text) < 0.4, `a light scheme's text is ${day.text}`);
  assert.ok(luminance(await ink()) < 0.4, `a light scheme's TikZ lines are ${await ink()}`);
  await dark.context().close();
  console.log("ok: a page follows the dark scheme, and the light one, TikZ pictures too");

  const phone = await newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await load(phone, "/s/docs/p/markdown-guide/");
  const fits = () => phone.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  assert.ok(await fits(), "a page is wider than a phone");
  assert.ok(await phone.locator("#app .search-input").isVisible(), "no search box on a phone");
  assert.ok(await phone.locator("#app .user-switcher-toggle").isVisible(), "no user menu on a phone");
  // The editor shows the Markdown there, its toolbar wrapped to the width,
  // and the preview instead of it when asked.
  await phone.locator("#app .user-switcher-toggle").tap();
  await phone.locator("#app .user-menu button[data-login=admin]").tap();
  await phone.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  await phone.locator("#app .page-view .actions a", { hasText: "Edit" }).tap();
  await phone.locator("#app .editor-text").waitFor({ timeout });
  assert.ok(await phone.locator("#app .editor-toolbar").isVisible(), "no toolbar on a phone");
  assert.ok(!(await phone.locator("#app .editor-side-by-side").isVisible()), "a side by side preview offered on a phone");
  assert.ok(await fits(), "the editor is wider than a phone");
  await phone.locator("#app .editor-show-preview").tap();
  await phone.locator("#app .editor-preview .page-body h1").waitFor({ timeout });
  assert.ok(!(await phone.locator("#app .editor-text").isVisible()), "the Markdown beside the preview on a phone");
  assert.ok(await fits(), "the editor's preview is wider than a phone");
  await phone.locator("#app .editor-back").tap();
  await phone.locator("#app .editor-text").waitFor({ timeout });
  assert.ok(!(await phone.locator("#app .editor-preview").isVisible()), "the preview stays after Back to editing");
  // A page's source wraps its long lines rather than widening the page.
  await load(phone, "/s/docs/p/tour/source/");
  await phone.locator("#app .source-text").waitFor({ timeout });
  assert.ok(await fits(), "a page's source is wider than a phone");
  await phone.context().close();
  console.log("ok: a page, the editor and a page's source fit a phone's width");

  // Copy puts the Markdown on the clipboard, as written. Headless Chromium
  // lets a page at it only with the permissions granted.
  const copier = await newPage({ permissions: ["clipboard-read", "clipboard-write"] });
  await load(copier, "/s/docs/p/tour/source/");
  const source = await copier.locator("#app .source-text").textContent();
  assert.ok(source.startsWith("# Tour\n"), "the source is not the tour's Markdown");
  await copier.locator("#app .source-view button.source-copy").click();
  await copier.locator("#app .source-copied", { hasText: "Copied" }).waitFor({ timeout });
  assert.equal(await copier.evaluate(() => navigator.clipboard.readText()), source, "the clipboard has something else");
  await copier.context().close();
  console.log("ok: Copy puts a page's source on the clipboard");
} catch (error) {
  // What the page reported is usually why it did not get there.
  failures.push(String(error.stack ?? error));
  if (process.env.SMOKE_DEBUG) {
    for (const [i, context] of browser.contexts().entries()) {
      for (const [j, p] of context.pages().entries()) {
        await p.screenshot({ path: `${process.env.SMOKE_DEBUG}/failure-${i}-${j}.png` }).catch(() => {});
        console.error("open page", i, j, p.url());
      }
    }
  }
} finally {
  await browser.close();
  server.close();
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`Smoke test passed in ${Math.round((Date.now() - started) / 1000)} s.`);
