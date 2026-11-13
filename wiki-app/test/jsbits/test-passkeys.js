// The assistant's keys across devices in the browser tests
// (Test.Browser.Vault). The test harness has no virtual authenticator, so
// navigator.credentials is replaced by a stub that makes and uses passkeys
// as a password manager would: each passkey has a random credential id,
// and its PRF output for a salt is SHA-256 of the id and the salt, the same
// on every "device", as a synced passkey's is. The stub counts its uses
// (each a touch), and can be made to lack the PRF extension, to give the
// output only when used, or to have its next dialog closed.
//
// The vault's server is played here too, in the place of fetch (through
// test-fetch.js's handlers): it keeps the vault and the passkeys as
// wiki-server does, checks no signature (wiki-server's own tests do), and
// answers as the API does.
//
// A "device" is what the browser keeps for the assistant: its two IndexedDB
// databases and the keys the page holds. A test saves one device's,
// clears them for another, and puts the first back, to play two devices
// in one page.

const wikiTestPasskeys = {
  original: null,
  credentials: [],
  prf: true,
  prfAtCreate: true,
  // How many of the next dialogs the person closes.
  cancelNext: 0,
  cancelAt: null,
  touches: 0,
  // The login field's offer of passkeys (conditional mediation) waiting
  // for the person to pick one: its resolve, which wiki_test_passkeys_pick
  // calls.
  offered: null,
  offers: 0,
  insecure: null,
  // The window's own crypto, kept while wiki_test_plain_http has replaced
  // it (false when the window had none of its own).
  crypto: null,
};

// The user handle the stub's passkeys were made for: the test's user.
const wikiTestUserHandle = wikiTestBytes("user-editor").buffer;

function wikiTestBytes(text) {
  return new TextEncoder().encode(text);
}

function wikiTestBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function wikiTestPrf(id, salt) {
  const both = new Uint8Array(id.byteLength + salt.byteLength);
  both.set(new Uint8Array(id), 0);
  both.set(new Uint8Array(salt), id.byteLength);
  return crypto.subtle.digest("SHA-256", both);
}

function wikiTestTouch() {
  wikiTestPasskeys.touches++;
  const closed = new DOMException("The operation either timed out or was not allowed.", "NotAllowedError");
  if (wikiTestPasskeys.cancelNext > 0) {
    wikiTestPasskeys.cancelNext--;
    throw closed;
  }
  if (wikiTestPasskeys.cancelAt === wikiTestPasskeys.touches) {
    wikiTestPasskeys.cancelAt = null;
    throw closed;
  }
}

const wikiTestCredentials = {
  async create({ publicKey }) {
    wikiTestTouch();
    const id = crypto.getRandomValues(new Uint8Array(16)).buffer;
    wikiTestPasskeys.credentials.push(wikiTestBase64(id));
    const first = publicKey.extensions?.prf?.eval?.first;
    const output = wikiTestPasskeys.prf && wikiTestPasskeys.prfAtCreate && first ? await wikiTestPrf(id, first) : undefined;
    const clientData = JSON.stringify({ type: "webauthn.create", challenge: wikiTestBase64(publicKey.challenge), origin: location.origin });
    return {
      type: "public-key",
      rawId: id,
      response: { clientDataJSON: wikiTestBytes(clientData).buffer, attestationObject: new Uint8Array([0xa0]).buffer },
      getClientExtensionResults: () => (wikiTestPasskeys.prf ? { prf: { enabled: true, ...(output ? { results: { first: output } } : {}) } } : {}),
    };
  },
  async get({ publicKey, mediation, signal }) {
    if (mediation === "conditional") {
      wikiTestPasskeys.offers++;
      // The offer in the login field waits until a passkey is picked there,
      // or until the page ends it.
      await new Promise((resolve, reject) => {
        wikiTestPasskeys.offered = resolve;
        signal?.addEventListener("abort", () => {
          wikiTestPasskeys.offered = null;
          reject(new DOMException("The operation was aborted.", "AbortError"));
        });
      });
      wikiTestPasskeys.offered = null;
    }
    wikiTestTouch();
    const allowed = (publicKey.allowCredentials ?? []).map((c) => wikiTestBase64(c.id));
    // With none named, any passkey the stub has for the site: the first.
    const chosen = allowed.length === 0 ? wikiTestPasskeys.credentials[0] : allowed.find((id) => wikiTestPasskeys.credentials.includes(id));
    if (chosen === undefined) throw new DOMException("No passkey for this site.", "NotAllowedError");
    const id = Uint8Array.fromBase64(chosen, { alphabet: "base64url" }).buffer;
    const first = publicKey.extensions?.prf?.eval?.first;
    const output = wikiTestPasskeys.prf && first ? await wikiTestPrf(id, first) : undefined;
    const clientData = JSON.stringify({ type: "webauthn.get", challenge: wikiTestBase64(publicKey.challenge), origin: location.origin });
    return {
      type: "public-key",
      rawId: id,
      response: {
        clientDataJSON: wikiTestBytes(clientData).buffer,
        authenticatorData: new Uint8Array(37).buffer,
        signature: new Uint8Array([0x30, 0]).buffer,
        userHandle: wikiTestUserHandle,
      },
      getClientExtensionResults: () => (output ? { prf: { results: { first: output } } } : {}),
    };
  },
};

