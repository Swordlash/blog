// What the application asks of the browser about reading offline and
// installing (Wiki.App.Offline): whether its service worker (web/src/sw.js)
// served the page from what it kept, whether the browser is online, the
// browser's offer to install the wiki, which web/index.js keeps, and letting
// go of the pages the worker keeps.

// The time the worker kept the page it served offline, as an ISO 8601 text,
// from the mark it put in the page's head; "" for a page from the network.
function wiki_offline_copy() {
  return document.querySelector('meta[name="wiki-offline-copy"]')?.content ?? "";
}

function wiki_browser_online() {
  return navigator.onLine;
}

// Whether the browser has offered to install the wiki and the offer is
// still open.
function wiki_install_available() {
  return globalThis.wikiInstallPrompt != null;
}

// Show the browser's offer, and say whether the reader took it. An offer is
// shown once: whatever the answer, it is spent, and the browser makes
// another if it is still installable.
async function wiki_install() {
  const offer = globalThis.wikiInstallPrompt;
  if (offer == null) return false;
  globalThis.wikiInstallPrompt = null;
  try {
    await offer.prompt();
    const choice = await offer.userChoice;
    return choice.outcome === "accepted";
  } catch {
    return false;
  } finally {
    dispatchEvent(new Event("wiki-installable"));
  }
}

// Let go of the pages and the API's answers the worker keeps for this wiki
// (the caches named "wiki-pages ..." and "wiki-answers ..." for the place the
// page is served at): they were read as whoever was signed in.
async function wiki_forget_reads() {
  if (!("caches" in globalThis)) return;
  try {
    const scope = new URL("./", document.baseURI).href;
    const names = await caches.keys();
    await Promise.all(
      names
        .filter((name) => (name.startsWith("wiki-pages ") || name.startsWith("wiki-answers ")) && name.endsWith(` ${scope}`))
        .map((name) => caches.delete(name)),
    );
  } catch {
    // Nothing kept, or the browser keeps nothing for this page.
  }
}
