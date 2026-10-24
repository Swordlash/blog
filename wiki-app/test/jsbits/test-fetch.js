// A server for the browser tests of the backend over HTTP (Test.Browser.Http),
// put in the place of the page's fetch: the application's requests go
// through its own fetch call (jsbits/fetch.js) as they would to wiki-server,
// and are answered here from a table the test fills, by method and address.
// An address the table has no answer for is a 404 with the API's NotFound.
//
// The test can take the network away (a request then fails as fetch fails
// offline, with a TypeError) and hold the answers back until it lets them
// go, to see what the application shows meanwhile. Every request is kept,
// with its headers and its body as text, for the test to read.

const wikiTestServer = { answers: new Map(), asked: [], offline: false, held: null, release: null, fetch: null };

function wiki_test_server_start() {
  if (wikiTestServer.fetch === null) wikiTestServer.fetch = globalThis.fetch;
  Object.assign(wikiTestServer, { answers: new Map(), asked: [], offline: false, held: null, release: null });
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method ?? "GET";
    const headers = init.headers ?? {};
    const body = init.body == null ? "" : new TextDecoder().decode(init.body);
    wikiTestServer.asked.push({ method, url: String(url), headers, body });
    if (wikiTestServer.held !== null) await wikiTestServer.held;
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

function wiki_test_server_hold() {
  wikiTestServer.held = new Promise((go) => (wikiTestServer.release = go));
}

function wiki_test_server_release() {
  wikiTestServer.release?.();
  wikiTestServer.held = null;
  wikiTestServer.release = null;
}

// Every request so far, as JSON: [{method, url, headers, body}].
function wiki_test_server_asked() {
  return JSON.stringify(wikiTestServer.asked);
}
