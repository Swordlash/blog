// Drive the built demo in headless Chromium, as a static host serves it, the
// way haskell-halogen's toolchain/test-gallery.mjs drives its gallery. This is
// the smoke test's first mode; the second, the server's build against a real
// wiki-server, is toolchain/smoke-test-server.mjs, and npm run smoke-test
// (toolchain/smoke-test.sh) runs both.
//
//   npm run smoke-test                      # after: npm run build-wasm
//   node toolchain/smoke-test.mjs [dir]     # default dist-newstyle/wasm/public/app
//   HALOGEN_BASE_PATH=/blog/ npm run smoke-test
//                                           # a build made for that base path
//                                           # (HALOGEN_BASE_PATH=/blog/ npm run
//                                           # build-wasm), served under it
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
//    editor as admin with a save, a new page made from its title and saved
//    with Ctrl+S and with Save and close, search, then back through the whole
//    history and forward again, each step checked by its address and what
//    is on screen. Then leaving the editor with changes by the back button
//    (Stay, then Leave), a reload on a page that keeps the edit (the demo
//    keeps its content in IndexedDB), the administration's export (a zip
//    file of directories, one per space and page, the edited page's body
//    in its page.md), its reset taking the edit away for good and its
//    import bringing it back, a
//    reload on a page's source, and 404.html for an address with no file,
//    the administration's among them. On the way, a page saved twice more
//    has its history opened, a version's diff read and the version
//    restored.
// 3. The same page in a dark scheme and at a phone's width (the
//    administration's forms too, each one column), a page shown
//    as slides (moved through, reloaded, printed), and a page's source
//    copied to the clipboard.
// 4. The demo as an application (WP4.17): its manifest and icons, its
//    service worker taking over the page, and the page read again offline
//    from what the worker kept, and the worker's offline page for a page
//    never read. Every other part runs with service workers blocked, so
//    that what it holds back (app.wasm, until the page is marked) is held
//    back: a worker's own requests and what it answers from its cache pass
//    by Playwright's routes.
// 5. The writing assistant (WP4.19, WP5.11), with the scripted provider:
//    its settings from the user menu, with a default effort, and its panel
//    in the editor: "Thinking" and the edit's status while the model works,
//    the times of the messages, the model's edit tracked in the text and
//    accepted, and Close.
//
// HALOGEN_BASE_PATH is the base path the build was made for, as
// toolchain/build-wasm.sh takes it (/ when unset): GitHub Pages serves the
// demo under /blog/, the repository's name. The directory is then served
// under that path only, as Pages serves a project's site, and everything
// the test asks for or expects to see is under it: the walk below names
// addresses as the wiki's routes (/s/docs/), and 'url', 'here', 'at' and
// 'local' put them under the base path and take them out of it again.
//
// Needs the Chromium that Playwright's version in package-lock.json launches
// (toolchain/bootstrap.sh installs it), and no network: the demo's NASA
// image and video on Wikimedia Commons are answered locally with stand-ins.
import assert from "node:assert/strict";
import { readFile, readdir, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, relative, resolve, sep } from "node:path";
import { strFromU8, unzipSync } from "fflate";
import { chromium } from "playwright";
import { drawable } from "../web/src/tikz-letters.mjs";

const started = Date.now();
const root = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
// The base path, with a slash at each end, as the prerender writes it into
// each page's <base href>.
const base = `/${(process.env.HALOGEN_BASE_PATH ?? "/").split("/").filter((part) => part !== "").join("/")}/`.replace("//", "/");
// A route's address on the site, and the route an address on the site is.
const at = (path) => `${base}${path.replace(/^\//, "")}`;
const local = (address) => (address.startsWith(base) ? `/${address.slice(base.length)}` : address);

// instantiateStreaming refuses a .wasm served without its media type, so the
// server has to get these right. A .gz goes out as application/gzip and a
// .bin as application/octet-stream, as GitHub Pages sends them: TikZJax's
// files are .bin (web/bundle.sh), since a proxy may refuse a gzip download.
const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json",
  ".gz": "application/gzip",
  ".bin": "application/octet-stream",
};