// Put the stub in the place of navigator.credentials: passkeys with the
// PRF extension or without, whose output comes at their making or only
// when used.
function wiki_test_passkeys_install(prf, prfAtCreate) {
  if (wikiTestPasskeys.original === null) wikiTestPasskeys.original = Object.getOwnPropertyDescriptor(navigator, "credentials") ?? false;
  Object.defineProperty(navigator, "credentials", { value: wikiTestCredentials, configurable: true });
  if (wikiTestPasskeys.conditional === undefined) wikiTestPasskeys.conditional = Object.getOwnPropertyDescriptor(PublicKeyCredential, "isConditionalMediationAvailable") ?? null;
  Object.defineProperty(PublicKeyCredential, "isConditionalMediationAvailable", { value: async () => true, configurable: true });
  Object.assign(wikiTestPasskeys, { credentials: [], prf, prfAtCreate, cancelNext: 0, cancelAt: null, touches: 0, offered: null, offers: 0 });
}

function wiki_test_passkeys_uninstall() {
  delete globalThis.wikiAssistantScript;
  delete navigator.credentials;
  delete PublicKeyCredential.isConditionalMediationAvailable;
  if (wikiTestPasskeys.conditional) Object.defineProperty(PublicKeyCredential, "isConditionalMediationAvailable", wikiTestPasskeys.conditional);
  if (wikiTestPasskeys.original) Object.defineProperty(navigator, "credentials", wikiTestPasskeys.original);
  wiki_test_plain_http_end();
}

// A passkey the stub already has, as on a device where one was made
// before: its credential id, which the vault's server keeps too.
function wiki_test_passkeys_existing() {
  const id = wikiTestBase64(crypto.getRandomValues(new Uint8Array(16)));
  wikiTestPasskeys.credentials.push(id);
  wikiTestVault.passkeys.push({ id, name: "My laptop", wrapped: null });
  return id;
}

// Whether the login field offers passkeys now (a conditional request is
// waiting).
function wiki_test_passkeys_offered() {
  return wikiTestPasskeys.offered !== null;
}

// How many offers the login field has started.
function wiki_test_passkeys_offers() {
  return wikiTestPasskeys.offers;
}

// The person picks the passkey the login field offers.
function wiki_test_passkeys_pick() {
  wikiTestPasskeys.offered?.();
}

// The page as one served over plain HTTP to another machine: not a secure
// context, where a browser offers no passkeys.
// The window's own isSecureContext is kept, to be put back: deleting the
// property the test defined would delete the browser's with it, and leave
// every later test of the page without passkeys.
function wiki_test_passkeys_insecure() {
  wikiTestPasskeys.insecure = Object.getOwnPropertyDescriptor(globalThis, "isSecureContext") ?? false;
  Object.defineProperty(globalThis, "isSecureContext", { value: false, configurable: true });
}

// The page as one served over plain HTTP in full: not a secure context,
// and without crypto.subtle, which a browser gives only to a secure one
// (the owner's wiki at work is served so). crypto.getRandomValues stays:
// a browser gives it to every page, and serenity-kit needs it. Put back by
// wiki_test_plain_http_end, and by wiki_test_passkeys_uninstall.
function wiki_test_plain_http() {
  if (wikiTestPasskeys.insecure === null) wiki_test_passkeys_insecure();
  if (wikiTestPasskeys.crypto !== null) return;
  const real = globalThis.crypto;
  wikiTestPasskeys.crypto = Object.getOwnPropertyDescriptor(globalThis, "crypto") ?? false;
  Object.defineProperty(globalThis, "crypto", { value: { getRandomValues: real.getRandomValues.bind(real) }, configurable: true });
}

