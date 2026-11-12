// The user's vault in the browser (WP5.21 and WP5.74 of docs/PLAN.md),
// declared in Wiki.App.Assistant: WebCrypto for the keys, the sealed
// items and the user's key pair, IndexedDB for this device's keys, and
// WebAuthn (navigator.credentials) for the passkeys that unlock the vault
// on another device. The format is Wiki.Core.Vault's; the steps are
// Wiki.App.Vault's and Wiki.App.Assistant.Keys's.
//
// Keys never leave this file as bytes. The application holds a number for
// each (a handle, in the page's registry of keys), and asks for what to
// do with it: seal or open text with a vault key, wrap a vault key with
// the key a passkey's PRF output or the password gives, unwrap it, make
// or open the user's key pair. The keys a device keeps are CryptoKeys that
// cannot be exported, stored in an IndexedDB database of their own
// (wiki-assistant-keys), apart from the records the application stores
// (wiki-assistant): the assistant's under the user's id, the user's vault
// key under "vault:" and the id, the user's private key under "identity:"
// and the id. The PRF output of a passkey is read here, made into a key
// that can only wrap and unwrap (HKDF-SHA256 with the vault's salt), and
// its bytes are then overwritten; it is never returned, logged or sent.
// So are the bytes of the user's private key, which exist only while they
// are sealed or opened.
//
// Bytes cross to the application in base64url without padding, as
// WebAuthn writes them. A failure comes back as {error: text}, with
// {cancelled: true} when the person closed the browser's passkey dialog
// or it timed out.

// The page's keys by handle. The registry is a global so that the
// JavaScript of another module (jsbits/encrypted.js, declared in
// Wiki.App.Encrypted) can use a key this file holds by its handle.
function wikiVaultRegistry() {
  // Written out rather than with the nullish assignment operator: the file
  // is embedded in C, where that operator's characters are a trigraph.
  if (!globalThis.wikiKeyRegistry) globalThis.wikiKeyRegistry = { next: 0, keys: new Map() };
  return globalThis.wikiKeyRegistry;
}

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
    if (typeof event.data?.dropped === "string") wikiVaultLetGo(event.data.dropped);
  };
}

// The handles given out for the key of each slot ("vault:<user>",
// "identity:<user>", the assistant's "<user>"), by slot: each read of the
// stored key gives an object of its own, so a slot's handles are known by
// the slot, not by the object.
function wikiVaultSlotHandles(slot) {
  if (!(globalThis.wikiVaultSlots instanceof Map)) globalThis.wikiVaultSlots = new Map();
  let handles = globalThis.wikiVaultSlots.get(slot);
  if (handles === undefined) {
    handles = new Set();
    globalThis.wikiVaultSlots.set(slot, handles);
  }
  return handles;
}

// Let go of the key this page holds in a slot: the page's copy, and every
// handle given out for it, so that no handle kept somewhere opens anything
// with it.
function wikiVaultLetGo(slot) {
  globalThis.wikiVaultPageKeys?.delete(slot);
  const registry = wikiVaultRegistry();
  for (const handle of wikiVaultSlotHandles(slot)) registry.keys.delete(handle);
  globalThis.wikiVaultSlots.delete(slot);
}

function wikiVaultHandle(key) {
  const registry = wikiVaultRegistry();
  const handle = ++registry.next;
  registry.keys.set(handle, key);
  return handle;
}

function wikiVaultKey(handle) {
  const key = wikiVaultRegistry().keys.get(handle);
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
  wikiVaultRegistry().keys.delete(handle);
}

// Hold a CryptoKey made outside this file: the key OPAQUE's export key
// gives, which opaque-hs's client (Crypto.OPAQUE.Client.WebCrypto) imports
// into WebCrypto for deriveKey only, so that its bytes never reach the
// program (Wiki.App.Backend.Opaque). Its handle, or 0 for anything that is
// not a CryptoKey.
function wiki_vault_hold_key(key) {
  if (typeof CryptoKey !== "function" || !(key instanceof CryptoKey)) return 0;
  return wikiVaultHandle(key);
}

