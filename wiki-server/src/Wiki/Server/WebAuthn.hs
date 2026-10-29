{-# LANGUAGE DataKinds #-}

-- | WebAuthn, the server's side of passkeys (WP5.21 of docs/PLAN.md),
-- through the @webauthn@ package (WP5.27): the package reads what the
-- browser sends and checks it, and this module says what the wiki asks of
-- a passkey and turns the package's errors into sentences. A passkey is
-- registered ('verifyRegistration') and then used ('verifyAssertion') to
-- unlock the assistant's vault ("Wiki.Server.Vault"). Neither signs anyone
-- in.
--
-- = Registration
--
-- The browser asks the authenticator for a new credential, for the wiki
-- as the relying party, with a challenge from the server. It sends back
-- the client data (JSON the browser writes: the kind of request, the
-- challenge, the page's origin) and the attestation object (CBOR: the
-- authenticator data, and an attestation statement). The wiki asks for no
-- attestation, and keeps no record of which make of authenticator a user
-- has. The package checks the client data, that the authenticator data is
-- for the wiki's relying-party id with the user present and verified, and
-- that the key is ES256 or RS256, the two algorithms the wiki takes. The
-- wiki keeps the credential's id and its public key, a COSE key, as the
-- authenticator wrote it.
--
-- = Assertion
--
-- The browser asks the authenticator to sign a challenge from the server
-- with the passkey. The package checks the client data and the
-- authenticator data as for a registration, and the signature, over the
-- authenticator data followed by the SHA-256 of the client data, with the
-- stored public key. It also compares the passkey's signature counter
-- with the stored one: an authenticator that counts sends a higher number
-- each time, and a number that is not higher than the last suggests a
-- copy of the passkey ('CounterWentBack'). A passkey synced across devices
-- counts nothing, and sends 0 each time, which is accepted.
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
  , CoseKey
  , parseCoseKey
  , coseAlgorithm
  , verifySignature
  , rpIdHash
  , toBase64Url
  , fromBase64Url
  )
