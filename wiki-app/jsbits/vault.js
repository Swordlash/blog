// The assistant's vault in the browser (WP5.21 of docs/PLAN.md), declared
// in Wiki.App.Assistant: WebCrypto for the keys and the sealed settings,
// IndexedDB for this device's key, and WebAuthn (navigator.credentials)
// for the passkeys that unlock the vault on another device. The format is
// Wiki.Core.Assistant.Vault's; the steps are Wiki.App.Assistant.Keys's.
//
// Keys never leave this file as bytes. The application holds a number for
// each (a handle, in wikiVaultKeys), and asks for what to do with it:
// seal or open text with a vault key, wrap a vault key with the key a
// passkey's PRF output gives, unwrap it. The vault key the device keeps
// is a CryptoKey that cannot be exported, stored in an IndexedDB database
// of its own (wiki-assistant-keys), apart from the record the application
// stores (wiki-assistant). The PRF output of a passkey is read here, made
// into a key that can only wrap and unwrap (HKDF-SHA256 with the vault's
// salt), and its bytes are then overwritten; it is never returned, logged
// or sent.
//
// Bytes cross to the application in base64url without padding, as
// WebAuthn writes them. A failure comes back as {error: text}, with
// {cancelled: true} when the person closed the browser's passkey dialog
// or it timed out.

const wikiVaultKeys = new Map();
let wikiVaultNextKey = 0;

// The vault key this page holds for each user, once opened: what "ask for
// the passkey each time" keeps instead of storing it. A reload of the page
// forgets it; it is a global so that the browser tests can play a reload
// by emptying it.
function wikiVaultPageKeys() {
  if (!(globalThis.wikiVaultPageKeys instanceof Map)) globalThis.wikiVaultPageKeys = new Map();
  wikiVaultListen();
  return globalThis.wikiVaultPageKeys;
}

// The wiki's other tabs, told when this one lets go of a user's key, so
// that they let go of theirs too: a tab that sealed settings under a key
// no longer stored would lose them at its next reload. (A key kept is
// read from IndexedDB before the page's own, so it needs no message.)
let wikiVaultChannel = null;

function wikiVaultListen() {
  if (wikiVaultChannel !== null || typeof BroadcastChannel !== "function") return;
  wikiVaultChannel = new BroadcastChannel("wiki-assistant-keys");
  wikiVaultChannel.onmessage = (event) => {
    if (typeof event.data?.dropped === "string") globalThis.wikiVaultPageKeys?.delete(event.data.dropped);
  };
}

function wikiVaultHandle(key) {
  const handle = ++wikiVaultNextKey;
  wikiVaultKeys.set(handle, key);
  return handle;
}

function wikiVaultKey(handle) {
  const key = wikiVaultKeys.get(handle);
  if (key === undefined) throw new Error("The key is no longer in this page.");
  return key;
}

// Bytes as base64url without padding, and back (with or without it), by
// the platform's own Uint8Array.prototype.toBase64 and Uint8Array.fromBase64.
function wikiVaultToBase64(buffer) {
  return new Uint8Array(buffer).toBase64({ alphabet: "base64url", omitPadding: true });
}

function wikiVaultFromBase64(text) {
  return Uint8Array.fromBase64(String(text), { alphabet: "base64url" });
}

function wikiVaultText(text) {
  return new TextEncoder().encode(String(text));
}

function wikiVaultFailure(error) {
  const cancelled = error?.name === "NotAllowedError" || error?.name === "AbortError";
  return JSON.stringify({ error: String(error?.message ?? error), cancelled });
}

// A new vault key: AES-GCM, 256 bits, which can be exported (to be
// wrapped for a passkey) only when asked.
// The handle, or 0 where the browser makes no key (no WebCrypto).
async function wiki_vault_new_key(exportable) {
  try {
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, Boolean(exportable), ["encrypt", "decrypt"]);
    return wikiVaultHandle(key);
  } catch {
    return 0;
  }
}

// Whether WebCrypto is here to seal with: a browser offers it only to a
// secure page (HTTPS, or the machine's own address).
function wiki_vault_sealing_here() {
  return typeof globalThis.crypto?.subtle?.encrypt === "function";
}

// Seal text with a vault key, the given additional data authenticated
// with it: JSON {nonce, ciphertext}, or {error}.
async function wiki_vault_seal(handle, text, data) {
  try {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: wikiVaultText(data) },
      wikiVaultKey(handle),
      wikiVaultText(text),
    );
    return JSON.stringify({ nonce: wikiVaultToBase64(nonce), ciphertext: wikiVaultToBase64(sealed) });
  } catch (error) {
    return wikiVaultFailure(error);
  }
}

