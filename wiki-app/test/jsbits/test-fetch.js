// A server for the browser tests of the backend over HTTP (Test.Browser.Http),
// put in the place of the page's fetch: the application's requests go
// through haskell-halogen-net's fetch call (Halogen.Net.Fetch) as they would
// to wiki-server, and are answered here from a table the test fills, by
// method and address. An address the table has no answer for is a 404 with
// the API's NotFound.
//
// The test can take the network away (a request then fails as fetch fails
// offline, with a TypeError) and hold the answers back until it lets them
// go, all of them or those to one address, to see what the application
// shows meanwhile. Every request is kept, with its headers and its body as
// text (and its bytes in base64), and whether it was aborted, for the test
// to read; an aborted request is rejected with an AbortError, as fetch
// rejects it, held or not.

const wikiTestServer = { answers: new Map(), asked: [], offline: false, holdAll: false, heldAt: new Set(), held: null, release: null, fetch: null };

function wiki_test_server_start() {
  if (wikiTestServer.fetch === null) wikiTestServer.fetch = globalThis.fetch;
  Object.assign(wikiTestServer, { answers: new Map(), asked: [], offline: false, holdAll: false, heldAt: new Set(), held: null, release: null });
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method ?? "GET";
    // Headers as fetch takes them: pairs (as Halogen.Net.Fetch passes them)
    // or an object, kept as an object with their names as written.
    const headers = Array.isArray(init.headers) ? Object.fromEntries(init.headers) : (init.headers ?? {});
    const body = init.body == null ? "" : new TextDecoder().decode(init.body);
    // The bytes as they were, too, for a body that is not text (a zip file).
    let binary = "";
    for (const byte of init.body == null ? [] : new Uint8Array(init.body)) binary += String.fromCharCode(byte);
    const request = { method, url: String(url), headers, body, bytes: btoa(binary), aborted: false };
    wikiTestServer.asked.push(request);
    const signal = init.signal;
    const abortError = () => new DOMException("The operation was aborted.", "AbortError");
    const aborted = new Promise((_, reject) => {
      signal?.addEventListener(
        "abort",
        () => {
          request.aborted = true;
          reject(abortError());
        },
        { once: true },
      );
    });
    aborted.catch(() => {});
    const key = `${method} ${url}`;
    if (wikiTestServer.held !== null && (wikiTestServer.holdAll || wikiTestServer.heldAt.has(key))) {
      await Promise.race([wikiTestServer.held, aborted]);
    }
    if (signal?.aborted) throw abortError();
    if (wikiTestServer.offline) throw new TypeError("Failed to fetch");
    const answer = wikiTestServer.answers.get(`${method} ${url}`) ?? { status: 404, body: '{"error":"NotFound"}' };
    const empty = answer.status === 204 || answer.status === 304;
    return new Response(empty ? null : answer.body, { status: answer.status, headers: { "Content-Type": "application/json" } });
  };
}

function wiki_test_server_stop() {
  if (wikiTestServer.fetch !== null) globalThis.fetch = wikiTestServer.fetch;
  wikiTestServer.release?.();
}

function wiki_test_server_answer(method, url, status, body) {
  wikiTestServer.answers.set(`${method} ${url}`, { status, body });
}

function wiki_test_server_offline(offline) {
  wikiTestServer.offline = offline;
}

// Hold back every answer, or those to one address, until released.
function wiki_test_server_hold() {
  wikiTestServer.holdAll = true;
  wikiTestServerGate();
}

function wiki_test_server_hold_at(method, url) {
  wikiTestServer.heldAt.add(`${method} ${url}`);
  wikiTestServerGate();
}

function wikiTestServerGate() {
  if (wikiTestServer.held === null) wikiTestServer.held = new Promise((go) => (wikiTestServer.release = go));
}

function wiki_test_server_release() {
  wikiTestServer.release?.();
  Object.assign(wikiTestServer, { holdAll: false, heldAt: new Set(), held: null, release: null });
}

// The window's online or offline event, as the browser dispatches it when
// its network comes or goes.
function wiki_test_network_event(online) {
  window.dispatchEvent(new Event(online ? "online" : "offline"));
}

// Every request so far, as JSON: [{method, url, headers, body, bytes, aborted}].
function wiki_test_server_asked() {
  return JSON.stringify(wikiTestServer.asked);
}

// What a page the server rendered carries for the program
// (Halogen.Static.embed): a JSON script by id, in the document, outside
// anything the application is mounted in. Its text is set rather than
// parsed, so it needs no escaping here.
function wiki_test_embed(id, json) {
  const script = document.createElement("script");
  script.type = "application/json";
  script.id = id;
  script.textContent = json;
  document.body.append(script);
}

function wiki_test_unembed(id) {
  document.getElementById(id)?.remove();
}