// A static server, as Pages is: a directory's address serves its index.html,
// a directory's address without its slash is redirected to the one with it,
// and an address with no file serves 404.html, with a 404. The directory is
// served under the base path; an address outside it is another site's, and
// gets a bare 404.
const server = createServer(async (request, response) => {
  const address = decodeURIComponent(new URL(request.url, "http://x").pathname);
  if (`${address}/` === base) {
    response.writeHead(301, { location: base }).end();
    return;
  }
  if (!address.startsWith(base)) {
    response.writeHead(404, { "content-type": "text/plain" }).end("Not under the site's base path");
    return;
  }
  const path = local(address);
  const file = join(root, normalize(path.endsWith("/") ? `${path}index.html` : path));
  try {
    if ((await stat(file)).isDirectory()) {
      response.writeHead(301, { location: `${address}/` }).end();
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
const url = (path) => `${origin}${at(path)}`;
const here = (page) => {
  const address = new URL(page.url());
  return local(address.pathname) + address.search;
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
  const context = await browser.newContext({ serviceWorkers: "block", ...options });
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
const islands = ".wiki-math, .wiki-mermaid, .wiki-tikz, .wiki-code, .wiki-time";
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
          // data-stuck is the layout's, set on a bar that sticks under the
          // header once the window scrolls (wiki-app/jsbits/layout.js), and
          // data-current the contents', set on the link to the section
          // being read (wiki-app/jsbits/toc.js).
          const scripts = ["data-prerendered", "data-stuck", "data-current"];
          if (scripts.includes(name) || mark.attributes[name] === now[name]) continue;
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

// The editor's text: CodeMirror (web/src/editor.js), which takes the place
// of the textarea the editor is rendered with once islands/editor.js has
// loaded. What one types into is its content; the Markdown is read from
// CodeMirror, through what its element carries for the application.
const editorText = "#app .editor-cm .cm-content";
const markdownIn = (page) =>
  page.evaluate((selector) => document.querySelector(selector)?.wikiEditor?.text() ?? null, editorText);

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
  for (const path of ["/", "/search/", "/s/docs/", "/s/docs/pages/", "/s/team/projects/", "/s/docs/p/tour/", "/s/docs/p/tour/source/", "/s/team/p/team-handbook/"]) {
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
    assert.ok(html.includes(`<base href="${base}">`), `${path}: no <base href="${base}">`);
    assert.match(html, /<div id="app"><div class="wiki">/, `${path}: not prerendered`);
    assert.ok(html.includes(footerHtml), `${path}: no footer prerendered`);
    visitor.requested.length = 0;
    const { before, repairs } = await load(visitor, path);
    // TikZJax is fetched by a page with a picture, and by no other.
    if (!html.includes('<div class="wiki-tikz">')) {
      const tikz = visitor.requested.filter((address) => /\/(islands\/tikz\.js|tikzjax\/)/.test(address));
      assert.deepEqual(tikz, [], `${path}: a page without a TikZ picture fetched TikZJax`);
    }
    // CodeMirror is the editor's, and no reader's page fetches it.
    const editor = visitor.requested.filter((address) => /\/islands\/editor\.js/.test(address));
    assert.deepEqual(editor, [], `${path}: a reader's page fetched the editor's CodeMirror`);
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
  console.log("ok: no prerendered (reader's) page fetched the editor's CodeMirror");

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
  // Letters beyond ASCII in pictures, through the real TikZJax: every letter
  // web/src/tikz-letters.mjs lists as drawable, in a node and in a pgfplots
  // label, drawn with no error. The SVG holds the glyphs that were missing
  // before web/src/tikz-patch.mjs: the stroke of "ł" (U+F0C3) and the
  // umlaut (U+F0C4). A letter the fonts do not have (the euro sign: TeX
  // looks for a TS1 font TikZJax lacks) and a glyph dvi2html cannot find
  // after TeX has finished each give the readable error, and a picture after
  // them is drawn again.
  const allLetters = [...drawable].join("");
  const pictures = await visitor.evaluate(
    async ([letters]) => {
      const tikz = await import(new URL("islands/tikz.js", document.baseURI).href);
      const glyphs = (result) => (result?.svg ? [...result.svg.querySelectorAll("text")].map((t) => t.textContent).join("") : null);
      const draw = async (preamble, picture) => {
        const result = await tikz.draw(preamble, picture);
        return { error: result?.error ?? null, glyphs: glyphs(result) };
      };
      const plots = String.raw`\usepackage{pgfplots}\pgfplotsset{compat=1.18}`;
      return {
        node: await draw("", String.raw`\begin{tikzpicture}\node[text width=8cm] {${letters}};\end{tikzpicture}`),
        plot: await draw(
          plots,
          String.raw`\begin{tikzpicture}\begin{axis}[ylabel={payoff (zł) ${letters}}]\addplot {x};\end{axis}\end{tikzpicture}`,
        ),
        euro: await draw("", "\\begin{tikzpicture}\\draw (0,0) -- (1,0);\n\\node {5 €};\n\\end{tikzpicture}"),
        glyph: await draw("", String.raw`\begin{tikzpicture}\node {\font\x=cmtex10\x\char2};\end{tikzpicture}`),
        after: await draw("", String.raw`\begin{tikzpicture}\node {Łódź};\end{tikzpicture}`),
      };
    },
    [allLetters],
  );
  for (const name of ["node", "plot", "after"]) {
    assert.equal(pictures[name].error, null, `the picture of letters (${name}) failed`);
    assert.ok(pictures[name].glyphs.includes("\uf0c3"), `the picture of letters (${name}) has no stroke of "ł"`);
  }
  assert.ok(pictures.node.glyphs.includes("\uf0c4"), "the picture of letters has no umlaut");
  assert.equal(
    pictures.euro.error?.split("\n")[0],
    "! The fonts TeX has here cannot draw '€' (line 2).",
    "the euro sign's error",
  );
  assert.equal(
    pictures.glyph.error?.split("\n")[0],
    "! The fonts TeX has here cannot draw a character of this picture (Cannot read properties of undefined (reading 'toString')).",
    "a missing glyph's error",
  );
  console.log(`ok: TikZ draws ${drawable.size} letters beyond ASCII, in a node and a plot's label, and names one it cannot draw`);
  // The Mathematics page sets every formula with the macros it uses: the
  // built-in ones, Docs' own, the page's \dist, and mhchem's \ce. KaTeX
  // shows a macro it does not know in red, and what it cannot parse in a
  // .katex-error.
  await load(visitor, "/s/docs/p/markdown-guide/mathematics/");
  const formulas = visitor.locator("#app .page-body .wiki-math");
  await eventually(async () => {
    const count = await formulas.count();
    const set = await visitor.locator("#app .page-body .wiki-math .katex").count();
    assert.ok(count >= 20 && set === count, "not yet");
  }, "the Mathematics page's formulas being set");
  const unset = await visitor.evaluate(() =>
    Array.from(document.querySelectorAll("#app .page-body .wiki-math"))
      .filter((f) => f.querySelector(".katex-error") || f.innerHTML.includes("#cc0000"))
      .map((f) => f.querySelector("annotation")?.textContent ?? f.textContent),
  );
  assert.deepEqual(unset, [], "formulas KaTeX could not set with their macros");
  console.log("ok: the Mathematics page sets its formulas with built-in, space and page macros, and \\ce");
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
    assert.ok([...tikzBytes.keys()].some((address) => address.endsWith("core.dump.bin")), "not yet");
    return [...tikzBytes.values()].reduce((a, b) => a + b, 0);
  }, "TikZJax's files being counted");
  console.log(
    `note: the first TikZ picture was drawn ${drawn} ms after the page was asked for, with nothing cached;` +
      ` TikZJax's files fetched for it: ${tikzBytes.size}, ${Math.round(fetchedTikz / 1024)} KiB`,
  );
  await cold.context().close();

  // TikZJax is GPL and its fonts are BaKoMa's: a page that serves them
  // serves their licences' texts beside them (web/bundle.sh), as conveying
  // them requires.
  for (const [path, says] of [
    ["/tikzjax/LICENSE.txt", "GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"],
    ["/tikzjax/fonts/LICENCE.txt", "BaKoMa Fonts Licence"],
    ["/tikzjax/NOTICE.txt", "Licence: GPL-3.0-or-later, whose text is LICENSE.txt"],
  ]) {
    const answer = await fetch(url(path));
    assert.equal(answer.status, 200, `${path} is not served`);
    assert.ok((await answer.text()).includes(says), `${path} does not say ${JSON.stringify(says)}`);
  }
  console.log("ok: TikZJax's licence and its fonts' are served beside them");
  // TikZJax's compressed files are zlib streams named .bin, served as
  // application/octet-stream, since a corporate proxy may refuse to download
  // a gzip archive (web/src/tikz-files.mjs): no .gz ships under tikzjax/,
  // so nothing there goes out as application/gzip. (The cold page above
  // drew its picture from them, through the worker's renaming.)
  {
    const shipped = (await readdir(join(root, "tikzjax"), { recursive: true })).map((name) => name.split(sep).join("/"));
    assert.deepEqual(
      shipped.filter((name) => name.endsWith(".gz")),
      [],
      "gzip files ship under tikzjax/",
    );
    const bins = shipped.filter((name) => name.endsWith(".bin"));
    for (const name of ["tex.wasm.bin", "core.dump.bin", "tex_files/tikzlibrarycalc.code.tex.bin"]) {
      assert.ok(bins.includes(name), `tikzjax/${name} is not built`);
    }
    for (const name of shipped) {
      const answer = await fetch(url(`/tikzjax/${name}`), { method: "HEAD" });
      const type = answer.headers.get("content-type");
      assert.notEqual(type, "application/gzip", `tikzjax/${name} is served as gzip`);
      if (name.endsWith(".bin")) assert.equal(type, "application/octet-stream", `tikzjax/${name}'s type`);
    }
    console.log(`ok: TikZJax's ${bins.length} compressed files are .bin, served as application/octet-stream, and none as gzip`);
  }
  // And the notices of what esbuild bundled into the page's scripts and
  // styles (web/src/licenses.mjs), each with its licence's text: the
  // libraries the README's licence section names, and Mermaid's own
  // dependencies, DOMPurify among them.
  {
    const answer = await fetch(url("/licenses.txt"));
    assert.equal(answer.status, 200, "licenses.txt is not served");
    const notices = await answer.text();
    for (const [name, says] of [
      ["katex", "The MIT License"],
      ["highlight.js", "BSD 3-Clause License"],
      ["@codemirror/view", "MIT License"],
      ["@lezer/highlight", "MIT License"],
      ["fflate", "MIT License"],
      ["mermaid", "The MIT License"],
      ["dompurify", "Apache License"],
      ["@bjorn3/browser_wasi_shim", "Permission is hereby granted"],
    ]) {
      const entry = notices.split(`\n${"=".repeat(78)}\n`).find((part) => part.startsWith(`${name} `));
      assert.ok(entry !== undefined, `licenses.txt does not list ${name}`);
      assert.ok(entry.includes(says), `licenses.txt's ${name} does not say ${JSON.stringify(says)}`);
    }
    console.log(`ok: licenses.txt carries the notices of the ${notices.split(`\n${"=".repeat(78)}\n`).length - 1} npm packages bundled into the page`);
  }

  // A page left while its picture is still being drawn: the next page shows
  // at once. (When an island's component waited for its drawing, following
  // a link then left the page as it was; see Wiki.App.Islands.Monad.) TeX's
  // format is held back for a while, so that the picture is still being
  // drawn when the links are followed.
  const hurried = await newPage();
  await hurried.route("**/tikzjax/core.dump.bin", async (route) => {
    await new Promise((later) => setTimeout(later, 5000));
    await route.continue();
  });
  await load(hurried, "/s/docs/p/markdown-guide/");
  assert.equal(await hurried.locator("#app .wiki-tikz > svg").count(), 0, "the picture was drawn before the page was left");
  await hurried.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await hurried.locator(editorText).waitFor({ timeout: 5000 });
  await hurried.goBack();
  await hurried.locator("#app .page-view h1", { hasText: "Markdown guide" }).waitFor({ timeout: 5000 });
  await hurried.locator("#app .wiki-sidebar .page-tree a", { hasText: "Mathematics" }).click();
  await hurried.locator("#app .page-view h1", { hasText: "Mathematics" }).waitFor({ timeout: 5000 });
  await hurried.context().close();
  console.log("ok: a page left while its TikZ picture is being drawn gives way to the next at once");

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
  await arrive({ path: "/", view: "directory" }, "the front page");
  // A space from anywhere: the directory, by the site's name, and the
  // space's card there; the space opens at its home page.
  const toSpace = async (href) => {
    await page.locator("#app .wiki-brand").click();
    await page.locator(`#app .space-card-link[href='${at(href)}']`).click();
    await page.locator(`#app .sidebar-space[href='${at(href)}']`).waitFor({ timeout });
  };
  // The spaces the sidebar's menu offers to switch to.
  const switchable = async () => {
    await page.locator("#app .space-switcher-toggle").click();
    await page.locator("#app .space-switcher-option").first().waitFor({ timeout });
    const hrefs = await page.locator("#app .space-switcher-option").evaluateAll((links) => links.map((a) => a.getAttribute("href")));
    await page.locator("#app .space-switcher-toggle").click();
    return hrefs.map(local);
  };

  // The tour, from the front page's invitation.
  await page.locator("#app .directory a", { hasText: "Take the tour" }).click();
  await arrive({ path: "/s/docs/p/tour/", view: "page-view", crumb: "Tour" }, "the tour");

  // Who one is, from the menu at the top right. The demo starts as admin;
  // nobody sees no private space, and admin every one.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login='']").click();
  await page.locator("#app .user-switcher-toggle", { hasText: "Not signed in" }).waitFor({ timeout });
  await eventually(async () => assert.deepEqual(await switchable(), ["/s/blog/", "/s/docs/"]), "nobody's spaces to switch to");
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login=admin]").click();
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  await eventually(async () => assert.deepEqual(await switchable(), ["/s/blog/", "/s/docs/", "/s/team/"]), "admin's spaces to switch to");
  // The spaces are clicked at once, while the shell may still be busy with
  // the switch. A link's handler then runs only once the shell is done, after
  // the browser would have followed the link; the browser is kept from it in
  // the click's listener instead, so no click here may load a page.

  // Every root space, from its card in the directory, which opens it at its
  // home page with a sidebar of its own; and a page of each from there.
  await page.locator("#app .all-spaces").click();
  await arrive({ path: "/", view: "directory" }, "the directory");
  const roots = await page.locator("#app .space-card-link").evaluateAll((links) =>
    links.map((a) => ({ href: a.getAttribute("href"), name: a.querySelector(".space-card-name").textContent })),
  ).then((links) => links.map((link) => ({ ...link, href: local(link.href) })));
  assert.deepEqual(roots.map((r) => r.name), ["Blog", "Docs", "Team"]);
  for (const space of roots) {
    if (here(page) !== "/") {
      await page.locator("#app .all-spaces").click();
      await arrive({ path: "/", view: "directory" }, `the directory, for ${space.name}`);
    }
    await page.locator(`#app .space-card-link[href='${at(space.href)}']`).click();
    // The blog opens at its posts (WP4.14), the others at their home pages.
    const opensAt = space.name === "Blog" ? "blog-view" : "page-view";
    await arrive({ path: space.href, view: opensAt, crumb: space.name }, `the space ${space.name}`);
    assert.equal(await page.locator("#app .sidebar-space-name").textContent(), space.name, "the sidebar's space");
    const first = page.locator("#app .wiki-sidebar .page-tree a").first();
    const target = { href: local(await first.getAttribute("href")), title: await first.textContent() };
    await first.click();
    await arrive({ path: target.href, view: "page-view", crumb: target.title }, `the page ${target.title}`);
  }
  await page.locator("#app .wiki-brand").click();
  await arrive({ path: "/", view: "directory" }, "the directory again");
  const recent = await page.locator("#app .recent-space-name").allTextContents();
  assert.deepEqual(recent, ["Team", "Docs", "Blog"], "the spaces visited last, the latest first");
  await samePage("going through the spaces");
  console.log("ok: every root space, and a page in each, by clicking, and the directory remembers them");

  // The blog: its posts the newest first, each with its date and comments,
  // and from a post to the one before it.
  await page.locator(`#app .space-card-link[href='${at("/s/blog/")}']`).click();
  await arrive({ path: "/s/blog/", view: "blog-view", crumb: "Blog" }, "Blog again");
  assert.deepEqual(await page.locator("#app .post-list .post-title").allTextContents(), ["Notes on Haskell", "Hello, world"], "the blog's posts");
  assert.deepEqual(
    await page.locator("#app .post-list .post-meta").allTextContents(),
    ["19 September 2026 · No comments", "1 September 2026 · 5 comments"],
    "the posts' dates and comments",
  );
  await page.locator(`#app .post-link[href='${at("/s/blog/p/notes-on-haskell/")}']`).click();
  await arrive({ path: "/s/blog/p/notes-on-haskell/", view: "page-view", crumb: "Notes on Haskell", text: "Posted 19 September 2026" }, "a post");
  assert.equal(await page.locator("#app .post-next").count(), 0, "the newest post has no next");
  console.log("ok: the blog lists its posts, the newest first, and a post its date");

  // The editor, as admin, with a save: Hello, world, the post before.
  await page.locator("#app .post-previous").click();
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

  // CodeMirror is fetched as the editor opens: how much of it.
  const editorBytes = new Promise((resolve) =>
    page.context().on("requestfinished", async (request) => {
      if (/\/islands\/editor\.js$/.test(request.url())) resolve((await request.sizes()).responseBodySize);
    }),
  );
  await page.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await arrive({ path: "/s/blog/p/hello-world/edit/", view: "editor", crumb: "Edit" }, "the editor");
  const textarea = page.locator(editorText);
  await textarea.press("Control+End");
  await textarea.pressSequentially("\n\n## Smoke test\n\nWritten by ");
  // A toolbar shortcut, whose placeholder is selected for the typing.
  await textarea.press("Control+b");
  await textarea.pressSequentially("Ada");
  await textarea.press("End");
  await textarea.pressSequentially(" with $x^2$.");
  // CodeMirror shows it as it will look: the new heading larger, Ada bold.
  await page.locator("#app .editor-cm .cm-md-h2", { hasText: "Smoke test" }).first().waitFor({ timeout });
  await page.locator("#app .editor-cm .cm-md-strong", { hasText: "Ada" }).first().waitFor({ timeout });
  assert.ok((await markdownIn(page)).endsWith("\n\n## Smoke test\n\nWritten by **Ada** with $x^2$."), "the Markdown typed");
  console.log(`note: the editor fetched islands/editor.js, ${Math.round((await editorBytes) / 1024)} KiB`);
  // The Markdown is shown alone until the preview is asked for, which
  // replaces it; Save is still there.
  assert.ok(!(await page.locator("#app .editor-preview").isVisible()), "the preview shows before it is asked for");
  await page.locator("#app .editor-show-preview").click();
  await page.locator("#app .editor-preview h2", { hasText: "Smoke test" }).waitFor({ timeout });
  await page.locator("#app .editor-preview strong", { hasText: "Ada" }).waitFor({ timeout });
  await page.locator("#app .editor-preview .wiki-math-inline .katex").last().waitFor({ timeout });
  assert.ok(!(await textarea.isVisible()), "the Markdown beside the preview shown on its own");
  await page.locator("#app .editor-save-close").click();
  await arrive({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text: "Smoke test" }, "the page saved");
  await samePage("editing");
  console.log("ok: the editor formats from a shortcut, previews what is typed, with its formulas, and saves it");

  // A new page: its title first, in a small form, which makes the page and
  // opens the editor on it; Ctrl+S saves and stays there, saying so, and
  // Save and close shows the page.
  await page.locator("#app .space-pages-link").click();
  await arrive({ path: "/s/blog/pages/", view: "space-view", crumb: "Pages and settings" }, "Blog's pages, for a new page");
  await page.locator("#app .space-view .actions a", { hasText: "New page" }).click();
  await arrive({ path: "/s/blog/new-page/", view: "new-page-view", crumb: "New page" }, "the new page's form");
  await page.locator("#app .new-page-title").pressSequentially("Smoke page");
  await page.locator("#app .new-page-view button.primary").click();
  await arrive({ path: "/s/blog/p/smoke-page/edit/", view: "editor", crumb: "Edit" }, "the new page's editor");
  const fresh = page.locator(editorText);
  await fresh.waitFor({ timeout });
  assert.equal(await markdownIn(page), "", "a new page's Markdown is not empty");
  await fresh.pressSequentially("Made through the *new* flow.");
  await fresh.press("Control+s");
  await page.locator("#app .editor-saved-notice", { hasText: "Saved" }).waitFor({ timeout });
  assert.equal(here(page), "/s/blog/p/smoke-page/edit/", "Ctrl+S left the editor");
  await page.locator("#app .editor-save-close").click();
  await arrive(
    { path: "/s/blog/p/smoke-page/", view: "page-view", crumb: "Smoke page", text: "Made through the new flow." },
    "the new page saved",
  );
  await samePage("making a page");
  console.log("ok: a new page is made from its title, Ctrl+S saves it and stays, and Save and close shows it");

  // A page from a template: the team's own, listed apart from its tree, is
  // offered by "New page" beside the built-in ones; the new page has its
  // title, today's date and its maker's name where the template has
  // {{title}}, {{date}} and {{author}}.
  // Every step is an entry of the history, which the walk goes back and
  // forward through later.
  await page.locator("#app .wiki-brand").click();
  await arrive({ path: "/", view: "directory" }, "the front page, for the team's space");
  await page.locator(`#app .space-card-link[href='${at("/s/team/")}']`).click();
  await arrive({ path: "/s/team/", view: "page-view", text: "Team handbook" }, "the team's space");
  await page.locator("#app .wiki-sidebar .sidebar-templates a", { hasText: "Weekly sync" }).waitFor({ timeout });
  await page.locator("#app .space-pages-link").click();
  await arrive({ path: "/s/team/pages/", view: "space-view", crumb: "Pages and settings" }, "Team's pages, for a page from a template");
  await page.locator("#app .space-view .actions a", { hasText: "New page" }).click();
  await arrive({ path: "/s/team/new-page/", view: "new-page-view", crumb: "New page" }, "the new page's form, with templates");
  const starts = await page.locator("#app .new-page-choice").allTextContents();
  assert.deepEqual(
    starts.map((t) => t.trim().split(/\s+/)[0]),
    ["Blank", "Weekly", "Meeting", "Decision", "How-to"],
    "what a new page may start from",
  );
  await page.locator("#app .new-page-title").pressSequentially("Smoke sync");
  await page.locator("#app .new-page-choice", { hasText: "Weekly sync" }).locator("input").check();
  await page.locator("#app .new-page-view button.primary").click();
  await arrive({ path: "/s/team/p/smoke-sync/edit/", view: "editor", crumb: "Edit" }, "the editor on a page from a template");
  await page.locator(editorText).waitFor({ timeout });
  const today = new Date().toISOString().slice(0, 10);
  await eventually(async () => {
    const made = (await markdownIn(page)) ?? "";
    assert.ok(made.startsWith("# Smoke sync\n"), `the template's title not filled in: ${made}`);
    assert.ok(made.includes(`Weekly sync of ${today}, notes by Ada Admin.`), `the date and the author not filled in: ${made}`);
  }, "the template's placeholders filled in");
  await page.locator("#app .editor-save-close").click();
  await arrive({ path: "/s/team/p/smoke-sync/", view: "page-view", crumb: "Smoke sync", text: "notes by Ada Admin" }, "the page made from a template");
  await samePage("making a page from a template");
  console.log("ok: New page offers the space's template and the built-in ones, and fills in the one chosen");

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
  await page.locator(`#app .search-view a.search-hit[href='${at("/s/docs/p/markdown-guide/diagrams/")}']`).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/", view: "page-view", crumb: "Diagrams" }, "Diagrams");
  await page.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/edit/", view: "editor", crumb: "Edit" }, "editing Diagrams");
  await page.locator(editorText).press("Control+End");
  await page.locator(editorText).pressSequentially("\nNot to be kept.");
  const entries = await page.evaluate(() => history.length);
  await page.goBack();
  await page.locator("#app .leave-confirm").waitFor({ timeout });
  await page.locator("#app .leave-confirm button", { hasText: "Stay" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/edit/", view: "editor" }, "staying in the editor");
  assert.ok((await markdownIn(page)).endsWith("Not to be kept."), "staying lost the draft");
  assert.equal(await page.evaluate(() => history.length), entries, "staying added an entry to the history");
  await page.goBack();
  await page.locator("#app .leave-confirm button", { hasText: "Leave" }).click();
  await check({ path: "/s/docs/p/markdown-guide/diagrams/", view: "page-view", crumb: "Diagrams" }, "leaving the editor");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Not to be kept."), "leaving kept the draft");
  await samePage("leaving the editor");
  console.log("ok: leaving the editor by the back button asks; Stay returns to its entry, Leave drops the draft");

  // A page's history: the new page saved twice more, its versions listed
  // the latest first with what the last save changed, an earlier version
  // chosen and restored, which saves it as a new version on top.
  await toSpace("/s/blog/");
  await page.locator(`#app .wiki-sidebar .page-tree a[href='${at("/s/blog/p/smoke-page/")}']`).click();
  await check({ path: "/s/blog/p/smoke-page/", view: "page-view", crumb: "Smoke page" }, "the new page again");
  for (const line of ["A second line.", "A third line."]) {
    await page.locator("#app .page-view .actions a", { hasText: "Edit" }).click();
    await check({ path: "/s/blog/p/smoke-page/edit/", view: "editor" }, `editing for "${line}"`);
    await page.locator(editorText).press("Control+End");
    await page.locator(editorText).pressSequentially(`\n\n${line}`);
    await page.locator("#app .editor-save-close").click();
    await check({ path: "/s/blog/p/smoke-page/", view: "page-view", text: line }, `"${line}" saved`);
  }
  await page.locator("#app .page-view .actions a", { hasText: "History" }).click();
  await check({ path: "/s/blog/p/smoke-page/history/", view: "history-view", crumb: "History" }, "the page's history");
  const versionNames = () => page.locator("#app .version-list li > a").allTextContents();
  const before = await versionNames();
  assert.ok(before.length >= 4, `the history lists ${before.length} versions`);
  assert.equal(before[0], `Version ${before.length} (current)`, "the latest is not first");
  assert.equal(await page.locator("#app .diff-added .diff-text").last().textContent(), "A third line.", "the latest diff");
  await eventually(async () => assert.ok((await page.locator("#app .version-meta time").first().textContent()).length > 0, "no time"), "the time written in");
  await page.locator("#app .version-list li > a", { hasText: /^Version 2$/ }).click();
  await page.locator("#app .version-detail h2", { hasText: "Version 2" }).waitFor({ timeout });
  assert.match(here(page), /^\/s\/blog\/p\/smoke-page\/history\/\?version=/, "a version's address");
  await page.locator("#app button.restore").click();
  await page.locator("#app .restore-confirm button", { hasText: "Restore" }).click();
  await check({ path: "/s/blog/p/smoke-page/", view: "page-view", text: "Made through the new flow." }, "the version restored");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("A second line."), "the restore kept a later line");
  await page.locator("#app .page-view .actions a", { hasText: "History" }).click();
  await check({ path: "/s/blog/p/smoke-page/history/", view: "history-view" }, "the history after the restore");
  const after = await versionNames();
  assert.equal(after.length, before.length + 1, "the restore made no new version");
  assert.equal(after[0], `Version ${after.length} (current)`);
  await samePage("the page's history");
  console.log(`ok: a page saved twice more lists ${before.length} versions with the last diff, and restoring version 2 makes version ${after.length}`);

  // A reload arrives at the same page, with the edit kept in the browser
  // (IndexedDB), as admin again: who one was is not kept, and the demo
  // starts as admin.
  await toSpace("/s/blog/");
  await page.locator(`#app .wiki-sidebar .page-tree a[href='${at("/s/blog/p/hello-world/")}']`).click();
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", text: "Smoke test" }, "the edited page");
  // The prerendered page shows the demo's own content, so adopting it
  // repairs the edited page into what the browser keeps.
  const edited = await reload(page);
  assert.ok(!noRepairs(edited.repairs), "a page edited in the browser was adopted with nothing to repair");
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text: "Smoke test" }, "the reload");
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  // The user menu only switches users: the wiki's data is the
  // administration's, linked from the header for an administrator.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login=admin]").waitFor({ timeout });
  assert.equal(await page.locator("#app .user-menu .demo-export").count(), 0, "the user menu still exports the wiki");
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .wiki-header a.admin-link").click();
  await check({ path: "/admin/", view: "admin-view", crumb: "Administration" }, "the administration");
  await page.locator("#app .admin-view .demo-kept", { hasText: "kept in this browser" }).waitFor({ timeout });
  // Exporting the wiki downloads a zip file of it, edit and all.
  const [exported] = await Promise.all([page.waitForEvent("download", { timeout }), page.locator("#app .admin-view .demo-export").click()]);
  assert.match(exported.suggestedFilename(), /^wiki-\d{4}-\d{2}-\d{2}\.zip$/, "the export's name");
  const exportPath = await exported.path();
  assert.equal((await readFile(exportPath)).subarray(0, 2).toString(), "PK", "the export is not a zip file");
  await page.locator("#app .admin-view .demo-told", { hasText: `Exported the wiki as ${exported.suggestedFilename()}.` }).waitFor({ timeout });
  // The zip file is version 2 of docs/export.md: a directory per space and
  // per page, the page's body as page.md, its comments beside it.
  const exportedFiles = unzipSync(await readFile(exportPath));
  assert.equal(JSON.parse(strFromU8(exportedFiles["manifest.json"])).formatVersion, 2, "the export's format version");
  const helloDir = "spaces/blog/pages/hello-world/";
  for (const name of ["page.json", "page.md", "comments.json"]) {
    assert.ok(exportedFiles[helloDir + name], `the export has no ${helloDir}${name}`);
  }
  assert.ok(strFromU8(exportedFiles[helloDir + "page.md"]).includes("Smoke test"), "the export's page.md is not the edited page");
  assert.ok(!("pages.json" in exportedFiles), "the export still has version 1's pages.json");
  // Resetting the demo's content, from the administration and after asking,
  // takes the edit away, and a reload does not bring it back.
  await page.locator("#app .admin-view .demo-reset-ask").click();
  await page.locator("#app .demo-reset-confirm button", { hasText: "Reset" }).click();
  await page.locator("#app .admin-view .demo-told", { hasText: "back as it was at the start" }).waitFor({ timeout });
  const toHelloWorld = async (step, text) => {
    await toSpace("/s/blog/");
    await page.locator(`#app .wiki-sidebar .page-tree a[href='${at("/s/blog/p/hello-world/")}']`).click();
    await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world", text }, step);
  };
  await toHelloWorld("the page after the reset");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Smoke test"), "the edit is still there");
  // The demo's own content again, which the prerendered page shows as it is.
  const reset = await reload(page);
  assert.ok(noRepairs(reset.repairs), `the page after a reset needed repairs: ${JSON.stringify(reset.repairs)}`);
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world" }, "the reload after the reset");
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Smoke test"), "the edit came back after a reset");
  // Importing the export brings it back, after asking.
  await page.locator("#app .wiki-header a.admin-link").click();
  await check({ path: "/admin/", view: "admin-view", crumb: "Administration" }, "the administration again");
  await page.locator("#app .admin-view .demo-import input").setInputFiles({
    name: exported.suggestedFilename(),
    mimeType: "application/zip",
    buffer: await readFile(exportPath),
  });
  await page.locator("#app .demo-import-confirm button", { hasText: "Replace" }).click();
  await page.locator("#app .admin-view .demo-told", { hasText: "Imported" }).waitFor({ timeout });
  await toHelloWorld("the import", "Smoke test");
  console.log("ok: the administration, from the header, exports a zip file of the wiki, resets it, and imports the export back");
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
  // Nor has the administration's, which the program opens for an
  // administrator, as the demo starts.
  assert.equal((await fetch(url("/admin/"))).status, 404);
  await load(page, "/admin/");
  await stillPrerendered(page, "the administration's address");
  await check({ path: "/admin/", view: "admin-view", crumb: "Administration" }, "the administration's address");
  await page.locator("#app .admin-view .demo-export").waitFor({ timeout });
  console.log("ok: the administration opens at its own address");
  // An editor's address has no page of its own either; the program opens it.
  assert.equal((await fetch(url("/s/blog/p/hello-world/edit/"))).status, 404);
  // 404.html is the page of no route, so the program repairs it into the
  // editor's: the shell is kept, what differs is built afresh.
  await load(page, "/s/blog/p/hello-world/edit/");
  await stillPrerendered(page, "an editor's address");
  await check({ path: "/s/blog/p/hello-world/edit/", view: "editor", crumb: "Edit" }, "an editor's address");
  // The demo starts as admin, who may edit it.
  await page.locator(editorText).waitFor({ timeout });
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
  await phone.locator(editorText).waitFor({ timeout });
  assert.ok(await phone.locator("#app .editor-toolbar").isVisible(), "no toolbar on a phone");
  assert.ok(!(await phone.locator("#app .editor-side-by-side").isVisible()), "a side by side preview offered on a phone");
  assert.ok(await fits(), "the editor is wider than a phone");
  await phone.locator("#app .editor-show-preview").tap();
  await phone.locator("#app .editor-preview .page-body h1").waitFor({ timeout });
  assert.ok(!(await phone.locator(editorText).isVisible()), "the Markdown beside the preview on a phone");
  assert.ok(await fits(), "the editor's preview is wider than a phone");
  await phone.locator("#app .editor-back").tap();
  await phone.locator(editorText).waitFor({ timeout });
  assert.ok(!(await phone.locator("#app .editor-preview").isVisible()), "the preview stays after Back to editing");
  // A page's source wraps its long lines rather than widening the page.
  await load(phone, "/s/docs/p/tour/source/");
  await phone.locator("#app .source-text").waitFor({ timeout });
  assert.ok(await fits(), "a page's source is wider than a phone");
  // The administration's forms are one column at any width (WP5.5): on a
  // phone too, each field under the one before, and none wider than it.
  await load(phone, "/admin/");
  await phone.locator("#app .user-create-fields").waitFor({ timeout });
  await phone.locator("#app .server-provider-add").tap();
  await phone.locator("#app .server-provider-form").waitFor({ timeout });
  assert.ok(await fits(), "the administration is wider than a phone");
  const besides = await phone.evaluate(() =>
    [".user-create-fields", ".server-provider-form"].flatMap((selector) => {
      const shown = [...document.querySelector(`#app ${selector}`).children].filter((c) => c.getClientRects().length > 0);
      return shown.slice(1).flatMap((child, i) =>
        child.getBoundingClientRect().top < shown[i].getBoundingClientRect().bottom - 0.5 ? [`${selector}: ${child.className}`] : [],
      );
    }),
  );
  assert.deepEqual(besides, [], "fields of the administration's forms side by side on a phone");
  await phone.context().close();
  console.log("ok: a page, the editor, a page's source and the administration's forms fit a phone's width");

  // A page presented as slides: moved through by the keys with the slide in
  // the address, which a reload comes back to; printed, one slide to a page.
  // Then a slide's steps: shown one at a time, kept in the address across a
  // reload, and printed one to a page when "each step on its own page" is
  // ticked.
  const deck = await newPage();
  await load(deck, "/s/docs/p/markdown-guide/presentations/slides/");
  await deck.locator("#app .slides-view .slide-frame.current .slide-title", { hasText: "Presentations" }).waitFor({ timeout });
  await deck.keyboard.press("ArrowRight");
  await deck.locator("#app .slides-position", { hasText: "2 / 9" }).waitFor({ timeout });
  assert.equal(new URL(deck.url()).search, "?slide=2", "the slide shown is not in the address");
  await deck.keyboard.press("ArrowRight");
  await deck.locator("#app .slide-frame.current .wiki-math-display .katex-display").waitFor({ timeout });
  await reload(deck);
  await deck.locator("#app .slides-position", { hasText: "3 / 9" }).waitFor({ timeout });
  await deck.locator("#app .slide-frame.current .wiki-math-display .katex-display").waitFor({ timeout });
  await deck.emulateMedia({ media: "print" });
  const printed = await deck.evaluate(() => ({
    slides: [...document.querySelectorAll("#app .slide-frame")].filter((f) => f.checkVisibility()).length,
    chrome: [".wiki-header", ".wiki-sidebar", ".slides-controls"].filter((s) => document.querySelector(`#app ${s}`)?.checkVisibility()),
  }));
  assert.deepEqual(printed, { slides: 9, chrome: [] }, "printing shows something else than every slide");
  const pdf = (await deck.pdf({ preferCSSPageSize: true })).toString("latin1");
  assert.equal(pdf.match(/\/Type\s*\/Page[^s]/g)?.length, 9, "the deck does not print as one page per slide");
  await deck.emulateMedia({ media: "screen" });
  await load(deck, "/s/docs/p/markdown-guide/presentations/slides/?slide=7");
  await deck.locator("#app .slide-frame.current .slide-title", { hasText: "Steps" }).waitFor({ timeout });
  const stepsShown = () => deck.evaluate(() => [...document.querySelectorAll("#app .slide-frame.current .slide-step")].map((e) => e.checkVisibility({ visibilityProperty: true })));
  assert.deepEqual(await stepsShown(), [false, false], "a slide's later steps are shown at its first");
  await deck.keyboard.press("ArrowRight");
  await deck.waitForURL((u) => u.search === "?slide=7&step=2", { timeout });
  assert.deepEqual(await stepsShown(), [true, false], "the next key does not show the next step");
  await reload(deck);
  await deck.locator("#app .slide-frame.current .slide-title", { hasText: "Steps" }).waitFor({ timeout });
  assert.deepEqual(await stepsShown(), [true, false], "a reload does not come back to the step");
  await deck.locator("#app .slides-print-steps input").check();
  await deck.emulateMedia({ media: "print" });
  const printedSteps = await deck.evaluate(() => ({
    pages: [...document.querySelectorAll("#app .slide-frame")].filter((f) => f.checkVisibility()).length,
    hidden: [...document.querySelectorAll("#app .slide-frame:not(.slide-step-copy) .slide-step")].filter((e) => !e.checkVisibility({ visibilityProperty: true })).length,
  }));
  assert.deepEqual(printedSteps, { pages: 13, hidden: 0 }, "printing each step does not add a page for each step before a slide's last");
  const stepsPdf = (await deck.pdf({ preferCSSPageSize: true })).toString("latin1");
  assert.equal(stepsPdf.match(/\/Type\s*\/Page[^s]/g)?.length, 13, "the deck does not print as one page per step");
  await deck.context().close();
  console.log("ok: a deck moves by its keys, keeps its slide and step in the address across a reload, and prints a slide, or a step, to a page");

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

  // Comments: the first post's quote marked as it was prerendered, text
  // selected in it commented on from the button beside it, and the comment
  // and its mark there after a reload, kept in IndexedDB.
  const commenter = await newPage();
  await load(commenter, "/s/blog/p/hello-world/");
  assert.equal(
    await commenter.locator('#app mark.comment-mark[data-thread="thread-hello-1"]').textContent(),
    "a blog that is also a wiki",
    "the first post's quote is not marked",
  );
  await commenter.evaluate(() => {
    const walker = document.createTreeWalker(document.querySelector("#app .page-body"), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      const at = node.data.indexOf("in other spaces");
      if (at < 0) continue;
      const range = document.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + "in other spaces".length);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      node.parentElement.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
      return;
    }
  });
  await commenter.locator("#app .comment-on-selection").click();
  await commenter.locator("#app .comments-panel .new-thread textarea").fill("Spaces all the way down?");
  await commenter.locator("#app .comments-panel .new-thread button", { hasText: "Comment" }).click();
  const marked = commenter.locator("#app mark.comment-mark", { hasText: "in other spaces" });
  await marked.waitFor({ timeout });
  await reload(commenter);
  await marked.waitFor({ timeout });
  await commenter.locator("#app .comments-toggle", { hasText: "Comments (3)" }).waitFor({ timeout });
  await commenter.context().close();
  console.log("ok: a quote is marked, text selected is commented on, and the comment is kept across a reload");

  // ---- 4. The demo as an application, read offline ---------------------------

  // In a block of its own: its names are its own.
  {
    // What a browser reads to install it: the manifest, linked from the page,
    // and its icons.
    const manifest = await (await fetch(url("/manifest.webmanifest"))).json();
    assert.equal(manifest.display, "standalone");
    assert.equal(manifest.start_url, "./");
    for (const icon of manifest.icons) {
      const fetched = await fetch(url(`/${icon.src}`));
      assert.equal(fetched.status, 200, `the manifest's icon ${icon.src}`);
    }
    // A browser that lets service workers in, as a reader's does.
    const offlineContext = await browser.newContext();
    const reader = await offlineContext.newPage();
    reader.on("pageerror", (error) => failures.push(`page error at ${reader.url()}: ${error.message}`));
    reader.on("console", (message) => {
      // Offline, what is not kept fails to load (the photograph from
      // Wikimedia Commons); that is what offline is.
      if (message.type() === "error" && !/ERR_INTERNET_DISCONNECTED|Failed to load resource|404/.test(message.text())) {
        failures.push(`console error at ${reader.url()}: ${message.text()}`);
      }
    });
    await reader.route("https://upload.wikimedia.org/**", (route) => route.fulfill({ contentType: "image/png", body: standInImage }));
    await reader.goto(url("/"));
    await reader.locator("#app .directory h1", { hasText: "Spaces" }).waitFor({ timeout });
    assert.equal(await reader.locator('head link[rel="manifest"]').getAttribute("href"), "./manifest.webmanifest");
    // The worker takes the page over, and keeps the page it did not serve
    // (the one that installed it) when the page asks.
    await eventually(async () => assert.ok(await reader.evaluate(() => navigator.serviceWorker.controller !== null), "no worker"), "the service worker taking the page over");
    // Installable where the page is served: the worker's scope is the site's
    // base path, and Chromium reads the manifest from under it with no
    // errors, its start and scope there too, and finds nothing that keeps
    // the page from being installed. Page.getInstallabilityErrors is
    // Chromium's own check, the one behind its "Install" offer.
    assert.equal(await reader.evaluate(async () => (await navigator.serviceWorker.getRegistration()).scope), url("/"), "the worker's scope");
    const devtools = await offlineContext.newCDPSession(reader);
    const read = await devtools.send("Page.getAppManifest");
    assert.equal(read.url, url("/manifest.webmanifest"), "the manifest's address");
    assert.deepEqual(read.errors, [], "the manifest's errors");
    const declared = JSON.parse(read.data);
    assert.equal(new URL(declared.start_url, read.url).href, url("/"), "the manifest's start_url");
    assert.equal(new URL(declared.scope, read.url).href, url("/"), "the manifest's scope");
    const { installabilityErrors } = await devtools.send("Page.getInstallabilityErrors");
    assert.deepEqual(installabilityErrors, [], "what keeps the page from being installed");
    await devtools.detach();
    const keptPage = (path) =>
      reader.evaluate(async (address) => {
        for (const name of await caches.keys()) {
          if (name.startsWith("wiki-pages ") && (await (await caches.open(name)).match(address))) return true;
        }
        return false;
      }, url(path));
    await eventually(async () => assert.ok(await keptPage("/"), "not kept"), "the front page kept by the worker");
    // A page loaded while the worker serves the page is kept as it comes.
    await reader.goto(url("/s/blog/p/hello-world/"));
    await reader.locator("#app .wiki-content h1", { hasText: "Hello" }).waitFor({ timeout });
    await eventually(async () => assert.ok(await keptPage("/s/blog/p/hello-world/"), "not kept"), "a page kept by the worker");
    // Offline: the page again, from what the worker kept, and the program
    // started on it from the application's files the worker kept. The demo's
    // wiki is in the browser, so it says nothing of an offline copy.
    await offlineContext.setOffline(true);
    await reader.reload();
    await reader.locator("#app .wiki-content h1", { hasText: "Hello" }).waitFor({ timeout });
    await eventually(async () => assert.ok(await programStarted(reader), "no listener yet"), "the program starting offline");
    assert.equal(await reader.locator("#app .offline-copy").count(), 0, "the demo says it is an offline copy");
    // A page never read here: the worker's offline page, which lists the
    // pages it kept.
    await reader.goto(url("/s/docs/"));
    await reader.locator(".offline-page h1", { hasText: "This page is not available offline" }).waitFor({ timeout });
    await reader.locator(".offline-page .offline-pages a", { hasText: "Hello" }).click();
    await reader.locator("#app .wiki-content h1", { hasText: "Hello" }).waitFor({ timeout });
    await offlineContext.setOffline(false);
    await reader.goto(url("/s/docs/"));
    await reader.locator("#app .sidebar-space-name", { hasText: "Docs" }).waitFor({ timeout });
    assert.equal(await reader.locator(".offline-page").count(), 0, "the offline page, online");
    await offlineContext.close();
    console.log(`ok: the demo is installable under ${base} (a manifest and its icons, a service worker of that scope, nothing in the way by Chromium's check), and reads offline what it read, with an offline page for the rest`);
  }

  // ---- 5. The writing assistant, with the scripted provider --------------------

  // No provider can be reached from here, and no key is at hand: the page
  // gets the scripted provider the browser tests use
  // (wiki-app/jsbits/assistant.js), installed before the program starts,
  // as no page served to anyone has it. The providers' own island is
  // loaded all the same, to see that the bundle runs in a browser.
  {
    const writer = await newPage();
    await writer.addInitScript(() => {
      const model = (id, label, created) => ({ id, label, created });
      globalThis.wikiAssistantScript = {
        // The providers' lists of models, as the script answers for them.
        lists: {
          scripted: [model("claude-opus-5-5", "Claude Opus 5.5", 300), model("claude-sonnet-5-5", "Claude Sonnet 5.5", 250), model("claude-opus-4-8", "Claude Opus 4.8", 200)],
          anthropic: [model("claude-opus-5-5", "Claude Opus 5.5", 300), model("claude-haiku-4-5-20251001", "Claude Haiku 4.5", 100)],
        },
        turns: [
          [
            { thinking: "Weighing the heading.", wait: 1500 },
            { text: "Retitled. " },
            { tool: "replace", input: { old_text: "## Why a wiki", new_text: "## Why this is a wiki" }, pause: 1500 },
            { text: "Done." },
          ],
        ],
      };
    });
    await writer.goto(url("/"));
    await writer.locator("#app .directory h1", { hasText: "Spaces" }).waitFor({ timeout });
    await eventually(async () => assert.ok(await programStarted(writer), "no listener yet"), "the program starting");
    // The settings, from the user menu: the demo starts as admin.
    await writer.locator("#app .user-switcher-toggle").click();
    await writer.locator("#app .user-menu .assistant-settings-entry").click();
    await writer.locator("#app .assistant-settings h1", { hasText: "Writing assistant" }).waitFor({ timeout });
    assert.equal(await crumb(writer), "Writing assistant");
    await writer.locator("#app .assistant-intro", { hasText: "billed by its provider" }).waitFor({ timeout });
    assert.equal(await writer.locator("#app .assistant-insecure").count(), 0, "the demo, served from this machine, said it was not secure");
    assert.equal(
      await writer.evaluate(async () => typeof (await globalThis.wikiIslands.assistant()).startChat),
      "function",
      "the providers' island did not load",
    );
    await writer.locator("#app input[name='assistant-provider'][value='scripted']").check();
    await writer.locator("#app .assistant-provider-settings[data-provider='scripted'] .assistant-test").click();
    await writer.locator("#app .assistant-check-works").waitFor({ timeout });
    // A key for Claude, kept, its list of models fetched with it (from the
    // script, which answers for every provider on this page).
    const claude = writer.locator("#app .assistant-provider-settings[data-provider='anthropic']");
    await claude.locator(".assistant-key").fill("sk-ant-smoke");
    await claude.locator(".assistant-key-form button[type='submit']").click();
    await claude.locator(".assistant-listed", { hasText: "2 models fetched" }).waitFor({ timeout });
    // The scripted provider's default effort, high, for new conversations.
    const scriptedEffort = writer.locator("#app .assistant-provider-settings[data-provider='scripted'] .assistant-default-effort");
    assert.equal(await scriptedEffort.inputValue(), "medium", "the default effort is not medium");
    await scriptedEffort.selectOption("high");
    await eventually(async () => assert.equal(await scriptedEffort.isDisabled(), false), "the default effort kept");
    // The editor's panel: a message, the model's edit a tracked change in
    // the text, accepted.
    await writer.goto(url("/s/blog/p/hello-world/edit/"));
    await writer.locator(editorText).waitFor({ timeout });
    // The providers' bubbles over the text, with their logos: Claude's,
    // which has a key, not ChatGPT's, which has none; the scripted
    // provider's is there as the page has its script.
    await writer.locator("#app .editor-provider[data-provider='anthropic']").waitFor({ timeout });
    assert.equal(await writer.locator("#app .editor-provider[data-provider='anthropic']").getAttribute("title"), "Chat with Claude");
    assert.equal(await writer.locator("#app .editor-provider[data-provider='anthropic'] svg path").count(), 1, "Claude's bubble has no logo");
    assert.equal(await writer.locator("#app .editor-provider[data-provider='openai']").count(), 0, "ChatGPT has a bubble without a key");
    await writer.locator("#app .editor-provider[data-provider='scripted']").click();
    await writer.locator("#app .assistant-using", { hasText: "Scripted" }).waitFor({ timeout });
    // Its models, as its list has them, grouped.
    await writer.locator("#app .assistant-model-choice optgroup[label='All models']").waitFor({ state: "attached", timeout });
    assert.deepEqual(
      await writer.locator("#app .assistant-model-choice optgroup").evaluateAll((groups) => groups.map((g) => [g.label, [...g.children].map((o) => o.textContent)])),
      [
        ["Recommended", ["Claude Opus 5.5", "Claude Sonnet 5.5"]],
        ["All models", ["Claude Opus 4.8"]],
      ],
    );
    // The effort under the message starts at the settings' default; one
    // chosen there goes with the message.
    await eventually(async () => assert.equal(await writer.locator("#app .assistant-effort").inputValue(), "high"), "the chat's effort starting at the default");
    await writer.locator("#app .assistant-effort").selectOption("low");
    await writer.locator("#app .assistant-input").fill("Retitle the second heading.");
    await writer.locator("#app .assistant-send").click();
    // While the model works: "Thinking" with its summary, then the status
    // of the edit it is writing.
    await writer.locator("#app .assistant-message.from-model .assistant-thinking", { hasText: "Thinking" }).waitFor({ timeout });
    await writer.locator("#app .assistant-message.from-model .assistant-thinking-text", { hasText: "Weighing the heading." }).waitFor({ state: "attached", timeout });
    await writer.locator("#app .assistant-message.from-model .assistant-status", { hasText: "Editing the page" }).waitFor({ timeout });
    await writer.locator("#app .cm-wiki-inserted", { hasText: "## Why this is a wiki" }).waitFor({ timeout });
    await writer.locator("#app .cm-wiki-removed", { hasText: "## Why a wiki" }).waitFor({ timeout });
    await writer.locator("#app .assistant-message.from-model .assistant-text", { hasText: "Retitled. Done." }).waitFor({ timeout });
    // The time of each message, and how long the answer took.
    await writer.locator("#app .assistant-message.from-model .assistant-took").waitFor({ timeout });
    assert.equal(await writer.locator("#app .assistant-message .assistant-time").count(), 2, "a message without its time");
    await writer.locator("#app .assistant-accept-all").click();
    await writer.locator("#app .cm-wiki-inserted").waitFor({ state: "detached", timeout });
    assert.match(await markdownIn(writer), /\n## Why this is a wiki\n/);
    assert.equal(
      await writer.evaluate(() => globalThis.wikiAssistantScript.requests[0].request.output_config.effort),
      "low",
      "the effort chosen did not go with the message",
    );
    // Close, in the panel's header.
    await writer.locator("#app .assistant-head .assistant-close", { hasText: "Close" }).click();
    await writer.locator("#app .editor-assistant").waitFor({ state: "hidden", timeout });
    await writer.context().close();
    console.log("ok: the assistant's settings, a key kept with its list of models, a default effort, its providers' bubbles and its panel, with the scripted provider: its models grouped, the effort starting at the default and the one chosen sent, Thinking and the edit's status while the model works, the times of the messages, an edit tracked in the text and accepted, Close; the providers' island loads");
  }
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
