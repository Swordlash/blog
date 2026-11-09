// HPKE (RFC 9180) for the user's keys (WP5.74 of docs/PLAN.md): @hpke/core,
// whose base mode with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and
// AES-256-GCM runs on the browser's WebCrypto, and takes a recipient's
// X25519 key that cannot be exported. web/bundle.sh bundles it into
// islands/hpke.js, which islands.js imports the first time a key is sealed
// to someone or opened (wikiIslands.hpke()), so that a reader's page never
// fetches it. Encrypted spaces seal a space's key to each member's public
// key with it; the browser tests pin its behaviour with RFC 9180's vector.
export { Aes128Gcm, Aes256Gcm, CipherSuite, DhkemX25519HkdfSha256, HkdfSha256 } from "@hpke/core";
