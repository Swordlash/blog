-- | The second factor at sign-in (WP4.11 of docs/PLAN.md): a code from an
-- authenticator application ("Wiki.Server.Totp"), asked for after the
-- password, or after a provider's sign-in, from a user who has turned it
-- on.
--
-- = Turning it on and off
--
-- A user requests a secret ('enrol'), which is stored but not yet asked
-- for. One code computed with it ('confirm') proves that their application
-- has it, and turns it on, with ten recovery codes, shown once and stored
-- as hashes. They turn it off with a code ('remove'), so that a browser
-- left signed in does not let a passer-by remove it. An administrator
-- turns it off without a code (the administration's @removeSecondFactor@,
-- which the storage checks, and the console's), for a user who has lost
-- both their application and their recovery codes.
--
-- = Codes
--
-- 'checkCode' accepts either a code from the application, within one time
-- step of now either way and later than the last one accepted (so each is
-- accepted once), or an unused recovery code, which is then used up.
--
-- = Half-finished sign-ins
--
-- When the password (or the provider) is right and a code is needed, the
-- server holds the half-finished sign-in in memory ('PendingSignIns'): the
-- user, and how many wrong codes it has had, under a random id that its
-- own cookie carries ('pendingCookie'), for 'pendingLifetime'. The right
-- code completes it ('finishPending'); 'maxWrongCodes' wrong ones end it
-- too, besides counting against the limit on failed sign-ins. A restart
-- forgets them, which costs whoever was halfway through entering their
-- password again.
module Wiki.Server.SecondFactor
  ( -- * Turning it on and off
    secondFactorState
  , enrol
  , confirm
  , CodeRefusal (..)
  , remove

    -- * Codes
  , checkCode

    -- * Sign-ins half done
  , PendingSignIns
  , PendingSignIn (..)
  , newPendingSignIns
  , holdSignIn
  , pendingSignIn
  , wrongCode
  , finishPending
  , pendingLifetime
  , maxWrongCodes
  , pendingCookieName
  , pendingCookie
  , requestPending
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Database.SQLite.Simple (Connection, Only (..), changes, execute, query)
import Network.HTTP.Types (hCookie)
import Network.Wai (Request (..))
import Protolude
import Wiki.Api.Security (SecondFactorState (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Accounts (immediately)
import Wiki.Server.Password (newToken, tokenHash)
import Wiki.Server.Session (CookieSettings (..))
import Wiki.Server.Storage (Storage, withDatabase)
import Wiki.Server.Storage.Rows (Stamp (..), deleteSecondFactor, totpEnabled)
import Wiki.Server.Totp (Secret, matchingCounter, newRecoveryCodes, newSecret, recoveryKey, secretFromText, secretText)

--------------------------------------------------------------------------------
-- Turning it on and off

-- | Whether a user has a second factor, and how many recovery codes they
-- have left.
secondFactorState :: Storage -> UserId -> IO SecondFactorState
secondFactorState st u = withDatabase st (`stateOf` u)

stateOf :: Connection -> UserId -> IO SecondFactorState
stateOf c u = do
  enabled <- totpEnabled c u
  left <- query c "SELECT count(*) FROM recovery_codes WHERE user_id = ? AND used_at IS NULL" (Only u.text)
  withPassword <- query c "SELECT password_hash IS NOT NULL FROM users WHERE id = ?" (Only u.text)
  pure
    SecondFactorState
      { enabled
      , recoveryCodesLeft = if enabled then maybe 0 fromOnly (head left) else 0
      , asksPassword = maybe False ((/= (0 :: Int)) . fromOnly) (head withPassword)
      }

-- | Start setting up a second factor: a new secret, stored for the user
-- but not asked for until 'confirm'. One started before and not confirmed
-- is replaced; one already on is a 'Conflict'.
enrol :: Storage -> UTCTime -> UserId -> IO (Either WikiError Secret)
enrol st now u = do
  secret <- newSecret
  withDatabase st $ \c ->
    immediately c $
      totpEnabled c u >>= \case
        True -> pure (Left (Conflict "You have a second factor already: remove it first to set up another."))
        False -> do
          execute c "DELETE FROM recovery_codes WHERE user_id = ?" (Only u.text)
          execute
            c
            "INSERT INTO totp (user_id, secret, created_at, enabled_at, last_counter) VALUES (?, ?, ?, NULL, NULL) ON CONFLICT (user_id) DO UPDATE SET secret = excluded.secret, created_at = excluded.created_at, enabled_at = NULL, last_counter = NULL"
            (u.text, secretText secret, Stamp now)
          pure (Right secret)

-- | Why a code was not accepted.
data CodeRefusal
  = -- | It is not a current code of theirs (nor an unused recovery code).
    WrongCode
  | -- | Any other failure: nothing to confirm or remove ('NotFound'), or a
    -- second factor already on ('Conflict').
    CodeRefused WikiError
  deriving stock (Eq, Show)

-- | Turn on the second factor that was started, with a code from the
-- application. The result is the recovery codes, in clear text this once.
confirm :: Storage -> UTCTime -> UserId -> Text -> IO (Either CodeRefusal [Text])
confirm st now u typed = do
  codes <- newRecoveryCodes
  withDatabase st $ \c ->
    immediately c $
      query c "SELECT secret, enabled_at IS NOT NULL FROM totp WHERE user_id = ?" (Only u.text) >>= \case
        [(_, True)] -> pure (Left (CodeRefused (Conflict "Your second factor is on already.")))
        [(stored, False)]
          | Just secret <- secretFromText stored
          , Just counter <- matchingCounter secret now Nothing typed -> do
              execute c "UPDATE totp SET enabled_at = ?, last_counter = ? WHERE user_id = ?" (Stamp now, fromIntegral counter :: Int64, u.text)
              execute c "DELETE FROM recovery_codes WHERE user_id = ?" (Only u.text)
              for_ codes $ \code ->
                for_ (recoveryKey code) $ \key ->
                  execute c "INSERT INTO recovery_codes (user_id, code_hash, used_at) VALUES (?, ?, NULL)" (u.text, tokenHash key)
              pure (Right codes)
          | otherwise -> pure (Left WrongCode)
        _ -> pure (Left (CodeRefused NotFound))

-- | Turn a user's second factor off, with one of their codes. The result
-- is their second factor's state afterwards (off).
remove :: Storage -> UTCTime -> UserId -> Text -> IO (Either CodeRefusal SecondFactorState)
remove st now u typed = withDatabase st $ \c ->
  immediately c $
    totpEnabled c u >>= \case
      False -> pure (Left (CodeRefused NotFound))
      True ->
        codeOf c now u typed >>= \case
          False -> pure (Left WrongCode)
          True -> do
            void (deleteSecondFactor c u)
            Right <$> stateOf c u

--------------------------------------------------------------------------------
-- Codes

-- | Whether a typed code is valid for a user who has a second factor: a
-- current code from their application, later than the last accepted, or
-- an unused recovery code. Either way it is used up, so that it is not
-- accepted again.
checkCode :: Storage -> UTCTime -> UserId -> Text -> IO Bool
checkCode st now u typed = withDatabase st $ \c -> immediately c (bool (Left ()) (Right ()) <$> codeOf c now u typed) <&> isRight

-- | 'checkCode' in a running transaction.
codeOf :: Connection -> UTCTime -> UserId -> Text -> IO Bool
codeOf c now u typed =
  query c "SELECT secret, last_counter FROM totp WHERE user_id = ? AND enabled_at IS NOT NULL" (Only u.text) >>= \case
    [(stored, lastUsed)]
      | Just secret <- secretFromText stored
      , Just counter <- matchingCounter secret now (fromIntegral <$> (lastUsed :: Maybe Int64)) typed -> do
          execute c "UPDATE totp SET last_counter = ? WHERE user_id = ?" (fromIntegral counter :: Int64, u.text)
          pure True
      | Just key <- recoveryKey typed -> do
          execute c "UPDATE recovery_codes SET used_at = ? WHERE user_id = ? AND code_hash = ? AND used_at IS NULL" (Stamp now, u.text, tokenHash key)
          (== 1) <$> changes c
    _ -> pure False

--------------------------------------------------------------------------------
-- Sign-ins half done

-- | A sign-in waiting for its code.
data PendingSignIn = PendingSignIn
  { user :: UserId
  , login :: Text
  -- ^ What the limit on failed sign-ins counts its wrong codes against.
  , next :: Text
  -- ^ Where a provider's sign-in continues to once it is done.
  , expires :: UTCTime
  , wrong :: Int
  -- ^ How many wrong codes it has had.
  }
  deriving stock (Eq, Show)

-- | The sign-ins waiting, by the hash of the id their cookie carries.
newtype PendingSignIns = PendingSignIns (IORef (Map Text PendingSignIn))

newPendingSignIns :: IO PendingSignIns
newPendingSignIns = PendingSignIns <$> newIORef mempty

-- | How long a sign-in waits for its code: five minutes.
pendingLifetime :: NominalDiffTime
pendingLifetime = 5 * 60

-- | How many wrong codes a sign-in takes before it ends.
maxWrongCodes :: Int
maxWrongCodes = 5

-- | The most sign-ins held waiting; beyond it the oldest are dropped.
maxPending :: Int
maxPending = 10000

-- | Hold a sign-in waiting for its code. The result is the id its cookie
-- is to carry.
holdSignIn :: PendingSignIns -> UTCTime -> UserId -> Text -> Text -> IO Text
holdSignIn (PendingSignIns ref) now user login next = do
  token <- newToken
  let held = PendingSignIn {user, login, next, expires = addUTCTime pendingLifetime now, wrong = 0}
  atomicModifyIORef' ref $ \m ->
    let live = Map.filter (\p -> p.expires > now) m
        bounded = if Map.size live >= maxPending then Map.fromList (drop (Map.size live - maxPending + 1) (sortOn (\(_, p) -> p.expires) (Map.toList live))) else live
     in (Map.insert (tokenHash token) held bounded, ())
  pure token

-- | The sign-in a cookie's id names, if it is still waiting.
pendingSignIn :: PendingSignIns -> UTCTime -> Text -> IO (Maybe PendingSignIn)
pendingSignIn (PendingSignIns ref) now token =
  atomicModifyIORef' ref $ \m -> case Map.lookup key m of
    Just p | p.expires > now -> (m, Just p)
    Just _ -> (Map.delete key m, Nothing)
    Nothing -> (m, Nothing)
  where
    key = tokenHash token

-- | Count a wrong code against a sign-in, which ends at the last allowed.
wrongCode :: PendingSignIns -> Text -> IO ()
wrongCode (PendingSignIns ref) token =
  atomicModifyIORef' ref $ \m -> (Map.update (\p -> if p.wrong + 1 >= maxWrongCodes then Nothing else Just p {wrong = p.wrong + 1}) (tokenHash token) m, ())

-- | End a sign-in that has received its code.
finishPending :: PendingSignIns -> Text -> IO ()
finishPending (PendingSignIns ref) token = atomicModifyIORef' ref (\m -> (Map.delete (tokenHash token) m, ()))

-- | The cookie that carries a waiting sign-in's id.
pendingCookieName :: Text
pendingCookieName = "wiki_pending"

-- | The @Set-Cookie@ value that gives a browser a waiting sign-in's id,
-- for as long as it waits, or (when empty) deletes it. It covers the
-- wiki's whole path, since a password sign-in ends at the API and a
-- provider's at its own page, and it is as strict as the session cookie.
pendingCookie :: CookieSettings -> Text -> Text
pendingCookie s value =
  T.intercalate "; " $
    [pendingCookieName <> "=" <> value, "Path=" <> s.path, "Max-Age=" <> (if T.null value then "0" else show (truncate pendingLifetime :: Int)), "HttpOnly", "SameSite=Strict"]
      <> ["Secure" | s.secure]

-- | The id of a waiting sign-in, from a request's cookies, if any.
requestPending :: Request -> Maybe Text
requestPending request =
  head
    [ value
    | (header, raw) <- requestHeaders request
    , header == hCookie
    , pair <- BC.split ';' raw
    , let (k, v) = BC.break (== '=') (BC.dropWhile (== ' ') pair)
    , decodeUtf8With lenientDecode k == pendingCookieName
    , let value = T.strip (decodeUtf8With lenientDecode (BC.drop 1 v))
    , not (T.null value)
    ]
