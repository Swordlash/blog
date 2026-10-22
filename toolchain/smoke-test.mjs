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
// in a real browser on every page the build wrote, in place of the page
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
//    seen and marked; then the program has to replace it with the same
//    route: the same title, heading and error, if any, and the same footer.
// 2. One long walk in one page, as someone would take it: the front page,
//    every root space and a page in each, the editor as admin with a save,
//    search, then back through the whole history and forward again, each
//    step checked by its address and what is on screen. Then leaving the
//    editor with changes by the back button (Stay, then Leave), a reload,
//    and 404.html for an address with no file.
// 3. The same page in a dark scheme and at a phone's width.
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

// Go to an address and wait for the program to have replaced the page
// prerendered there, which is returned as it was shown.
async function load(page, path) {
  let release;
  page.gate = new Promise((go) => (release = go));
  await page.goto(url(path), { waitUntil: "commit" });
  const prerendered = page.locator("#app .wiki");
  await prerendered.waitFor({ timeout });
  const before = await shown(page);
  await prerendered.evaluate((shell) => (shell.dataset.prerendered = "true"));
  release();
  page.gate = null;
  await page.locator("#app .wiki:not([data-prerendered])").waitFor({ timeout });
  assert.equal(await page.locator("#app .wiki").count(), 1, `${path}: the prerendered shell is still there`);
  return before;
}

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

// A link clicked while the shell is still reloading the wiki for someone
// just switched to is now and then followed by the browser, loading the page
// afresh (and so starting the demo over): Halogen.Router's link stops the
// browser in the click's handler, and that handler, then, now and then runs
// only after the browser has gone on. A person does not click that fast; the
// test waits as long as one would. (About one click in twenty made at once
// after a switch was followed, none made 100 ms after it.)
const settleAfterSwitch = (page) => page.waitForTimeout(300);

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
  assert.ok(paths.length >= 10, `only ${paths.length} pages were prerendered`);
  for (const path of ["/", "/search/", "/s/docs/", "/s/docs/p/tour/", "/s/team/p/team-handbook/"]) {
    assert.ok(paths.includes(path), `${path} was not prerendered`);
  }
  const visitor = await newPage();
  for (const path of paths) {
    // As a server sends it, before any script runs.
    const html = await (await fetch(url(path))).text();
    assert.match(html, /<base href="\/">/, `${path}: no <base href>`);
    assert.match(html, /<div id="app"><div class="wiki">/, `${path}: not prerendered`);
    assert.ok(html.includes(footerHtml), `${path}: no footer prerendered`);
    const before = await load(visitor, path);
    if (path !== "/") assert.notEqual(before.title, "Wiki", `${path}: no title of its own`);
    // The program shows the same route, once it has loaded what it shows.
    await eventually(async () => assert.deepEqual(await shown(visitor), before), `${path}: the program shows another page`);
    await footerShown(visitor, path);
    if (process.env.SMOKE_DEBUG) console.log(path, JSON.stringify(before));
  }
  console.log(`ok: each of the ${paths.length} prerendered pages is replaced by the program, showing the same, footer included`);

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
  console.log("ok: a page's islands are drawn: KaTeX, Mermaid, highlight.js");
  await visitor.context().close();

  // ---- 2. A walk through the demo, in one page -------------------------------

  const page = await newPage();
  await load(page, "/");
  // No click from here on may load a page: a mark on the window would go.
  await page.evaluate(() => (window.stillTheSamePage = true));
  const samePage = async (step) => assert.ok(await page.evaluate(() => window.stillTheSamePage), `${step} loaded a page`);

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

  // Who one is, from the menu at the top right: admin sees every space.
  await page.locator("#app .user-switcher-toggle").click();
  await page.locator("#app .user-menu button[data-login=admin]").click();
  await page.locator("#app .user-switcher-toggle", { hasText: "Ada Admin" }).waitFor({ timeout });
  await page.locator("#app .wiki-sidebar a[href='/s/team/']").waitFor({ timeout });
  await settleAfterSwitch(page);

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

  // A reload starts the demo over, on the same page: as nobody, and with
  // the edit gone.
  await page.locator("#app .wiki-sidebar a[href='/s/blog/']").click();
  await page.locator("#app .space-view .page-tree a[href='/s/blog/p/hello-world/']").click();
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", text: "Smoke test" }, "the edited page");
  await page.reload();
  await page.waitForFunction(() => window.stillTheSamePage === undefined, null, { timeout });
  await page.locator("#app .wiki:not([data-prerendered])").waitFor({ timeout });
  await check({ path: "/s/blog/p/hello-world/", view: "page-view", crumb: "Hello, world" }, "the reload");
  await page.locator("#app .user-switcher-toggle", { hasText: "Not signed in" }).waitFor({ timeout });
  assert.ok(!(await page.locator("#app .page-body").textContent()).includes("Smoke test"), "the edit survived a reload");
  console.log("ok: a reload arrives at the same page, with the demo started over");

  // An address with no file: 404.html, which the program reads as its own.
  const missing = await fetch(url("/no/such/address/"));
  assert.equal(missing.status, 404);
  assert.ok((await missing.text()).includes(footerHtml), "404.html has no footer");
  await load(page, "/no/such/address/");
  await check({ path: "/no/such/address/", view: "not-found" }, "an address the wiki does not have");
  await footerShown(page, "404.html");
  // An editor's address has no page of its own either; the program opens it.
  assert.equal((await fetch(url("/s/blog/p/hello-world/edit/"))).status, 404);
  await load(page, "/s/blog/p/hello-world/edit/");
  await check({ path: "/s/blog/p/hello-world/edit/", view: "editor", crumb: "Edit" }, "an editor's address");
  await page.locator("#app .editor .sign-in-hint").waitFor({ timeout });
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
  await dark.emulateMedia({ colorScheme: "light" });
  const day = await colours(dark);
  assert.ok(luminance(day.background) > 0.75, `a light scheme's background is ${day.background}`);
  assert.ok(luminance(day.text) < 0.4, `a light scheme's text is ${day.text}`);
  await dark.context().close();
  console.log("ok: a page follows the dark scheme, and the light one");

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
  await settleAfterSwitch(phone);
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
  await phone.context().close();
  console.log("ok: a page and the editor fit a phone's width");
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
