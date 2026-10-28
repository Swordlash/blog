-- | WebAuthn, the server's side of passkeys (WP5.21 of docs/PLAN.md),
-- written here rather than taken from a package: what the wiki needs is
-- small. A passkey is registered ('verifyRegistration') and then used
-- ('verifyAssertion') to unlock the assistant's vault
-- ("Wiki.Server.Vault"). Neither signs anyone in.
--
-- = Registration
--
-- The browser asks the authenticator for a new credential, for the wiki
-- as the relying party, with a challenge from the server. It sends back
-- the client data (JSON the browser writes: the kind of request, the
-- challenge, the page's origin) and the attestation object (CBOR: the
-- authenticator data, and an attestation statement). The wiki asks for no
-- attestation, and does not check a statement: it does not care which
-- make of authenticator a user has. It checks the client data, that the
-- authenticator data is for the wiki's relying-party id with the user
-- present and verified, and takes the credential's id and public key (a
-- COSE key, ES256 or RS256) from the authenticator data.
--
-- = Assertion
--
-- The browser asks the authenticator to sign a challenge from the server
-- with the passkey. The wiki checks the client data and the authenticator
-- data as for a registration, and the signature, over the authenticator
-- data followed by the SHA-256 of the client data, with the stored public
-- key. It also checks the passkey's signature counter: an authenticator
-- that counts sends a higher number each time, and a number that is not
-- higher than the last suggests a copy of the passkey ('CounterWentBack').
-- A passkey synced across devices counts nothing, and sends 0 each time,
-- which is accepted.
module Wiki.Server.WebAuthn
  ( -- * What is checked
    Expected (..)

    -- * Registration
  , NewCredential (..)
  , verifyRegistration

    -- * Assertion
  , StoredKey (..)
  , AssertionRefusal (..)
  , verifyAssertion

    -- * The parts
  , AuthenticatorData (..)
  , parseAuthenticatorData
  , CoseKey (..)
  , parseCoseKey
  , coseAlgorithm
  , verifySignature
  , derSignature
  , rpIdHash
  , toBase64Url
  , fromBase64Url
  )
where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm)
import Crypto.ECC (Curve_P256R1)
import Crypto.Error (CryptoFailable (..))
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.PubKey.ECDSA qualified as ECDSA
import Crypto.PubKey.RSA.PKCS15 qualified as PKCS15
import Crypto.PubKey.RSA.Types qualified as RSA
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.ByteArray (constEq, convert)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Protolude

--------------------------------------------------------------------------------
-- What is checked

-- | 'Expected': what a registration or an assertion must have been made
-- for: the challenge the server gave for it, the origins the wiki's pages
-- are served from, and the relying party's id (the wiki's host).
data Expected = Expected
  { challenge :: ByteString
  , origins :: [Text]
  , rpId :: Text
  }
  deriving stock (Eq, Show)

-- | The client data, as the browser writes it.
data ClientData = ClientData
  { kind :: Text
  , challenge :: Text
  , origin :: Text
  , crossOrigin :: Bool
  }

instance FromJSON ClientData where
  parseJSON = withObject "ClientData" $ \o ->
    ClientData <$> o .: "type" <*> o .: "challenge" <*> o .: "origin" <*> o .:? "crossOrigin" .!= False

-- | Check client data of the given type (@webauthn.create@ or
-- @webauthn.get@) against what was expected.
checkClientData :: Text -> Expected -> ByteString -> Either Text ()
checkClientData wanted expected raw = do
  given :: ClientData <- first (const "its client data is not what a browser writes") (eitherDecodeStrict raw)
  unless (given.kind == wanted) (Left ("its client data is of type " <> given.kind <> ", not " <> wanted))
  answered <- maybe (Left "its client data's challenge is not in base64url") Right (fromBase64Url given.challenge)
  unless (answered `constEq` expected.challenge) (Left "it answers another challenge than the one the wiki gave")
  unless (given.origin `elem` expected.origins) (Left ("it was made on another site, " <> given.origin))
  when given.crossOrigin (Left "it was made in a frame of another site")

-- | Check authenticator data against what was expected: made for the
-- wiki's relying party, with the user present and verified.
checkAuthenticator :: Expected -> AuthenticatorData -> Either Text ()
checkAuthenticator expected ad = do
  unless (ad.rpIdHash `constEq` rpIdHash expected.rpId) (Left "it was made for another site than this wiki")
  unless (testBit ad.flags 0) (Left "the authenticator does not say the user was present")
  unless (testBit ad.flags 2) (Left "the authenticator does not say it verified the user")

-- | The SHA-256 of a relying party's id, as the authenticator data
-- starts with it.
rpIdHash :: Text -> ByteString
rpIdHash = sha256 . encodeUtf8

sha256 :: ByteString -> ByteString
sha256 = convert . hashWith SHA256

--------------------------------------------------------------------------------
-- Registration

-- | 'NewCredential': a passkey just registered: its credential id, its
-- public key as the authenticator wrote it (a COSE key, 'parseCoseKey'),
-- the key's algorithm, and the authenticator's signature counter.
data NewCredential = NewCredential
  { credentialId :: ByteString
  , publicKey :: ByteString
  , algorithm :: Int
  , signCount :: Word32
  }
  deriving stock (Eq, Show)

