// The backend over HTTP's one request (Wiki.App.Backend.Http): a fetch of an
// address relative to the page's <base href>, which waits for the whole
// answer and never throws. What it gives is read by the three functions
// after it: the status (0 when no answer came), the body's bytes, and why
// no answer came.
//
// The request is made as the wiki's own: on its origin, with its cookies,
// and never answered from the browser's cache, since what the server says
// now is the point (the application keeps its own copy of what it read).
// A request that has had no whole answer after `timeout` milliseconds is
// abandoned, so that a server that has gone away is reported rather than
// waited for.
async function wiki_fetch(method, url, headersJson, body, timeout) {
  try {
    const init = {
      method,
      headers: JSON.parse(headersJson),
      credentials: "same-origin",
      cache: "no-store",
      signal: AbortSignal.timeout(timeout),
    };
    if (body !== null) init.body = body;
    const response = await fetch(url, init);
    const bytes = new Uint8Array(await response.arrayBuffer());
    return { status: response.status, bytes, error: "" };
  } catch (error) {
    const why =
      error?.name === "TimeoutError"
        ? `no answer in ${Math.round(timeout / 1000)} seconds`
        : error?.name === "TypeError"
          ? "the network or the server is down"
          : String(error?.message ?? error);
    return { status: 0, bytes: new Uint8Array(0), error: why };
  }
}

function wiki_fetch_status(result) {
  return result.status;
}

function wiki_fetch_bytes(result) {
  return result.bytes;
}

function wiki_fetch_error(result) {
  return result.error;
}
