// The browser's OPAQUE client (WP5.74a of docs/PLAN.md): @serenity-kit/opaque,
// opaque-ke compiled to wasm, with its wasm inlined. web/bundle.sh bundles it
// into islands/opaque.js, which islands.js imports the first time a password
// is used (wikiIslands.opaque(), which is also globalThis.opaqueHsSerenity),
// so that a reader's page never fetches it. opaque-hs's client
// (Crypto.OPAQUE.Client, in Wiki.App.Backend.Opaque) calls it.
export * from "@serenity-kit/opaque";
