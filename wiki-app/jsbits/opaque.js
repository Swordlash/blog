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
    return r?.finishLoginRequest ?? "";
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
    return r.registrationRecord;
  } catch (error) {
    console.error("OPAQUE: the registration could not finish:", error);
    return "";
  }
}
