// Encrypted spaces in the browser (WP5.74 of docs/PLAN.md), declared in
// Wiki.App.Encrypted: the space's key, sealed to each member's public key
// with HPKE (@hpke/core, islands/hpke.js), the pages' keys, wrapped by the
// space's key, and the pages' titles and texts, encrypted with the page's
// key. The format, and the additional data each ciphertext is bound to,
// are Wiki.Core.Encrypted's.
//
// Keys never leave this file as bytes, as in jsbits/vault.js: the
// application holds a number for each (a handle in the page's registry of
// keys, which vault.js and opaque.js share), and every key kept is a
// WebCrypto key that cannot be exported. A space's key exists as bytes
// only while it is sealed to someone or opened from a grant; the bytes are
// overwritten then. Text crosses to the application as JSON; bytes in
// base64url without padding. A failure comes back as {error: text}.

function wikiEncRegistry() {
  // Written out rather than with the nullish assignment operator: the file
  // is embedded in C, where that operator's characters are a trigraph.
  if (!globalThis.wikiKeyRegistry) globalThis.wikiKeyRegistry = { next: 0, keys: new Map() };
  return globalThis.wikiKeyRegistry;
}

function wikiEncHandle(key) {
  const registry = wikiEncRegistry();
  const handle = ++registry.next;
  registry.keys.set(handle, key);
  return handle;
}

function wikiEncKey(handle) {
  const key = wikiEncRegistry().keys.get(handle);
  if (key === undefined) throw new Error("The key is no longer in this page.");
  return key;
}

function wikiEncToBase64(buffer) {
  return new Uint8Array(buffer).toBase64({ alphabet: "base64url", omitPadding: true });
}

function wikiEncFromBase64(text) {
  return Uint8Array.fromBase64(String(text), { alphabet: "base64url" });
}

function wikiEncText(text) {
  return new TextEncoder().encode(String(text));
}

function wikiEncFailure(error) {
  return JSON.stringify({ error: String(error?.message ?? error) });
}

// HPKE base mode with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
// AES-256-GCM, from the island the wiki bundles.
async function wikiEncSuite() {
  const hpke = await globalThis.wikiIslands.hpke();
  return { hpke, suite: new hpke.CipherSuite({ kem: new hpke.DhkemX25519HkdfSha256(), kdf: new hpke.HkdfSha256(), aead: new hpke.Aes256Gcm() }) };
}

// A key's bytes as an AES-GCM key that cannot be exported.
function wikiEncImport(raw) {
  return crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

// Seal a key's bytes to a public key (raw X25519, as the directory gives
// it): {enc, sealed}.
async function wikiEncSealTo(publicKey, info, raw) {
  const { hpke, suite } = await wikiEncSuite();
  const recipientPublicKey = await new hpke.DhkemX25519HkdfSha256().importKey("raw", wikiEncFromBase64(publicKey).buffer, true);
  const sealed = await suite.seal({ recipientPublicKey, info: wikiEncText(info) }, raw);
  return { enc: wikiEncToBase64(sealed.enc), sealed: wikiEncToBase64(sealed.ct) };
}

// Open a grant with this device's private key (a handle): the key's bytes,
// for the caller to overwrite.
async function wikiEncOpenGrant(identity, enc, sealed, info) {
  const { suite } = await wikiEncSuite();
  return new Uint8Array(await suite.open({ recipientKey: wikiEncKey(identity), enc: wikiEncFromBase64(enc).buffer, info: wikiEncText(info) }, wikiEncFromBase64(sealed).buffer));
}

// Whether this page can encrypt: WebCrypto, which a browser offers only to
// a secure page (HTTPS, or the machine's own address).
function wiki_enc_here() {
  return typeof globalThis.crypto?.subtle?.encrypt === "function";
}

// 16 random bytes in base64url: a key's id, a version's tag.
function wiki_enc_random_id() {
  return wikiEncToBase64(crypto.getRandomValues(new Uint8Array(16)));
}

// A random UUID: a new page's id.
function wiki_enc_uuid() {
  return crypto.randomUUID();
}

// A new space key, sealed to the given public key, its id appended to the
// info given: JSON {handle, keyId, enc, sealed}, or {error}.
async function wiki_enc_space_key_new(publicKey, infoPrefix) {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  try {
    const keyId = wiki_enc_random_id();
    const grant = await wikiEncSealTo(publicKey, infoPrefix + keyId, raw);
    const key = await wikiEncImport(raw);
    return JSON.stringify({ handle: wikiEncHandle(key), keyId, enc: grant.enc, sealed: grant.sealed });
  } catch (error) {
    return wikiEncFailure(error);
  } finally {
    raw.fill(0);
  }
}

// Open a grant of a space's key with this device's private key: JSON
// {handle}, or {error}.
async function wiki_enc_space_key_open(identity, enc, sealed, info) {
  let raw = null;
  try {
    raw = await wikiEncOpenGrant(identity, enc, sealed, info);
    return JSON.stringify({ handle: wikiEncHandle(await wikiEncImport(raw)) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "This device's key does not open the space's key." : String(error?.message ?? error) });
  } finally {
    raw?.fill(0);
  }
}

// A public key's id, as the wiki's directory of keys names it: the first
// 16 bytes of the SHA-256 of its raw bytes, in base64url.
async function wikiEncKeyId(publicKey) {
  const digest = await crypto.subtle.digest("SHA-256", wikiEncFromBase64(publicKey));
  return wikiEncToBase64(new Uint8Array(digest).slice(0, 16));
}

// Seal a space's key, opened from one's own grant, to each of the readers
// waiting for it (JSON [{user, keyId, publicKey}]), with the info given:
// JSON {grants: [{recipient, recipientKeyId, enc, sealed}]}, or {error}.
// A reader whose public key is not the one its id names is left out: the
// grant would name a key the reader does not hold.
async function wiki_enc_space_key_share(identity, enc, sealed, info, recipients) {
  let raw = null;
  try {
    raw = await wikiEncOpenGrant(identity, enc, sealed, info);
    const grants = [];
    for (const r of JSON.parse(recipients)) {
      if ((await wikiEncKeyId(r.publicKey)) !== r.keyId) continue;
      const grant = await wikiEncSealTo(r.publicKey, info, raw);
      grants.push({ recipient: r.user, recipientKeyId: r.keyId, enc: grant.enc, sealed: grant.sealed });
    }
    return JSON.stringify({ grants });
  } catch (error) {
    return wikiEncFailure(error);
  } finally {
    raw?.fill(0);
  }
}

// A new page key, wrapped by the space's key with the additional data
// given, its id appended: JSON {handle, keyId, nonce, wrapped}, or {error}.
async function wiki_enc_page_key_new(space, dataPrefix) {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  try {
    const keyId = wiki_enc_random_id();
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const wrapped = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: wikiEncText(dataPrefix + keyId) }, wikiEncKey(space), raw);
    const key = await wikiEncImport(raw);
    return JSON.stringify({ handle: wikiEncHandle(key), keyId, nonce: wikiEncToBase64(nonce), wrapped: wikiEncToBase64(wrapped) });
  } catch (error) {
    return wikiEncFailure(error);
  } finally {
    raw.fill(0);
  }
}