// The window's own crypto and isSecureContext back, if they were taken.
function wiki_test_plain_http_end() {
  if (wikiTestPasskeys.crypto !== null) {
    delete globalThis.crypto;
    if (wikiTestPasskeys.crypto) Object.defineProperty(globalThis, "crypto", wikiTestPasskeys.crypto);
    wikiTestPasskeys.crypto = null;
  }
  if (wikiTestPasskeys.insecure !== null) {
    delete globalThis.isSecureContext;
    if (wikiTestPasskeys.insecure) Object.defineProperty(globalThis, "isSecureContext", wikiTestPasskeys.insecure);
    wikiTestPasskeys.insecure = null;
  }
}

// How many times a passkey was made or used: the person's touches.
function wiki_test_passkeys_touches() {
  return wikiTestPasskeys.touches;
}

// The person closes the next dialog.
function wiki_test_passkeys_cancel_next() {
  wikiTestPasskeys.cancelNext++;
}

// The person closes a later dialog: the one after this many touches.
function wiki_test_passkeys_cancel_after(touches) {
  wikiTestPasskeys.cancelAt = wikiTestPasskeys.touches + touches + 1;
}

// The vault's server: one user's vault (its salt, its items by name and
// the password's wrap of its key), their passkeys with each one's wrap,
// and their current public key in the directory.
const wikiTestVault = { vault: null, revision: 0, passkeys: [], publicKey: null };

function wikiTestJson(status, value, headers = {}) {
  return { status, body: JSON.stringify(value), headers };
}

function wikiTestStored() {
  const wraps = {};
  if (wikiTestVault.vault.password) wraps.password = wikiTestVault.vault.password;
  for (const p of wikiTestVault.passkeys) if (p.wrapped) wraps[`passkey:${p.id}`] = p.wrapped;
  return { tag: `"${wikiTestVault.revision}"`, vault: { format: 2, salt: wikiTestVault.vault.salt, items: wikiTestVault.vault.items, wraps } };
}

function wikiTestInfo(p) {
  return { id: p.id, name: p.name, createdAt: "2026-10-28T09:30:00Z", lastUsedAt: null, unlocks: p.wrapped !== null };
}

