// The server of encrypted spaces, played in the browser tests
// (Test.Browser.Encrypted) beside the test's server in fetch's place
// (test-fetch.js), as the vault's is (test-passkeys.js): the list of
// spaces, the directory of public keys, and the routes under encrypted/
// (Wiki.Api.Encrypted), with the server's rules for grants (only a holder
// of the key grants it, only to a reader with a current public key, and
// only the current key) and for saves (against the version read). It
// stores what the browser sends and never reads it, as the real server.
// The user asking is the one the test names (wiki_test_encrypted_as).

const wikiTestEncrypted = { as: null, spaces: new Map(), directory: new Map(), pages: new Map(), next: 0, created: [] };

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
  };
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
    if (!s || !s.readers.includes(me)) return wikiTestEncJson(404, { error: "NotFound" });
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
      });
    }
    if (rest === "/grants" && request.method === "POST") {
      const sent = JSON.parse(request.body);
      if (!wikiTestEncGrantOf(s, me)) return wikiTestEncJson(403, { error: "Forbidden" });
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
          return { ...sealed, heading: { tag: sealed.content.tag, keyId: sealed.content.keyId, title: sealed.content.title }, content: undefined };
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
    if (!p || !s.readers.includes(me)) return wikiTestEncJson(404, { error: "NotFound" });
    const rest = m[2] ?? "";
    if (rest === "" && request.method === "PUT") {
      const latest = p.versions[p.versions.length - 1];
      if (header("if-match") !== wikiTestEncTag(latest.updatedAt)) return wikiTestEncJson(409, { error: "Conflict", text: "The page has been saved by someone else since this edit began." });
      p.versions.push({ updatedAt: wikiTestEncNow(), content: JSON.parse(request.body).content, author: me });
      const sealed = wikiTestEncSealed(p);
      return wikiTestEncJson(200, sealed, { ETag: wikiTestEncTag(sealed.updatedAt) });
    }
    if (rest === "/versions" && request.method === "GET") {
      const n = p.versions.length;
      return wikiTestEncJson(
        200,
        [...p.versions].reverse().map((v, i) => ({ page: p.id, updatedAt: v.updatedAt, heading: { tag: v.content.tag, keyId: v.content.keyId, title: v.content.title }, author: null, number: n - i })),
      );
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
  Object.assign(wikiTestEncrypted, { as: null, spaces: new Map([[s.id, { space: s, readers: JSON.parse(readers), grants: [] }]]), directory: new Map(), pages: new Map(), next: 0, created: [] });
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
