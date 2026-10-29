// Take the README's screenshots from the built demo, in headless Chromium,
// so that they can be taken again whenever the wiki's look changes:
//
//   npm run screenshots                  # after: npm run build-wasm
//   node toolchain/screenshots.mjs [dir] [out]
//                                        # default dist-newstyle/wasm/public/app
//                                        # and docs/screenshots
//
// It serves the built page as a static host does (as toolchain/smoke-test.mjs
// does, under the base path the build was made for, read from its
// <base href>), opens each view at a fixed size, 1280 by 800 at a device
// scale of 1, in the light scheme (the administration in the dark one
// too), waits until the libraries have drawn what
// the view shows (KaTeX's formulas and fonts, Mermaid's diagrams,
// highlight.js's colours, CodeMirror), and writes a PNG of the window:
//
//   page.png     the Markdown guide at its Mathematics section: formulas and,
//                under them, a diagram
//   editor.png   the editor on the Mathematics page, the preview beside it
//   slides.png   the Presentations deck at its slide of formulas
//   spaces.png   the front page, the directory of spaces
//   admin-users.png, admin-users-dark.png
//                the administration's users, with a few more users made
//                in it, in the light and the dark scheme
//   admin-dialog.png, admin-dialog-dark.png
//                the same with a user's "Manage" dialog open
//   admin-remove.png, admin-remove-dark.png
//                a disabled user's dialog, asking to remove the account,
//                the login typed
//
// The README shows them, and a test of wiki-app (Test.Readme) checks that
// each is under 300 KB; so does this script, which fails on one that is not.
// Needs no network: the demo's photograph on Wikimedia Commons is answered
// with a stand-in, as the smoke test does, though no view shows it.
import { readFile, stat, mkdir, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { chromium } from "playwright";

const root = resolve(process.argv[2] ?? "dist-newstyle/wasm/public/app");
const out = resolve(process.argv[3] ?? "docs/screenshots");
const limit = 300 * 1024;
const timeout = 60_000;

const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".json": "application/json",
  ".gz": "application/gzip",
  ".bin": "application/octet-stream",
  ".webmanifest": "application/manifest+json",
};

// The base path the build was made for (HALOGEN_BASE_PATH), which every
// address of the page is under.
const index = await readFile(join(root, "index.html"), "utf8").catch(() => {
  console.error(`no built page in ${root}: run npm run build-wasm first`);
  process.exit(1);
});
const base = index.match(/<base href="([^"]*)">/)?.[1] ?? "/";

// A static server, as Pages is: a directory's address serves its index.html,
// and an address with no file serves 404.html.
const server = createServer(async (request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, "http://x").pathname);
  if (!pathname.startsWith(base)) {
    response.writeHead(404).end();
    return;
  }
  const path = `/${pathname.slice(base.length)}`;
  const file = join(root, normalize(path.endsWith("/") ? `${path}index.html` : path));
  try {
    if ((await stat(file)).isDirectory()) {
      response.writeHead(301, { location: `${pathname}/` }).end();
      return;
    }
    response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
    response.end(await readFile(file));
  } catch {
    response.writeHead(404, { "content-type": "text/html" });
    response.end(await readFile(join(root, "404.html")).catch(() => ""));
  }
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const url = (path) => `http://127.0.0.1:${server.address().port}${base}${path.replace(/^\//, "")}`;

// A 32×32 PNG, standing in for the demo's photograph.
const standIn = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAASklEQVR42mP48OUXTRHDCLDAJHUJHjRqwagFI8MCZFTR1ANENMzJoxbQyQKIKeShwWQBqeX+sLeAvPKAGF2jFoxaMHQsGG384kYAzNSeSHKJ2CAAAAAASUVORK5CYII=",
  "base64",
);

const browser = await chromium.launch();
const problems = [];