where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm, encodeTerm)
import Codec.CBOR.Write (toStrictByteString)
import Codec.Serialise (decode, serialise)
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.WebAuthn.AttestationStatementFormat.None qualified as None
import Crypto.WebAuthn.Cose.Internal.Verify qualified as Verify
import Crypto.WebAuthn.Cose.PublicKeyWithSignAlg qualified as Cose
import Crypto.WebAuthn.Cose.SignAlg qualified as Cose
import Crypto.WebAuthn.Encoding.Binary (decodeAuthenticatorData, decodeCollectedClientData)
import Crypto.WebAuthn.Model.Kinds (CeremonyKind (..))
import Crypto.WebAuthn.Model.Types qualified as M
import Crypto.WebAuthn.Operation.Authentication (AuthenticationError (..), AuthenticationResult (..), SignatureCounterResult (..), verifyAuthenticationResponse)
import Crypto.WebAuthn.Operation.CredentialEntry (CredentialEntry (..))
import Crypto.WebAuthn.Operation.Registration (RegistrationError (..), RegistrationResult (..), verifyRegistrationResponse)
import Data.Aeson (decodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString.Lazy qualified as BSL
import Data.Hourglass (Elapsed (..), timeConvert)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as T
import Data.Validation (Validation (..))
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

-- | The client data of a ceremony as the package read it, with the check
-- the package does not make: that the page that asked was not in a frame
-- of another site. When the package cannot read it, the refusal says why
-- in the wiki's words, never the package's (which name its internals):
-- the client data's type when it is another ceremony's, read from the JSON
-- only then.
clientDataFor :: Text -> ByteString -> Either Text (M.CollectedClientData c 'True) -> Either Text (M.CollectedClientData c 'True)
clientDataFor wanted raw decoded = do
  given <- first (const refusal) decoded
  when (given.ccdCrossOrigin == Just True) (Left "it was made in a frame of another site")
  pure given
  where
    refusal = case decodeStrict raw >>= parseMaybe (withObject "client data" (.: "type")) of
      Just kind | kind /= wanted -> "its client data is of type " <> kind <> ", not " <> wanted
      _ -> "its client data is not what a browser writes"

-- | The origins the package compares the client data's with.
originsOf :: Expected -> Either Text (NonEmpty M.Origin)
originsOf expected = maybe (Left "the wiki has no address to take a passkey on") Right (NonEmpty.nonEmpty (map M.Origin expected.origins))

-- | The SHA-256 of a relying party's id, as the authenticator data
-- starts with it.
rpIdHash :: Text -> ByteString
rpIdHash = convert . hashWith SHA256 . encodeUtf8

--------------------------------------------------------------------------------
-- Registration

-- | 'NewCredential': a passkey just registered: its credential id, its
-- public key (a COSE key, 'parseCoseKey', in the package's canonical
-- encoding, which is how it reads a key back), the key's algorithm, and
-- the authenticator's signature counter.
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
  client <- clientDataFor "webauthn.create" clientData (decodeCollectedClientData @'Registration clientData)
  -- The wiki asks for no attestation and keeps no verdict on one, so only
  -- the authenticator data is read from the attestation object, and the
  -- registration is checked as the format "none": a statement an
  -- authenticator sends anyway, in whatever format, is never read.
  authBytes <- case deserialiseFromBytes decodeTerm (BSL.fromStrict attestation) of
    Right (rest, TMap pairs)
      | BSL.null rest, Just (TBytes b) <- snd <$> find ((== TString "authData") . fst) pairs -> Right b
    _ -> Left "its attestation object is not what a browser writes"
  authData <- first (const "its authenticator data is not what an authenticator writes") (decodeAuthenticatorData @'Registration authBytes)
  origins <- originsOf expected
  let credentialId = case authData.adAttestedCredentialData of
        M.AttestedCredentialData {acdCredentialId} -> acdCredentialId
      unattested = M.AttestationObject {aoAuthData = authData, aoFmt = None.Format, aoAttStmt = ()}
      credential =
        M.Credential
          { cIdentifier = credentialId
          , cResponse = M.AuthenticatorResponseRegistration {arrClientData = client, arrAttestationObject = unattested, arrTransports = []}
          , cAuthenticatorAttachment = Nothing
          , cClientExtensionResults = M.AuthenticationExtensionsClientOutputs {aecoCredProps = Nothing}
          }
  -- The time is the one the package would check certificates at: as the
  -- format "none" has none, any time does.
  result <- first (registrationRefusal . NonEmpty.head) (outcome (verifyRegistrationResponse origins (M.RpIdHash (hashWith SHA256 (encodeUtf8 expected.rpId))) mempty (timeConvert (Elapsed 0)) (creation expected) credential))
  let entry = result.rrEntry
  key <- parseCoseKey (M.unPublicKeyBytes entry.cePublicKeyBytes)
  pure
    NewCredential
      { credentialId = M.unCredentialId entry.ceCredentialId
      , publicKey = BSL.toStrict (serialise key)
      , algorithm = coseAlgorithm key
      , signCount = M.unSignatureCounter entry.ceSignCounter
      }

-- | The options a registration is checked against: this challenge, the
-- user verified, an ES256 or RS256 key, and no attestation. The user and
-- the relying party's name are the browser's business, and the package
-- does not check them.
creation :: Expected -> M.CredentialOptions 'Registration
creation expected =
  M.CredentialOptionsRegistration
    { corRp = M.CredentialRpEntity {creId = Just (M.RpId expected.rpId), creName = "wiki"}
    , corUser = M.CredentialUserEntity {cueId = M.UserHandle "", cueDisplayName = "", cueName = ""}
    , corChallenge = M.Challenge expected.challenge
    , corPubKeyCredParams = [M.CredentialParameters {cpTyp = M.CredentialTypePublicKey, cpAlg = alg} | alg <- takenAlgorithms]
    , corTimeout = Nothing
    , corExcludeCredentials = []
    , corAuthenticatorSelection = Just M.AuthenticatorSelectionCriteria {ascAuthenticatorAttachment = Nothing, ascResidentKey = M.ResidentKeyRequirementDiscouraged, ascUserVerification = M.UserVerificationRequirementRequired}
    , corHints = []
    , corAttestation = M.AttestationConveyancePreferenceNone
    , corExtensions = Nothing
    }

-- | Why a registration is refused, as a sentence that completes "The
-- passkey was refused: …".
registrationRefusal :: RegistrationError -> Text
registrationRefusal = \case
  RegistrationChallengeMismatch _ _ -> "it answers another challenge than the one the wiki gave"
  RegistrationOriginMismatch _ origin -> "it was made on another site, " <> M.unOrigin origin
  RegistrationRpIdHashMismatch _ _ -> "it was made for another site than this wiki"
  RegistrationUserNotPresent -> "the authenticator does not say the user was present"
  RegistrationUserNotVerified -> "the authenticator does not say it verified the user"
  RegistrationPublicKeyAlgorithmDisallowed _ _ -> notTaken
  RegistrationAttestationFormatError _ _ -> "its attestation statement does not hold"

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
--
-- The wiki looks a passkey up by its credential id, and a passkey belongs
-- to the user whose vault it unlocks, so the package is given neither: the
-- credential id and the user handle it compares are the same empty ones on
-- both sides.
verifyAssertion :: Expected -> StoredKey -> ByteString -> ByteString -> ByteString -> Either AssertionRefusal Word32
verifyAssertion expected stored clientData authBytes signature = do
  client <- first Refused (clientDataFor "webauthn.get" clientData (decodeCollectedClientData @'Authentication clientData))
  authData <- first (const (Refused "its authenticator data is not what an authenticator writes")) (decodeAuthenticatorData @'Authentication authBytes)
  origins <- first Refused (originsOf expected)
  let nobody = M.UserHandle ""
      entry =
        CredentialEntry
          { ceCredentialId = M.CredentialId ""
          , ceUserHandle = nobody
          , cePublicKeyBytes = M.PublicKeyBytes (canonicalCoseKey stored.publicKey)
          , ceSignCounter = M.SignatureCounter stored.signCount
          , ceTransports = []
          }
      options =
        M.CredentialOptionsAuthentication
          { coaChallenge = M.Challenge expected.challenge
          , coaTimeout = Nothing
          , coaRpId = Just (M.RpId expected.rpId)
          , coaAllowCredentials = []
          , coaUserVerification = M.UserVerificationRequirementRequired
          , coaHints = []
          , coaExtensions = Nothing
          }
      credential =
        M.Credential
          { cIdentifier = M.CredentialId ""
          , cResponse = M.AuthenticatorResponseAuthentication {araClientData = client, araAuthenticatorData = authData, araSignature = M.AssertionSignature signature, araUserHandle = Nothing}
          , cAuthenticatorAttachment = Nothing
          , cClientExtensionResults = M.AuthenticationExtensionsClientOutputs {aecoCredProps = Nothing}
          }
      received = M.unSignatureCounter authData.adSignCount
  result <- first (Refused . assertionRefusal . NonEmpty.head) (outcome (verifyAuthenticationResponse origins (M.RpIdHash (hashWith SHA256 (encodeUtf8 expected.rpId))) (Just nobody) entry options credential))
  case result.arSignatureCounterResult of
    SignatureCounterZero -> Right 0
    SignatureCounterUpdated counter -> Right (M.unSignatureCounter counter)
    SignatureCounterPotentiallyCloned -> Left (CounterWentBack stored.signCount received)

-- | Why an assertion is refused, as a sentence.
assertionRefusal :: AuthenticationError -> Text
assertionRefusal = \case
  AuthenticationChallengeMismatch _ _ -> "it answers another challenge than the one the wiki gave"
  AuthenticationOriginMismatch _ origin -> "it was made on another site, " <> M.unOrigin origin
  AuthenticationRpIdHashMismatch _ _ -> "it was made for another site than this wiki"
  AuthenticationUserNotPresent -> "the authenticator does not say the user was present"
  AuthenticationUserNotVerified -> "the authenticator does not say it verified the user"
  AuthenticationSignatureDecodingError _ -> "its stored public key is not a COSE key"
  AuthenticationSignatureInvalid _ -> "its signature is not the passkey's"
  AuthenticationCredentialDisallowed _ _ -> "it is not a passkey the wiki asked for"
  AuthenticationIdentifiedUserHandleMismatch _ _ -> "it is another user's passkey"
  AuthenticationCredentialUserHandleMismatch _ _ -> "it is another user's passkey"
  AuthenticationCannotVerifyUserHandle -> "it names no user"

--------------------------------------------------------------------------------
-- The parts

-- | 'CoseKey': a credential's public key with its signing algorithm, as
-- the package reads a COSE key.
type CoseKey = Cose.PublicKeyWithSignAlg

-- | The algorithms the wiki takes a passkey's key in: ES256 (ECDSA on
-- P-256 with SHA-256) and RS256 (RSA PKCS#1 v1.5 with SHA-256), which
-- every authenticator offers.
takenAlgorithms :: [Cose.CoseSignAlg]
takenAlgorithms = [Cose.CoseAlgorithmES256, Cose.CoseAlgorithmRS256]

notTaken :: Text
notTaken = "its public key is of a kind the wiki does not take: it takes ES256 and RS256"

-- | A COSE key read from its CBOR, if it is ES256 or RS256. The bytes are
-- made canonical first ('canonicalCoseKey'), since the package reads only
-- that encoding.
parseCoseKey :: ByteString -> Either Text CoseKey
parseCoseKey bytes = case deserialiseFromBytes decode (BSL.fromStrict (canonicalCoseKey bytes)) of
  Right (rest, key)
    | BSL.null rest -> if Cose.signAlg key `elem` takenAlgorithms then Right key else Left notTaken
  _ -> Left "its public key is not a COSE key"

-- | A COSE key's CBOR in the encoding the package reads: the parameters an
-- ES256 or RS256 key has (1, the key type; 3, the algorithm; -1, -2 and
-- -3, the curve and coordinates or the modulus and exponent), in that
-- order, each integer in its shortest form, and nothing else. It exists
-- for the keys the wiki stored before it used the package: the
-- hand-written server kept a key as the authenticator wrote it, and read
-- it leniently, so a stored key may have its parameters in another order
-- or one more (a key id). A new key is stored canonical
-- ('verifyRegistration'), and a registration reads the key the
-- authenticator sends strictly, as the package does: CTAP2 requires an
-- authenticator to write canonical CBOR. Bytes that are not a CBOR map
-- are given back as they are, for the package to refuse.
canonicalCoseKey :: ByteString -> ByteString
canonicalCoseKey bytes = case deserialiseFromBytes decodeTerm (BSL.fromStrict bytes) of
  Right (rest, TMap pairs)
    | BSL.null rest ->
        toStrictByteString (encodeTerm (TMap [(TInt k, shortest v) | k <- [1, 3, -1, -2, -3], Just v <- [snd <$> find ((== Just k) . intOf . fst) pairs]]))
  _ -> bytes
  where
    intOf = \case
      TInt i -> Just i
      TInteger i | i >= fromIntegral (minBound :: Int) && i <= fromIntegral (maxBound :: Int) -> Just (fromIntegral i)
      _ -> Nothing
    shortest t = maybe t TInt (intOf t)

-- | A key's COSE algorithm: -7 for ES256, -257 for RS256.
coseAlgorithm :: CoseKey -> Int
coseAlgorithm = Cose.fromCoseSignAlg . Cose.signAlg

-- | Whether a signature of a message is the key's. ES256 signatures come
-- DER-encoded, as WebAuthn sends them.
verifySignature :: CoseKey -> ByteString -> ByteString -> Bool
verifySignature key message signature = isRight (Verify.verify key (Verify.Message message) (Verify.Signature signature))

-- | The package's verdict as an 'Either'.
outcome :: Validation e a -> Either e a
outcome = \case
  Failure e -> Left e
  Success a -> Right a

-- | Bytes in base64url without padding, as WebAuthn writes them.
toBase64Url :: ByteString -> Text
toBase64Url = decodeUtf8 . convertToBase Base64URLUnpadded

-- | The bytes of base64url, with or without padding.
fromBase64Url :: Text -> Maybe ByteString
fromBase64Url t = rightToMaybe (convertFromBase Base64URLUnpadded (encodeUtf8 (T.dropWhileEnd (== '=') t)) :: Either [Char] ByteString)
