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
  , PendingToken (..)
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
import Database.Beam (QExpr, aggregate_, all_, as_, countAll_, delete, filter_, insert, insertValues, isJust_, isNothing_, runDelete, runInsert, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Database.Beam.Backend.SQL.BeamExtensions (conflictingFields, insertOnConflict, onConflictUpdateSet)
import Network.HTTP.Types (hCookie)
import Network.Wai (Request (..))
import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Api.Security (SecondFactorState (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..))
import Wiki.Server.Password (newToken, tokenHash)
import Wiki.Server.Session (CookieSettings (..))
import Wiki.Server.Storage (Storage, reading, writing, writingEither)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (deleteSecondFactor, micro, totpEnabled)
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S
import Wiki.Server.Totp (Secret, matchingCounter, newRecoveryCodes, newSecret, recoveryKey, secretFromText, secretText)

--------------------------------------------------------------------------------
-- Turning it on and off

-- | Whether a user has a second factor, and how many recovery codes they
-- have left.
secondFactorState :: Storage -> UserId -> IO SecondFactorState
secondFactorState st u = reading st (stateOf u)

stateOf :: (Backend be) => UserId -> Db be SecondFactorState
stateOf u = do
  enabled <- totpEnabled u
  left <- runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ (\r -> r.user_id ==. val_ u.text &&. isNothing_ r.used_at) (all_ wikiDb.recovery_codes))))
  withPassword <- runSelectReturningOne (select ((\r -> isJust_ r.password_hash) <$> filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))
  pure
    SecondFactorState
      { enabled
      , recoveryCodesLeft = if enabled then maybe 0 fromIntegral left else 0
      , asksPassword = fromMaybe False withPassword
      }

-- | Start setting up a second factor: a new secret, stored for the user
-- but not asked for until 'confirm'. One started before and not confirmed
-- is replaced; one already on is a 'Conflict'.
enrol :: Storage -> UTCTime -> UserId -> IO (Either WikiError Secret)
enrol st now u = do
  secret <- newSecret
  writingEither st $
    totpEnabled u >>= \case
      True -> pure (Left (Conflict "You have a second factor already: remove it first to set up another."))
      False -> do
        runDelete (delete wikiDb.recovery_codes (\r -> r.user_id ==. val_ u.text))
        runInsert $
          insertOnConflict
            wikiDb.totp
            (insertValues [S.TotpRow {user_id = u.text, secret = secretText secret, created_at = micro now, enabled_at = Nothing, last_counter = Nothing}])
            (conflictingFields (\r -> r.user_id))
            (onConflictUpdateSet (\r new -> mconcat [r.secret <-. new.secret, r.created_at <-. new.created_at, r.enabled_at <-. val_ Nothing, r.last_counter <-. val_ Nothing]))
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
  writingEither st $
    runSelectReturningOne (select (filter_ (\r -> r.user_id ==. val_ u.text) (all_ wikiDb.totp))) >>= \case
      Just r
        | isJust r.enabled_at -> pure (Left (CodeRefused (Conflict "Your second factor is on already.")))
        | Just secret <- secretFromText r.secret
        , Just counter <- matchingCounter secret now Nothing typed -> do
            runUpdate (update wikiDb.totp (\x -> (x.enabled_at <-. val_ (Just (micro now))) <> (x.last_counter <-. val_ (Just (fromIntegral counter)))) (\x -> x.user_id ==. val_ u.text))
            runDelete (delete wikiDb.recovery_codes (\x -> x.user_id ==. val_ u.text))
            runInsert (insert wikiDb.recovery_codes (insertValues [S.RecoveryCodeRow {user_id = u.text, code_hash = tokenHash key, used_at = Nothing} | code <- codes, Just key <- [recoveryKey code]]))
            pure (Right codes)
        | otherwise -> pure (Left WrongCode)
      Nothing -> pure (Left (CodeRefused NotFound))

-- | Turn a user's second factor off, with one of their codes. The result
-- is their second factor's state afterwards (off).
remove :: Storage -> UTCTime -> UserId -> Text -> IO (Either CodeRefusal SecondFactorState)
remove st now u typed = writingEither st $
  totpEnabled u >>= \case
    False -> pure (Left (CodeRefused NotFound))
    True ->
      codeOf now u typed >>= \case
        False -> pure (Left WrongCode)
        True -> do
          void (deleteSecondFactor u)
          Right <$> stateOf u

--------------------------------------------------------------------------------
-- Codes

-- | Whether a typed code is valid for a user who has a second factor: a
-- current code from their application, later than the last accepted, or
-- an unused recovery code. Either way it is used up, so that it is not
-- accepted again.
checkCode :: Storage -> UTCTime -> UserId -> Text -> IO Bool
checkCode st now u typed = writing st (codeOf now u typed)