function wikiTestVaultServer(request) {
  const path = request.url.replace(/^.*api\/v1\/(?:assistant|account)\//, "");
  if (path === request.url) return null;
  const header = (name) => Object.entries(request.headers).find(([k]) => k.toLowerCase() === name)?.[1];
  const challenge = wikiTestBase64(crypto.getRandomValues(new Uint8Array(32)));
  if (path === "vault" && request.method === "GET") {
    if (wikiTestVault.vault === null) return wikiTestJson(404, { error: "NotFound" });
    const stored = wikiTestStored();
    if (header("if-none-match") === stored.tag) return { status: 304, body: "" };
    return wikiTestJson(200, stored, { ETag: stored.tag });
  }
  if (path === "vault" && request.method === "PUT") {
    const base = header("if-match");
    const sent = JSON.parse(request.body);
    if (wikiTestVault.vault === null ? base !== undefined : base !== `"${wikiTestVault.revision}"`) {
      return wikiTestJson(409, { error: "Conflict", text: "The vault was changed on another device meanwhile." });
    }
    const wraps = Object.entries(sent.wraps ?? {});
    for (const [unlock] of wraps) {
      if (unlock.startsWith("passkey:") && !wikiTestVault.passkeys.some((k) => `passkey:${k.id}` === unlock)) {
        return wikiTestJson(400, { error: "Invalid", text: "The vault names a passkey that is not one of yours." });
      }
    }
    const identity = sent.items?.identity;
    if (sent.publicKey) {
      if (identity?.keyId !== sent.publicKey.keyId) return wikiTestJson(400, { error: "Invalid", text: "The public key sent is not the key pair the vault holds." });
      if (wikiTestVault.publicKey && wikiTestVault.publicKey.keyId !== sent.publicKey.keyId) {
        return wikiTestJson(409, { error: "Conflict", text: "You have a key pair already: it is replaced only after a password reset." });
      }
      wikiTestVault.publicKey = { user: "user-editor", keyId: sent.publicKey.keyId, publicKey: sent.publicKey.publicKey, createdAt: "2026-11-06T09:30:00Z" };
    } else if (identity && identity.keyId !== wikiTestVault.publicKey?.keyId) {
      return wikiTestJson(400, { error: "Invalid", text: "The vault holds a key pair the directory does not have: send its public key with it." });
    }
    for (const [unlock, wrapped] of wraps) {
      const p = wikiTestVault.passkeys.find((k) => `passkey:${k.id}` === unlock);
      if (p) p.wrapped = wrapped;
    }
    wikiTestVault.vault = { salt: sent.salt, items: sent.items ?? {}, password: sent.wraps?.password ?? null };
    wikiTestVault.revision++;
    return wikiTestJson(200, wikiTestStored());
  }
  if (path === "vault" && request.method === "DELETE") {
    // The assistant's settings go; the vault goes only when it holds
    // nothing else, and its passkeys' wraps with it. The passkeys stay,
    // since they sign the user in.
    if (wikiTestVault.vault !== null) {
      delete wikiTestVault.vault.items.assistant;
      if (Object.keys(wikiTestVault.vault.items).length > 0) wikiTestVault.revision++;
      else {
        wikiTestVault.vault = null;
        for (const p of wikiTestVault.passkeys) p.wrapped = null;
      }
    }
    return { status: 204, body: "" };
  }
  if (path.startsWith("public-keys/") && request.method === "GET") {
    return wikiTestVault.publicKey ? wikiTestJson(200, wikiTestVault.publicKey) : wikiTestJson(404, { error: "NotFound" });
  }
  if (path === "passkeys" && request.method === "GET") return wikiTestJson(200, wikiTestVault.passkeys.map(wikiTestInfo));
  if (path === "passkeys/registration" && request.method === "POST") {
    return wikiTestJson(200, {
      challenge,
      rpId: location.hostname,
      rpName: "Wiki",
      userId: wikiTestBase64(wikiTestBytes("user-editor")),
      userName: "editor",
      displayName: "Editor",
      exclude: wikiTestVault.passkeys.map((p) => p.id),
    });
  }
  if (path === "passkeys/registration" && request.method === "PUT") {
    const sent = JSON.parse(request.body);
    const p = { id: sent.id, name: sent.name ?? `Passkey ${wikiTestVault.passkeys.length + 1}`, wrapped: null };
    wikiTestVault.passkeys.push(p);
    return wikiTestJson(200, wikiTestInfo(p));
  }
  if (path === "passkeys/assertion" && request.method === "POST") {
    return wikiTestJson(200, { challenge, rpId: location.hostname, allow: wikiTestVault.passkeys.map((p) => p.id) });
  }
  if (path === "passkeys/assertion" && request.method === "PUT") {
    const p = wikiTestVault.passkeys.find((k) => k.id === JSON.parse(request.body).id);
    return p ? wikiTestJson(200, wikiTestInfo(p)) : wikiTestJson(404, { error: "NotFound" });
  }
  if (path.startsWith("passkeys/") && request.method === "DELETE") {
    const id = decodeURIComponent(path.slice("passkeys/".length));
    const before = wikiTestVault.passkeys.length;
    wikiTestVault.passkeys = wikiTestVault.passkeys.filter((p) => p.id !== id);
    if (wikiTestVault.passkeys.length === before) return wikiTestJson(404, { error: "NotFound" });
    wikiTestVault.revision++;
    return wikiTestJson(200, wikiTestVault.passkeys.map(wikiTestInfo));
  }
  return null;
}

// Start the vault's server, empty, in fetch's place (after the test's
// server has started: Test.Browser.Http's serverStarts).
function wiki_test_vault_server_start() {
  Object.assign(wikiTestVault, { vault: null, revision: 0, passkeys: [], publicKey: null });
  globalThis.wikiTestHandlers = [...(globalThis.wikiTestHandlers ?? []), wikiTestVaultServer];
}

// What the vault's server keeps, as JSON: {vault, revision, passkeys,
// publicKey}.
function wiki_test_vault_server_state() {
  return JSON.stringify(wikiTestVault);
}

// Every entry of a database's store, as [key, value] pairs; or none if the
// database does not exist.
async function wikiTestEntries(name, store) {
  if (!(await indexedDB.databases()).some((d) => d.name === name)) return null;
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open(name);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    if (!db.objectStoreNames.contains(store)) return [];
    return await new Promise((resolve, reject) => {
      const entries = [];
      const cursor = db.transaction(store, "readonly").objectStore(store).openCursor();
      cursor.onsuccess = () => {
        const at = cursor.result;
        if (at) {
          entries.push([at.key, at.value]);
          at.continue();
        } else resolve(entries);
      };
      cursor.onerror = () => reject(cursor.error);
    });
  } finally {
    db.close();
  }
}

