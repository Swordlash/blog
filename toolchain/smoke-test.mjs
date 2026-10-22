// Drive the built application in headless Chromium: the page arrives with the
// component prerendered into it, app.wasm loads and mounts the component in
// its place, and a click reaches it.
//
//   npm run smoke-test                      # after: npm run build-wasm
//   node toolchain/smoke-test.mjs [dir]     # default dist-newstyle/wasm/public/app
//
// This is what the unit tests cannot see: the size-optimised app.wasm loading
// in a real browser and its event handlers running. Needs the Chromium that
// Playwright's version in package-lock.json launches (toolchain/bootstrap.sh
// installs it). index.js loads @bjorn3/browser_wasi_shim from jsDelivr; the
// test serves it from node_modules instead, the same version, so that it needs
// no network.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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
};

// A static server, as Pages is: a directory's address serves its index.html.
const server = createServer(async (request, response) => {
  const path = decodeURIComponent(new URL(request.url, "http://x").pathname);
  const file = join(root, normalize(path.endsWith("/") ? `${path}index.html` : path));
  try {
    const body = await readFile(file);
    response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
    response.end(body);
  } catch {
    response.writeHead(404).end();
  }
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const url = `http://127.0.0.1:${server.address().port}/`;

const timeout = 30_000;
const browser = await chromium.launch();
const failures = [];
try {
  // The page as a server sends it, before any script runs: the component is
  // in it already.
  const html = await (await fetch(url)).text();
  assert.match(html, /<div id="app"><main><h1>Wiki<\/h1>/, "index.html is not prerendered");
  assert.match(html, />Clicked 0 times<\/button>/, "index.html has no counter");
  console.log("ok: index.html arrives with the component prerendered");

  const page = await browser.newPage();
  page.on("pageerror", (error) => failures.push(`page error: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") failures.push(`console error: ${message.text()}`);
  });
  await page.route("https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@*/dist/**", async (route) => {
    const file = new URL(route.request().url()).pathname.replace(/^.*\/dist\//, "");
    await route.fulfill({
      contentType: "text/javascript",
      body: await readFile(join(shimDir, normalize(file))),
    });
  });

  // app.wasm is held back until the prerendered button is marked, so that the
  // button found afterwards without the mark is the one the program rendered.
  let releaseWasm;
  const wasmHeld = new Promise((release) => (releaseWasm = release));
  await page.route("**/app.wasm", async (route) => {
    await wasmHeld;
    await route.continue();
  });

  await page.goto(url, { waitUntil: "commit" });
  const prerendered = page.locator("#app button");
  await prerendered.waitFor({ timeout });
  await prerendered.evaluate((button) => (button.dataset.prerendered = "true"));
  releaseWasm();

  const button = page.locator("#app button:not([data-prerendered])");
  await button.waitFor({ timeout });
  assert.equal(await page.locator("#app button").count(), 1, "the prerendered button was not replaced");
  assert.equal(await page.locator("#app h1").textContent(), "Wiki");
  console.log("ok: app.wasm mounts the component in place of the prerendered one");

  for (const n of [1, 2]) {
    await button.click();
    await page.locator("#app button", { hasText: `Clicked ${n} times` }).waitFor({ timeout });
  }
  console.log("ok: clicking the button counts");
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
