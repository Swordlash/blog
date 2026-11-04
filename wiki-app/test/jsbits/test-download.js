// What the page gives the browser to save or to open, for the browser tests
// of the Export menu (Test.Browser.Export): every object URL the page makes
// is kept with its blob, a click on a link that saves a blob (a hidden
// anchor with download, as Wiki.App.Browser.download makes one) is
// recorded instead of saving, and window.open is recorded instead of
// opening a tab. The test says whether the browser opens tabs or blocks
// them, as Chromium blocks one opened too long after the click that asked
// for it. A test's documents are answered by the server in fetch's place
// (test-fetch.js), through its handlers, with their own headers.

const wikiTestDownloads = { blobs: new Map(), saved: [], opened: [], tabs: true, original: null };

function wiki_test_downloads_start(tabs) {
  Object.assign(wikiTestDownloads, { blobs: new Map(), saved: [], opened: [], tabs });
  if (wikiTestDownloads.original !== null) return;
  wikiTestDownloads.original = { createObjectURL: URL.createObjectURL, click: HTMLAnchorElement.prototype.click, open: globalThis.open };
  const { createObjectURL, click } = wikiTestDownloads.original;
  URL.createObjectURL = function (blob) {
    const url = createObjectURL.call(URL, blob);
    wikiTestDownloads.blobs.set(url, blob);
    return url;
  };
  HTMLAnchorElement.prototype.click = function () {
    const blob = wikiTestDownloads.blobs.get(this.href);
    if (this.hasAttribute("download") && blob !== undefined) {
      wikiTestDownloads.saved.push({ name: this.getAttribute("download"), blob });
      return;
    }
    click.call(this);
  };
  globalThis.open = (url, target) => {
    wikiTestDownloads.opened.push({ url: String(url), target: String(target), blob: wikiTestDownloads.blobs.get(String(url)) });
    return wikiTestDownloads.tabs ? {} : null;
  };
}

function wiki_test_downloads_stop() {
  const original = wikiTestDownloads.original;
  if (original === null) return;
  URL.createObjectURL = original.createObjectURL;
  HTMLAnchorElement.prototype.click = original.click;
  globalThis.open = original.open;
  wikiTestDownloads.original = null;
}

// What was saved and what was opened, as JSON: {saved: [{name, type,
// text}], opened: [{url, target, type, text}]}, each blob read as text.
async function wiki_test_downloads() {
  const read = async (blob) => (blob === undefined ? { type: "", text: "" } : { type: blob.type, text: await blob.text() });
  const saved = await Promise.all(wikiTestDownloads.saved.map(async (s) => ({ name: s.name, ...(await read(s.blob)) })));
  const opened = await Promise.all(wikiTestDownloads.opened.map(async (o) => ({ url: o.url, target: o.target, ...(await read(o.blob)) })));
  return JSON.stringify({ saved, opened });
}

// The server in fetch's place answers a request to this address with a
// document: its status, its media type, its Content-Disposition and its
// body as text.
function wiki_test_answer_document(method, url, status, type, disposition, body) {
  globalThis.wikiTestHandlers = globalThis.wikiTestHandlers ?? [];
  globalThis.wikiTestHandlers.push((request) =>
    request.method === method && request.url === url ? { status, body, headers: { "Content-Type": type, "Content-Disposition": disposition } } : null,
  );
}