async function wikiTestPut(name, version, store, entries) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open(name, version);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(store)) request.result.createObjectStore(store);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction(store, "readwrite");
      for (const [key, value] of entries) transaction.objectStore(store).put(value, key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

// Delete a database, once every connection to it has closed (the
// application's close theirs when asked).
function wikiTestDelete(name) {
  return new Promise((resolve) => {
    const request = indexedDB.deleteDatabase(name);
    request.onsuccess = request.onerror = () => resolve();
  });
}

const wikiTestDevices = new Map();

// Keep this device's assistant (its two databases) under a name, and
// leave the browser as a new device's: the databases deleted and the
// page's keys forgotten, as a browser that never ran the wiki.
async function wiki_test_device_leave(name) {
  wikiTestDevices.set(name, {
    records: await wikiTestEntries("wiki-assistant", "settings"),
    keys: await wikiTestEntries("wiki-assistant-keys", "keys"),
  });
  await wiki_test_device_new();
}

// A new device: nothing kept, and the page's keys forgotten.
async function wiki_test_device_new() {
  await wikiTestDelete("wiki-assistant");
  await wikiTestDelete("wiki-assistant-keys");
  globalThis.wikiVaultPageKeys?.clear();
}

// Come back to a device left under a name, as when the wiki opens again
// there: its databases as they were, and no key in the page.
async function wiki_test_device_return(name) {
  await wiki_test_device_new();
  const device = wikiTestDevices.get(name);
  if (device?.records) await wikiTestPut("wiki-assistant", 1, "settings", device.records);
  if (device?.keys) await wikiTestPut("wiki-assistant-keys", 1, "keys", device.keys);
}

// The page reloaded: the keys it held forgotten, what is stored kept.
function wiki_test_device_reload() {
  globalThis.wikiVaultPageKeys?.clear();
  globalThis.wikiVaultSignedIn = false;
}

// A tab that completed a sign-in, as jsbits/vault.js tells the others.
function wiki_test_tell_signed_in() {
  const other = new BroadcastChannel("wiki-assistant-keys");
  other.postMessage({ signedIn: true });
  other.close();
}

// Whether this page heard of a sign-in completed (jsbits/vault.js).
function wiki_test_heard_signed_in() {
  return globalThis.wikiVaultSignedIn === true;
}

// Whether this device stores a key for the user (not only the page).
async function wiki_test_device_stores_key(user) {
  const keys = await wikiTestEntries("wiki-assistant-keys", "keys");
  return (keys ?? []).some(([key, value]) => key === user && value instanceof CryptoKey && value.extractable === false);
}

// What this device stores for the user, as text, to look for a key in.
async function wiki_test_device_record(user) {
  const records = await wikiTestEntries("wiki-assistant", "settings");
  const found = (records ?? []).find(([key]) => key === user);
  if (!found) return "";
  const value = found[1];
  return typeof value === "string" ? value : new TextDecoder().decode(value);
}

// The scripted provider (wiki-app's jsbits/assistant.js) answers for every
// provider, so that keeping a key, which fetches the provider's models,
// reaches no provider from the test page.
function wiki_test_passkeys_scripted() {
  globalThis.wikiAssistantScript = { turns: [] };
}

// Another device turned syncing on meanwhile: the vault's server is
// emptied, its vault and passkeys stashed, and put back when asked.
let wikiTestStashed = null;

function wiki_test_vault_server_stash() {
  wikiTestStashed = JSON.parse(JSON.stringify(wikiTestVault));
  Object.assign(wikiTestVault, { vault: null, revision: 0, passkeys: [], publicKey: null });
}

function wiki_test_vault_server_unstash() {
  if (wikiTestStashed !== null) Object.assign(wikiTestVault, wikiTestStashed);
  wikiTestStashed = null;
}

// A passkey the server knows and the password manager keeps, made before
// the others but holding no copy of the vault's key (as one whose
// wrapping was never stored): the first the stub would choose.
function wiki_test_vault_server_add_unwrapped() {
  const id = wikiTestBase64(crypto.getRandomValues(new Uint8Array(16)));
  wikiTestVault.passkeys.unshift({ id, name: "A passkey that cannot unlock", wrapped: null });
  wikiTestPasskeys.credentials.unshift(id);
}

// The keys the page holds, saved, and put back: what another tab of the
// wiki holds while this one changes what is stored.
let wikiTestSavedPageKeys = null;

function wiki_test_page_keys_save() {
  wikiTestSavedPageKeys = new Map(globalThis.wikiVaultPageKeys ?? []);
}

function wiki_test_page_keys_restore() {
  globalThis.wikiVaultPageKeys = new Map(wikiTestSavedPageKeys ?? []);
}

// Another tab let go of a user's settings (nothing set there, and not
// syncing): the stored record and key deleted, and the tabs told, as
// wiki_vault_drop_key does.
async function wikiTestDeleteEntry(name, store, key) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(store);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction(store, "readwrite");
      transaction.objectStore(store).delete(key);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

async function wiki_test_other_tab_drops(user) {
  await wikiTestDeleteEntry("wiki-assistant", "settings", String(user));
  await wikiTestDeleteEntry("wiki-assistant-keys", "keys", String(user));
  const other = new BroadcastChannel("wiki-assistant-keys");
  other.postMessage({ dropped: String(user) });
  other.close();
  // The message arrives as a task of its own.
  await new Promise((resolve) => setTimeout(resolve, 50));
}

// Put a key in this device's store of keys, under a slot.
async function wikiTestPutKey(slot, key) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open("wiki-assistant-keys", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("keys");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction("keys", "readwrite");
      transaction.objectStore("keys").put(key, slot);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

// The assistant's own key in its slot (the user's id): a key of its own,
// as when its settings do not sync, or the vault key, as when they do.
async function wiki_test_assistant_key(user, vaultKey) {
  const key = vaultKey
    ? (await wikiTestEntries("wiki-assistant-keys", "keys")).find(([slot]) => slot === `vault:${user}`)?.[1]
    : await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  if (!(key instanceof CryptoKey)) throw new Error("No vault key to share.");
  await wikiTestPutKey(String(user), key);
}

// What the wiki's tabs are told of keys let go, heard from now on as
// another tab hears it.
const wikiTestDropsHeard = [];
let wikiTestDropsChannel = null;
function wiki_test_hear_drops() {
  wikiTestDropsHeard.length = 0;
  if (wikiTestDropsChannel !== null) return;
  wikiTestDropsChannel = new BroadcastChannel("wiki-assistant-keys");
  wikiTestDropsChannel.onmessage = (event) => {
    if (typeof event.data?.dropped === "string") wikiTestDropsHeard.push(event.data.dropped);
  };
}

function wiki_test_drops_heard() {
  return JSON.stringify(wikiTestDropsHeard);
}

// The slots whose keys the page holds for its life (jsbits/vault.js).
function wiki_test_page_key_slots() {
  return JSON.stringify([...(globalThis.wikiVaultPageKeys ?? new Map()).keys()]);
}

// A key held by the page in a slot, as another tab's would be.
async function wiki_test_page_key_hold(slot) {
  if (!(globalThis.wikiVaultPageKeys instanceof Map)) globalThis.wikiVaultPageKeys = new Map();
  globalThis.wikiVaultPageKeys.set(String(slot), await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]));
}

