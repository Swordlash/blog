// Object URLs for the bytes of attachments uploaded into the in-memory
// backend (Wiki.App.Backend.Mem): the demo has no server to fetch a file
// from, so the browser serves it from a Blob for as long as the tab lives.
// The bytes arrive as base64 text, which crosses the FFI the same way on
// every backend.

function wiki_object_url(base64, mediaType) {
  return URL.createObjectURL(new Blob([Uint8Array.fromBase64(base64)], { type: mediaType }));
}

function wiki_revoke_object_url(url) {
  URL.revokeObjectURL(url);
}
