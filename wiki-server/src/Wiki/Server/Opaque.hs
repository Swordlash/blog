-- | The server's side of the passwords through OPAQUE (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"): its long-term secret, the records it
-- stores, the sign-ins under way, and the sessions that have just proved
-- their password.
--
-- = The server's secret
--
-- 'Crypto.OPAQUE.ServerSetup' is the server's key pair, the seed every
-- user's OPRF key is derived from, and the fake record that answers for a
-- login without a record. It is made the first time it is needed and kept
-- in the settings table, beside the key of the unsubscribe links, as safe
-- as the database file. Losing it makes every record useless; a thief of
-- the database who has it can test password guesses against the records,
-- each guess costing one Argon2id.
--
-- = Stretching
--
-- The browser stretches the OPRF's output with Argon2id before it derives
-- anything from it ('Stretch'). The parameters are stored beside each
-- record, so that a later server can ask for more for new records without
-- breaking the old ones. 'defaultStretch' is what new records get: 64 MiB
-- and two passes, libsodium's interactive limits, which take about half a
-- second in a browser tab (the RFC's own recommendation, 2 GiB, is too
-- much for one). The salt is the RFC's sixteen zero bytes: the OPRF's
-- output is already unique to the user and the server.
--
-- = Sign-ins under way
--
-- Between the first and the last message of a sign-in the server keeps
-- what it needs to check the last one ('Attempts'): the expected MAC and
-- the session key, the user and the login, for two minutes, under a random
-- id. The map is bounded, and every start counts toward the limit on failed
-- sign-ins ("Wiki.Server.Limiter"), so that starting sign-ins is no free way
-- to fill the server's memory.
--
-- = Proofs
--
-- A session that has just proved its password again ('Proofs'), through
-- the same exchange, may make one change that needs the password, within
-- five minutes. So may the session a sign-in from before OPAQUE has just
-- made, so that the browser can register the account's record at once
-- without sending the password a second time.
module Wiki.Server.Opaque
  ( -- * The server's secret
    loadServerSetup
  , setupKey
  , setupFromText

    -- * Stretching
  , defaultStretch
  , stretchText
  , readStretch

    -- * Records
  , storedRecordOf
  , recordFromStored
  , registerHere
  , registrationChallenge

    -- * Sign-ins under way
  , Attempts
  , Attempt (..)
  , newAttempts
  , holdAttempt
  , takeAttempt
  , respondTo
  , attemptLifetime

    -- * Proofs
  , Proofs
  , newProofs
  , prove
  , takeProof
  , proofLifetime
  )
where

import Crypto.OPAQUE (CredentialId (..), Encoding (..), KE1, RegistrationRecord, ServerLoginState, ServerSetup, defaultIdentities, finalizeRegistration, generateServerSetup, registrationRequest, registrationResponse, serverRespond)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Protolude
import Wiki.Api.Opaque (Message (..), PasswordRecord (..), RegistrationChallenge (..), Stretch (..), bytesOf, messageOf, opaqueConfig)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Password (..))
import Wiki.Server.Password (newToken)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (StoredRecord (..), keepSetting)

--------------------------------------------------------------------------------
-- The server's secret

-- | The server's 'ServerSetup', from the settings table, made and stored
-- there the first time. It runs in a write transaction, since the first
-- call writes; a setup that does not decode (a database edited by hand)
-- stops the server's sign-ins rather than replace it.
loadServerSetup :: forall be. (Backend be) => Db be ServerSetup
loadServerSetup = do
  fresh <- liftIO generateServerSetup >>= either (\e -> panic ("opaque: no server setup: " <> show e)) pure
  kept <- keepSetting setupKey (messageOf (encode fresh)).text
  maybe (panic "opaque: the server setup in the settings table does not decode") pure (setupFromText kept)

-- | The settings table's row of the server's 'ServerSetup'.
setupKey :: Text
setupKey = "opaque-server-setup"

-- | The 'ServerSetup' the settings table's row holds, if it decodes.
setupFromText :: Text -> Maybe ServerSetup
setupFromText t = bytesOf (Message t) >>= rightToMaybe . decode

--------------------------------------------------------------------------------
-- Stretching