// Tell the wiki's tabs that a key was let go, as another tab does.
function wiki_test_tell_dropped(slot) {
  const other = new BroadcastChannel("wiki-assistant-keys");
  other.postMessage({ dropped: String(slot) });
  other.close();
}

// Where an example starts counting the keys it leaves: the last handle the
// page's registry of keys (wiki-app/jsbits/vault.js) gave out when the
// example before it was checked (wiki_test_keys_checked), or, for the
// first, now. The examples share the page and its registry, whose handles
// only ever grow, so a key an earlier example left behind and was failed
// for has a handle at or below the mark; one given out after that
// example's check (a step of its that ended late) is above it, and fails
// this example rather than none.
function wiki_test_keys_mark() {
  globalThis.wikiTestKeysFrom = globalThis.wikiTestKeysChecked ?? globalThis.wikiKeyRegistry?.next ?? 0;
}

// The keys an example left that can be exported, once it has ended: every
// key the registry holds above the example's mark whose CryptoKey says it
// is extractable, as "<handle>:<algorithm>:<usages>", space-separated (empty
// when there is none). Read from the registry itself, which is the page's
// and outlives the example's passkey stub, so it needs no passkey; a key
// that is extractable is one the vault's wrap would export, which is what
// wiki_test_exportable_keys_left counts while the stub is there. The next
// example counts from here.
function wiki_test_keys_checked() {
  const registry = globalThis.wikiKeyRegistry;
  const from = globalThis.wikiTestKeysFrom ?? 0;
  globalThis.wikiTestKeysChecked = registry?.next ?? 0;
  if (!registry) return "";
  return [...registry.keys.entries()]
    .filter(([handle, key]) => handle > from && key?.extractable === true)
    .map(([handle, key]) => `${handle}:${key.algorithm?.name}:${(key.usages ?? []).join("+")}`)
    .join(" ");
}

