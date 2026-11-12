// The server of encrypted spaces, played in the browser tests
// (Test.Browser.Encrypted) beside the test's server in fetch's place
// (test-fetch.js), as the vault's is (test-passkeys.js): the list of
// spaces, the directory of public keys, the starred pages, and the routes
// under encrypted/
// (Wiki.Api.Encrypted), with the server's rules for grants (only a holder
// of the key grants it, only to a reader with a current public key, and
// only the current key) and for saves (against the version read, as the
// next of the page's chain of versions). It stores what the browser sends
// and never reads it, as the real server.
// The user asking is the one the test names (wiki_test_encrypted_as).

const wikiTestEncrypted = { as: null, spaces: new Map(), directory: new Map(), pages: new Map(), next: 0, created: [], historyWithoutLatest: false };

function wikiTestEncJson(status, body, headers) {
  return { status, body: JSON.stringify(body), headers: headers ?? {} };
}

function wikiTestEncTag(time) {
  return `"${time}"`;
}

// A time a second later than the last, as the server's versions are.
function wikiTestEncNow() {
  wikiTestEncrypted.next++;
  return new Date(Date.UTC(2026, 10, 7, 9, 0, wikiTestEncrypted.next)).toISOString().replace(".000Z", "Z");
}

function wikiTestEncGrantOf(s, user) {
  const mine = wikiTestEncrypted.directory.get(user);
  return s.grants.find((g) => g.keyId === s.space.encryption && g.recipient === user && mine && g.recipientKeyId === mine.keyId) ?? null;
}

// Whether a rotation of the space's key is due: a grant of its current key
// to someone who is no longer a reader, or to a public key that is no
// longer theirs (Wiki.Server.Storage.Renewal).
function wikiTestEncDue(s) {
  return s.grants.some((g) => g.keyId === s.space.encryption && (!s.readers.includes(g.recipient) || wikiTestEncrypted.directory.get(g.recipient)?.keyId !== g.recipientKeyId));
}

const wikiTestEncRenewal = { error: "Conflict", text: "This space's key must be renewed before anything more is written in it: someone who held the key can no longer read the space. An administrator of the space who holds the key renews it by opening the space, and then this can be done again." };

function wikiTestEncSealed(p) {
  const latest = p.versions[p.versions.length - 1];
  return {
    id: p.id,
    space: p.space,
    parent: p.parent,
    slug: p.slug,
    createdAt: p.versions[0].updatedAt,
    updatedAt: latest.updatedAt,
    position: p.position,
    pageKey: p.pageKey,
    content: latest.content,
    createdBy: null,
    updatedBy: null,
    pageKeys: [p.pageKey, ...(p.olderKeys ?? [])],
  };
}

// A version's heading, as the lists of pages and of versions carry it.
function wikiTestEncHeading(content) {
  return { tag: content.tag, keyId: content.keyId, chain: content.chain, title: content.title };
}

// Whether a version's chain is the one the server takes on top of the
// latest version (null for a new page's first): the next number, naming the
// latest's tag (Wiki.Core.Encrypted's chainAfter).
function wikiTestEncFollows(chain, latest) {
  if (!chain) return false;
  if (latest === null) return chain.number === 1 && (chain.previous ?? null) === null;
  const number = latest.chain ? latest.chain.number + 1 : 1;
  return chain.number === number && chain.previous === latest.tag;
}

