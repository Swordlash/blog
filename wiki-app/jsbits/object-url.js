// Object URLs for the bytes of attachments uploaded into the in-memory
// backend (Wiki.App.Backend.Mem): the demo has no server to fetch a file
// from, so the browser serves it from a Blob for as long as the tab lives.
// The bytes arrive as base64 text, which crosses the FFI the same way on
// every backend.

function wiki_object_url(base64, mediaType) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return URL.createObjectURL(new Blob([bytes], { type: mediaType }));
}

function wiki_revoke_object_url(url) {
  URL.revokeObjectURL(url);
}
