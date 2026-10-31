// The other end of the channel between the wiki's windows, for the tests of
// the preview that follows its editor (Test.Browser.Workspace): a window
// played here, which hears the editor of a page, and speaks as one.
let wikiTestLive = null;

// Listen on the channel: what the editor says, and the key a preview window
// asks hello with.
function wiki_test_live_start() {
  wikiTestLive?.channel.close();
  const channel = new BroadcastChannel("wiki-live-preview");
  wikiTestLive = { channel, heard: [], hello: "" };
  channel.onmessage = (event) => {
    if (typeof event.data?.hello === "string") wikiTestLive.hello = event.data.hello;
    else wikiTestLive.heard.push(event.data);
  };
}

function wiki_test_live_stop() {
  wikiTestLive?.channel.close();
  wikiTestLive = null;
}

// The key a preview window asked hello with ("" until one has).
function wiki_test_live_hello() {
  return wikiTestLive?.hello ?? "";
}

// The last message an editor sent, as JSON ("null" for none).
function wiki_test_live_heard() {
  return JSON.stringify(wikiTestLive?.heard.at(-1) ?? null);
}

// Every message an editor sent, in order, as a JSON array.
function wiki_test_live_heard_all() {
  return JSON.stringify(wikiTestLive?.heard ?? []);
}

// Speak as the editor of the page a preview window asked about: the text,
// the title ("" for none) and the line, or that the editor has gone.
function wiki_test_live_send(text, title, line) {
  wikiTestLive?.channel.postMessage({ key: wikiTestLive.hello, text, title, line });
}

function wiki_test_live_close() {
  wikiTestLive?.channel.postMessage({ key: wikiTestLive.hello, closed: true });
}

// Put the open editor's cursor at a character.
function wiki_test_live_cursor(at) {
  const editor = document.querySelector(".editor-cm .cm-content")?.wikiEditor;
  editor?.replace(at, at, "", at, at);
}

// How far an element (the first a selector finds), or the page, is scrolled.
function wiki_test_live_scrolled(selector) {
  const element = selector === "" ? document.scrollingElement : document.querySelector(selector);
  return element ? element.scrollTop : -1;
}

