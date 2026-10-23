// Files for the browser tests (Test.Browser.Editor, Test.Browser.Persist), without a file
// dialog: the harness has no way to answer one, so these make a File from
// bytes and hand it to the page as a drop or a file input's choice would.
// Each waits for a task of its own first, so that the events arrive from
// the browser's event loop, as a user's do, rather than from inside the
// Haskell call that asked for them.

function wikiTestFile(name, type, base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const transfer = new DataTransfer();
  transfer.items.add(new File([bytes], name, { type }));
  return transfer;
}

async function wiki_test_drop_file(selector, name, type, base64) {
  await new Promise((ready) => setTimeout(ready, 0));
  const target = document.querySelector(selector);
  const dataTransfer = wikiTestFile(name, type, base64);
  for (const kind of ["dragenter", "dragover", "drop"]) {
    target.dispatchEvent(new DragEvent(kind, { bubbles: true, cancelable: true, dataTransfer }));
  }
}

async function wiki_test_choose_file(selector, name, type, base64) {
  await new Promise((ready) => setTimeout(ready, 0));
  const input = document.querySelector(selector);
  input.files = wikiTestFile(name, type, base64).files;
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

// The names of the files the page has handed the browser to save since the
// first call (a link with a download attribute clicked, as the wiki's export
// does), one per line. The harness cannot see a download itself, so the
// click that starts one is listened for instead, before anything else hears
// it.
function wiki_test_downloads() {
  if (globalThis.wikiTestDownloads === undefined) {
    const saved = [];
    document.addEventListener(
      "click",
      (event) => {
        const link = event.target instanceof Element ? event.target.closest("a[download]") : null;
        if (link !== null) saved.push(link.download);
      },
      true,
    );
    globalThis.wikiTestDownloads = saved;
  }
  return globalThis.wikiTestDownloads.join("\n");
}