-- | Check a registration, from its client data and attestation object;
-- the new credential, or why it is refused.
verifyRegistration :: Expected -> ByteString -> ByteString -> Either Text NewCredential
verifyRegistration expected clientData attestation = do
  checkClientData "webauthn.create" expected clientData
  term <- cbor "its attestation object" attestation
  authBytes <- case term of
    TMap pairs | Just (TBytes b) <- lookupKey (TString "authData") pairs -> Right b
    _ -> Left "its attestation object has no authenticator data"
  ad <- parseAuthenticatorData authBytes
  checkAuthenticator expected ad
  (credentialId, publicKey) <- maybe (Left "its authenticator data has no credential") Right ad.attested
  key <- parseCoseKey publicKey
  pure NewCredential {credentialId, publicKey, algorithm = coseAlgorithm key, signCount = ad.signCount}

--------------------------------------------------------------------------------
-- Assertion

-- | 'StoredKey': what the wiki keeps of a passkey to check its
-- assertions: its public key (a COSE key) and the last signature counter
-- it sent.
data StoredKey = StoredKey
  { publicKey :: ByteString
  , signCount :: Word32
  }
  deriving stock (Eq, Show)

-- | 'AssertionRefusal': why an assertion is refused.
data AssertionRefusal
  = -- | It is not a valid answer to the wiki's challenge, by this passkey.
    Refused Text
  | -- | It is valid, but its signature counter is not higher than the last
    -- one: the stored and the received counter. The passkey may have been
    -- copied.
    CounterWentBack Word32 Word32
  deriving stock (Eq, Show)

-- | Check an assertion of a stored passkey, from its client data,
-- authenticator data and signature; the passkey's new signature counter,
-- or why it is refused.
verifyAssertion :: Expected -> StoredKey -> ByteString -> ByteString -> ByteString -> Either AssertionRefusal Word32
verifyAssertion expected stored clientData authBytes signature = do
  first Refused (checkClientData "webauthn.get" expected clientData)
  ad <- first Refused (parseAuthenticatorData authBytes)
  first Refused (checkAuthenticator expected ad)
  key <- first Refused (parseCoseKey stored.publicKey)
  unless (verifySignature key (authBytes <> sha256 clientData) signature) (Left (Refused "its signature is not the passkey's"))
  when ((ad.signCount /= 0 || stored.signCount /= 0) && ad.signCount <= stored.signCount) $
    Left (CounterWentBack stored.signCount ad.signCount)
  pure ad.signCount

--------------------------------------------------------------------------------
-- The parts

-- | 'AuthenticatorData': the authenticator data's parts: the SHA-256 of
-- the relying party's id it was made for, its flags (bit 0: the user was
-- present; bit 2: verified; bit 6: a credential follows), its signature
-- counter, and, in a registration, the new credential's id and public key.
data AuthenticatorData = AuthenticatorData
  { rpIdHash :: ByteString
  , flags :: Word8
  , signCount :: Word32
  , attested :: Maybe (ByteString, ByteString)
  }
  deriving stock (Eq, Show)

-- | Authenticator data read from its bytes: 32 bytes of the relying party's
-- hash, a byte of flags, four of the counter (big-endian), and, when bit 6
-- is set, the attested credential: 16 bytes of the authenticator's model,
-- the credential id's length in two bytes, the id, and the COSE key, whose
-- length is that of its CBOR.
parseAuthenticatorData :: ByteString -> Either Text AuthenticatorData
parseAuthenticatorData bytes = do
  when (BS.length bytes < 37) (Left "its authenticator data is too short")
  let flags = BS.index bytes 32
      signCount = bigEndian (BS.take 4 (BS.drop 33 bytes))
  attested <-
    if testBit flags 6
      then do
        let afterModel = BS.drop (37 + 16) bytes
        when (BS.length afterModel < 2) (Left "its attested credential is cut short")
        let idLength = fromIntegral (bigEndian (BS.take 2 afterModel) :: Word16)
            credentialId = BS.take idLength (BS.drop 2 afterModel)
            keyAndRest = BS.drop (2 + idLength) afterModel
        when (BS.length credentialId < idLength || idLength == 0) (Left "its credential id is cut short")
        case deserialiseFromBytes decodeTerm (BSL.fromStrict keyAndRest) of
          Left _ -> Left "its credential's public key is not CBOR"
          Right (rest, _) -> Right (Just (credentialId, BS.take (BS.length keyAndRest - fromIntegral (BSL.length rest)) keyAndRest))
      else Right Nothing
  pure AuthenticatorData {rpIdHash = BS.take 32 bytes, flags, signCount, attested}

-- | 'CoseKey': a credential's public key: ES256 (ECDSA on P-256 with
-- SHA-256: the point's coordinates, 32 bytes each) or RS256 (RSA PKCS#1
-- v1.5 with SHA-256: the modulus and the exponent).
data CoseKey
  = Es256 ByteString ByteString
  | Rs256 Integer Integer
  deriving stock (Eq, Show)

