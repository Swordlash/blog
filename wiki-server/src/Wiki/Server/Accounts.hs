-- | Users' accounts and sessions, as the server keeps them: who may sign
-- in, with what password, and who has (decisions 8, 11 and 20 of
-- docs/PLAN.md).
--
-- The operations here are the console's (@wiki-server users …@,
-- "Wiki.Server.Console") and the administration API's ("Wiki.Server.Api")
-- alike, so that a user made either way is the same user; who may call
-- them is the caller's business (the console is whoever can read the data
-- directory, the API checks for an administrator). Each is one transaction
-- on the storage's connection, except that a password is hashed before the
-- connection is taken, since hashing one takes tens of milliseconds
-- ("Wiki.Server.Password") that the rest of the server should not wait
-- for.
--
-- = Sessions
--
-- Signing in makes a session: a random id, which the cookie carries
-- ("Wiki.Server.Session") and of which the database keeps only a hash.
-- A session ends when its user signs out, when they are disabled or given a
-- new password, and when it has not been used for 'idleTime'; each use
-- moves its end on, at most once every 'refreshEvery', so that a session
-- in use does not cost a write per request.
--
-- = Accounts people make themselves
--
-- In an open wiki anyone may make themself an account ('register'); in
-- any wiki, someone invited may, with the invitation's secret
-- ('acceptInvitation', WP3.5 of docs/PLAN.md), which is then used up. The
-- account holds no grant, unless the wiki's settings give a new account
-- the global create-spaces, and its maker is signed in as it at once.
-- The secret is checked before the password is hashed, so that a link
-- that lets nobody in costs the server nothing.
module Wiki.Server.Accounts
  ( -- * Accounts
    accountOf
  , accountByLogin
  , listAccounts
  , createAccount
  , setPassword
  , setDisabled
  , setAdministrator
  , checkLogin

    -- * Accounts people make themselves
  , register
  , invitationFor
  , acceptInvitation

    -- * Sessions
  , signIn
  , SignInFailure (..)
  , Resolved (..)
  , resolveSession
  , endSession
  , idleTime
  , refreshEvery
  )
where

import Control.Monad.UUID (MonadUUID (..))
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.UUID.Types qualified as UUID
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, execute_, query, query_)
import Protolude
import Wiki.Api.Account (Account (..), InvitationInfo (..), InvitationToken (..), NewAccount (..))
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Access (takesNewAccounts)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (User (..), checkLogin)
import Wiki.Server.Password (checkPassword, hashPassword, newToken, tokenHash, verifyPassword)
import Wiki.Server.Storage (Storage, readSettings, settingsWith, withDatabase)
import Wiki.Server.Storage.Rows (AccountRow, Stamp (..), accountFromRow, deleteInvitation, deleteSessionsOf, grantCreateSpaces, insertAccount, loadAccount, pendingInvitation, selectAccounts, updateDisabled, updatePasswordHash)

--------------------------------------------------------------------------------
-- Accounts

-- | A user's account, by id.
accountOf :: Storage -> UserId -> IO (Maybe Account)
accountOf st u = withDatabase st (`loadAccount` u)

-- | A user's account, by login, which is compared as SQLite compares
-- without case (ASCII letters): what someone types to sign in.
accountByLogin :: Storage -> Text -> IO (Maybe Account)
accountByLogin st login = withDatabase st $ \c ->
  fmap accountFromRow . head <$> query c (selectAccounts "WHERE login = ? COLLATE NOCASE") (Only (T.strip login))

-- | Every user's account, by login, with whether they are an administrator
-- (hold the global @administer@ themselves).
listAccounts :: Storage -> IO [(Account, Bool)]
listAccounts st = withDatabase st $ \c -> do
  rows <-
    query_
      c
      ( Query . T.unwords $
          [ "SELECT id, login, display_name, password_hash, disabled,"
          , "EXISTS (SELECT 1 FROM global_grants g WHERE g.subject_kind = 'user' AND g.subject_id = users.id AND g.permission = 'administer')"
          , "FROM users ORDER BY login COLLATE NOCASE"
          ]
      )
  pure [(accountFromRow (uid, login, name, phc, disabled), admin /= (0 :: Int)) | (uid, login, name, phc, disabled, admin) <- rows]

-- | Make a user, who signs in with this password, or (with none) cannot
-- sign in until they are given one. Their display name is their login if
-- it is blank. A login another user has, whatever its case, is a
-- 'Conflict'; one or a password that cannot be one is 'Invalid'.
createAccount :: Storage -> Text -> Text -> Maybe Text -> IO (Either WikiError Account)
createAccount st rawLogin rawName password = runExceptT $ do
  login <- either (throwError . Invalid) pure (checkLogin rawLogin)
  phc <- for password $ \p -> either (throwError . Invalid) (liftIO . hashPassword) (checkPassword p)
  uid <- liftIO (UUID.toText <$> generateV4)
  let name = case T.strip rawName of
        "" -> login
        n -> n
  ExceptT . withDatabase st $ \c ->
    immediately c (first taken <$> insertAccount c (UserId uid) login name phc)
  where
    taken login = Conflict ("There is a user with the login " <> login <> " already.")

