// HPKE (RFC 9180) as the wiki bundles it, @hpke/core (web/src/hpke.js,
// wikiIslands.hpke()), for Test.Browser.Hpke: one known answer, and a round
// trip to a key pair the browser made that cannot be exported.

function wikiTestHex(hex) {
  return Uint8Array.from(hex.match(/../g) ?? [], (h) => parseInt(h, 16));
}

function wikiTestToHex(buffer) {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
}

// The test vector of base mode with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256
// and AES-256-GCM (kem_id 0x0020, kdf_id 0x0001, aead_id 0x0002), and its
// first encryption, from the test vectors RFC 9180's authors publish with
// it (test-vectors.json of github.com/cfrg/draft-irtf-cfrg-hpke). The
// RFC's own appendix prints this KEM and KDF with AES-128-GCM only.
const wikiTestHpkeVector = {
  info: "4f6465206f6e2061204772656369616e2055726e",
  skEm: "179d4b53b6365c45b600c4163b61d95cbc2f4d9e36f1695558dce265ab8bab11",
  pkEm: "6c93e09869df3402d7bf231bf540fadd35cd56be14f97178f0954db94b7fc256",
  skRm: "497b4502664cfea5d5af0b39934dac72242a74f8480451e1aee7d6a53320333d",
  pkRm: "430f4b9859665145a6b1ba274024487bd66f03a2dd577d7753c68d7d7d00c00c",
  enc: "6c93e09869df3402d7bf231bf540fadd35cd56be14f97178f0954db94b7fc256",
  pt: "4265617574792069732074727574682c20747275746820626561757479",
  aad: "436f756e742d30",
  ct: "e5d84cd531cfb583096e7cfa9641bd3079cf3a91cda813c52deb5f512be9931980a41de125a925cdad859d5b7a",
};

async function wikiTestHpkeSuite() {
  const hpke = await globalThis.wikiIslands.hpke();
  return { hpke, suite: new hpke.CipherSuite({ kem: new hpke.DhkemX25519HkdfSha256(), kdf: new hpke.HkdfSha256(), aead: new hpke.Aes256Gcm() }) };
}

// The vector run both ways: its ciphertext opened with the recipient's
// private key, and its plaintext sealed with its ephemeral key pair, which
// gives its enc and its ciphertext. JSON {opened, enc, ct}, in hexadecimal.
async function wiki_test_hpke_vector() {
  const v = wikiTestHpkeVector;
  const { hpke, suite } = await wikiTestHpkeSuite();
  const kem = new hpke.DhkemX25519HkdfSha256();
  const skR = await kem.importKey("raw", wikiTestHex(v.skRm).buffer, false);
  const pkR = await kem.importKey("raw", wikiTestHex(v.pkRm).buffer, true);
  const recipient = await suite.createRecipientContext({ recipientKey: skR, enc: wikiTestHex(v.enc).buffer, info: wikiTestHex(v.info).buffer });
  const opened = await recipient.open(wikiTestHex(v.ct).buffer, wikiTestHex(v.aad).buffer);
  const ekm = { privateKey: await kem.importKey("raw", wikiTestHex(v.skEm).buffer, false), publicKey: await kem.importKey("raw", wikiTestHex(v.pkEm).buffer, true) };
  const sender = await suite.createSenderContext({ recipientPublicKey: pkR, info: wikiTestHex(v.info).buffer, ekm });
  const sealed = await sender.seal(wikiTestHex(v.pt).buffer, wikiTestHex(v.aad).buffer);
  return JSON.stringify({ opened: wikiTestToHex(opened), enc: wikiTestToHex(sender.enc), ct: wikiTestToHex(sealed) });
}

// A key sealed to a key pair the browser made, whose private key cannot be
// exported, as a user's is kept (jsbits/vault.js), and opened with it, from
// its raw public key alone as the directory gives it: JSON {opened,
// extractable}.
async function wiki_test_hpke_round_trip() {
  const { hpke, suite } = await wikiTestHpkeSuite();
  const pair = await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"]);
  const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
  const recipientPublicKey = await new hpke.DhkemX25519HkdfSha256().importKey("raw", raw, true);
  const secret = new TextEncoder().encode("a space's key, 32 bytes of it!!!");
  const info = new TextEncoder().encode("wiki-grant/1 space s1 k1");
  const sealed = await suite.seal({ recipientPublicKey, info }, secret);
  const opened = await suite.open({ recipientKey: pair.privateKey, enc: sealed.enc, info }, sealed.ct);
  return JSON.stringify({ opened: new TextDecoder().decode(opened), extractable: pair.privateKey.extractable });
}