// Open what wiki_vault_seal sealed: JSON {text}, or {error} when the key
// or the data is not the one it was sealed with.
async function wiki_vault_open(handle, nonce, ciphertext, data) {
  try {
    const opened = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: wikiVaultFromBase64(nonce), additionalData: wikiVaultText(data) },
      wikiVaultKey(handle),
      wikiVaultFromBase64(ciphertext),
    );
    return JSON.stringify({ text: new TextDecoder().decode(opened) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "The key does not open these settings." : String(error?.message ?? error) });
  }
}

// The handle no longer needed: the page lets the key go.
function wiki_vault_forget_key(handle) {
  wikiVaultKeys.delete(handle);
}

// 32 random bytes, in base64url: a vault's salt.
function wiki_vault_salt() {
  return wikiVaultToBase64(crypto.getRandomValues(new Uint8Array(32)));
}

// This device's keys, one per user, in IndexedDB.
function wikiVaultDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("wiki-assistant-keys", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("keys");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function wikiVaultStore(mode, act) {
  const db = await wikiVaultDatabase();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction("keys", mode);
      const request = act(transaction.objectStore("keys"));
      transaction.oncomplete = () => resolve(request.result);
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

// Keep a user's vault key on this device: for the page's life, and, when
// asked, in IndexedDB too (as a key that cannot be exported, made so here
// if it could be), or nowhere but the page ("ask each time"). "" when
// done, or what failed.
async function wiki_vault_keep_key(user, handle, onDisk) {
  try {
    let key = wikiVaultKey(handle);
    if (key.extractable) {
      const raw = await crypto.subtle.exportKey("raw", key);
      key = await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
      new Uint8Array(raw).fill(0);
      // The handle holds the copy that cannot be exported from now on, so
      // that the exportable one is not left in the page.
      wikiVaultKeys.set(handle, key);
    }
    wikiVaultPageKeys().set(String(user), key);
    if (onDisk) await wikiVaultStore("readwrite", (store) => store.put(key, String(user)));
    else await wikiVaultStore("readwrite", (store) => store.delete(String(user)));
    return "";
  } catch (error) {
    return String(error?.message ?? error);
  }
}

// The vault key this device holds for a user: the one in IndexedDB, else
// the page's (asked for each time); its handle, or 0 for none. The stored
// key comes first because another tab may have stored a new one (syncing
// turned on or unlocked there), and the page's would then be out of date.
async function wiki_vault_device_key(user) {
  try {
    const stored = await wikiVaultStore("readonly", (store) => store.get(String(user)));
    if (stored instanceof CryptoKey) {
      wikiVaultPageKeys().set(String(user), stored);
      return wikiVaultHandle(stored);
    }
  } catch {
    // No database, as in some private windows: the page's key, if any.
  }
  const held = wikiVaultPageKeys().get(String(user));
  return held === undefined ? 0 : wikiVaultHandle(held);
}

// Let go of a user's vault key on this device: the page's and the stored.
async function wiki_vault_drop_key(user) {
  wikiVaultPageKeys().delete(String(user));
  wikiVaultChannel?.postMessage({ dropped: String(user) });
  try {
    await wikiVaultStore("readwrite", (store) => store.delete(String(user)));
  } catch {
    // Nothing stored.
  }
}

// Whether passkeys can be used here: WebAuthn, which a browser offers
// only to a secure context (HTTPS, or the machine's own address).
function wiki_vault_passkeys_here() {
  return globalThis.isSecureContext === true && typeof globalThis.PublicKeyCredential === "function" && typeof navigator.credentials?.create === "function";
}

// The key a passkey's PRF output gives: HKDF-SHA256 with the vault's salt
// and the format's info, to an AES-GCM key that only wraps and unwraps.
// The output's bytes are overwritten once the key is made.
async function wikiVaultWrappingKey(output, salt, info) {
  const bytes = new Uint8Array(output);
  try {
    const material = await crypto.subtle.importKey("raw", bytes, "HKDF", false, ["deriveKey"]);
    return await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: wikiVaultFromBase64(salt), info: wikiVaultText(info) },
      material,
      { name: "AES-GCM", length: 256 },
      false,
      ["wrapKey", "unwrapKey"],
    );
  } finally {
    bytes.fill(0);
  }
}

