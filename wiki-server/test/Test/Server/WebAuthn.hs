-- | WebAuthn as the server checks it ("Wiki.Server.WebAuthn"), against an
-- authenticator played here: a fixed ES256 key pair (and a generated RSA
-- one) that makes and signs as an authenticator would. A registration is
-- taken with its key; one for another challenge, origin or relying party,
-- or without the user verified, is refused; an assertion's signature is
-- checked, and a signature counter that does not go up is reported.
module Test.Server.WebAuthn
  ( spec

    -- * An authenticator played by the tests
  , Authenticator (..)
  , authenticator
  , registration
  , assertion
  , assertionFlagged
  , clientData
  )
where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm, encodeTerm)
import Codec.CBOR.Write (toStrictByteString)
import Crypto.ECC (Curve_P256R1)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.PubKey.ECDSA qualified as ECDSA
import Crypto.PubKey.RSA qualified as RSA
import Crypto.PubKey.RSA.PKCS15 qualified as PKCS15
import Data.Aeson (encode, object, (.=))
import Data.ByteArray (convert)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Server.WebAuthn

-- | 'Authenticator': a passkey played by the tests: its credential id and
-- its ES256 private key.
data Authenticator = Authenticator
  { credentialId :: ByteString
  , key :: ECDSA.PrivateKey Curve_P256R1
  }

curve :: Proxy Curve_P256R1
curve = Proxy

-- | A passkey with this credential id, whose private key is made from the
-- id: fixed, so that a test always signs with the same key.
authenticator :: ByteString -> Authenticator
authenticator credentialId = case ECDSA.decodePrivate curve (convert (hashWith SHA256 credentialId) :: ByteString) of
  CryptoPassed key -> Authenticator {credentialId, key}
  CryptoFailed e -> panic ("no key: " <> show e)

-- | The passkey's public key, as a COSE key.
coseKey :: Authenticator -> ByteString
coseKey a =
  let point = ECDSA.encodePublic curve (ECDSA.toPublic curve a.key) :: ByteString
      (x, y) = BS.splitAt 32 (BS.drop 1 point)
   in toStrictByteString . encodeTerm $ TMap [(TInt 1, TInt 2), (TInt 3, TInt (-7)), (TInt (-1), TInt 1), (TInt (-2), TBytes x), (TInt (-3), TBytes y)]

-- | The client data a browser writes.
clientData :: Text -> ByteString -> Text -> ByteString
clientData kind challenge origin = BSL.toStrict (encode (object ["type" .= kind, "challenge" .= toBase64Url challenge, "origin" .= origin, "crossOrigin" .= False]))

-- | What a browser sends when the passkey is made: its client data and
-- attestation object (format @none@), with the given flags (0x45: the
-- user present and verified, a credential attested).
registration :: Authenticator -> Word8 -> Text -> Text -> ByteString -> (ByteString, ByteString)
registration a flags rpId origin challenge =
  ( clientData "webauthn.create" challenge origin
  , toStrictByteString . encodeTerm $ TMap [(TString "fmt", TString "none"), (TString "attStmt", TMap []), (TString "authData", TBytes authData)]
  )
  where
    authData =
      rpIdHash rpId
        <> BS.singleton flags
        <> BS.pack [0, 0, 0, 0]
        <> BS.replicate 16 0
        <> BS.pack [fromIntegral (BS.length a.credentialId `div` 256), fromIntegral (BS.length a.credentialId `mod` 256)]
        <> a.credentialId
        <> coseKey a

-- | What a browser sends when the passkey is used: its client data, the
-- authenticator data with this counter (the user present and verified),
-- and the signature over both, in DER.
assertion :: Authenticator -> Word32 -> Text -> Text -> ByteString -> IO (ByteString, ByteString, ByteString)
assertion = assertionFlagged 0x05

-- | 'assertion', with the given flags in the authenticator data (0x05:
-- the user present and verified; 0x01: present only).
assertionFlagged :: Word8 -> Authenticator -> Word32 -> Text -> Text -> ByteString -> IO (ByteString, ByteString, ByteString)
assertionFlagged flags a counter rpId origin challenge = do
  let client = clientData "webauthn.get" challenge origin
      authData = rpIdHash rpId <> BS.singleton flags <> BS.pack [fromIntegral (counter `div` (256 ^ k)) | k <- [3, 2, 1, 0 :: Int]]
  signature <- ECDSA.sign curve a.key SHA256 (authData <> convert (hashWith SHA256 client))
  let (r, s) = ECDSA.signatureToIntegers curve signature
  pure (client, authData, der r s)

