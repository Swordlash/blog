// The browser's half of OPAQUE (WP5.74a of docs/PLAN.md), declared in
// Wiki.App.Backend.Opaque: @serenity-kit/opaque, opaque-ke compiled to
// wasm, bundled by web/bundle.sh into islands/opaque.js and loaded the first
// time a password is used (wikiIslands.opaque()). Its messages and states
// are unpadded base64url, as the API carries them.
//
// Each function answers a promise of text: the words of its result joined
// by a space, or "" when the step fails (a wrong password at the end of a
// sign-in, a message that does not decode). Argon2id runs with the passes
// and memory the server names for the record, and parallelism 1.
//
// A finished sign-in or registration also gives OPAQUE's export key, a
// secret only this browser knows, the same for every sign-in with the same
// password (WP5.74 of docs/PLAN.md): the user's vault derives from it the
// key that wraps its own key when the vault opens with the password.
// serenity-kit gives it as a string, the one secret WebCrypto cannot hold.
// Its bytes are imported at once as HKDF's input, a WebCrypto key that
// cannot be exported, the bytes overwritten, and the string dropped: the
// result names that key by a handle of the page's keys (jsbits/vault.js),
// 0 where the browser has no WebCrypto.

async function wikiOpaqueExportKey(exportKey) {
  if (typeof exportKey !== "string" || typeof globalThis.crypto?.subtle?.importKey !== "function") return 0;
  let bytes = null;
  try {
    bytes = Uint8Array.fromBase64(exportKey, { alphabet: "base64url" });
    const key = await crypto.subtle.importKey("raw", bytes, "HKDF", false, ["deriveKey"]);
    const registry = (globalThis.wikiKeyRegistry ??= { next: 0, keys: new Map() });
    const handle = ++registry.next;
    registry.keys.set(handle, key);
    return handle;
  } catch {
    return 0;
  } finally {
    bytes?.fill(0);
  }
}

async function wikiOpaque() {
  const load = globalThis.wikiIslands?.opaque;
  if (typeof load !== "function") throw new Error("The page has no OPAQUE client (islands.js).");
  const opaque = await load();
  await opaque.ready;
  return opaque;
}

function wikiOpaqueStretch(iterations, kib) {
  return { "argon2id-custom": { iterations, memory: kib, parallelism: 1 } };
}

async function wiki_opaque_start_login(password) {
  try {
    const r = (await wikiOpaque()).client.startLogin({ password });
    return `${r.clientLoginState} ${r.startLoginRequest}`;
  } catch (error) {
    console.error("OPAQUE: the sign-in could not start:", error);
    return "";
  }
}

async function wiki_opaque_finish_login(state, password, iterations, kib, ke2) {
  try {
    const r = (await wikiOpaque()).client.finishLogin({
      clientLoginState: state,
      loginResponse: ke2,
      password,
      keyStretching: wikiOpaqueStretch(iterations, kib),
    });
    if (r === undefined) return "";
    return `${r.finishLoginRequest} ${await wikiOpaqueExportKey(r.exportKey)}`;
  } catch (error) {
    console.error("OPAQUE: the sign-in could not finish:", error);
    return "";
  }
}

async function wiki_opaque_start_registration(password) {
  try {
    const r = (await wikiOpaque()).client.startRegistration({ password });
    return `${r.clientRegistrationState} ${r.registrationRequest}`;
  } catch (error) {
    console.error("OPAQUE: the registration could not start:", error);
    return "";
  }
}

async function wiki_opaque_finish_registration(state, password, iterations, kib, response) {
  try {
    const r = (await wikiOpaque()).client.finishRegistration({
      clientRegistrationState: state,
      registrationResponse: response,
      password,
      keyStretching: wikiOpaqueStretch(iterations, kib),
    });
    return `${r.registrationRecord} ${await wikiOpaqueExportKey(r.exportKey)}`;
  } catch (error) {
    console.error("OPAQUE: the registration could not finish:", error);
    return "";
  }
}