-- | Give a user a new password, and end their sessions.
setPassword :: Storage -> UserId -> Text -> IO (Either WikiError Account)
setPassword st u password = case checkPassword password of
  Left why -> pure (Left (Invalid why))
  Right p -> do
    phc <- hashPassword p
    changeAccount st u $ \c -> do
      updatePasswordHash c u phc
      deleteSessionsOf c u

-- | Disable a user's login, which ends their sessions, or enable it again.
setDisabled :: Storage -> UserId -> Bool -> IO (Either WikiError Account)
setDisabled st u disabled = changeAccount st u $ \c -> do
  updateDisabled c u disabled
  when disabled (deleteSessionsOf c u)

-- | Make a user an administrator (the global @administer@, granted to
-- them), or take it away. What their groups are granted is not changed.
setAdministrator :: Storage -> UserId -> Bool -> IO (Either WikiError Account)
setAdministrator st u administrator = changeAccount st u $ \c ->
  if administrator
    then execute c "INSERT OR IGNORE INTO global_grants (subject_kind, subject_id, permission) VALUES ('user', ?, 'administer')" (Only u.text)
    else execute c "DELETE FROM global_grants WHERE subject_kind = 'user' AND subject_id = ? AND permission = 'administer'" (Only u.text)

-- | Change a user who is there, in one transaction, and give back their
-- account as it then is; 'NotFound' for a user who is not.
changeAccount :: Storage -> UserId -> (Connection -> IO ()) -> IO (Either WikiError Account)
changeAccount st u change = withDatabase st $ \c -> immediately c $ do
  loadAccount c u >>= \case
    Nothing -> pure (Left NotFound)
    Just _ -> do
      change c
      maybe (Left NotFound) Right <$> loadAccount c u

-- | Run something in a transaction that holds the write lock from its
-- start: committed if it gives a 'Right', rolled back if it gives a 'Left'
-- or throws.
immediately :: Connection -> IO (Either e a) -> IO (Either e a)
immediately c body = do
  execute_ c "BEGIN IMMEDIATE"
  result <- body `onException` execute_ c "ROLLBACK"
  case result of
    Left _ -> execute_ c "ROLLBACK"
    Right _ -> execute_ c "COMMIT" `onException` execute_ c "ROLLBACK"
  pure result

--------------------------------------------------------------------------------
-- Accounts people make themselves

-- | Make oneself an account, in an open wiki: the user made, and the id of
-- the session they are signed in with. A closed wiki refuses it
-- ('Forbidden') before anything is checked, then the account is checked as
-- 'createAccount' checks one ('Invalid', 'Conflict').
register :: Storage -> UTCTime -> NewAccount -> IO (Either WikiError (User, Text))
register st now new = runExceptT $ do
  open <- liftIO (takesNewAccounts . (\s -> s.access) <$> readSettings st)
  unless open (throwError Forbidden)
  made <- prepared new
  ExceptT . withDatabase st $ \c -> immediately c $ do
    -- Closed meanwhile, while the password was hashed.
    settings <- settingsWith st c
    if takesNewAccounts settings.access
      then makeAccount c now settings made
      else pure (Left Forbidden)

-- | Whom an invitation is for, if it can be used now.
invitationFor :: Storage -> UTCTime -> InvitationToken -> IO (Maybe InvitationInfo)
invitationFor st now token = withDatabase st $ \c -> fmap snd <$> pendingInvitation c now (tokenHash token.text)