async function wikiEncOpenPageKey(space, nonce, wrapped, data) {
  const raw = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: wikiEncFromBase64(nonce), additionalData: wikiEncText(data) }, wikiEncKey(space), wikiEncFromBase64(wrapped)));
  try {
    return await wikiEncImport(raw);
  } finally {
    raw.fill(0);
  }
}

// Open a page key with the space's key: JSON {handle}, or {error}.
async function wiki_enc_page_key_open(space, nonce, wrapped, data) {
  try {
    return JSON.stringify({ handle: wikiEncHandle(await wikiEncOpenPageKey(space, nonce, wrapped, data)) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "The space's key does not open this page's key." : String(error?.message ?? error) });
  }
}

// Encrypt text with a page key and the additional data given: JSON
// {nonce, ciphertext}, or {error}.
async function wiki_enc_seal(handle, text, data) {
  try {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: wikiEncText(data) }, wikiEncKey(handle), wikiEncText(text));
    return JSON.stringify({ nonce: wikiEncToBase64(nonce), ciphertext: wikiEncToBase64(sealed) });
  } catch (error) {
    return wikiEncFailure(error);
  }
}

async function wikiEncOpenText(key, nonce, ciphertext, data) {
  const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: wikiEncFromBase64(nonce), additionalData: wikiEncText(data) }, key, wikiEncFromBase64(ciphertext));
  return new TextDecoder().decode(opened);
}

// Decrypt text with a page key: JSON {text}, or {error} when the key or
// the additional data is not the one it was encrypted with.
async function wiki_enc_open(handle, nonce, ciphertext, data) {
  try {
    return JSON.stringify({ text: await wikiEncOpenText(wikiEncKey(handle), nonce, ciphertext, data) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "This text does not open with its page's key." : String(error?.message ?? error) });
  }
}

// Decrypt many pages at once, as a list of a space's pages or the search
// needs: JSON [{pageKey: {nonce, wrapped, data}, fields: [{nonce,
// ciphertext, data}]}], each page's key opened with the space's key and
// forgotten after: JSON [[text or null]], null for a field that does not
// open.
async function wiki_enc_open_many(space, items) {
  try {
    const out = [];
    for (const item of JSON.parse(items)) {
      let key = null;
      try {
        key = await wikiEncOpenPageKey(space, item.pageKey.nonce, item.pageKey.wrapped, item.pageKey.data);
      } catch {
        out.push(item.fields.map(() => null));
        continue;
      }
      const texts = [];
      for (const f of item.fields) {
        try {
          texts.push(await wikiEncOpenText(key, f.nonce, f.ciphertext, f.data));
        } catch {
          texts.push(null);
        }
      }
      out.push(texts);
    }
    return JSON.stringify(out);
  } catch (error) {
    return wikiEncFailure(error);
  }
}

// The handle no longer needed: the page lets the key go.
function wiki_enc_forget(handle) {
  wikiEncRegistry().keys.delete(handle);
}

// The latest version of each page of an encrypted space that this browser
// has read and checked (Wiki.Core.Encrypted's Seen), by user: in local
// storage under "wiki-chain:" and the user's id, as JSON {page: {number,
// tag}}. Nothing in it is secret (ids, numbers and random tags); it stays
// across sign-outs and reloads, so that a server that later sends an
// older version of a page is caught. Without local storage, nothing is
// remembered, and nothing is caught.
function wikiEncSeenAll(user) {
  try {
    const all = JSON.parse(localStorage.getItem("wiki-chain:" + user));
    return all !== null && typeof all === "object" ? all : {};
  } catch {
    return {};
  }
}

// The version seen of a page, as JSON {number, tag}, or "" for none.
function wiki_enc_seen(user, page) {
  const seen = wikiEncSeenAll(user)[page];
  return seen === undefined ? "" : JSON.stringify(seen);
}

// Remember the version seen of a page (JSON {number, tag}).
function wiki_enc_keep_seen(user, page, seen) {
  try {
    const all = wikiEncSeenAll(user);
    all[page] = JSON.parse(seen);
    localStorage.setItem("wiki-chain:" + user, JSON.stringify(all));
  } catch {
    // No local storage: nothing is remembered.
  }
}