// How many keys the page still holds that can be exported, of those given
// out since the mark (wiki_test_keys_mark), through the vault's own
// functions (Wiki.App.Assistant's): every such handle is tried as the key
// to wrap, with a wrapping key from a passkey the stub makes for this,
// which is no touch of the person's.
async function wiki_test_exportable_keys_left() {
  const vault = Object.getOwnPropertySymbols(globalThis)
    .map((symbol) => globalThis[symbol])
    .find((namespace) => typeof namespace?.wiki_vault_wrap === "function" && typeof namespace?.wiki_vault_get === "function");
  if (vault === undefined) throw new Error("The vault's functions are not in this page.");
  const id = wikiTestBase64(crypto.getRandomValues(new Uint8Array(16)));
  wikiTestPasskeys.credentials.push(id);
  const salt = wikiTestBase64(crypto.getRandomValues(new Uint8Array(32)));
  const prf = wikiTestPasskeys.prf;
  wikiTestPasskeys.prf = true;
  try {
    const got = JSON.parse(await vault.wiki_vault_get(JSON.stringify({ challenge: salt, rpId: location.hostname, allow: [id] }), salt, "probe"));
    wikiTestPasskeys.touches--;
    if (!got.wrapping) throw new Error(`No wrapping key for the probe: ${got.error}`);
    let left = 0;
    for (let handle = (globalThis.wikiTestKeysFrom ?? 0) + 1; handle < got.wrapping; handle++) {
      if (JSON.parse(await vault.wiki_vault_wrap(got.wrapping, handle, "probe")).key !== undefined) left++;
    }
    vault.wiki_vault_forget_key(got.wrapping);
    return left;
  } finally {
    wikiTestPasskeys.prf = prf;
    wikiTestPasskeys.credentials = wikiTestPasskeys.credentials.filter((c) => c !== id);
  }
}

// The server's side of OPAQUE for the user's keys' tests (Test.Browser.Keys),
// with @serenity-kit/opaque's own server functions: a sign-in, a proof of
// the password and a registration run for real, so that the browser's
// export key is the one a real server's exchange gives, the same at each
// sign-in with the same password. One user, the editor, with the session
// the test gives. A change of password takes the vault's new password wrap
// as wiki-server does (both or neither), and a reset takes away what only
// the old password unlocked.
const wikiTestOpaque = { setup: null, record: null, attempts: new Map(), session: null, next: 0, secondFactor: false };

const wikiTestCheap = { opsLimit: 1, memLimit: 8192 };