// The key that wraps the vault key for the password: HKDF-SHA256 over the
// key OPAQUE's export key gave (wiki_vault_hold_key), with the vault's salt
// and the format's info, to an AES-GCM key that only wraps and unwraps.
// JSON {handle}, or {error}.
async function wiki_vault_password_key(base, salt, info) {
  try {
    const key = await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: wikiVaultFromBase64(salt), info: wikiVaultText(info) },
      wikiVaultKey(base),
      { name: "AES-GCM", length: 256 },
      false,
      ["wrapKey", "unwrapKey"],
    );
    return JSON.stringify({ handle: wikiVaultHandle(key) });
  } catch (error) {
    return wikiVaultFailure(error);
  }
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
      wikiVaultRegistry().keys.set(handle, key);
    }
    wikiVaultPageKeys().set(String(user), key);
    wikiVaultSlotHandles(String(user)).add(handle);
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
      const handle = wikiVaultHandle(stored);
      wikiVaultSlotHandles(String(user)).add(handle);
      return handle;
    }
  } catch {
    // No database, as in some private windows: the page's key, if any.
  }
  const held = wikiVaultPageKeys().get(String(user));
  if (held === undefined) return 0;
  const handle = wikiVaultHandle(held);
  wikiVaultSlotHandles(String(user)).add(handle);
  return handle;
}

// Let go of a user's vault key on this device: the page's and the stored.
async function wiki_vault_drop_key(user) {
  wikiVaultPageKeys();
  wikiVaultLetGo(String(user));
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
// JSON), asking for its PRF on the salt, unless the salt is "" (a passkey
// added to sign in with, WP5.30): JSON {response, prf, wrapping},
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
        // Without a salt (a passkey added to sign in with), PRF is still
        // asked for, unevaluated: some authenticators give a credential
        // its PRF only when asked as it is made, and the vault may use it
        // later.
        extensions: { prf: salt === "" ? {} : { eval: { first: wikiVaultFromBase64(salt) } } },
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
        userHandle: wikiPasskeyUserHandle(assertion),
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

// The user's key pair (WP5.74 of docs/PLAN.md, Wiki.Core.Vault's identity
// item): X25519 in WebCrypto. The private key is sealed in the vault under
// the vault key, as PKCS #8, and kept on this device as a key that cannot
// be exported, in IndexedDB under "identity:" and the user's id. The
// public key goes to the server's directory, raw (32 bytes), with its id:
// the first 16 bytes of its SHA-256.

async function wikiKeysIdOf(raw) {
  return wikiVaultToBase64(new Uint8Array(await crypto.subtle.digest("SHA-256", raw)).slice(0, 16));
}

// A new key pair for the user, its private key sealed with the vault key
// under the additional data given with the key id appended: JSON {handle,
// keyId, publicKey, nonce, ciphertext}, where handle is the private key,
// which cannot be exported; or {error}. The PKCS #8 bytes exist only while
// they are sealed, and are overwritten then.
async function wiki_keys_generate(vaultHandle, data) {
  try {
    const pair = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits"]);
    const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
    const keyId = await wikiKeysIdOf(raw);
    const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    try {
      const nonce = crypto.getRandomValues(new Uint8Array(12));
      const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: wikiVaultText(data + keyId) }, wikiVaultKey(vaultHandle), pkcs8);
      const kept = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "X25519" }, false, ["deriveBits"]);
      return JSON.stringify({
        handle: wikiVaultHandle(kept),
        keyId,
        publicKey: wikiVaultToBase64(raw),
        nonce: wikiVaultToBase64(nonce),
        ciphertext: wikiVaultToBase64(sealed),
      });
    } finally {
      pkcs8.fill(0);
    }
  } catch (error) {
    return wikiVaultFailure(error);
  }
}

