// What the tests of reading offline and installing (Test.Browser.Offline)
// put in the page in place of the service worker and the browser: the mark
// the worker puts in a page it served from what it kept, the browser's
// offer to install the wiki, whether the browser says it is online, and the
// caches the worker would keep.

// Mark the page as an offline copy kept at this time, or, given "", as
// one from the network.
function wiki_test_offline_copy(at) {
  document.querySelector('meta[name="wiki-offline-copy"]')?.remove();
  if (at !== "") {
    const mark = document.createElement("meta");
    mark.name = "wiki-offline-copy";
    mark.content = at;
    document.head.append(mark);
  }
}

// navigator.onLine as the test says (1 online, 0 offline), or, given -1, as
// the browser does.
function wiki_test_navigator_online(online) {
  if (online < 0) {
    delete navigator.onLine;
  } else {
    Object.defineProperty(navigator, "onLine", { configurable: true, get: () => online === 1 });
  }
}

// The browser's offer to install, as web/index.js keeps it, which records
// how often it was shown and is answered as told; given "", withdrawn.
let wikiTestPrompts = 0;
function wiki_test_offer_install(outcome) {
  wikiTestPrompts = 0;
  globalThis.wikiInstallPrompt =
    outcome === ""
      ? null
      : {
          prompt: async () => {
            wikiTestPrompts += 1;
          },
          userChoice: Promise.resolve({ outcome, platform: "" }),
        };
  dispatchEvent(new Event("wiki-installable"));
}

function wiki_test_install_prompts() {
  return wikiTestPrompts;
}

// The caches the worker keeps for the place the page is at, each with one
// answer: the application's, the pages' and the API's.
async function wiki_test_keep_reads() {
  const scope = new URL("./", document.baseURI).href;
  for (const kind of ["app", "pages", "answers"]) {
    const cache = await caches.open(`wiki-${kind} test ${scope}`);
    await cache.put(new URL(`kept-${kind}`, scope).href, new Response(kind));
  }
}

// The kinds of the caches kept for the place the page is at, sorted, as
// text: "app pages".
async function wiki_test_kept_kinds() {
  const scope = new URL("./", document.baseURI).href;
  const names = await caches.keys();
  return names
    .filter((name) => name.endsWith(` ${scope}`))
    .map((name) => name.split(" ")[0].replace(/^wiki-/, ""))
    .sort()
    .join(" ");
}

async function wiki_test_forget_kept() {
  const scope = new URL("./", document.baseURI).href;
  for (const name of await caches.keys()) {
    if (name.endsWith(` ${scope}`)) await caches.delete(name);
  }
}