// A window of the fixed size, in a context of its own, so that each view
// starts from the demo as it is published (its content in a fresh IndexedDB,
// signed in as admin) and nothing one view did shows in another.
async function newPage(colorScheme = "light") {
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 1,
    colorScheme,
    reducedMotion: "reduce",
    serviceWorkers: "block",
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => problems.push(`page error at ${page.url()}: ${error.message}`));
  await page.route("https://upload.wikimedia.org/**", (route) =>
    /\.webm$/.test(route.request().url())
      ? route.fulfill({ status: 204 })
      : route.fulfill({ contentType: "image/png", body: standIn }),
  );
  return page;
}

// Wait until the fonts the page asked for have loaded, then for two frames,
// so that what the libraries drew last is on the screen.
async function settled(page) {
  await page.evaluate(async () => {
    await document.fonts.ready;
    await new Promise((frame) => requestAnimationFrame(() => requestAnimationFrame(frame)));
  });
}

// Every formula in an element set by KaTeX, none left as its source.
async function formulasSet(page, within) {
  await page.waitForFunction(
    (within) => {
      const formulas = [...document.querySelectorAll(`${within} .wiki-math`)];
      return formulas.length > 0 && formulas.every((f) => f.querySelector(".katex"));
    },
    within,
    { timeout },
  );
}

async function shoot(page, name, { close = true } = {}) {
  await settled(page);
  const file = join(out, name);
  await writeFile(file, await page.screenshot({ type: "png" }));
  const size = (await stat(file)).size;
  const kb = Math.round(size / 1024);
  if (size >= limit) problems.push(`${name} is ${kb} KB, over ${limit / 1024} KB`);
  console.log(`${name}: ${kb} KB`);
  if (close) await page.context().close();
}

// The users the administration's screenshots add to the demo's three, made
// with its "New user" form, so that the table looks like a wiki's.
const moreUsers = [
  ["bea", "Bea Builder", true],
  ["carl", "Carl Coder", false],
  ["dora", "Dora Designer", false],
  ["eve", "Eve Operations", false],
];

// The administration's users, and a user's dialog, in a colour scheme.
async function administration(colorScheme, suffix) {
  const page = await newPage(colorScheme);
  await page.goto(url("/admin/users/"));
  await page.locator("#app .user-row").first().waitFor({ timeout });
  for (const [login, name, administrator] of moreUsers) {
    await page.locator("#app .user-create-open").click();
    await page.locator("#app .user-create-login").fill(login);
    await page.locator("#app .user-create-name").fill(name);
    await page.locator("#app .user-create-password").fill(`${login}'s password`);
    if (administrator) await page.locator("#app .user-create-administrator input").check();
    await page.locator("#app .user-create button.primary").click();
    await page.locator(`#app .user-row[data-login=${login}]`).waitFor({ timeout });
  }
  // Dora's login disabled, from her dialog, which asks first.
  await page.locator("#app .user-row[data-login=dora] .user-manage").click();
  await page.locator("#app .user-dialog .disable-toggle").click();
  await page.locator("#app .user-dialog .disable-confirm-button").click();
  await page.locator("#app .user-row[data-login=dora].user-disabled").waitFor({ timeout });
  await page.keyboard.press("Escape");
  await page.locator("#app .user-dialog").waitFor({ state: "detached", timeout });
  await page.mouse.move(1270, 790);
  await shoot(page, `admin-users${suffix}.png`, { close: false });
  // Dora's dialog again, asking to remove her account, her login typed.
  await page.locator("#app .user-row[data-login=dora] .user-manage").click();
  await page.locator("#app .user-dialog .user-remove").click();
  await page.locator("#app .user-dialog .remove-confirm-login").fill("dora");
  await page.locator("#app .user-dialog .remove-confirm-button:not([disabled])").waitFor({ timeout });
  await page.locator("#app .user-dialog").evaluate((dialog) => {
    for (const e of [dialog, dialog.querySelector(".user-dialog-body")]) e.scrollTop = e.scrollHeight;
  });
  await shoot(page, `admin-remove${suffix}.png`, { close: false });
  await page.keyboard.press("Escape");
  await page.locator("#app .user-dialog").waitFor({ state: "detached", timeout });
  // Edgar's dialog: in a group, creating spaces, no password yet.
  await page.locator("#app .user-row[data-login=editor] .user-manage").click();
  await page.locator("#app .user-dialog[data-login=editor] .user-dialog-groups").waitFor({ timeout });
  await page.locator("#app .user-dialog").evaluate((dialog) => dialog.querySelector("button")?.blur());
  await shoot(page, `admin-dialog${suffix}.png`);
}