function wikiTestEncServer(request) {
  const url = request.url.replace(/^.*api\/v1\//, "");
  if (url === request.url) return null;
  const [path] = url.split("?");
  const header = (name) => Object.entries(request.headers).find(([k]) => k.toLowerCase() === name)?.[1];
  const me = wikiTestEncrypted.as;
  if (path === "spaces" && request.method === "GET") {
    return wikiTestEncJson(200, [...wikiTestEncrypted.spaces.values()].filter((s) => s.readers.includes(me)).map((s) => s.space));
  }
  if (path === "search" && request.method === "GET") return wikiTestEncJson(200, []);
  // Every page of the encrypted spaces the user reads, starred, with the
  // empty title the server lists for a page it holds only encrypted.
  if (path === "stars" && request.method === "GET") {
    const readable = [...wikiTestEncrypted.pages.values()].filter((p) => wikiTestEncrypted.spaces.get(p.space)?.readers.includes(me));
    return wikiTestEncJson(
      200,
      readable.map((p) => ({ page: p.id, space: p.space, title: "", location: { space: [wikiTestEncrypted.spaces.get(p.space).space.slug], page: [p.slug] } })),
    );
  }
  const spaceAt = path.match(/^spaces\/at\/([^/]+)$/);
  if (spaceAt && request.method === "GET") {
    const s = [...wikiTestEncrypted.spaces.values()].find((x) => x.space.slug === decodeURIComponent(spaceAt[1]));
    return s && s.readers.includes(me) ? wikiTestEncJson(200, s.space) : null;
  }
  let m = path.match(/^account\/public-keys\/([^/]+)$/);
  if (m && request.method === "GET") {
    const k = wikiTestEncrypted.directory.get(decodeURIComponent(m[1]));
    return k ? wikiTestEncJson(200, { user: decodeURIComponent(m[1]), keyId: k.keyId, publicKey: k.publicKey, createdAt: "2026-11-07T09:00:00Z" }) : wikiTestEncJson(404, { error: "NotFound" });
  }
  // The plain routes of an encrypted space's pages refuse, as the server's
  // do, so that the backend reads them through the encrypted routes.
  const plain = path.match(/^spaces\/([^/]+)\/pages/) ?? path.match(/^pages\/([^/]+)/);
  if (plain) {
    const id = decodeURIComponent(plain[1]);
    const s = wikiTestEncrypted.spaces.get(id) ?? wikiTestEncrypted.spaces.get(wikiTestEncrypted.pages.get(id)?.space);
    if (s && s.space.encryption && s.readers.includes(me)) return wikiTestEncJson(409, { error: "Conflict", text: "This page is in an encrypted space." });
  }
  m = path.match(/^encrypted\/spaces\/([^/]+)(\/.*)?$/);
  if (m) {
    const s = wikiTestEncrypted.spaces.get(decodeURIComponent(m[1]));
    const rest = m[2] ?? "";
    if (!s || !(s.readers.includes(me) || s.leaked.includes(me))) return wikiTestEncJson(404, { error: "NotFound" });
    if (rest === "" && request.method === "POST") {
      if (s.space.encryption) return wikiTestEncJson(409, { error: "Conflict", text: "This space is encrypted already." });
      const sent = JSON.parse(request.body);
      s.space.encryption = sent.keyId;
      s.space.sealed = true;
      s.grants.push({ keyId: sent.keyId, recipient: sent.grant.recipient, recipientKeyId: sent.grant.recipientKeyId, enc: sent.grant.enc, sealed: sent.grant.sealed });
      return wikiTestEncJson(200, s.space);
    }
    if (!s.space.encryption) return wikiTestEncJson(409, { error: "Conflict", text: "This space is not encrypted." });
    if (rest === "" && request.method === "GET") {
      const mine = wikiTestEncGrantOf(s, me);
      const others = s.readers.filter((u) => !wikiTestEncGrantOf(s, u));
      return wikiTestEncJson(200, {
        keyId: s.space.encryption,
        grant: mine,
        pending: mine ? others.filter((u) => wikiTestEncrypted.directory.has(u)).map((u) => ({ user: u, ...wikiTestEncrypted.directory.get(u) })) : [],
        waiting: mine ? others.filter((u) => !wikiTestEncrypted.directory.has(u)) : [],
        rotationDue: wikiTestEncDue(s),
      });
    }
    const allPages = [...wikiTestEncrypted.pages.values()].filter((p) => p.space === s.space.id);
    if (rest === "/rotation" && request.method === "GET") {
      if (!s.admins.includes(me)) return wikiTestEncJson(403, { error: "Forbidden" });
      return wikiTestEncJson(200, {
        keyId: s.space.encryption,
        readers: s.readers.filter((u) => wikiTestEncrypted.directory.has(u)).map((u) => ({ user: u, ...wikiTestEncrypted.directory.get(u) })),
        pages: allPages.map((p) => ({ page: p.id, keys: [p.pageKey, ...(p.olderKeys ?? [])], latest: wikiTestEncrypted.tamperLatest ? wikiTestEncHeading(allPages.find((q) => q !== p)?.versions.at(-1).content ?? p.versions[0].content) : wikiTestEncHeading(p.versions.at(-1).content) })),
      });
    }
    if (rest === "/rotation" && request.method === "POST") {
      if (!s.admins.includes(me) || !wikiTestEncGrantOf(s, me)) return wikiTestEncJson(403, { error: "Forbidden" });
      const sent = JSON.parse(request.body);
      if (sent.from !== s.space.encryption) return wikiTestEncJson(409, { error: "Conflict", text: "The space's key has changed since: open the space again." });
      const readers = s.readers.filter((u) => wikiTestEncrypted.directory.has(u)).sort();
      if (JSON.stringify(sent.grants.map((g) => g.recipient).sort()) !== JSON.stringify(readers)) return wikiTestEncJson(409, { error: "Conflict", text: "The space's readers have changed since." });
      if (sent.pages.length !== allPages.length) return wikiTestEncJson(409, { error: "Conflict", text: "The space's pages have changed since." });
      wikiTestEncrypted.rotations.push(request.body);
      s.space.encryption = sent.keyId;
      s.grants = sent.grants.map((g) => ({ keyId: sent.keyId, ...g }));
      for (const r of sent.pages) {
        const p = wikiTestEncrypted.pages.get(r.page);
        p.pageKey = r.current;
        p.olderKeys = r.rewrapped;
      }
      return { status: 204, body: "" };
    }
    if (rest === "/grants" && request.method === "POST") {
      const sent = JSON.parse(request.body);
      if (!wikiTestEncGrantOf(s, me)) return wikiTestEncJson(403, { error: "Forbidden" });
      if (wikiTestEncDue(s)) return wikiTestEncJson(409, wikiTestEncRenewal);
      if (sent.grants.length > 500) return wikiTestEncJson(400, { error: "Invalid", text: "At most 500 grants are made at once." });
      if (sent.keyId !== s.space.encryption) return wikiTestEncJson(409, { error: "Conflict", text: "The space's key has changed since: open the space again." });
      for (const g of sent.grants) {
        if (!s.readers.includes(g.recipient)) return wikiTestEncJson(400, { error: "Invalid", text: "A space's key is granted only to its readers." });
        if (wikiTestEncrypted.directory.get(g.recipient)?.keyId !== g.recipientKeyId) return wikiTestEncJson(409, { error: "Conflict", text: "A reader's public key has changed since: open the space again." });
        if (!wikiTestEncGrantOf(s, g.recipient)) s.grants.push({ keyId: sent.keyId, ...g });
      }
      return { status: 204, body: "" };
    }
    const pages = [...wikiTestEncrypted.pages.values()].filter((p) => p.space === s.space.id);
    if (rest === "/pages" && request.method === "GET") {
      return wikiTestEncJson(
        200,
        pages.map((p) => {
          const sealed = wikiTestEncSealed(p);
          return { ...sealed, heading: wikiTestEncHeading(sealed.content), content: undefined };
        }),
      );
    }
    if (rest === "/contents" && request.method === "GET") return wikiTestEncJson(200, pages.map(wikiTestEncSealed));
    const at = rest.match(/^\/pages\/at\/(.+)$/);
    if (at && request.method === "GET") {
      const slug = decodeURIComponent(at[1]);
      const p = pages.find((x) => x.slug === slug);
      if (!p) return wikiTestEncJson(404, { error: "NotFound" });
      const sealed = wikiTestEncSealed(p);
      return wikiTestEncJson(200, sealed, { ETag: wikiTestEncTag(sealed.updatedAt) });
    }
    if (rest === "/pages" && request.method === "POST") {
      const sent = JSON.parse(request.body);
      if (sent.pageKey.spaceKeyId !== s.space.encryption) return wikiTestEncJson(409, { error: "Conflict", text: "The space's key has changed since: open the space again." });
      if (!wikiTestEncFollows(sent.content.chain, null)) return wikiTestEncJson(409, { error: "Conflict", text: "This version does not follow on the page's latest one." });
      if (wikiTestEncDue(s)) return wikiTestEncJson(409, wikiTestEncRenewal);
      const time = wikiTestEncNow();
      const p = { id: sent.id, space: s.space.id, parent: sent.parent, slug: `p${wikiTestEncrypted.next}x${Math.random().toString(36).slice(2, 9)}`, position: pages.length, pageKey: sent.pageKey, versions: [{ updatedAt: time, content: sent.content, author: me }] };
      wikiTestEncrypted.pages.set(p.id, p);
      wikiTestEncrypted.created.push(request.body);
      const sealed = wikiTestEncSealed(p);
      return wikiTestEncJson(201, sealed, { ETag: wikiTestEncTag(sealed.updatedAt) });
    }
    return null;
  }
  m = path.match(/^encrypted\/pages\/([^/]+)(\/.*)?$/);
  if (m) {
    const p = wikiTestEncrypted.pages.get(decodeURIComponent(m[1]));
    const s = p && wikiTestEncrypted.spaces.get(p.space);
    if (!p || !(s.readers.includes(me) || s.leaked.includes(me))) return wikiTestEncJson(404, { error: "NotFound" });
    const rest = m[2] ?? "";
    if (rest === "" && request.method === "PUT") {
      const latest = p.versions[p.versions.length - 1];
      if (header("if-match") !== wikiTestEncTag(latest.updatedAt)) return wikiTestEncJson(409, { error: "Conflict", text: "The page has been saved by someone else since this edit began." });
      const content = JSON.parse(request.body).content;
      if (!wikiTestEncFollows(content.chain, latest.content)) return wikiTestEncJson(409, { error: "Conflict", text: "This version does not follow on the page's latest one." });
      if (wikiTestEncDue(s)) return wikiTestEncJson(409, wikiTestEncRenewal);
      if (content.keyId !== p.pageKey.keyId) return wikiTestEncJson(409, { error: "Conflict", text: "This page's key has changed since it was opened." });
      p.versions.push({ updatedAt: wikiTestEncNow(), content, author: me });
      const sealed = wikiTestEncSealed(p);
      return wikiTestEncJson(200, sealed, { ETag: wikiTestEncTag(sealed.updatedAt) });
    }
    // A page of the history, the latest first: at most limit versions (50
    // if not given), of those before the version before (all if not given),
    // as the server's. The latest is left out while the test says so.
    if (rest === "/versions" && request.method === "GET") {
      const query = new URLSearchParams(url.split("?")[1] ?? "");
      const limit = Number(query.get("limit") ?? 50);
      const before = query.get("before");
      const n = p.versions.length;
      const all = [...p.versions].reverse().map((v, i) => ({ page: p.id, updatedAt: v.updatedAt, heading: wikiTestEncHeading(v.content), author: null, number: n - i }));
      const listed = all.filter((v, i) => !(i === 0 && wikiTestEncrypted.historyWithoutLatest) && (before === null || Date.parse(v.updatedAt) < Date.parse(before)));
      return wikiTestEncJson(200, listed.slice(0, limit));
    }
    const v = rest.match(/^\/versions\/(.+)$/);
    if (v && request.method === "GET") {
      const time = decodeURIComponent(v[1]);
      const found = p.versions.find((x) => Date.parse(x.updatedAt) === Date.parse(time));
      return found ? wikiTestEncJson(200, { page: p.id, updatedAt: found.updatedAt, content: found.content, author: null }) : wikiTestEncJson(404, { error: "NotFound" });
    }
    return null;
  }
  return null;
}

// Start the server, before the other handlers, with a space (Wiki.Core.Space
// as JSON) and its readers (user ids).
function wiki_test_encrypted_start(space, readers) {
  const s = JSON.parse(space);
  Object.assign(wikiTestEncrypted, { as: null, spaces: new Map([[s.id, { space: s, readers: JSON.parse(readers), admins: ["user-admin"], leaked: [], grants: [] }]]), directory: new Map(), pages: new Map(), next: 0, created: [], historyWithoutLatest: false, rotations: [], tamperLatest: false });
  globalThis.wikiTestHandlers = [wikiTestEncServer, ...(globalThis.wikiTestHandlers ?? []).filter((h) => h !== wikiTestEncServer)];
}

// Who asks the server from now on.
function wiki_test_encrypted_as(user) {
  wikiTestEncrypted.as = user;
}

// Give a user a key pair, as their first sign-in in a browser makes one:
// its private half kept in this browser where the wiki keeps it
// (wiki-assistant-keys, under "identity:" and the user's id), as a key
// that cannot be exported, and its public half in the directory.
async function wiki_test_encrypted_key_pair(user) {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const keyId = new Uint8Array(await crypto.subtle.digest("SHA-256", raw)).slice(0, 16).toBase64({ alphabet: "base64url", omitPadding: true });
  wikiTestEncrypted.directory.set(user, { keyId, publicKey: raw.toBase64({ alphabet: "base64url", omitPadding: true }) });
  await wikiTestEncKeep(`identity:${user}`, pair.privateKey);
}

async function wikiTestEncDatabase() {
  return await new Promise((resolve, reject) => {
    const request = indexedDB.open("wiki-assistant-keys", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("keys");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function wikiTestEncKeep(slot, key) {
  const db = await wikiTestEncDatabase();
  try {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction("keys", "readwrite");
      if (key === null) transaction.objectStore("keys").delete(slot);
      else transaction.objectStore("keys").put(key, slot);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

async function wikiTestEncRead(slot) {
  const db = await wikiTestEncDatabase();
  try {
    return await new Promise((resolve, reject) => {
      const request = db.transaction("keys", "readonly").objectStore("keys").get(slot);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  } finally {
    db.close();
  }
}

// Give a user a new key pair in the directory whose private half this
// device does not hold: a public key the server would choose for them.
async function wiki_test_encrypted_foreign_key(user) {
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const keyId = new Uint8Array(await crypto.subtle.digest("SHA-256", raw)).slice(0, 16).toBase64({ alphabet: "base64url", omitPadding: true });
  wikiTestEncrypted.directory.set(user, { keyId, publicKey: raw.toBase64({ alphabet: "base64url", omitPadding: true }) });
}

// List a user's public key in the directory under an id that is not its
// own, as a server that lies about which key a reader holds.
function wiki_test_encrypted_misname_key(user) {
  const k = wikiTestEncrypted.directory.get(user);
  wikiTestEncrypted.directory.set(user, { keyId: "AAAAAAAAAAAAAAAAAAAAAA", publicKey: k.publicKey });
}

// So many more readers of the space, each with a key pair whose private
// half nobody keeps: readers waiting for the key.
async function wiki_test_encrypted_many_readers(n) {
  const s = [...wikiTestEncrypted.spaces.values()][0];
  for (let i = 0; i < n; i++) {
    const user = `user-many-${i}`;
    await wiki_test_encrypted_foreign_key(user);
    s.readers.push(user);
  }
}

// How many grants of the space's key the server holds.
function wiki_test_encrypted_grants() {
  return [...wikiTestEncrypted.spaces.values()][0].grants.length;
}

// The private key this device holds for a user, set aside, as a device
// that never held it: the page's handles of keys opened with it are
// forgotten too, as on a fresh device.
const wikiTestEncAside = new Map();

async function wiki_test_encrypted_forget_device(user) {
  wikiTestEncAside.set(user, await wikiTestEncRead(`identity:${user}`));
  await wikiTestEncKeep(`identity:${user}`, null);
  // The page's own copy (jsbits/vault.js keeps one for its life), as a
  // reload or another device has none.
  globalThis.wikiVaultPageKeys?.delete(`identity:${user}`);
}

// The private key set aside, back on the device: what an unlock of the
// user's vault puts there (Wiki.App.Vault, tested on its own).
async function wiki_test_encrypted_unlock_device(user) {
  await wikiTestEncKeep(`identity:${user}`, wikiTestEncAside.get(user) ?? null);
}

// Everything the server stored of the space's pages and grants, as one
// text: what a test searches for a plain title or text.
function wiki_test_encrypted_stored() {
  return JSON.stringify({ pages: [...wikiTestEncrypted.pages.values()], spaces: [...wikiTestEncrypted.spaces.values()], created: wikiTestEncrypted.created });
}

// Take WebCrypto away, as a page over plain HTTP has none, or give it back.
let wikiTestEncCrypto = null;

function wiki_test_encrypted_plain_http(plain) {
  if (plain) {
    wikiTestEncCrypto = Object.getOwnPropertyDescriptor(globalThis, "crypto") ?? Object.getOwnPropertyDescriptor(Object.getPrototypeOf(globalThis), "crypto");
    const getRandomValues = crypto.getRandomValues.bind(crypto);
    Object.defineProperty(globalThis, "crypto", { configurable: true, value: { getRandomValues } });
  } else if (wikiTestEncCrypto !== null) {
    delete globalThis.crypto;
    if (!("crypto" in globalThis)) Object.defineProperty(globalThis, "crypto", wikiTestEncCrypto);
    wikiTestEncCrypto = null;
  }
}

// The server rolls a page back: its latest version is no longer there, so
// that the one before it is served as the latest.
function wiki_test_encrypted_roll_back(page) {
  wikiTestEncrypted.pages.get(page).versions.pop();
}

// The server leaves a version out of a page's history, by its index from
// the first version (0).
function wiki_test_encrypted_drop_version(page, index) {
  wikiTestEncrypted.pages.get(page).versions.splice(index, 1);
}

// What this browser remembers of a page for a user (jsbits/encrypted.js's
// "wiki-chain:" in local storage), set to the version at an index from the
// first (0), as if it had read that one last; nothing for an index below 0.
function wiki_test_encrypted_seen_at(user, page, index) {
  const key = "wiki-chain:" + user;
  const all = JSON.parse(localStorage.getItem(key) ?? "{}");
  if (index < 0) delete all[page];
  else {
    const content = wikiTestEncrypted.pages.get(page).versions[index].content;
    all[page] = { number: content.chain.number, tag: content.tag };
  }
  localStorage.setItem(key, JSON.stringify(all));
}

// The server's history leaves out a page's latest version, or no longer.
function wiki_test_encrypted_history_without_latest(leave) {
  wikiTestEncrypted.historyWithoutLatest = leave;
}

// A reader is removed from the space; the server goes on answering them
// the space's ciphertext, as a server that leaks it would.
function wiki_test_encrypted_remove_reader(user) {
  const s = [...wikiTestEncrypted.spaces.values()][0];
  s.readers = s.readers.filter((u) => u !== user);
  s.leaked.push(user);
}

// The rotations the server took, as JSON.
function wiki_test_encrypted_rotations() {
  return JSON.stringify(wikiTestEncrypted.rotations.map((r) => JSON.parse(r)));
}

// The server lists, as a page's latest title for a rotation, another
// page's: a wrap checked against it does not open.
function wiki_test_encrypted_tamper_latest(tamper) {
  wikiTestEncrypted.tamperLatest = tamper;
}