// Open the user's sealed private key with the vault key: JSON {handle},
// a key that cannot be exported, or {error}.
async function wiki_keys_open(vaultHandle, nonce, ciphertext, data) {
  let pkcs8 = null;
  try {
    pkcs8 = new Uint8Array(
      await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: wikiVaultFromBase64(nonce), additionalData: wikiVaultText(data) },
        wikiVaultKey(vaultHandle),
        wikiVaultFromBase64(ciphertext),
      ),
    );
    const key = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "X25519" }, false, ["deriveBits"]);
    return JSON.stringify({ handle: wikiVaultHandle(key) });
  } catch (error) {
    return JSON.stringify({ error: error?.name === "OperationError" ? "The vault key does not open this key pair." : String(error?.message ?? error) });
  } finally {
    pkcs8?.fill(0);
  }
}

// A public key's fingerprint: SHA-256 of its raw bytes, in hexadecimal.
async function wiki_keys_fingerprint(publicKey) {
  try {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", wikiVaultFromBase64(publicKey)));
    return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    return "";
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

// The user handle an assertion gave (the bytes of its owner's user id), in
// base64url, or null when the authenticator gave none.
function wikiPasskeyUserHandle(assertion) {
  const handle = assertion.response.userHandle;
  return handle && handle.byteLength > 0 ? wikiVaultToBase64(handle) : null;
}

// The sign-in with a passkey under way, if any (WP5.30): one at a time,
// since a browser shows one passkey dialog at a time, and a new one (the
// button, after the field's offer) replaces the last.
let wikiPasskeySignIn = null;

// The number of the sign-in with a passkey that may start: every abort and
// every dialog moves it on, so that a sign-in whose challenge arrives after
// either (the form closed meanwhile) does not start at all.
let wikiPasskeyOffer = 0;

// The number a sign-in about to ask for its challenge holds.
function wiki_passkey_offer_ticket() {
  return wikiPasskeyOffer;
}

// Whether the browser offers saved passkeys in the login field
// (conditional mediation), as it does as the field is focused.
async function wiki_passkey_conditional_here() {
  try {
    return wiki_vault_passkeys_here() && (await globalThis.PublicKeyCredential.isConditionalMediationAvailable?.()) === true;
  } catch {
    return false;
  }
}

// Sign in with a passkey (Wiki.Api.Vault's AssertionOptions, as JSON): the
// browser's dialog, or, when conditional, the offer in the login field
// marked autocomplete="username webauthn", which waits until a passkey is
// picked there or the sign-in is aborted. Either starts only if its ticket
// (wiki_passkey_offer_ticket) is still the current one; the dialog then
// ends any offer. No PRF is asked for: signing in unwraps nothing. JSON
// {response}, or {error, cancelled}.
async function wiki_passkey_sign_in(options, conditional, ticket) {
  if (ticket !== wikiPasskeyOffer) return JSON.stringify({ error: "The sign-in ended.", cancelled: true });
  if (!conditional) wikiPasskeyOffer++;
  wikiPasskeySignIn?.abort();
  const controller = new AbortController();
  wikiPasskeySignIn = controller;
  try {
    const o = JSON.parse(options);
    const assertion = await navigator.credentials.get({
      mediation: conditional ? "conditional" : "optional",
      signal: controller.signal,
      publicKey: {
        challenge: wikiVaultFromBase64(o.challenge),
        rpId: o.rpId,
        allowCredentials: (o.allow ?? []).map((id) => ({ type: "public-key", id: wikiVaultFromBase64(id) })),
        userVerification: "required",
        timeout: 300000,
      },
    });
    return JSON.stringify({
      response: {
        id: wikiVaultToBase64(assertion.rawId),
        clientDataJSON: wikiVaultToBase64(assertion.response.clientDataJSON),
        authenticatorData: wikiVaultToBase64(assertion.response.authenticatorData),
        signature: wikiVaultToBase64(assertion.response.signature),
        userHandle: wikiPasskeyUserHandle(assertion),
      },
    });
  } catch (error) {
    return wikiVaultFailure(error);
  } finally {
    if (wikiPasskeySignIn === controller) wikiPasskeySignIn = null;
  }
}

// End the sign-in with a passkey under way, if any: the form closed, or
// the password was used instead.
function wiki_passkey_abort() {
  wikiPasskeyOffer++;
  wikiPasskeySignIn?.abort();
  wikiPasskeySignIn = null;
}