-- | The stretching new records get (see the module's haddock): 128 MiB,
-- four passes, about half a second as wasm in Chromium (WP5.74a's
-- measurement on a four-core machine: 0.53 s; 64 MiB and two passes took
-- 0.13 s).
defaultStretch :: Stretch
defaultStretch = Stretch {opsLimit = 4, memLimit = 128 * 1024 * 1024}

-- | A 'Stretch' as the users table stores it: @t=\<passes>,m=\<bytes>@.
stretchText :: Stretch -> Text
stretchText s = "t=" <> show s.opsLimit <> ",m=" <> show s.memLimit

-- | A 'Stretch' from the users table, within what a browser can afford.
readStretch :: Text -> Maybe Stretch
readStretch t = case map (T.breakOn "=") (T.splitOn "," t) of
  [("t", ops), ("m", mem)] -> do
    opsLimit <- number ops
    memLimit <- number mem
    guard (opsLimit >= 1 && opsLimit <= 16 && memLimit >= 8192 && memLimit <= 1024 * 1024 * 1024)
    pure Stretch {opsLimit, memLimit}
  _ -> Nothing
  where
    number v = T.stripPrefix "=" v >>= readMaybe . T.unpack

--------------------------------------------------------------------------------
-- Records

-- | A record the browser sent, checked, as the users table stores it, for
-- the user whose id is its credential id. 'Left' with the reason for a
-- record that does not decode, or one made for another user or with a
-- stretching the server does not accept.
storedRecordOf :: UserId -> PasswordRecord -> Either Text StoredRecord
storedRecordOf u r
  | r.credential /= u.text = Left "The password was prepared for another account: try again."
  | otherwise = do
      bytes <- maybe (Left "The password's record is not base64url.") Right (bytesOf r.record)
      record :: RegistrationRecord <- first (const "The password's record is not a valid OPAQUE record.") (decode bytes)
      when (isNothing (readStretch (stretchText r.stretch))) (Left "The password's record was stretched too little or too much.")
      pure StoredRecord {record = (messageOf (encode record)).text, stretch = stretchText r.stretch}

-- | The record a 'StoredRecord' holds, with its stretching, if it decodes.
recordFromStored :: StoredRecord -> Maybe (RegistrationRecord, Stretch)
recordFromStored s = do
  bytes <- bytesOf (Message s.record)
  record <- rightToMaybe (decode bytes)
  stretch <- readStretch s.stretch
  pure (record, stretch)

-- | Register a password for a user with both sides in this process: what
-- the console and the server's own operations do with a password they are
-- given. The password is still never stored; only its record is.
registerHere :: ServerSetup -> Stretch -> UserId -> Password -> IO (Either Text StoredRecord)
registerHere setup stretch u (Password password) = runExceptT $ do
  (st, request) <- ExceptT (first (const "The password cannot be used: try another.") <$> registrationRequest (encodeUtf8 password))
  response <- ExceptT . pure $ (first (const "The password cannot be registered.") (registrationResponse setup (CredentialId (encodeUtf8 u.text)) request))
  (record, _) <- ExceptT (first (const "The password cannot be registered.") <$> finalizeRegistration (opaqueConfig stretch) st response defaultIdentities)
  pure StoredRecord {record = (messageOf (encode record)).text, stretch = stretchText stretch}

-- | The server's half of a new record for a user: the answer to the
-- browser's blinded password.
registrationChallenge :: ServerSetup -> Stretch -> UserId -> Message -> Either Text RegistrationChallenge
registrationChallenge setup stretch u request = do
  bytes <- maybe (Left "The request is not base64url.") Right (bytesOf request)
  req <- first (const "The request is not an OPAQUE registration request.") (decode bytes)
  response <- first (const "The request cannot be answered.") (registrationResponse setup (CredentialId (encodeUtf8 u.text)) req)
  pure RegistrationChallenge {credential = u.text, response = messageOf (encode response), stretch}

--------------------------------------------------------------------------------
-- Sign-ins under way

-- | 'Attempt': a sign-in (or a proof) between its first and last message.
data Attempt = Attempt
  { state :: ServerLoginState
  , user :: Maybe UserId
  -- ^ The user who would be signed in: none for a login nobody has.
  , login :: Text
  -- ^ The login as typed, which the limit on failed sign-ins counts by.
  , startedAt :: UTCTime
  -- ^ When it started, which is also when it was counted as a failure
  -- until it is finished ("Wiki.Server.Limiter").
  , expires :: UTCTime
  , hasRecord :: Bool
  -- ^ Whether the user has a record: a sign-in for a user without one
  -- (a login nobody has, an account from before OPAQUE) never finishes.
  }

-- | The sign-ins under way, by their ids.
newtype Attempts = Attempts (IORef (Map Text Attempt))

newAttempts :: IO Attempts
newAttempts = Attempts <$> newIORef mempty

-- | How long the browser has for its last message: two minutes, ample for
-- one Argon2id.
attemptLifetime :: NominalDiffTime
attemptLifetime = 120

-- | The most sign-ins kept under way; the oldest go first.
maxAttempts :: Int
maxAttempts = 10000

-- | Keep an attempt, and answer its id.
holdAttempt :: Attempts -> UTCTime -> Attempt -> IO Text
holdAttempt (Attempts ref) now a = do
  key <- newToken
  atomicModifyIORef' ref $ \m ->
    let live = Map.filter (\x -> x.expires > now) m
        bounded = if Map.size live >= maxAttempts then Map.fromList (drop (Map.size live - maxAttempts + 1) (sortOn (\(_, x) -> x.expires) (Map.toList live))) else live
     in (Map.insert key a bounded, ())
  pure key

-- | Take an attempt by its id, if it has not expired: it is used up,
-- whatever its last message turns out to be.
takeAttempt :: Attempts -> UTCTime -> Text -> IO (Maybe Attempt)
takeAttempt (Attempts ref) now key =
  atomicModifyIORef' ref $ \m -> (Map.delete key m, mfilter (\a -> a.expires > now) (Map.lookup key m))

-- | The server's answer to a first message, for a user's record or, with
-- none, for the setup's fake record, under the credential id given (a
-- user's id, or for a login nobody has, one made from the login). The
-- answer has the same shape either way, and the stretching of the record,
-- or for the fake the one new records get. 'Left' for a first message that does
-- not decode.
respondTo :: ServerSetup -> Stretch -> Maybe (RegistrationRecord, Stretch) -> ByteString -> KE1 -> IO (Either Text (ServerLoginState, Message, Stretch))
respondTo setup current found credential ke1 = do
  let stretch = maybe current snd found
  serverRespond (opaqueConfig stretch) setup (fst <$> found) (CredentialId credential) ke1 defaultIdentities <&> \case
    Left _ -> Left "The sign-in's first message cannot be answered."
    Right (st, ke2) -> Right (st, messageOf (encode ke2), stretch)

--------------------------------------------------------------------------------
-- Proofs

-- | The sessions that have proved their password, by a key (the hash of
-- their session's id, or of a sign-in waiting for a second factor), with
-- the user and until when.
newtype Proofs = Proofs (IORef (Map Text (UserId, UTCTime)))

newProofs :: IO Proofs
newProofs = Proofs <$> newIORef mempty

-- | How long a proof lasts: five minutes.
proofLifetime :: NominalDiffTime
proofLifetime = 5 * 60

-- | Record that a session has proved its user's password now.
prove :: Proofs -> UTCTime -> Text -> UserId -> IO ()
prove (Proofs ref) now key u = atomicModifyIORef' ref $ \m ->
  let live = Map.filter (\(_, until') -> until' > now) m
      bounded = if Map.size live >= maxAttempts then Map.fromList (drop (Map.size live - maxAttempts + 1) (sortOn (\(_, (_, t)) -> t) (Map.toList live))) else live
   in (Map.insert key (u, addUTCTime proofLifetime now) bounded, ())

-- | Use up a session's proof of its user's password, if it has one that
-- has not expired.
takeProof :: Proofs -> UTCTime -> Text -> UserId -> IO Bool
takeProof (Proofs ref) now key u = atomicModifyIORef' ref $ \m -> case Map.lookup key m of
  Just (owner, until') | owner == u && until' > now -> (Map.delete key m, True)
  _ -> (m, False)
