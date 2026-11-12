// Part 10 of the server's smoke test (toolchain/smoke-test-server.mjs):
// an encrypted space (WP5.74b2 and b3 of docs/PLAN.md) against the real
// server, in real browsers, on 127.0.0.1, which a browser treats as a
// secure page and so gives WebCrypto.
//
// - The administrator signs in through the form, which makes her key pair
//   in that browser, makes a space, and encrypts it with the permissions'
//   "Encrypt this space…" and its confirmation.
// - She writes a page through the forms: a first version, and a second
//   that no longer has the first's text. She reads the page back, and the
//   older text in its history.
// - A reader signs in in a browser of her own, is granted the space, and
//   waits for its key; the administrator's browser shares it when she next
//   opens the space; the reader then reads the page.
// - The administrator, in a browser that holds none of her keys (signed in
//   by her session's cookie alone), sees the space locked, and unlocks it
//   with her password in the space's own unlock form.
// - She attaches a file to the page in the editor, and comments on text
//   she selects in it; the reader reads both. They were written before
//   the key's renewal, and are read after it.
// - After the reader's removal, she makes a subspace from the encrypted
//   space's "New subspace", encrypted with a key of its own, writes a page
//   in it, and grants it alone to the reader removed, who reads the page
//   and not the space around it.
// - She exports the space through its "Export, decrypted here": her
//   browser decrypts the space and its subspace into an archive, which a
//   second server, on a fresh data directory of its own, imports through
//   its administration's merge import; every title, text, attachment
//   (name, type, bytes) and comment (text, quote, author's name) is there,
//   plain. The second server and what is sent to it are outside the
//   canary's watch: the export's plain text is the reader's to keep.
// - The canary (toolchain/smoke-canary.mjs): a marker in the title, the
//   text, the older version, a comment, the text it quotes, an
//   attachment's name and its bytes, and the title and text of the
//   subspace's page, is found nowhere in the data directory, the database,
//   any request the browsers sent or any answer or live channel's frame
//   they and the test received.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { assertNoCanary, marker, saw, watch } from "./smoke-canary.mjs";