async function wikiTestOpaqueServer(request) {
  const path = request.url.replace(/^.*api\/v1\//, "");
  const routes = ["session/password", "account/password/proof", "password-registration", "account/password", "password-reset/"];
  if (!routes.some((r) => path === r || (r.endsWith("/") && path.startsWith(r)))) return null;
  const opaque = await globalThis.wikiIslands.opaque();
  await opaque.ready;
  const server = opaque.server;
  if (wikiTestOpaque.setup === null) wikiTestOpaque.setup = server.createSetup();
  const sent = request.body === "" ? {} : JSON.parse(request.body);
  const starting = (path === "session/password" || path === "account/password/proof") && request.method === "POST";
  if (starting) {
    if (wikiTestOpaque.record === null) return wikiTestJson(401, { error: "Unauthenticated" });
    const started = server.startLogin({ serverSetup: wikiTestOpaque.setup, registrationRecord: wikiTestOpaque.record, startLoginRequest: sent.ke1, userIdentifier: "user-editor" });
    const attempt = `t${++wikiTestOpaque.next}`;
    wikiTestOpaque.attempts.set(attempt, started.serverLoginState);
    return wikiTestJson(200, { attempt, ke2: started.loginResponse, stretch: wikiTestCheap, fallback: false });
  }
  if ((path === "session/password" || path === "account/password/proof") && request.method === "PUT") {
    const state = wikiTestOpaque.attempts.get(sent.attempt);
    wikiTestOpaque.attempts.delete(sent.attempt);
    try {
      server.finishLogin({ finishLoginRequest: sent.ke3, serverLoginState: state });
    } catch {
      return wikiTestJson(401, { error: "Unauthenticated" });
    }
    if (path === "account/password/proof") return { status: 204, body: "" };
    // An account with a second factor waits for its code (which the test
    // answers) rather than being signed in.
    return wikiTestOpaque.secondFactor ? wikiTestJson(401, { error: "SecondFactorRequired" }) : wikiTestJson(200, wikiTestOpaque.session);
  }
  if (path === "password-registration" && request.method === "POST") {
    const made = server.createRegistrationResponse({ serverSetup: wikiTestOpaque.setup, userIdentifier: "user-editor", registrationRequest: sent.request });
    return wikiTestJson(200, { credential: "user-editor", response: made.registrationResponse, stretch: wikiTestCheap });
  }
  if (path === "account/password" && request.method === "PUT") {
    const vault = wikiTestVault.vault;
    if (sent.vault) {
      if (vault === null || !vault.password || sent.vault.tag !== `"${wikiTestVault.revision}"`) {
        return wikiTestJson(409, { error: "Conflict", text: "Your vault was changed meanwhile: try again." });
      }
      vault.password = sent.vault.wrapped;
      wikiTestVault.revision++;
    } else if (vault?.password) {
      return wikiTestJson(409, { error: "Conflict", text: "Your vault opens with your password." });
    }
    wikiTestOpaque.record = sent.password.record;
    return wikiTestJson(200, { password: true, identities: [] });
  }
  if (path.startsWith("password-reset/") && request.method === "POST") {
    wikiTestOpaque.record = sent.record;
    const vault = wikiTestVault.vault;
    if (vault !== null) {
      if (wikiTestVault.passkeys.some((p) => p.wrapped)) {
        vault.password = null;
        wikiTestVault.revision++;
      } else {
        wikiTestVault.vault = null;
        wikiTestVault.publicKey = null;
      }
    }
    return { status: 204, body: "" };
  }
  return null;
}

// Play OPAQUE's server, for the user whose session (JSON) a sign-in
// answers, before the vault's server (wiki_test_vault_server_start).
function wiki_test_opaque_server_start(session) {
  Object.assign(wikiTestOpaque, { setup: null, record: null, attempts: new Map(), session: JSON.parse(session), next: 0, secondFactor: false });
  globalThis.wikiTestHandlers = [...(globalThis.wikiTestHandlers ?? []), wikiTestOpaqueServer];
}

// Give the editor a second factor: a sign-in with the password then waits
// for its code.
function wiki_test_opaque_second_factor() {
  wikiTestOpaque.secondFactor = true;
}

// Register the editor's password, as an administrator would have set it.
async function wiki_test_opaque_register(password) {
  const opaque = await globalThis.wikiIslands.opaque();
  await opaque.ready;
  if (wikiTestOpaque.setup === null) wikiTestOpaque.setup = opaque.server.createSetup();
  const start = opaque.client.startRegistration({ password });
  const response = opaque.server.createRegistrationResponse({ serverSetup: wikiTestOpaque.setup, userIdentifier: "user-editor", registrationRequest: start.registrationRequest });
  const done = opaque.client.finishRegistration({
    clientRegistrationState: start.clientRegistrationState,
    registrationResponse: response.registrationResponse,
    password,
    keyStretching: { "argon2id-custom": { iterations: 1, memory: 8, parallelism: 1 } },
  });
  wikiTestOpaque.record = done.registrationRecord;
}

// Whether this device's private key for a user, in IndexedDB, refuses to
// be exported, as a key that cannot be exported must: "refused", "exported"
// or "none" when the device holds no key.
async function wiki_test_identity_export(user) {
  const [found] = ((await wikiTestEntries("wiki-assistant-keys", "keys")) ?? []).filter(([key]) => key === `identity:${user}`);
  if (found === undefined || !(found[1] instanceof CryptoKey)) return "none";
  try {
    await crypto.subtle.exportKey("pkcs8", found[1]);
    return "exported";
  } catch {
    return found[1].extractable === false ? "refused" : "exported";
  }
}

// The names of the page's globals that hold text as long as an export key
// written in base64url (64 bytes, 86 characters) or longer, and whether
// the page's registry of keys holds anything but CryptoKeys: an export key
// left in the page would show in one of them.
function wiki_test_export_key_traces() {
  const found = [];
  for (const name of Object.getOwnPropertyNames(globalThis)) {
    let value;
    try {
      value = globalThis[name];
    } catch {
      continue;
    }
    if (typeof value === "string" && /^[A-Za-z0-9_-]{86,}$/.test(value)) found.push(name);
  }
  for (const value of globalThis.wikiKeyRegistry?.keys.values() ?? []) {
    if (!(value instanceof CryptoKey)) found.push("wikiKeyRegistry");
  }
  return JSON.stringify(found);
}
