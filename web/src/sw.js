// The wiki's service worker (WP4.17 of docs/PLAN.md): it keeps the
// application's files and the last pages read in the browser's Cache API,
// and serves them when the network is gone, so that a page read here can be
// read again offline and the wiki can be installed as an application.
//
// web/bundle.sh writes it into the build as sw.js, with the build's version
// and the list of the application's files put in place of the two names in
// capitals below (web/src/pwa.mjs). A new build is a new worker, which the
// browser installs beside the old one; once it is active it deletes the
// caches of every other version, pages read under the old one included, so
// that what it serves offline is always of one build.
//
// What it does with each request of the page, below its scope (the place the
// wiki is served at, where sw.js is):
//
// - The application's files (the program, its scripts, styles and fonts):
//   from the network, as without a worker, and from the cache when there is
//   no network. The listed ones are fetched when the worker is installed, the
//   rest the first time they are used (Mermaid's diagrams, TikZ).
// - A page (a navigation): from the network, kept as the last answer for its
//   address; offline, the kept answer, marked as an offline copy with the
//   time it was kept (<meta name="wiki-offline-copy">, which the program
//   reads, Wiki.App.Offline), or, for an address never read here, the
//   wiki's offline page (web/offline.html), listing the pages that can be
//   read offline. The last READ_LIMIT pages are kept, the oldest let go.
// - A read of the API (GET api/v1/...): likewise from the network, kept, and
//   answered from what was kept when there is no network, so that a page
//   followed by a link offline can be shown from what was read of it; an
//   attachment or a space's icon only if it is an image of at most
//   IMAGE_LIMIT bytes. Never kept, and left to the network as without a
//   worker: who is asking (api/v1/session), the administration
//   (api/v1/admin/...), one's account and notifications
//   (api/v1/account/..., api/v1/notifications...), drafts, exports and the
//   wiki's archive, invitations, password resets, mail links, the live
//   channel (api/v1/events) and signing in with a provider (auth/...).
//
// Writes (anything but GET and HEAD) are never touched: offline they fail
// as they would without a worker, and the editor says so.
//
// Signing out deletes the pages and the API's answers kept (from the page,
// Wiki.App.Offline.forgetReads), since they were read as whoever was signed
// in. They are the browser profile's, as everything a site keeps is.

const VERSION = "__WIKI_VERSION__";
const PRECACHE = __WIKI_PRECACHE__;

// How many pages, and API answers, are kept: the last read, oldest out.
const READ_LIMIT = 50;
const ANSWER_LIMIT = 300;
// The largest image kept, in bytes.
const IMAGE_LIMIT = 1024 * 1024;
// The header a kept answer carries with the time it was kept.
const KEPT_AT = "X-Wiki-Kept-At";

const scope = self.registration.scope;
// One wiki's caches apart from another's on the same origin (one served
// under another path), and each build's apart from the others'.
const cacheName = (kind) => `wiki-${kind} ${VERSION} ${scope}`;
const APP = cacheName("app");
const PAGES = cacheName("pages");
const ANSWERS = cacheName("answers");
const ours = (name) => name.startsWith("wiki-") && name.endsWith(` ${scope}`);

// The API's addresses that are never kept, below api/v1/.
const unkept = [
  /^session(\/|$)/,
  /^admin(\/|$)/,
  /^account(\/|$)/,
  /^notifications(\/|$)/,
  /^events$/,
  /^archive(\/|$)/,
  /^invitations(\/|$)/,
  /^password-reset(\/|$)/,
  /^email-verification(\/|$)/,
  /^unsubscribe(\/|$)/,
  /^pages\/[^/]+\/draft$/,
  /^(pages|spaces)\/[^/]+\/export(\/|$)/,
];
// An attachment's bytes and a space's icon: kept only if a small image.
const blobs = [/^attachments\//, /^spaces\/[^/]+\/icon\//];

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(APP);
      // Each file revalidated rather than taken from the HTTP cache as it
      // is, which may still hold the last build's.
      await cache.addAll(PRECACHE.map((path) => new Request(new URL(path, scope), { cache: "no-cache" })));
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const current = [APP, PAGES, ANSWERS];
      for (const name of await caches.keys()) {
        if (ours(name) && !current.includes(name)) await caches.delete(name);
      }
      // The pages open now are served by this worker from here on, so that
      // what they read next is kept.
      await self.clients.claim();
    })(),
  );
});

// A page loaded before this worker served it (the first visit, which
// installed it) asks for itself to be kept, which its own load was not
// (web/index.js).
self.addEventListener("message", (event) => {
  const message = event.data;
  if (message?.type === "keep-page" && typeof message.url === "string") {
    const url = new URL(message.url);
    if (url.origin === self.location.origin && url.href.startsWith(scope)) {
      event.waitUntil(
        fetch(url, { credentials: "same-origin" })
          .then((response) => keepPage(url.href, response))
          .catch(() => {}),
      );
    }
  }
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || request.headers.has("range")) return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin || !url.href.startsWith(scope)) return;
  const path = url.pathname.slice(new URL(scope).pathname.length);
  if (path.startsWith("auth/")) return;
  if (request.mode === "navigate") {
    event.respondWith(page(event, request));
  } else if (path.startsWith("api/v1/")) {
    const endpoint = path.slice("api/v1/".length);
    if (unkept.some((pattern) => pattern.test(endpoint))) return;
    event.respondWith(answer(event, request, blobs.some((pattern) => pattern.test(endpoint))));
  } else {
    event.respondWith(file(event, request));
  }
});

