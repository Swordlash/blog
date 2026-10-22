// Required by every Node test run (browser-test-env.sh): code that reaches
// the browser's storage through window finds Node's real Web Storage there.
globalThis.window = globalThis;
