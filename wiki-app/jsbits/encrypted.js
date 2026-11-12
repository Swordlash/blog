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

// Give a space a new key (Wiki.Api.Encrypted's Rotation), from this
// device's private key (a handle) and the user's own grant of the current
// key (JSON {enc, sealed, info}): a new key, its id appended to infoPrefix,
// sealed to every reader (JSON [{user, keyId, publicKey}], the user
// included); every key of every page (JSON [{page, keys: [{keyId, nonce,
// wrapped, data}], newData, latest: {keyId, nonce, ciphertext, data}}])
// opened with the current key and wrapped again with the new one; and a new
// key for every page, its id appended to newData.
//
// Nothing is returned unless what would be sent opens: the user's own new
// grant is opened with this device's private key, and the key it gives,
// not the one made here, opens every new wrap; the page key the latest
// version of each page is encrypted with, opened so, decrypts that
// version's title. JSON {handle, keyId, grants, pages: [{page, current,
// rewrapped}]}, the handle the new key opened from the grant; or {error}.
async function wiki_enc_space_key_rotate(identity, grant, infoPrefix, me, recipients, pages) {
  const raws = [];
  const forget = (raw) => {
    raws.push(raw);
    return raw;
  };
  try {
    const own = JSON.parse(grant);
    const current = await wikiEncImport(forget(await wikiEncOpenGrant(identity, own.enc, own.sealed, own.info)));
    const fresh = forget(crypto.getRandomValues(new Uint8Array(32)));
    const made = await wikiEncImport(fresh);
    const keyId = wiki_enc_random_id();
    const info = infoPrefix + keyId;
    const grants = [];
    for (const r of JSON.parse(recipients)) {
      if ((await wikiEncKeyId(r.publicKey)) !== r.keyId) throw new Error("A reader's public key is not the one its id names: the key was not renewed.");
      const g = await wikiEncSealTo(r.publicKey, info, fresh);
      grants.push({ recipient: r.user, recipientKeyId: r.keyId, enc: g.enc, sealed: g.sealed });
    }
    const mine = grants.find((g) => g.recipient === me);
    if (mine === undefined) throw new Error("The new key would not be sealed to you: it was not renewed.");
    // The key the user's own new grant gives: what checks every wrap below.
    const opened = await wikiEncImport(forget(await wikiEncOpenGrant(identity, mine.enc, mine.sealed, info)));
    const wrap = async (raw, data) => {
      const nonce = crypto.getRandomValues(new Uint8Array(12));
      const wrapped = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: wikiEncText(data) }, made, raw);
      return { nonce: wikiEncToBase64(nonce), wrapped: wikiEncToBase64(wrapped) };
    };
    const reopen = async (w, data) => await wikiEncImport(forget(new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: wikiEncFromBase64(w.nonce), additionalData: wikiEncText(data) }, opened, wikiEncFromBase64(w.wrapped)))));
    const out = [];
    for (const p of JSON.parse(pages)) {
      if (!p.keys.some((k) => k.keyId === p.latest.keyId)) throw new Error("A page's latest version is not encrypted with any of its keys: the key was not renewed, and nothing was sent.");
      const rewrapped = [];
      for (const k of p.keys) {
        const raw = forget(new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: wikiEncFromBase64(k.nonce), additionalData: wikiEncText(k.data) }, current, wikiEncFromBase64(k.wrapped))));
        const w = await wrap(raw, k.data);
        const again = await reopen(w, k.data);
        if (k.keyId === p.latest.keyId) await wikiEncOpenText(again, p.latest.nonce, p.latest.ciphertext, p.latest.data);
        rewrapped.push({ keyId: k.keyId, nonce: w.nonce, wrapped: w.wrapped });
      }
      const newId = wiki_enc_random_id();
      const w = await wrap(forget(crypto.getRandomValues(new Uint8Array(32))), p.newData + newId);
      await reopen(w, p.newData + newId);
      out.push({ page: p.page, current: { keyId: newId, nonce: w.nonce, wrapped: w.wrapped }, rewrapped });
    }
    return JSON.stringify({ handle: wikiEncHandle(opened), keyId, grants, pages: out });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "A key of the space would not open with the new key: it was not renewed, and nothing was sent." : String(error?.message ?? error) });
  } finally {
    for (const raw of raws) raw.fill(0);
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

// Remember the version seen of a page (JSON {number, tag}), only forward,
// as Wiki.Core.Encrypted's keepIn: compared with what is stored at this
// moment, and written in the same turn (local storage is synchronous, so
// another tab cannot write between the two). "now" when it is remembered,
// "later" when a later version was remembered already and stays, "fork"
// when another version under the same number was, which stays too.
function wiki_enc_keep_seen(user, page, seen) {
  try {
    const all = wikiEncSeenAll(user);
    const next = JSON.parse(seen);
    const before = all[page];
    if (before !== undefined && before.number > next.number) return "later";
    if (before !== undefined && before.number === next.number) return before.tag === next.tag ? "now" : "fork";
    all[page] = next;
    localStorage.setItem("wiki-chain:" + user, JSON.stringify(all));
    return "now";
  } catch {
    // No local storage: nothing is remembered.
    return "now";
  }
}

// Encrypt bytes (an attachment's, a Uint8Array) with a page key and the
// additional data given: an object {nonce, bytes}, the bytes encrypted, or
// {error}. A new random nonce each time, so that two uploads of one file
// are two different ciphertexts.
async function wiki_enc_seal_bytes(handle, bytes, data) {
  try {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: wikiEncText(data) }, wikiEncKey(handle), bytes);
    return { nonce: wikiEncToBase64(nonce), bytes: new Uint8Array(sealed) };
  } catch (error) {
    return { error: String(error?.message ?? error) };
  }
}

// The parts of what wiki_enc_seal_bytes gave: its nonce, its bytes, and
// why it failed ("" when it did not).
function wiki_enc_sealed_nonce(sealed) {
  return sealed.nonce ?? "";
}

function wiki_enc_sealed_bytes(sealed) {
  return sealed.bytes ?? new Uint8Array(0);
}

function wiki_enc_sealed_error(sealed) {
  return sealed.error ?? "";
}

// An attachment's bytes, fetched from the address given (the server's, of
// its encrypted bytes), decrypted with a page key and the additional data
// given, as an object URL of this media type, and one of the link's type
// (the same URL when the types are one): JSON {url, link}, or {error}. The
// caller revokes the URLs when the page no longer shows them.
async function wiki_enc_open_attachment(handle, address, nonce, data, mediaType, linkType) {
  try {
    const answer = await fetch(address, { credentials: "same-origin" });
    if (!answer.ok) throw new Error(`The attachment could not be read: ${answer.status}.`);
    const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: wikiEncFromBase64(nonce), additionalData: wikiEncText(data) }, wikiEncKey(handle), await answer.arrayBuffer());
    const url = URL.createObjectURL(new Blob([opened], { type: mediaType }));
    const link = linkType === mediaType ? url : URL.createObjectURL(new Blob([opened], { type: linkType }));
    return JSON.stringify({ url, link });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "This attachment does not open with its page's key." : String(error?.message ?? error) });
  }
}

// Let an object URL go.
function wiki_enc_revoke(url) {
  try {
    URL.revokeObjectURL(url);
  } catch {
    // Not an object URL: nothing to let go.
  }
}
