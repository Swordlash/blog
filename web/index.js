import { WASI, OpenFile, File, ConsoleStdout } from "./wasi-shim.js";
import ghcWasmImports from "./ghc_wasm_jsffi.js";

// The browser's offer to install the wiki as an application, which it makes
// (in Chromium) once it finds the page installable, before or after the
// program has started: kept here for the program's "Install" button
// (wiki-app/jsbits/offline.js), which hears "wiki-installable" when it comes
// and goes.
globalThis.wikiInstallPrompt = null;
addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  globalThis.wikiInstallPrompt = event;
  dispatchEvent(new Event("wiki-installable"));
});
addEventListener("appinstalled", () => {
  globalThis.wikiInstallPrompt = null;
  dispatchEvent(new Event("wiki-installable"));
});

// The service worker (sw.js, from web/src/sw.js), which keeps the
// application and the pages read for reading offline, at the place the
// wiki is served at: where this script is. A browser without one, or a page
// that is not a secure context (served over plain HTTP from another machine
// than this one), goes without, as before. Registering is not waited for.
if ("serviceWorker" in navigator) {
  const scope = new URL("./", import.meta.url);
  navigator.serviceWorker
    .register(new URL("./sw.js", import.meta.url), { scope: scope.href })
    .then(async () => {
      // A page the worker did not serve (the first visit, which installed
      // it) asks it to keep this page too, as it keeps every page it serves.
      if (navigator.serviceWorker.controller === null) {
        const registration = await navigator.serviceWorker.ready;
        registration.active?.postMessage({ type: "keep-page", url: location.href });
      }
    })
    .catch((error) => console.info(`The wiki will not be kept for reading offline: ${error.message}`));
}

const wasi = new WASI([], [], [
  new OpenFile(new File([])),
  ConsoleStdout.lineBuffered((line) => console.log(line)),
  ConsoleStdout.lineBuffered((line) => console.error(line)),
]);
const exports = {};
const { instance } = await WebAssembly.instantiateStreaming(
  fetch(new URL("./app.wasm", import.meta.url)),
  {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghcWasmImports(exports),
  },
);
Object.assign(exports, instance.exports);
wasi.initialize(instance);
await instance.exports.hs_start();