export async function encryptedSpaces({ browser, url, origin, data, work, wikiServer, app, timeout, eventually, failures, admin, reader }) {
  const editorText = "#app .editor-cm .cm-content";
  const shown = [];
  const read = async (page) => shown.push(await page.locator("#app").innerText());

  // A browser of its own, watched by the canary, reporting what goes
  // wrong in it.
  const contextOf = async () => {
    const context = await browser.newContext({ serviceWorkers: "block" });
    watch(context);
    const page = await context.newPage();
    page.on("pageerror", (error) => failures.push(`page error at ${page.url()}: ${error.message}`));
    page.on("console", (message) => {
      if (message.type() === "error" && !/\b(401|404|409)\b/.test(message.text())) failures.push(`console error at ${page.url()}: ${message.text()}`);
    });
    return { context, page };
  };
  // Signed in through the header's form, which makes the user's key pair in
  // this browser at the first sign-in with a password.
  const signedIn = async (who) => {
    const { context, page } = await contextOf();
    await page.goto(url("/"));
    await page.locator("#app .sign-in-toggle").click();
    await page.locator("#app .sign-in-form input[name=login]").fill(who.login);
    await page.locator("#app .sign-in-form input[name=password]").fill(who.password);
    await page.locator("#app .sign-in-form button[type=submit]").click();
    await page.locator("#app .sign-out").waitFor({ timeout });
    const cookie = (await context.cookies()).find((c) => c.name === "wiki_session")?.value;
    assert.ok(cookie, `${who.login}: no session cookie`);
    const me = await page.evaluate(() => fetch("/api/v1/session").then((r) => r.json()));
    // The key pair is made and kept after the sign-in shows: wait until
    // this browser holds its private half, or a page loaded meanwhile would
    // stop the keeping halfway.
    await eventually(
      async () =>
        assert.ok(
          await page.evaluate(
            (slot) =>
              new Promise((done) => {
                const opened = indexedDB.open("wiki-assistant-keys", 1);
                opened.onupgradeneeded = () => opened.result.createObjectStore("keys");
                opened.onsuccess = () => {
                  const got = opened.result.transaction("keys", "readonly").objectStore("keys").get(slot);
                  got.onsuccess = () => done(got.result instanceof CryptoKey);
                  got.onerror = () => done(false);
                };
                opened.onerror = () => done(false);
              }),
            `identity:${me.user.id}`,
          ),
          "no private key yet",
        ),
      `${who.login}'s key pair kept in the browser`,
    );
    return { context, page, cookie: `wiki_session=${cookie}`, id: me.user.id };
  };
  const as = (who) => async (path, init = {}) => {
    const response = await fetch(url(`/api/v1/${path}`), { ...init, headers: { "Content-Type": "application/json", "X-Wiki-Request": "1", Cookie: who.cookie, ...init.headers } });
    const bytes = Buffer.from(await response.arrayBuffer());
    saw(`the test's ${init.method ?? "GET"} ${path}`, bytes);
    return { status: response.status, body: bytes.length > 0 && response.headers.get("content-type")?.includes("json") ? JSON.parse(bytes.toString()) : null };
  };

  // ---- The space, encrypted through its permissions ------------------------

  const ada = await signedIn(admin);
  const page = ada.page;
  await page.locator("#app .wiki-sidebar .new-space-link").click();
  await page.locator("#app .new-space-view input").fill("Smoke secret");
  await page.locator("#app .new-space-view button.primary").click();
  await page.locator("#app .sidebar-space-name", { hasText: "Smoke secret" }).waitFor({ timeout });
  await page.locator("#app .space-pages-link").click();
  await page.locator("#app .space-settings-toggle").click();
  await page.locator("#app .space-permissions .encrypt-space").click();
  await page.locator("#app .space-permissions .encrypt-explained").waitFor({ timeout });
  await page.locator("#app .space-permissions .encrypt-confirm").click();
  await page.locator("#app .space-permissions .encrypted-note").waitFor({ timeout });
  const space = (await as(ada)("spaces/at/smoke-secret")).body;
  assert.ok(space.encryption, `the space is not encrypted: ${JSON.stringify(space)}`);
  console.log("ok: a space encrypted through its permissions' \"Encrypt this space…\" and its confirmation");

  // ---- A page in two versions ----------------------------------------------

  const title = marker("title");
  // A word the search looks for, which is no marker. The search page's
  // address carries its words, and loading it sends them to the server,
  // which searches the plain spaces with them: the server learns what a
  // reader searched for, though never the encrypted pages nor which of
  // them matched (the README's "What the server still sees"). A marker
  // searched for would be found there by the canary, rightly.
  const searchWord = `zebracrossing${Date.now()}`;
  // The space's address shows its home page, made with it in this browser;
  // its list of pages is under its settings.
  await page.goto(url("/s/smoke-secret/"));
  await page.locator("#app .page-view .page-body", { hasText: "Welcome to" }).waitFor({ timeout });
  await page.goto(url("/s/smoke-secret/pages/"));
  await page.locator("#app .space-view .actions a", { hasText: "New page" }).click();
  await page.locator("#app .new-page-title").pressSequentially(title);
  await page.locator("#app .new-page-view button.primary").click();
  const editor = page.locator(editorText);
  await editor.waitFor({ timeout });
  const saved = () => page.waitForResponse((r) => ["POST", "PUT"].includes(r.request().method()) && /\/api\/v1\/encrypted\/(spaces\/[^/]+\/pages|pages\/[^/]+)$/.test(new URL(r.url()).pathname), { timeout });
  await editor.press("Control+End");
  await editor.press("Enter");
  await editor.pressSequentially(`At first: ${marker("older version")}.`);
  // A file attached, an image: its name and bytes encrypted in the
  // browser. Its reference goes into this version, and the attachment
  // stays the page's after the next.
  const fileName = `${marker("attachment name")}.svg`;
  const fileBytes = `<svg xmlns="http://www.w3.org/2000/svg" width="7" height="1"><title>${marker("attachment bytes")}</title></svg>`;
  const uploaded = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/v1\/encrypted\/pages\/[^/]+\/attachments$/.test(new URL(r.url()).pathname), { timeout });
  await page.locator("#app .editor-attach input[type=file]").setInputFiles({ name: fileName, mimeType: "image/svg+xml", buffer: Buffer.from(fileBytes) });
  assert.equal((await uploaded).status(), 201, "the encrypted attachment's upload");
  await page.locator("#app .editor-attachments a", { hasText: fileName }).waitFor({ timeout });
  let answered = saved();
  await editor.press("Control+s");
  assert.ok((await answered).ok(), "the first save of the encrypted page");
  // The second version holds the title and a text of its own, and not the
  // first's. The editor keeps the title line's "# " (web/src/editor.js): a
  // selection of everything starts after it, so the title is typed alone.
  await editor.press("Control+a");
  await editor.pressSequentially(title);
  await editor.press("Enter");
  await editor.press("Enter");
  await editor.pressSequentially(`Now: ${marker("text")}, ${marker("quote")} and ${searchWord}.`);
  answered = saved();
  await editor.press("Control+s");
  assert.ok((await answered).ok(), "the second save of the encrypted page");
  const pageAddress = new URL(page.url()).pathname.replace(/edit\/$/, "");
  await page.goto(url(pageAddress));
  await page.locator("#app .page-view .page-body", { hasText: marker("text") }).waitFor({ timeout });
  await read(page);
  // The history compares the latest version with the one before, whose
  // text is the older marker.
  await page.locator("#app .page-view .actions a", { hasText: "History" }).click();
  await page.locator("#app .history-view", { hasText: marker("older version") }).waitFor({ timeout });
  await read(page);
  console.log("ok: a page of the encrypted space written in two versions, read back with its history");

  // ---- An attachment and a comment ----------------------------------------

  // The file attached in the editor, read back, decrypted, from the page.
  // The file behind an attachment's link on the page: the link leads to an
  // object URL of the bytes, decrypted, which an SVG's link downloads
  // (application/octet-stream), never opens as a document; downloaded as a
  // reader saves it, its bytes are the file's, which the canary's
  // read-back must find.
  const attachmentIn = async (p) => {
    const link = p.locator("#app .page-view .attachments a", { hasText: fileName });
    await link.waitFor({ timeout });
    await eventually(async () => assert.match((await link.getAttribute("href")) ?? "", /^blob:/), "the attachment's decrypted link");
    assert.equal(await link.getAttribute("download"), fileName, "the link's download name");
    const downloading = p.waitForEvent("download", { timeout });
    await link.click();
    const bytes = await readFile(await (await downloading).path(), "utf8");
    shown.push(bytes);
    return bytes;
  };
  await page.goto(url(pageAddress));
  assert.equal(await attachmentIn(page), fileBytes, "the attachment's bytes, decrypted");
  // Text selected on the page, commented on: the comment and the text it
  // quotes encrypted in the browser.
  const quote = marker("quote");
  await page.locator("#app .page-view .page-body", { hasText: quote }).waitFor({ timeout });
  await page.evaluate((wanted) => {
    const walker = document.createTreeWalker(document.querySelector("#app .page-body"), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      const at = node.data.indexOf(wanted);
      if (at < 0) continue;
      const range = document.createRange();
      range.setStart(node, at);
      range.setEnd(node, at + wanted.length);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      node.parentElement.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
      return;
    }
  }, quote);
  await page.locator("#app .comment-on-selection").click();
  await page.locator("#app .comments-panel .new-thread textarea").fill(marker("comment"));
  const commented = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/v1\/encrypted\/pages\/[^/]+\/threads$/.test(new URL(r.url()).pathname), { timeout });
  await page.locator("#app .comments-panel .new-thread button", { hasText: "Comment" }).click();
  assert.equal((await commented).status(), 201, "the encrypted comment");
  await page.locator("#app mark.comment-mark", { hasText: quote }).waitFor({ timeout });
  // The comment and its mark, read again from the server.
  const commentIn = async (p) => {
    await p.locator("#app mark.comment-mark", { hasText: quote }).waitFor({ timeout });
    await p.locator("#app .comments-toggle").click();
    await p.locator("#app .comments-panel", { hasText: marker("comment") }).waitFor({ timeout });
  };
  await page.reload();
  await commentIn(page);
  await read(page);
  console.log("ok: a file attached and a comment on selected text, encrypted in the browser, read back decrypted");

  // ---- A reader, given the key by a member's browser -----------------------

  const bea = await signedIn(reader);
  const granted = await as(ada)(`spaces/${encodeURIComponent(space.id)}/grants`, {
    method: "PUT",
    body: JSON.stringify({ subject: { tag: "SubjectUser", contents: bea.id }, permission: "View", granted: true }),
  });
  assert.equal(granted.status, 204, "granting the reader the space");
  await bea.page.goto(url("/s/smoke-secret/"));
  await bea.page.locator("#app .encrypted-state", { hasText: "no member has shared its key with you yet" }).waitFor({ timeout });
  // The administrator opens the space: her browser seals its key to the
  // reader.
  await page.goto(url("/s/smoke-secret/"));
  await page.locator("#app .page-view .page-body", { hasText: "Welcome to" }).waitFor({ timeout });
  await eventually(async () => {
    await bea.page.locator("#app .encrypted-retry").click();
    await bea.page.locator("#app .page-view .page-body", { hasText: "Welcome to" }).waitFor({ timeout: 2000 });
  }, "the reader given the key");
  await bea.page.goto(url(pageAddress));
  await bea.page.locator("#app .page-view .page-body", { hasText: marker("text") }).waitFor({ timeout });
  assert.equal(await attachmentIn(bea.page), fileBytes, "the attachment's bytes, decrypted for the reader");
  await commentIn(bea.page);
  await read(bea.page);
  console.log("ok: a reader granted the space waits for its key, and reads the page, its attachment and its comment once a member's browser has shared it");

  // ---- A browser without the keys, unlocked with the password --------------

  const { context: elsewhere, page: fresh } = await contextOf();
  await elsewhere.addCookies([{ name: "wiki_session", value: ada.cookie.replace(/^wiki_session=/, ""), url: origin }]);
  await fresh.goto(url(pageAddress));
  await fresh.locator("#app .encrypted-state", { hasText: "does not hold your keys" }).waitFor({ timeout });
  await fresh.locator("#app .encrypted-unlock input[name=encrypted-password]").fill(admin.password);
  await fresh.locator("#app .encrypted-unlock-password").click();
  await fresh.locator("#app .page-view .page-body", { hasText: marker("text") }).waitFor({ timeout });
  await read(fresh);
  console.log("ok: a browser without the keys shows the space locked, and the space's own form unlocks it with the password");

  // ---- A reader removed: a new key, and the pages read after ---------------

  // The administrator revokes the reader in the space's permissions: her
  // browser gives the space a new key at once, without the space being
  // opened again. The page nobody saved since stays under its older page
  // key, and is read, with its history, its attachment, its comment and
  // in the search, in a new browser's tab, and in the tab of the browser
  // opened before.
  await page.goto(url("/s/smoke-secret/pages/"));
  await page.locator("#app .space-settings-toggle").click();
  const rotated = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/v1\/encrypted\/spaces\/[^/]+\/rotation$/.test(new URL(r.url()).pathname), { timeout });
  await page.locator(`#app .grant-row[data-subject=${reader.login}] .grant-revoke`).click();
  assert.equal((await rotated).status(), 204, "the new key's rotation");
  const word = marker("text");
  const readsAfter = async (p, who) => {
    await p.goto(url("/s/smoke-secret/pages/"));
    await p.locator("#app .space-view", { hasText: title }).waitFor({ timeout });
    await p.goto(url(pageAddress));
    await p.locator("#app .page-view .page-body", { hasText: word }).waitFor({ timeout });
    assert.equal(await attachmentIn(p), fileBytes, `${who}: the attachment's bytes after the new key`);
    await commentIn(p);
    await p.locator("#app .page-view .actions a", { hasText: "History" }).click();
    await p.locator("#app .history-view", { hasText: marker("older version") }).waitFor({ timeout });
    await p.goto(url(`/search/?q=${encodeURIComponent(searchWord)}&space=smoke-secret`));
    await p.locator("#app .search-hits .search-hit-title", { hasText: title }).waitFor({ timeout });
    await read(p);
    console.log(`ok: after the new key, ${who} reads the page nobody saved since, its attachment, its comment, its history and its search`);
  };
  const { context: afterwards, page: newTab } = await contextOf();
  await afterwards.addCookies([{ name: "wiki_session", value: ada.cookie.replace(/^wiki_session=/, ""), url: origin }]);
  // A browser that holds none of her keys yet: unlocked first.
  await newTab.goto(url(pageAddress));
  await newTab.locator("#app .encrypted-unlock input[name=encrypted-password]").fill(admin.password);
  await newTab.locator("#app .encrypted-unlock-password").click();
  await newTab.locator("#app .page-view .page-body", { hasText: marker("text") }).waitFor({ timeout });
  await readsAfter(newTab, "a new browser");
  await readsAfter(fresh, "the browser opened before");
  await afterwards.close();

  // ---- A subspace, with a reader of its own ---------------------------------

  // Made after the reader's removal, so that no renewal of its key falls
  // due: made from the encrypted space's "New subspace", it is encrypted
  // with a key of its own, and its home page is made in her browser. Its
  // name is plain, as every space's; its pages' titles and texts are not.
  // From the space's list of pages, once it shows a title decrypted here
  // (the program runs): the form is the program's, not the page the
  // server rendered.
  await page.goto(url("/s/smoke-secret/pages/"));
  await page.locator("#app .space-view", { hasText: title }).waitFor({ timeout });
  await page.locator("#app .space-view .actions a", { hasText: "New subspace" }).click();
  await page.locator("#app .new-space-view input").fill("Smoke inner");
  const subspaceMade = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/v1\/encrypted\/spaces\/[^/]+\/subspaces$/.test(new URL(r.url()).pathname), { timeout });
  await page.locator("#app .new-space-view button.primary").click();
  assert.equal((await subspaceMade).status(), 201, "the encrypted subspace");
  const inner = (await as(ada)("spaces/at/smoke-secret/smoke-inner")).body;
  assert.ok(inner.encryption && inner.homePage && inner.encryption !== space.encryption, `the subspace is not encrypted with a key of its own: ${JSON.stringify(inner)}`);
  const innerTitle = marker("subspace title");
  await page.goto(url("/s/smoke-secret/smoke-inner/"));
  await page.locator("#app .page-view .page-body", { hasText: "Welcome to" }).waitFor({ timeout });
  await page.goto(url("/s/smoke-secret/smoke-inner/pages/"));
  await page.locator("#app .space-view .actions a", { hasText: "New page" }).click();
  await page.locator("#app .new-page-title").pressSequentially(innerTitle);
  await page.locator("#app .new-page-view button.primary").click();
  await editor.waitFor({ timeout });
  await editor.press("Control+End");
  await editor.press("Enter");
  await editor.pressSequentially(`Inside: ${marker("subspace text")}.`);
  answered = saved();
  await editor.press("Control+s");
  assert.ok((await answered).ok(), "the save of the subspace's page");
  const innerAddress = new URL(page.url()).pathname.replace(/edit\/$/, "");
  // The reader removed from the space is granted the subspace alone: the
  // administrator's browser shares its key when she opens it, and the
  // reader reads its page; the space around it stays closed to her.
  const innerGranted = await as(ada)(`spaces/${encodeURIComponent(inner.id)}/grants`, {
    method: "PUT",
    body: JSON.stringify({ subject: { tag: "SubjectUser", contents: bea.id }, permission: "View", granted: true }),
  });
  assert.equal(innerGranted.status, 204, "granting the reader the subspace");
  await page.goto(url("/s/smoke-secret/smoke-inner/pages/"));
  await page.locator("#app .space-view", { hasText: innerTitle }).waitFor({ timeout });
  await eventually(async () => {
    await bea.page.goto(url(innerAddress));
    await bea.page.locator("#app .page-view .page-body", { hasText: marker("subspace text") }).waitFor({ timeout: 3000 });
  }, "the subspace's reader given its key");
  await read(bea.page);
  assert.notEqual((await as(bea)("spaces/at/smoke-secret")).status, 200, "the reader of the subspace alone reads the space around it");
  console.log("ok: a subspace of the encrypted space is encrypted with a key of its own, and a reader of it alone reads its page and not the space around it");

  // ---- The export decrypted in the browser, imported elsewhere -------------

  // From the space's list of pages, once it shows a title decrypted here.
  // Her browser holds both keys, so nothing is left out.
  await page.goto(url("/s/smoke-secret/pages/"));
  await page.locator("#app .space-view", { hasText: title }).waitFor({ timeout });
  await page.locator("#app .space-view .export-decrypted").click();
  await page.locator("#app .export-decrypted-panel", { hasText: "older versions" }).waitFor({ timeout });
  const downloading = page.waitForEvent("download", { timeout });
  await page.locator("#app .export-decrypted-confirm").click();
  const download = await downloading;
  assert.match(download.suggestedFilename(), /^smoke-secret-decrypted-\d{4}-\d{2}-\d{2}\.zip$/, "the export's file name");
  const exported = await readFile(await download.path());
  const done = await page.locator("#app .export-decrypted-done").textContent({ timeout });
  assert.match(done, /4 pages of 2 spaces/, `the export's summary: ${done}`);
  assert.doesNotMatch(done, /Left out/, `the export left something out: ${done}`);
  const imported = await importedElsewhere(exported);
  try {
    const at = (path) => imported.get(path);
    const pagesOf = async (spacePath) => {
      const s = await at(`spaces/at/${spacePath}`);
      return { s, pages: await at(`spaces/${encodeURIComponent(s.id)}/pages`) };
    };
    const outer = await pagesOf("smoke-secret");
    assert.equal(outer.s.encryption ?? null, null, "the imported space is plain");
    const summary = outer.pages.find((p) => p.title === title);
    assert.ok(summary, `the page is not imported: ${JSON.stringify(outer.pages.map((p) => p.title))}`);
    const imp = await at(`spaces/${encodeURIComponent(outer.s.id)}/pages/at/${summary.slug}`);
    assert.ok(imp.body.includes(marker("text")) && imp.body.includes(quote), "the imported page's text");
    assert.deepEqual(imp.attachments.map((a) => [a.name, a.mediaType, a.size]), [[fileName, "image/svg+xml", Buffer.byteLength(fileBytes)]], "the imported attachment");
    assert.equal(await imported.bytes(`attachments/${encodeURIComponent(imp.attachments[0].id)}/${encodeURIComponent(fileName)}`), fileBytes, "the imported attachment's bytes");
    const threads = await at(`pages/${encodeURIComponent(imp.id)}/threads`);
    assert.deepEqual(
      threads.map((t) => [t.anchor?.exact, t.comments.map((c) => c.body)]),
      [[quote, [marker("comment")]]],
      "the imported comment and the text it quotes",
    );
    assert.match(threads[0].comments[0].author.name, /Ada Admin/, "the imported comment's author");
    const innerImported = await pagesOf("smoke-secret/smoke-inner");
    const innerSummary = innerImported.pages.find((p) => p.title === innerTitle);
    assert.ok(innerSummary, "the subspace's page is not imported");
    const innerPage = await at(`spaces/${encodeURIComponent(innerImported.s.id)}/pages/at/${innerSummary.slug}`);
    assert.ok(innerPage.body.includes(marker("subspace text")), "the imported subspace page's text");
  } finally {
    imported.stop();
  }
  console.log("ok: the space exported decrypted in the browser, and imported by a server on a fresh data directory, with its title, text, attachment, comment and subspace");

  // ---- What the server keeps and sends -------------------------------------

  for (const [who, cookie] of [
    ["the administrator", ada.cookie],
    ["the reader", bea.cookie],
    ["nobody", null],
  ]) {
    for (const path of [pageAddress, "/s/smoke-secret/", "/sitemap.xml"]) {
      const response = await fetch(url(path), { headers: cookie ? { Cookie: cookie } : {} });
      saw(`${path} as ${who}`, Buffer.from(await response.arrayBuffer()));
    }
  }
  const checked = await assertNoCanary({ data, shown: shown.join("\n") });
  console.log(`ok: none of ${checked.markers} markers of the encrypted space is in any of ${checked.places} files, requests and answers`);

  for (const c of [ada.context, bea.context, elsewhere]) await c.close();

  // A second server, on a fresh data directory beside the first's, always
  // on SQLite (the PostgreSQL run's database is the first server's, which
  // the canary dumps), with the archive imported through its admin
  // listener's merge import, which asks nobody to sign in. What it is sent
  // and answers is not watched: the plain text there is what the export
  // is for.
  async function importedElsewhere(archive) {
    const env = { ...process.env };
    delete env.WIKI_DATABASE_URL;
    const second = spawn(
      wikiServer,
      ["serve", "--data", join(work, "imported"), "--static", app, "--listen", "127.0.0.1:0", "--admin-listen", "127.0.0.1:0", "--no-guide"],
      { stdio: ["ignore", "pipe", "pipe"], env },
    );
    let log = "";
    const api = await new Promise((ready, fail) => {
      const read = (chunk) => {
        log += chunk;
        const match = log.match(/listener=admin address="?(http:\/\/[^\s"]+?)\/admin\/"?(\s|$)/m);
        if (match) ready(`${match[1]}/admin/api/v1`);
      };
      second.stdout.on("data", read);
      second.stderr.on("data", read);
      second.on("exit", (code) => fail(new Error(`the second wiki-server exited (${code}):\n${log}`)));
      setTimeout(() => fail(new Error(`the second wiki-server did not start:\n${log}`)), timeout).unref();
    });
    const stop = () => second.kill();
    try {
      const form = new FormData();
      form.append("archive", new Blob([archive], { type: "application/zip" }), "export.zip");
      form.append("choices", JSON.stringify({ skipSpaces: [], skipPages: [], conflicts: [] }));
      const applied = await fetch(`${api}/import/apply`, { method: "POST", headers: { "X-Wiki-Request": "1" }, body: form });
      const said = await applied.text();
      assert.equal(applied.status, 200, `the import of the export: ${said}`);
      assert.match(said, /"spacesCreated":2/, `the import's summary: ${said}`);
    } catch (error) {
      stop();
      throw error;
    }
    return {
      get: async (path) => {
        const response = await fetch(`${api}/${path}`);
        assert.equal(response.status, 200, `the second server's ${path}`);
        return response.json();
      },
      bytes: async (path) => {
        const response = await fetch(`${api}/${path}`);
        assert.equal(response.status, 200, `the second server's ${path}`);
        return Buffer.from(await response.arrayBuffer()).toString("utf8");
      },
      stop,
    };
  }
}