-- | Two integers as an ECDSA signature in DER.
der :: Integer -> Integer -> ByteString
der r s = element 0x30 (element 0x02 (int r) <> element 0x02 (int s))
  where
    element tag body = BS.pack [tag, fromIntegral (BS.length body)] <> body
    int n =
      let bytes = BS.reverse (BS.unfoldr (\m -> if m == 0 then Nothing else Just (fromIntegral (m `mod` 256), m `div` 256)) n)
       in if BS.null bytes || BS.head bytes >= 0x80 then BS.cons 0 bytes else bytes

spec :: Spec
spec = describe "Wiki.Server.WebAuthn" $ do
  let site = "wiki.example.org"
      origin = "https://wiki.example.org"
      challenge = "a challenge of thirty-two bytes!"
      expected = Expected {challenge, origins = [origin], rpId = site}
      passkey = authenticator "credential-one"
      owner = Identified "u1"
      registered = do
        let (client, attestation) = registration passkey 0x45 site origin challenge
        either (\why -> panic ("refused: " <> why)) pure (verifyRegistration expected client attestation)

  describe "a registration" $ do
    it "is taken with the credential's id, its ES256 key and its counter" $ do
      new <- registered
      new.credentialId `shouldBe` "credential-one"
      new.algorithm `shouldBe` (-7)
      new.signCount `shouldBe` 0
      parseCoseKey new.publicKey `shouldSatisfy` isRight

    it "is refused for another challenge, another origin, another relying party, or a user not verified" $ do
      let refusedAs what (client, attestation) = case verifyRegistration expected client attestation of
            Left why -> why `shouldSatisfy` T.isInfixOf what
            Right _ -> expectationFailure ("taken: " <> toS what)
      refusedAs "another challenge" (registration passkey 0x45 site origin "another challenge, also 32 bytes")
      refusedAs "another site, https://evil.example" (registration passkey 0x45 site "https://evil.example" challenge)
      refusedAs "another site than this wiki" (registration passkey 0x45 "evil.example" origin challenge)
      refusedAs "verified" (registration passkey 0x41 site origin challenge)
      -- A use of a passkey is not its making.
      let (_, attestation) = registration passkey 0x45 site origin challenge
      verifyRegistration expected (clientData "webauthn.get" challenge origin) attestation `shouldSatisfy` isLeft

  describe "a registration, further" $ do
    it "says which ceremony client data of the other type was for" $ do
      let (_, attestation) = registration passkey 0x45 site origin challenge
      verifyRegistration expected (clientData "webauthn.get" challenge origin) attestation
        `shouldBe` Left "its client data is of type webauthn.get, not webauthn.create"

    it "takes a passkey whose authenticator attests anyway, in any format, without reading the statement" $ do
      let (client, attestation) = registration passkey 0x45 site origin challenge
          packed = case deserialiseFromBytes decodeTerm (BSL.fromStrict attestation) of
            Right (_, TMap pairs) ->
              toStrictByteString . encodeTerm . TMap $
                [(k, v) | (k, v) <- pairs, k /= TString "fmt", k /= TString "attStmt"]
                  <> [(TString "fmt", TString "packed"), (TString "attStmt", TMap [(TString "alg", TInt (-7)), (TString "sig", TBytes "not a signature")])]
            _ -> panic "not an attestation object"
      ((\n -> n.credentialId) <$> verifyRegistration expected client packed) `shouldBe` Right "credential-one"
      -- A format the package does not know, with a statement of no shape.
      let unknown = case deserialiseFromBytes decodeTerm (BSL.fromStrict attestation) of
            Right (_, TMap pairs) ->
              toStrictByteString . encodeTerm . TMap $
                [(k, v) | (k, v) <- pairs, k /= TString "fmt", k /= TString "attStmt"]
                  <> [(TString "fmt", TString "a-format-of-its-own"), (TString "attStmt", TString "anything")]
            _ -> panic "not an attestation object"
      ((\n -> n.credentialId) <$> verifyRegistration expected client unknown) `shouldBe` Right "credential-one"

  describe "an assertion" $ do
    it "is taken with its signature by the passkey, and gives its counter" $ do
      new <- registered
      (client, authData, signature) <- assertion passkey 7 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 3} (Answer client authData signature Nothing) `shouldBe` Right 7

    it "is refused when another key signed it, or it signs something else" $ do
      new <- registered
      (client, authData, _) <- assertion passkey 1 site origin challenge
      (_, _, otherSignature) <- assertion (authenticator "credential-two") 1 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 0} (Answer client authData otherSignature Nothing) `shouldSatisfy` isRefused
      (otherClient, _, signature) <- assertion passkey 1 site origin "another challenge, also 32 bytes"
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 0} (Answer otherClient authData signature Nothing) `shouldSatisfy` isRefused
      (_, _, signed) <- assertion passkey 1 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 0} (Answer client authData signed Nothing) `shouldBe` Right 1

    it "reports a counter that does not go up, and takes a passkey that counts nothing" $ do
      new <- registered
      (client, authData, signature) <- assertion passkey 5 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 5} (Answer client authData signature Nothing) `shouldBe` Left (CounterWentBack 5 5)
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 9} (Answer client authData signature Nothing) `shouldBe` Left (CounterWentBack 9 5)
      (synced, syncedData, syncedSignature) <- assertion passkey 0 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = new.publicKey, signCount = 0} (Answer synced syncedData syncedSignature Nothing) `shouldBe` Right 0

  describe "whose passkey an assertion is" $ do
    it "is the user handle's, which a sign-in with a passkey alone needs and checks" $ do
      new <- registered
      (client, authData, signature) <- assertion passkey 2 site origin challenge
      let stored = StoredKey {publicKey = new.publicKey, signCount = 1}
      verifyAssertion expected (Unnamed "u1") stored (Answer client authData signature (Just "u1")) `shouldBe` Right 2
      verifyAssertion expected (Unnamed "u1") stored (Answer client authData signature Nothing) `shouldBe` Left (Refused "the authenticator did not say whose passkey it is")
      verifyAssertion expected (Unnamed "u1") stored (Answer client authData signature (Just "u2")) `shouldBe` Left (Refused "it is another user's passkey")

    it "must be the user's the wiki knows, when it knows who asks" $ do
      new <- registered
      (client, authData, signature) <- assertion passkey 2 site origin challenge
      let stored = StoredKey {publicKey = new.publicKey, signCount = 1}
      verifyAssertion expected (Identified "u1") stored (Answer client authData signature (Just "u1")) `shouldBe` Right 2
      verifyAssertion expected (Identified "u1") stored (Answer client authData signature (Just "u2")) `shouldBe` Left (Refused "it is another user's passkey")

    it "is refused when the authenticator does not say it verified the user" $ do
      new <- registered
      (client, authData, signature) <- assertionFlagged 0x01 passkey 2 site origin challenge
      verifyAssertion expected (Unnamed "u1") StoredKey {publicKey = new.publicKey, signCount = 1} (Answer client authData signature (Just "u1"))
        `shouldBe` Left (Refused "the authenticator does not say it verified the user")

    it "names its challenge in its client data" $ do
      challengeOf (clientData "webauthn.get" challenge origin) `shouldBe` Just challenge
      challengeOf "not JSON" `shouldBe` Nothing

  describe "a key stored before the wiki used the webauthn package" $
    it "is read in another order and with a key id, and checks an assertion" $ do
      new <- registered
      stored <- case deserialiseFromBytes decodeTerm (BSL.fromStrict new.publicKey) of
        Right (_, TMap pairs) -> pure (toStrictByteString (encodeTerm (TMap ((TInt 2, TBytes "a key id") : reverse pairs))))
        _ -> panic "not a COSE key"
      (client, authData, signature) <- assertion passkey 2 site origin challenge
      verifyAssertion expected owner StoredKey {publicKey = stored, signCount = 1} (Answer client authData signature Nothing) `shouldBe` Right 2

  describe "an RS256 key" $
    it "checks its signatures" $ do
      (public, private) <- RSA.generate 256 65537
      let cose = toStrictByteString . encodeTerm $ TMap [(TInt 1, TInt 3), (TInt 3, TInt (-257)), (TInt (-1), TBytes (bytesOf (RSA.public_n public))), (TInt (-2), TBytes (bytesOf (RSA.public_e public)))]
      key <- either (\why -> panic why) pure (parseCoseKey cose)
      coseAlgorithm key `shouldBe` (-257)
      signature <- either (panic . show) pure =<< PKCS15.signSaferDigest private (hashWith SHA256 ("signed" :: ByteString))
      verifySignature key "signed" signature `shouldBe` True
      verifySignature key "not signed" signature `shouldBe` False

  describe "the parts" $
    it "writes and reads base64url without padding" $ do
      toBase64Url "\251\255" `shouldBe` "-_8"
      fromBase64Url "-_8" `shouldBe` Just "\251\255"
      fromBase64Url "-_8=" `shouldBe` Just "\251\255"
  where
    isRefused = \case
      Left (Refused _) -> True
      _ -> False
    bytesOf n = BS.reverse (BS.unfoldr (\m -> if m == 0 then Nothing else Just (fromIntegral (m `mod` 256), m `div` 256)) n)