-- | 'checkCode' in a running transaction.
codeOf :: (Backend be) => UTCTime -> UserId -> Text -> Db be Bool
codeOf now u typed =
  runSelectReturningOne (select (filter_ (\r -> r.user_id ==. val_ u.text &&. isJust_ r.enabled_at) (all_ wikiDb.totp))) >>= \case
    Just r
      | Just secret <- secretFromText r.secret
      , Just counter <- matchingCounter secret now (fromIntegral <$> r.last_counter) typed -> do
          runUpdate (update wikiDb.totp (\x -> x.last_counter <-. val_ (Just (fromIntegral counter))) (\x -> x.user_id ==. val_ u.text))
          pure True
      | Just key <- recoveryKey typed -> do
          found <- runSelectReturningOne (select ((\x -> x.code_hash) <$> filter_ (unused key) (all_ wikiDb.recovery_codes)))
          runUpdate (update wikiDb.recovery_codes (\x -> x.used_at <-. val_ (Just (micro now))) (unused key))
          pure (isJust found)
    _ -> pure False
  where
    -- The user's recovery code with this key, if it is not used.
    unused :: (Backend be) => Text -> S.RecoveryCodes (QExpr be s) -> QExpr be s Bool
    unused key x = x.user_id ==. val_ u.text &&. x.code_hash ==. val_ (tokenHash key) &&. isNothing_ x.used_at

--------------------------------------------------------------------------------
-- Sign-ins half done

-- | A sign-in waiting for its code.
data PendingSignIn = PendingSignIn
  { user :: UserId
  , login :: Login
  -- ^ What the limit on failed sign-ins counts its wrong codes against.
  , next :: Text
  -- ^ Where a provider's sign-in continues to once it is done.
  , expires :: UTCTime
  , wrong :: Int
  -- ^ How many wrong codes it has had.
  }
  deriving stock (Eq, Show)

-- | 'PendingToken': the secret a waiting sign-in's cookie carries. It is
-- not a session: it lets its browser give the second factor's code, and
-- nothing else. Its 'Show' instance never prints it. It is a type of its
-- own so that it cannot be passed where a session's secret goes.
newtype PendingToken = PendingToken {text :: Text}
  deriving stock (Eq, Ord)

instance Show PendingToken where
  showsPrec _ _ rest = "PendingToken <hidden>" <> rest

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
holdSignIn :: PendingSignIns -> UTCTime -> UserId -> Login -> Text -> IO PendingToken
holdSignIn (PendingSignIns ref) now user login next = do
  token <- PendingToken <$> newToken
  let held = PendingSignIn {user, login, next, expires = addUTCTime pendingLifetime now, wrong = 0}
  atomicModifyIORef' ref $ \m ->
    let live = Map.filter (\p -> p.expires > now) m
        bounded = if Map.size live >= maxPending then Map.fromList (drop (Map.size live - maxPending + 1) (sortOn (\(_, p) -> p.expires) (Map.toList live))) else live
     in (Map.insert (tokenHash token.text) held bounded, ())
  pure token

-- | The sign-in a cookie's id names, if it is still waiting.
pendingSignIn :: PendingSignIns -> UTCTime -> PendingToken -> IO (Maybe PendingSignIn)
pendingSignIn (PendingSignIns ref) now token =
  atomicModifyIORef' ref $ \m -> case Map.lookup key m of
    Just p | p.expires > now -> (m, Just p)
    Just _ -> (Map.delete key m, Nothing)
    Nothing -> (m, Nothing)
  where
    key = tokenHash token.text

-- | Count a wrong code against a sign-in, which ends at the last allowed.
wrongCode :: PendingSignIns -> PendingToken -> IO ()
wrongCode (PendingSignIns ref) token =
  atomicModifyIORef' ref $ \m -> (Map.update (\p -> if p.wrong + 1 >= maxWrongCodes then Nothing else Just p {wrong = p.wrong + 1}) (tokenHash token.text) m, ())

-- | End a sign-in that has received its code.
finishPending :: PendingSignIns -> PendingToken -> IO ()
finishPending (PendingSignIns ref) token = atomicModifyIORef' ref (\m -> (Map.delete (tokenHash token.text) m, ()))

-- | The cookie that carries a waiting sign-in's id.
pendingCookieName :: Text
pendingCookieName = "wiki_pending"

-- | The @Set-Cookie@ value that gives a browser a waiting sign-in's id,
-- for as long as it waits, or (with none) deletes it. It covers the
-- wiki's whole path, since a password sign-in ends at the API and a
-- provider's at its own page, and it is as strict as the session cookie.
pendingCookie :: CookieSettings -> Maybe PendingToken -> Text
pendingCookie s token =
  T.intercalate "; " $
    [pendingCookieName <> "=" <> value, "Path=" <> s.path, "Max-Age=" <> (if T.null value then "0" else show (truncate pendingLifetime :: Int)), "HttpOnly", "SameSite=Strict"]
      <> ["Secure" | s.secure]
  where
    value = maybe "" (\t -> t.text) token

-- | The id of a waiting sign-in, from a request's cookies, if any.
requestPending :: Request -> Maybe PendingToken
requestPending request =
  head
    [ PendingToken value
    | (header, raw) <- requestHeaders request
    , header == hCookie
    , pair <- BC.split ';' raw
    , let (k, v) = BC.break (== '=') (BC.dropWhile (== ' ') pair)
    , decodeUtf8With lenientDecode k == pendingCookieName
    , let value = T.strip (decodeUtf8With lenientDecode (BC.drop 1 v))
    , not (T.null value)
    ]