// A page: the network's answer, kept; offline, the copy kept or the
// offline page.
async function page(event, request) {
  try {
    const response = await fetch(request);
    event.waitUntil(keepPage(request.url, response.clone()).catch(() => {}));
    return response;
  } catch (error) {
    const pages = await caches.open(PAGES);
    const kept = await pages.match(request, { ignoreVary: true });
    if (kept) return offlineCopy(kept);
    const offline = await caches.match(new URL("offline.html", scope).href, { cacheName: APP });
    if (offline) return offlinePage(offline);
    throw error;
  }
}

// Keep a page's answer if it is the page itself: a 200 with HTML, not a
// redirect, and not one that asks to be kept nowhere.
async function keepPage(url, response) {
  if (response.status !== 200 || response.type !== "basic" || response.redirected) return;
  if (!(response.headers.get("content-type") ?? "").startsWith("text/html")) return;
  if (/no-store/.test(response.headers.get("cache-control") ?? "")) return;
  await keep(PAGES, url, response, READ_LIMIT);
}

// A read of the API: the network's answer, kept if it is to be; offline,
// the answer kept, or the failure as it is.
async function answer(event, request, blob) {
  try {
    const response = await fetch(request);
    if (keepable(response, blob)) event.waitUntil(keep(ANSWERS, request.url, response.clone(), ANSWER_LIMIT).catch(() => {}));
    return response;
  } catch (error) {
    const kept = await (await caches.open(ANSWERS)).match(request, { ignoreVary: true });
    if (kept) return kept;
    throw error;
  }
}

function keepable(response, blob) {
  if (response.status !== 200 || response.type !== "basic") return false;
  if (/no-store/.test(response.headers.get("cache-control") ?? "")) return false;
  if (!blob) return true;
  const size = Number(response.headers.get("content-length") ?? NaN);
  return (response.headers.get("content-type") ?? "").startsWith("image/") && size <= IMAGE_LIMIT;
}

// One of the application's files: the network's answer, as without a
// worker, kept in place of the one kept if it differs; offline, the one
// kept.
async function file(event, request) {
  const cache = await caches.open(APP);
  try {
    const response = await fetch(request);
    if (response.status === 200 && response.type === "basic") {
      event.waitUntil(
        (async () => {
          const kept = await cache.match(request, { ignoreVary: true });
          const tag = response.headers.get("etag");
          if (!kept || tag === null || kept.headers.get("etag") !== tag) await cache.put(request, response.clone());
        })().catch(() => {}),
      );
    }
    return response;
  } catch (error) {
    const kept = await cache.match(request, { ignoreVary: true, ignoreSearch: true });
    if (kept) return kept;
    throw error;
  }
}

// Keep an answer under its address with the time it was kept, and let the
// oldest go beyond the limit.
async function keep(name, url, response, limit) {
  const headers = new Headers(response.headers);
  headers.set(KEPT_AT, new Date().toISOString());
  const body = await response.blob();
  const cache = await caches.open(name);
  await cache.put(url, new Response(body, { status: response.status, statusText: response.statusText, headers }));
  const keys = await cache.keys();
  if (keys.length > limit) {
    const dated = await Promise.all(keys.map(async (key) => [key, (await cache.match(key))?.headers.get(KEPT_AT) ?? ""]));
    dated.sort((a, b) => (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
    await Promise.all(dated.slice(0, keys.length - limit).map(([key]) => cache.delete(key)));
  }
}

// A kept page, marked as an offline copy with the time it was kept: the
// program reads the mark and says so (the server never writes it, so a page
// served online is adopted as it always was).
async function offlineCopy(kept) {
  const html = await kept.text();
  const at = escapeHtml(kept.headers.get(KEPT_AT) ?? "");
  const marked = html.replace(/<\/head>/i, `  <meta name="wiki-offline-copy" content="${at}">\n  </head>`);
  return new Response(marked, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

// The offline page, with the page's base (wherever it is shown, its links
// and styles are the wiki's) and the pages that can be read offline.
async function offlinePage(offline) {
  const html = await offline.text();
  const pages = await caches.open(PAGES);
  const listed = [];
  for (const key of await pages.keys()) {
    const kept = await pages.match(key);
    if (!kept) continue;
    const title = /<title>([^<]*)<\/title>/i.exec(await kept.text())?.[1] ?? key.url;
    listed.push({ url: key.url, title, at: kept.headers.get(KEPT_AT) ?? "" });
  }
  listed.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0));
  const items = listed.map((p) => `<li><a href="${escapeHtml(p.url)}">${p.title}</a></li>`).join("\n        ");
  const based = html
    .replace(/<base href="[^"]*">/i, "")
    .replace(/<head>/i, `<head>\n    <base href="${escapeHtml(scope)}">`)
    .replace("<!-- wiki-offline-pages -->", items === "" ? '<li class="offline-none">None yet.</li>' : items);
  return new Response(based, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

function escapeHtml(text) {
  return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}
