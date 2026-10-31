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
  cancelNext: false,
  cancelAt: null,
  touches: 0,
  // The login field's offer of passkeys (conditional mediation) waiting
  // for the person to pick one: its resolve, which wiki_test_passkeys_pick
  // calls.
  offered: null,
  insecure: null,
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
  if (wikiTestPasskeys.cancelNext || wikiTestPasskeys.cancelAt === wikiTestPasskeys.touches) {
    wikiTestPasskeys.cancelNext = false;
    wikiTestPasskeys.cancelAt = null;
    throw new DOMException("The operation either timed out or was not allowed.", "NotAllowedError");
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
  Object.assign(wikiTestPasskeys, { credentials: [], prf, prfAtCreate, cancelNext: false, cancelAt: null, touches: 0, offered: null });
}

function wiki_test_passkeys_uninstall() {
  delete globalThis.wikiAssistantScript;
  delete navigator.credentials;
  delete PublicKeyCredential.isConditionalMediationAvailable;
  if (wikiTestPasskeys.conditional) Object.defineProperty(PublicKeyCredential, "isConditionalMediationAvailable", wikiTestPasskeys.conditional);
  if (wikiTestPasskeys.original) Object.defineProperty(navigator, "credentials", wikiTestPasskeys.original);
  if (wikiTestPasskeys.insecure !== null) {
    delete globalThis.isSecureContext;
    wikiTestPasskeys.insecure = null;
  }
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

// The person picks the passkey the login field offers.
function wiki_test_passkeys_pick() {
  wikiTestPasskeys.offered?.();
}

// The page as one served over plain HTTP to another machine: not a secure
// context, where a browser offers no passkeys.
function wiki_test_passkeys_insecure() {
  wikiTestPasskeys.insecure = true;
  Object.defineProperty(globalThis, "isSecureContext", { value: false, configurable: true });
}

// How many times a passkey was made or used: the person's touches.
function wiki_test_passkeys_touches() {
  return wikiTestPasskeys.touches;
}

// The person closes the next dialog.
function wiki_test_passkeys_cancel_next() {
  wikiTestPasskeys.cancelNext = true;
}

// The person closes a later dialog: the one after this many touches.
function wiki_test_passkeys_cancel_after(touches) {
  wikiTestPasskeys.cancelAt = wikiTestPasskeys.touches + touches + 1;
}

// The vault's server: one user's vault and passkeys.
const wikiTestVault = { vault: null, revision: 0, passkeys: [] };

function wikiTestJson(status, value, headers = {}) {
  return { status, body: JSON.stringify(value), headers };
}

function wikiTestStored() {
  const wrapped = {};
  for (const p of wikiTestVault.passkeys) if (p.wrapped) wrapped[p.id] = p.wrapped;
  return { tag: `"${wikiTestVault.revision}"`, vault: { ...wikiTestVault.vault, wrapped } };
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
    for (const [id, wrapped] of Object.entries(sent.wrapped ?? {})) {
      const p = wikiTestVault.passkeys.find((k) => k.id === id);
      if (!p) return wikiTestJson(400, { error: "Invalid", text: "The vault names a passkey that is not one of yours." });
      p.wrapped = wrapped;
    }
    wikiTestVault.vault = { format: sent.format, salt: sent.salt, nonce: sent.nonce, ciphertext: sent.ciphertext };
    wikiTestVault.revision++;
    return wikiTestJson(200, wikiTestStored());
  }
  if (path === "vault" && request.method === "DELETE") {
    // The passkeys stay, since they sign the user in; their wrapped keys go.
    wikiTestVault.vault = null;
    for (const p of wikiTestVault.passkeys) p.wrapped = null;
    return { status: 204, body: "" };
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
  Object.assign(wikiTestVault, { vault: null, revision: 0, passkeys: [] });
  globalThis.wikiTestHandlers = [...(globalThis.wikiTestHandlers ?? []), wikiTestVaultServer];
}

// What the vault's server keeps, as JSON: {vault, revision, passkeys}.
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
  Object.assign(wikiTestVault, { vault: null, revision: 0, passkeys: [] });
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

// How many keys the page still holds that can be exported, through the
// vault's own functions (Wiki.App.Assistant's): every handle given so far
// is tried as the key to wrap, with a wrapping key from a passkey the
// stub makes for this, which is no touch of the person's.
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
    for (let handle = 1; handle < got.wrapping; handle++) {
      if (JSON.parse(await vault.wiki_vault_wrap(got.wrapping, handle, "probe")).key !== undefined) left++;
    }
    vault.wiki_vault_forget_key(got.wrapping);
    return left;
  } finally {
    wikiTestPasskeys.prf = prf;
    wikiTestPasskeys.credentials = wikiTestPasskeys.credentials.filter((c) => c !== id);
  }
}