try {
  await mkdir(out, { recursive: true });

  // A page with formulas and a diagram: the Markdown guide, scrolled to its
  // Mathematics section, under which is the Diagrams section's flowchart.
  const page = await newPage();
  await page.goto(url("/s/docs/p/markdown-guide/"));
  await formulasSet(page, "#app .page-body");
  await page.locator("#app .page-body .wiki-mermaid > svg").first().waitFor({ timeout });
  await page.locator("#app .page-body .wiki-code code.hljs").first().waitFor({ timeout });
  await page.waitForFunction(() => document.fonts.check('16px "KaTeX_Main"'), null, { timeout });
  await page.evaluate(() => {
    const heading = document.getElementById("mathematics");
    heading.scrollIntoView({ block: "start" });
    // Then below whatever stays at the top of the window as it scrolls (the
    // header, the page's actions), with a little room above, or less room
    // where that keeps the whole of the diagram under it in the window.
    const stuck = [...document.querySelectorAll("#app *")]
      .filter((e) => ["sticky", "fixed"].includes(getComputedStyle(e).position))
      .map((e) => e.getBoundingClientRect())
      .filter((r) => r.top < 200 && r.width > window.innerWidth / 3)
      .reduce((bottom, r) => Math.max(bottom, r.bottom), 0);
    window.scrollBy(0, heading.getBoundingClientRect().top - stuck - 16);
    const diagram = document.querySelector("#app .page-body .wiki-mermaid > svg").getBoundingClientRect();
    const below = diagram.bottom - (window.innerHeight - 12);
    if (below > 0) window.scrollBy(0, Math.min(below, heading.getBoundingClientRect().top - stuck));
  });
  await shoot(page, "page.png");

  // The editor, with the preview beside the Markdown: "Side by side
  // preview", which a wide window offers.
  const editor = await newPage();
  await editor.goto(url("/s/docs/p/markdown-guide/mathematics/edit/"));
  await editor.locator("#app .editor-cm .cm-content").waitFor({ timeout });
  await editor.locator("#app .editor-side-by-side input").check();
  await editor.locator("#app .editor-preview .wiki-math .katex").first().waitFor({ timeout });
  await formulasSet(editor, "#app .editor-preview");
  await shoot(editor, "editor.png");

  // A deck, at its third slide: a formula inline and one on its own.
  const deck = await newPage();
  await deck.goto(url("/s/docs/p/markdown-guide/presentations/slides/?slide=3"));
  await deck.locator("#app .slide-frame.current .wiki-math-display .katex-display").waitFor({ timeout });
  await formulasSet(deck, "#app .slide-frame.current");
  await deck.mouse.move(640, 400);
  await shoot(deck, "slides.png");

  // The front page: the directory of spaces, as a newcomer sees it.
  const front = await newPage();
  await front.goto(url("/"));
  await front.locator("#app .space-card").first().waitFor({ timeout });
  await front.waitForLoadState("networkidle");
  await shoot(front, "spaces.png");

  // The administration's users and a user's dialog, light and dark.
  await administration("light", "");
  await administration("dark", "-dark");
} catch (error) {
  problems.push(error.stack ?? String(error));
} finally {
  await browser.close();
  server.close();
}

if (problems.length > 0) {
  console.error(`screenshots failed:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}
console.log(`ok: the README's screenshots are in ${out}`);