-- | Make the account an invitation invites to, open wiki or closed, and use
-- the invitation up: the user made, and the id of the session they are
-- signed in with. An invitation that cannot be used (it has been used,
-- revoked, or has expired) is 'NotFound', before the account is checked;
-- a login taken leaves the invitation as it was, to try another.
acceptInvitation :: Storage -> UTCTime -> InvitationToken -> NewAccount -> IO (Either WikiError (User, Text))
acceptInvitation st now token new = runExceptT $ do
  let secret = tokenHash token.text
  pending <- liftIO (withDatabase st (\c -> pendingInvitation c now secret))
  when (isNothing pending) (throwError NotFound)
  made <- prepared new
  ExceptT . withDatabase st $ \c ->
    immediately c $
      pendingInvitation c now secret >>= \case
        -- Used or revoked meanwhile.
        Nothing -> pure (Left NotFound)
        Just (i, _) -> do
          settings <- settingsWith st c
          made' <- makeAccount c now settings made
          when (isRight made') (void (deleteInvitation c i))
          pure made'

-- | An account to make, checked, with its password hashed: its id, login,
-- display name and the password's hash.
prepared :: NewAccount -> ExceptT WikiError IO (UserId, Text, Text, Text)
prepared new = do
  (login, password) <- either (throwError . Invalid) pure ((,) <$> checkLogin new.login <*> checkPassword new.password)
  phc <- liftIO (hashPassword password)
  uid <- liftIO (UUID.toText <$> generateV4)
  let name = case T.strip new.displayName of
        "" -> login
        n -> n
  pure (UserId uid, login, name, phc)

-- | Make a checked account, in a transaction under way, with the grant the
-- wiki's settings give a new one, and sign its maker in.
makeAccount :: Connection -> UTCTime -> WikiSettings -> (UserId, Text, Text, Text) -> IO (Either WikiError (User, Text))
makeAccount c now settings (uid, login, name, phc) =
  insertAccount c uid login name (Just phc) >>= \case
    Left taken -> pure (Left (Conflict ("There is a user with the login " <> taken <> " already.")))
    Right account -> do
      when settings.newAccountsCreateSpaces (grantCreateSpaces c uid)
      token <- startSession c now uid
      pure (Right (account.user, token))

--------------------------------------------------------------------------------
-- Sessions

-- | How long a session that is not used lasts: two weeks, so that someone
-- who reads the wiki now and then stays signed in, and a session left on a
-- machine that is not used any more ends by itself.
idleTime :: NominalDiffTime
idleTime = 14 * 24 * 60 * 60

-- | How long after its last recorded use a session's use is recorded again
-- (and its end moved on): an hour.
refreshEvery :: NominalDiffTime
refreshEvery = 60 * 60

-- | Why signing in failed.
data SignInFailure
  = -- | No user has that login and password, or their account cannot sign
    -- in (it has no password, or it is disabled); which, the answer does
    -- not say.
    NoSuchAccount
  | -- | The password is not one the server takes (too long).
    BadPassword
  deriving stock (Eq, Show)

-- | Sign in with a login and a password: the user, and the id of their new
-- session for the cookie. An unknown login costs the same hashing as a
-- known one, so that how long the answer takes does not tell whether a
-- login exists. Sessions that have ended by themselves are deleted on the
-- way.
signIn :: Storage -> UTCTime -> Text -> Text -> IO (Either SignInFailure (User, Text))
signIn st now login password
  | T.length password > 1024 = pure (Left BadPassword)
  | otherwise = do
      found <- withDatabase st $ \c ->
        head <$> query c (selectAccounts "WHERE login = ? COLLATE NOCASE") (Only (T.strip login))
      let hashOf :: AccountRow -> Maybe Text
          hashOf (_, _, _, phc, _) = phc
          matches = verifyPassword (fromMaybe unknownHash (found >>= hashOf)) password
      case found of
        Just row@(uid, _, _, Just _, 0) | matches -> do
          token <- withDatabase st (\c -> startSession c now (UserId uid))
          pure (Right ((accountFromRow row).user, token))
        _ -> pure (Left NoSuchAccount)

-- | A new session for a user, from now: the id its cookie is to carry.
-- Sessions that have ended by themselves are deleted on the way.
startSession :: Connection -> UTCTime -> UserId -> IO Text
startSession c now u = do
  token <- newToken
  execute c "DELETE FROM sessions WHERE expires_at <= ?" (Only (Stamp now))
  execute c "INSERT INTO sessions (id_hash, user_id, created_at, last_seen_at, expires_at) VALUES (?, ?, ?, ?, ?)" (tokenHash token, u.text, Stamp now, Stamp now, Stamp (addUTCTime idleTime now))
  pure token

-- | A hash of no one's password, to check a password against when the
-- login is no user's or has none, so that the answer takes as long.
unknownHash :: Text
unknownHash = "$argon2id$v=19$m=19456,t=2,p=1$bm8gc3VjaCB1c2Vy$7J1aqbF9XWbPBHCGdFP2N5tTqYlUvlEkB5qe2PAU4p0"

-- | A session, found by the id its cookie carries.
data Resolved = Resolved
  { user :: UserId
  , refreshed :: Bool
  -- ^ Whether its end was moved on by this use, and the cookie should be
  -- sent again to last as long.
  }
  deriving stock (Eq, Show)

-- | The session a cookie's id names, if it has not ended: one that has
-- (idle too long, its user disabled) is deleted, and is no one's.
resolveSession :: Storage -> UTCTime -> Text -> IO (Maybe Resolved)
resolveSession st now token = withDatabase st $ \c -> do
  let key = tokenHash token
  rows <-
    query
      c
      "SELECT s.user_id, s.last_seen_at, s.expires_at, u.disabled FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id_hash = ?"
      (Only key)
  case rows of
    [(uid, Stamp seen, Stamp expires, disabled)]
      | expires <= now || disabled /= (0 :: Int) -> do
          execute c "DELETE FROM sessions WHERE id_hash = ?" (Only key)
          pure Nothing
      | diffUTCTime now seen >= refreshEvery -> do
          execute c "UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id_hash = ?" (Stamp now, Stamp (addUTCTime idleTime now), key)
          pure (Just Resolved {user = UserId uid, refreshed = True})
      | otherwise -> pure (Just Resolved {user = UserId uid, refreshed = False})
    _ -> pure Nothing

-- | End the session a cookie's id names, if there is one.
endSession :: Storage -> Text -> IO ()
endSession st token = withDatabase st $ \c -> execute c "DELETE FROM sessions WHERE id_hash = ?" (Only (tokenHash token))