-- | A COSE key read from its CBOR: a map whose key 1 is its type (2 for
-- an elliptic curve, 3 for RSA) and key 3 its algorithm (-7 for ES256,
-- -257 for RS256); for ES256, -1 is the curve (1, P-256), -2 and -3 the
-- coordinates; for RSA, -1 is the modulus and -2 the exponent.
parseCoseKey :: ByteString -> Either Text CoseKey
parseCoseKey bytes =
  cbor "its public key" bytes >>= \case
    TMap pairs -> case (int 1, int 3) of
      (Just 2, Just (-7))
        | Just 1 <- int (-1)
        , Just x <- byteField (-2)
        , Just y <- byteField (-3)
        , BS.length x == 32
        , BS.length y == 32 ->
            Right (Es256 x y)
      (Just 3, Just (-257))
        | Just n <- byteField (-1)
        , Just e <- byteField (-2) ->
            Right (Rs256 (unsigned n) (unsigned e))
      _ -> Left "its public key is of a kind the wiki does not take: it takes ES256 and RS256"
      where
        field k = lookupKey (TInt k) pairs <|> lookupKey (TInteger (fromIntegral k)) pairs
        int k =
          field k >>= \case
            TInt i -> Just i
            TInteger i -> Just (fromIntegral i)
            _ -> Nothing
        byteField k =
          field k >>= \case
            TBytes b -> Just b
            _ -> Nothing
    _ -> Left "its public key is not a COSE key"

-- | A key's COSE algorithm: -7 for ES256, -257 for RS256.
coseAlgorithm :: CoseKey -> Int
coseAlgorithm = \case
  Es256 _ _ -> -7
  Rs256 _ _ -> -257

-- | Whether a signature of a message is the key's. ES256 signatures come
-- DER-encoded, as WebAuthn sends them ('derSignature').
verifySignature :: CoseKey -> ByteString -> ByteString -> Bool
verifySignature key message signature = case key of
  Es256 x y -> fromMaybe False $ do
    point <- passed (ECDSA.decodePublic curve (BS.cons 4 (x <> y)))
    integers <- derSignature signature
    sig <- passed (ECDSA.signatureFromIntegers curve integers)
    pure (ECDSA.verify curve SHA256 point sig message)
  Rs256 n e ->
    PKCS15.verifyDigest RSA.PublicKey {RSA.public_size = byteLength n, RSA.public_n = n, RSA.public_e = e} (hashWith SHA256 message) signature
  where
    curve = Proxy :: Proxy Curve_P256R1
    passed = \case
      CryptoPassed a -> Just a
      CryptoFailed _ -> Nothing
    byteLength i = length (takeWhile (> 0) (iterate (`div` 256) i))

-- | The two integers of an ECDSA signature in DER, @SEQUENCE { INTEGER r,
-- INTEGER s }@, as WebAuthn sends an ES256 signature.
derSignature :: ByteString -> Maybe (Integer, Integer)
derSignature bytes = do
  (0x30, body, rest) <- element bytes
  guard (BS.null rest)
  (0x02, r, afterR) <- element body
  (0x02, s, afterS) <- element afterR
  guard (BS.null afterS)
  pure (unsigned r, unsigned s)
  where
    element b = do
      (tag, afterTag) <- BS.uncons b
      (size, afterSize) <- lengthOf afterTag
      guard (BS.length afterSize >= size)
      pure (tag, BS.take size afterSize, BS.drop size afterSize)
    lengthOf b = do
      (first', afterFirst) <- BS.uncons b
      if first' < 0x80
        then pure (fromIntegral first', afterFirst)
        else do
          guard (first' == 0x81)
          (size, afterSize) <- BS.uncons afterFirst
          pure (fromIntegral size, afterSize)

-- | Bytes in base64url without padding, as WebAuthn writes them.
toBase64Url :: ByteString -> Text
toBase64Url = decodeUtf8 . convertToBase Base64URLUnpadded

-- | The bytes of base64url, with or without padding.
fromBase64Url :: Text -> Maybe ByteString
fromBase64Url t = rightToMaybe (convertFromBase Base64URLUnpadded (encodeUtf8 (T.dropWhileEnd (== '=') t)) :: Either [Char] ByteString)

-- | Bytes as an unsigned big-endian number.
unsigned :: ByteString -> Integer
unsigned = BS.foldl' (\n b -> n * 256 + fromIntegral b) 0

bigEndian :: (Num a, Bits a) => ByteString -> a
bigEndian = BS.foldl' (\n b -> (n `shiftL` 8) .|. fromIntegral b) 0

-- | One item of CBOR, the whole of the bytes.
cbor :: Text -> ByteString -> Either Text Term
cbor what bytes = case deserialiseFromBytes decodeTerm (BSL.fromStrict bytes) of
  Right (rest, term) | BSL.null rest -> Right term
  _ -> Left (what <> " is not CBOR")

lookupKey :: Term -> [(Term, Term)] -> Maybe Term
lookupKey k pairs = snd <$> find ((== k) . fst) pairs
