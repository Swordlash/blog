// What the account's avatar (Wiki.App.View.Avatar) asks of the browser:
// Cropper.js put in the dialog's element on the picture chosen, and the
// crop read back as PNG bytes. They only forward to globalThis.wikiIslands,
// which the page's islands.js publishes (web/src/islands.js), and to what
// web/src/avatar.js leaves on the element (`wikiAvatar`).

// Put the cropper in `host` on `file`; the promise settles once it is
// there with the picture loaded (or the cropper could not be loaded). Without the page's islands.js
// there is no cropper.
async function wiki_avatar_crop(host, file) {
  await globalThis.wikiIslands?.cropAvatar?.(host, file);
}

// The crop as PNG bytes; no bytes when there is no cropper in `host`.
async function wiki_avatar_cropped(host) {
  return (await host.wikiAvatar?.result()) ?? new Uint8Array(0);
}

// Take the cropper out of `host`, and let the picture go.
function wiki_avatar_drop(host) {
  host.wikiAvatar?.destroy();
}

// Place the cropper's selection in `host`: (x, y) from its canvas's
// corner, side by side pixels.
function wiki_avatar_select(host, x, y, side) {
  host.wikiAvatar?.select(x, y, side);
}