// Make a passkey for the wiki (Wiki.Api.Vault's RegistrationOptions, as
// JSON), asking for its PRF on the salt: JSON {response, prf, wrapping},
// where response is what the server checks (Wiki.Api.Vault's
// RegistrationResponse), prf whether the passkey has the PRF extension,
// and wrapping the handle of the key its PRF output gives, when the
// authenticator gave the output at once (0 otherwise: a use of the
// passkey gives it). Or {error, cancelled}.
async function wiki_vault_create(options, salt, info) {
  try {
    const o = JSON.parse(options);
    const credential = await navigator.credentials.create({
      publicKey: {
        challenge: wikiVaultFromBase64(o.challenge),
        rp: { id: o.rpId, name: o.rpName },
        user: { id: wikiVaultFromBase64(o.userId), name: o.userName, displayName: o.displayName },
        pubKeyCredParams: [
          { type: "public-key", alg: -7 },
          { type: "public-key", alg: -257 },
        ],
        // A passkey kept by the person's password manager, which syncs it
        // to their other devices, verified each time: an authenticator's
        // PRF gives another output without the verification.
        authenticatorSelection: { residentKey: "required", requireResidentKey: true, userVerification: "required" },
        attestation: "none",
        excludeCredentials: (o.exclude ?? []).map((id) => ({ type: "public-key", id: wikiVaultFromBase64(id) })),
        timeout: 300000,
        extensions: { prf: { eval: { first: wikiVaultFromBase64(salt) } } },
      },
    });
    const prf = credential.getClientExtensionResults().prf ?? {};
    const output = prf.results?.first;
    const wrapping = output ? wikiVaultHandle(await wikiVaultWrappingKey(output, salt, info)) : 0;
    return JSON.stringify({
      response: {
        id: wikiVaultToBase64(credential.rawId),
        clientDataJSON: wikiVaultToBase64(credential.response.clientDataJSON),
        attestationObject: wikiVaultToBase64(credential.response.attestationObject),
      },
      prf: prf.enabled === true || output !== undefined,
      wrapping,
    });
  } catch (error) {
    return wikiVaultFailure(error);
  }
}

// Use one of the user's passkeys (Wiki.Api.Vault's AssertionOptions, as
// JSON), asking for its PRF on the salt: JSON {response, wrapping}, where
// response is what the server checks (AssertionResponse) and wrapping the
// handle of the key the PRF output gives, or 0 when the passkey gave
// none. Or {error, cancelled}.
async function wiki_vault_get(options, salt, info) {
  try {
    const o = JSON.parse(options);
    const assertion = await navigator.credentials.get({
      publicKey: {
        challenge: wikiVaultFromBase64(o.challenge),
        rpId: o.rpId,
        allowCredentials: (o.allow ?? []).map((id) => ({ type: "public-key", id: wikiVaultFromBase64(id) })),
        userVerification: "required",
        timeout: 300000,
        extensions: { prf: { eval: { first: wikiVaultFromBase64(salt) } } },
      },
    });
    const output = assertion.getClientExtensionResults().prf?.results?.first;
    const wrapping = output ? wikiVaultHandle(await wikiVaultWrappingKey(output, salt, info)) : 0;
    return JSON.stringify({
      response: {
        id: wikiVaultToBase64(assertion.rawId),
        clientDataJSON: wikiVaultToBase64(assertion.response.clientDataJSON),
        authenticatorData: wikiVaultToBase64(assertion.response.authenticatorData),
        signature: wikiVaultToBase64(assertion.response.signature),
      },
      wrapping,
    });
  } catch (error) {
    return wikiVaultFailure(error);
  }
}

// Wrap a vault key (which must be exportable) with a passkey's wrapping
// key: JSON {nonce, key}, or {error}.
async function wiki_vault_wrap(wrapping, handle, data) {
  try {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const wrapped = await crypto.subtle.wrapKey("raw", wikiVaultKey(handle), wikiVaultKey(wrapping), {
      name: "AES-GCM",
      iv: nonce,
      additionalData: wikiVaultText(data),
    });
    return JSON.stringify({ nonce: wikiVaultToBase64(nonce), key: wikiVaultToBase64(wrapped) });
  } catch (error) {
    return wikiVaultFailure(error);
  }
}

// Unwrap a vault key with a passkey's wrapping key, exportable only when
// asked (to wrap it for another passkey): JSON {handle}, or {error}.
async function wiki_vault_unwrap(wrapping, nonce, key, data, exportable) {
  try {
    const unwrapped = await crypto.subtle.unwrapKey(
      "raw",
      wikiVaultFromBase64(key),
      wikiVaultKey(wrapping),
      { name: "AES-GCM", iv: wikiVaultFromBase64(nonce), additionalData: wikiVaultText(data) },
      { name: "AES-GCM", length: 256 },
      Boolean(exportable),
      ["encrypt", "decrypt"],
    );
    return JSON.stringify({ handle: wikiVaultHandle(unwrapped) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "This passkey's copy of the vault key does not open." : String(error?.message ?? error) });
  }
}

// Tell the person's password manager that a passkey the wiki no longer
// knows (one without the PRF extension, removed at once) can go, where
// the browser can say so.
async function wiki_vault_discard(rpId, credentialId) {
  try {
    await globalThis.PublicKeyCredential?.signalUnknownCredential?.({ rpId: String(rpId), credentialId: String(credentialId) });
  } catch {
    // Not every browser can, and nothing depends on it.
  }
}
