-- | Users' accounts and sessions, as the server stores them: who may sign
-- in, with which password, and who is signed in (decisions 8, 11 and 20
-- of docs/PLAN.md).
--
-- The console (@wiki-server users …@, "Wiki.Server.Console") and the
-- administration API ("Wiki.Server.Api") both use these operations, so a
-- user created either way is the same kind of user. Who may call them is
-- the caller's responsibility: the console is whoever can read the data
-- directory, and the API checks for an administrator. Each operation is
-- one transaction on the storage's connection, except that a password is
-- hashed before the connection is taken, since hashing takes tens of
-- milliseconds ("Wiki.Server.Password") that the rest of the server should
-- not wait for.
--
-- What the console does ('createAccount', 'setPassword', 'setDisabled',
-- 'setAdministrator') is recorded in the audit log as done by the
-- operator, from the console (WP4.10 of docs/PLAN.md), as
-- "Wiki.Server.Storage" records the administration's own writes. An
-- account someone creates for themself, by registering or with an
-- invitation, is recorded as done by them.
--
-- = Sessions
--
-- Signing in creates a session: a random id, which the cookie carries
-- ("Wiki.Server.Session"); the database stores only a hash of it. A
-- session ends when its user signs out, when the user is disabled or given
-- a new password, and when it has not been used for 'idleTime'. Each use
-- moves its end later, at most once every 'refreshEvery', so that a
-- session in use does not cost a write per request. When and from where
-- it was last used is written at most once every 'seenEvery', for the
-- account panel. The panel lists a user's sessions and ends any of them
-- (WP4.11 of docs/PLAN.md), by a separate id of the session, never by the
-- secret its cookie carries.
--
-- A user who has a second factor ("Wiki.Server.SecondFactor") does not get
-- a session for the right password alone: 'signIn' reports that a code is
-- needed, and the session starts once the code is given.
--
-- = Accounts people create themselves
--
-- In an open wiki anyone may create their own account ('register'). In
-- any wiki, an invited person may, with the invitation's secret
-- ('acceptInvitation', WP3.5 of docs/PLAN.md), which is then used up. The
-- account holds no grant, unless the wiki's settings give new accounts the
-- global create-spaces, and its creator is signed in as it at once. The
-- secret is checked before the password is hashed, so that a link that
-- lets nobody in costs the server nothing.
--
-- = Signing in with a provider
--
-- A user may sign in with an account at a provider instead of a password,
-- or as well as one (WP3.6 of docs/PLAN.md). Such an account is an
-- identity: the provider's account, by the subject id the provider gives
-- it ("Wiki.Server.Oidc" has the provider confirm who it is). 'landWith'
-- decides the result, in one transaction, by the same rules as the rest.
-- If the identity belongs to a user, that user is signed in, unless they
-- are disabled. If it belongs to nobody, it is connected to the signed-in
-- user who asked for that; or it creates an account in an open wiki, or
-- with an invitation in any wiki, which it uses up; otherwise a closed
-- wiki refuses it. An account created this way has no password, and a
-- login made from what the provider said ('loginCandidates').
--
-- A user may disconnect their identities ('unlinkIdentity'), but not
-- their last way to sign in: an identity they cannot do without, because
-- they have no password and no other identity. The administration may (its
-- own operation, in "Wiki.Server.Storage").
--
-- = One's own password
--
-- A signed-in user changes their password, or sets one if they have none
-- and no server provider to sign in with ('changePassword', WP3.7 of
-- docs/PLAN.md). A user who signs in with such a provider has no password
-- to set (WP5.6), and is refused. The current password must be given and
-- be correct: a session is not enough, so that someone who finds a browser
-- left signed in cannot take over the account. The user's other sessions
-- end, as when an administrator sets a password, but not the one they
-- change it from, which the caller names by the id its cookie carries.
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

    -- * Signing in with a provider
  , Claimed (..)
  , Intent (..)
  , Landing (..)
  , Refusal (..)
  , landWith
  , loginCandidates
  , signInMethods
  , unlinkIdentity

    -- * One's own password
  , PasswordRefusal (..)
  , changePassword
  , currentPasswordIs

    -- * Sessions
  , signIn
  , SignInFailure (..)
  , Resolved (..)
  , resolveSession
  , endSession
  , startSession
  , idleTime
  , refreshEvery
  , seenEvery

    -- * One's own sessions
  , listSessions
  , endSessionOf
  , endOtherSessions

    -- * Transactions
  , immediately
  )
where

import Control.Monad.UUID (MonadUUID (..))
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.UUID.Types qualified as UUID
import Database.SQLite.Simple (Connection, Only (..), Query (..), ToRow, execute, execute_, query, query_)
import Protolude
import Wiki.Api.Account (Account (..), InvitationInfo (..), InvitationToken (..), LinkedIdentity (..), NewAccount (..), SignInMethods (..), signsInSomehow, withoutIdentity)
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.Security (SessionRef (..), SessionSummary (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Access (takesNewAccounts)
import Wiki.Core.Audit (Actor (..), Subject (..))
import Wiki.Core.Id (InvitationId (..), UserId (..))
import Wiki.Core.User (User (..), checkLogin)
import Wiki.Server.Password (checkPassword, hashPassword, newPublicId, newToken, tokenHash, verifyPassword)
import Wiki.Server.Storage (Storage, readServerSettings, readSettings, settingsWith, withDatabase, withReadConnection)
import Wiki.Server.Storage.Audit (Recorded (..), consoleAddress, insertAudit, operator)
import Wiki.Server.Storage.Rows (AccountRow, IdentityRow (..), Stamp (..), accountFromRow, deleteIdentity, deleteInvitation, deleteSessionsOf, grantCreateSpaces, identitiesOf, identityOf, insertAccount, insertIdentity, loadAccount, noPasswordToSet, pendingInvitation, providerNames, refreshIdentity, selectAccounts, totpEnabled, updateDisabled, updatePasswordHash)

--------------------------------------------------------------------------------
-- Accounts

-- | A user's account, by id.
accountOf :: Storage -> UserId -> IO (Maybe Account)
accountOf st u = withDatabase st (`loadAccount` u)

-- | A user's account, by login, compared as SQLite compares text ignoring
-- case (ASCII letters only): what someone types to sign in.
accountByLogin :: Storage -> Text -> IO (Maybe Account)
accountByLogin st login = withDatabase st $ \c ->
  fmap accountFromRow . head <$> query c (selectAccounts "WHERE login = ? COLLATE NOCASE") (Only (T.strip login))

-- | Every user's account, by login, with whether they are an
-- administrator (hold the global @administer@ themselves).
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

-- | Create a user, who signs in with this password, or (with none) cannot
-- sign in until they are given one. A blank display name becomes the
-- login. A login another user has, in any case, is a 'Conflict'; an
-- invalid login or password is 'Invalid'.
createAccount :: Storage -> Text -> Text -> Maybe Text -> IO (Either WikiError Account)
createAccount st rawLogin rawName password = runExceptT $ do
  login <- either (throwError . Invalid) pure (checkLogin rawLogin)
  phc <- for password $ \p -> either (throwError . Invalid) (liftIO . hashPassword) (checkPassword p)
  uid <- liftIO (UUID.toText <$> generateV4)
  let name = case T.strip rawName of
        "" -> login
        n -> n
  ExceptT . withDatabase st $ \c ->
    immediately c $
      insertAccount c (UserId uid) login name phc >>= \case
        Left t -> pure (Left (taken t))
        Right account -> do
          fromConsole c "user.create" account.user [("login", login), ("name", name)]
          pure (Right account)
  where
    taken login = Conflict ("There is a user with the login " <> login <> " already.")

-- | Give a user a new password, and end their sessions.
setPassword :: Storage -> UserId -> Text -> IO (Either WikiError Account)
setPassword st u password = case checkPassword password of
  Left why -> pure (Left (Invalid why))
  Right p -> do
    phc <- hashPassword p
    changeAccount st u "user.password" [] $ \c -> do
      updatePasswordHash c u phc
      deleteSessionsOf c u

-- | Disable a user's login, which ends their sessions, or enable it again.
setDisabled :: Storage -> UserId -> Bool -> IO (Either WikiError Account)
setDisabled st u disabled = changeAccount st u (if disabled then "user.disable" else "user.enable") [] $ \c -> do
  updateDisabled c u disabled
  when disabled (deleteSessionsOf c u)

-- | Make a user an administrator (the global @administer@, granted to
-- them directly), or take it away. Their groups' grants are not changed.
setAdministrator :: Storage -> UserId -> Bool -> IO (Either WikiError Account)
setAdministrator st u administrator = changeAccount st u "user.administrator" [("administrator", if administrator then "yes" else "no")] $ \c ->
  if administrator
    then execute c "INSERT OR IGNORE INTO global_grants (subject_kind, subject_id, permission) VALUES ('user', ?, 'administer')" (Only u.text)
    else execute c "DELETE FROM global_grants WHERE subject_kind = 'user' AND subject_id = ? AND permission = 'administer'" (Only u.text)

-- | Change an existing user, from the console, in one transaction with
-- its audit log row, and return their account afterwards; 'NotFound' for a
-- user who does not exist.
changeAccount :: Storage -> UserId -> Text -> [(Text, Text)] -> (Connection -> IO ()) -> IO (Either WikiError Account)
changeAccount st u action detail change = withDatabase st $ \c -> immediately c $ do
  loadAccount c u >>= \case
    Nothing -> pure (Left NotFound)
    Just a -> do
      change c
      fromConsole c action a.user detail
      maybe (Left NotFound) Right <$> loadAccount c u

-- | Record what the console did to a user.
fromConsole :: Connection -> Text -> User -> [(Text, Text)] -> IO ()
fromConsole c action u detail =
  insertAudit c Recorded {actor = operator, action, subject = Subject {kind = "user", id = Just u.id.text, name = u.login}, detail, address = consoleAddress}

-- | Run something in a transaction that holds the write lock from its
-- start: committed if it returns a 'Right', rolled back if it returns a
-- 'Left' or throws.
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

-- | Create one's own account, in an open wiki, from a network address.
-- The result is the user created, and the id of the session they are
-- signed in with. A closed wiki refuses it ('Forbidden') before anything
-- is checked; then the account is checked as 'createAccount' checks one
-- ('Invalid', 'Conflict').
register :: Storage -> UTCTime -> Text -> NewAccount -> IO (Either WikiError (User, Text))
register st now address new = runExceptT $ do
  open <- liftIO (takesNewAccounts . (\s -> s.access) <$> readSettings st)
  unless open (throwError Forbidden)
  made <- prepared new
  ExceptT . withDatabase st $ \c -> immediately c $ do
    -- The wiki may have been closed while the password was hashed.
    settings <- settingsWith st c
    if takesNewAccounts settings.access
      then makeAccount c now address settings made >>= recordMade c address "user.register" []
      else pure (Left Forbidden)

-- | Who an invitation is for, if it can be used now.
invitationFor :: Storage -> UTCTime -> InvitationToken -> IO (Maybe InvitationInfo)
invitationFor st now token = withDatabase st $ \c -> fmap snd <$> pendingInvitation c now (tokenHash token.text)

-- | Create the account an invitation is for, in an open or closed wiki,
-- and use up the invitation. The result is the user created, and the id of
-- the session they are signed in with. An invitation that cannot be used
-- (used, revoked, or expired) is 'NotFound', checked before the account. A
-- login that is taken leaves the invitation unused, so another can be
-- tried.
acceptInvitation :: Storage -> UTCTime -> Text -> InvitationToken -> NewAccount -> IO (Either WikiError (User, Text))
acceptInvitation st now address token new = runExceptT $ do
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
          made' <- makeAccount c now address settings made
          when (isRight made') (void (deleteInvitation c i))
          recordMade c address "invitation.accept" [("invitation", i.text)] made'

-- | Record in the audit log that someone created their own account, as
-- done by them, from their address, in the transaction that created it.
recordMade :: Connection -> Text -> Text -> [(Text, Text)] -> Either e (User, Text) -> IO (Either e (User, Text))
recordMade c address action detail made = do
  for_ made $ \(u, _) ->
    insertAudit c Recorded {actor = Actor {id = u.id, login = u.login}, action, subject = Subject {kind = "user", id = Just u.id.text, name = u.login}, detail, address}
  pure made

-- | An account to create, checked, with its password hashed: its id,
-- login, display name and the password's hash.
prepared :: NewAccount -> ExceptT WikiError IO (UserId, Text, Text, Maybe Text)
prepared new = do
  (login, password) <- either (throwError . Invalid) pure ((,) <$> checkLogin new.login <*> checkPassword new.password)
  phc <- liftIO (hashPassword password)
  uid <- liftIO (UUID.toText <$> generateV4)
  let name = case T.strip new.displayName of
        "" -> login
        n -> n
  pure (UserId uid, login, name, Just phc)

-- | Create a checked account, in a running transaction, with the grant the
-- wiki's settings give new accounts, and sign its creator in, from their
-- network address. An account without a password signs in another way:
-- with a provider's account.
makeAccount :: Connection -> UTCTime -> Text -> WikiSettings -> (UserId, Text, Text, Maybe Text) -> IO (Either WikiError (User, Text))
makeAccount c now address settings (uid, login, name, phc) =
  insertAccount c uid login name phc >>= \case
    Left taken -> pure (Left (Conflict ("There is a user with the login " <> taken <> " already.")))
    Right account -> do
      when settings.newAccountsCreateSpaces (grantCreateSpaces c uid)
      token <- startSession c now uid address
      pure (Right (account.user, token))

--------------------------------------------------------------------------------
-- Signing in with a provider

-- | What a provider said about one of its accounts, once the server has
-- verified that the provider said it ("Wiki.Server.Oidc").
data Claimed = Claimed
  { provider :: Text
  -- ^ The provider, by the name the configuration gives it.
  , subject :: Text
  -- ^ The account's permanent id at the provider.
  , email :: Maybe Text
  -- ^ Its e-mail address, only if the provider verified it.
  , name :: Maybe Text
  -- ^ The person's name, as they gave it at the provider.
  , login :: Maybe Text
  -- ^ Their user name at the provider, if any (a GitHub login, an OpenID
  -- Connect @preferred_username@): the first choice for a login here.
  }
  deriving stock (Eq, Show)

-- | What signing in with a provider was requested for.
data Intent
  = -- | To sign in: as the user whose identity it is, or as a new account
    -- where the wiki accepts one.
    SignInOnly
  | -- | To connect it to this user, who was signed in when they asked.
    LinkTo UserId
  | -- | To create the account this invitation is for.
    Invited InvitationToken
  deriving stock (Eq, Show)

-- | The result of signing in with a provider.
data Landing
  = -- | Signed in as this user, with this new session id; and whether the
    -- account was created just now.
    SignedInAs User Text Bool
  | -- | The identity now belongs to this user (or already did).
    Linked User
  | -- | The identity belongs to this user, who has a second factor: they
    -- are signed in once they give a code ("Wiki.Server.SecondFactor").
    SecondFactorFor User
  deriving stock (Eq, Show)

-- | Why signing in with a provider failed.
data Refusal
  = -- | The identity belongs to a disabled user.
    DisabledAccount
  | -- | Connecting it was requested, but it belongs to another user.
    AnotherUsers
  | -- | Connecting it was requested, but the user already has an identity
    -- at that provider.
    HasOneThere
  | -- | Connecting it was requested by a user who has since been deleted
    -- or disabled.
    NoOneToLink
  | -- | It belongs to nobody, and the wiki is closed.
    ClosedWiki
  | -- | It was to create an invitation's account, and the invitation
    -- cannot be used (used, revoked or expired).
    UnusableInvitation
  deriving stock (Eq, Show)

-- | Sign in with a provider's account, connect it, or create an account
-- with it, as requested and as the wiki's rules allow, in one transaction
-- (see the module's Haddock), from a network address. What the provider
-- now says about the account is stored with the identity. A user who has
-- a second factor is not signed in by their identity alone, just as not by
-- their password alone: the result says that a code is needed.
landWith :: Storage -> UTCTime -> Text -> Intent -> Claimed -> IO (Either Refusal Landing)
landWith st now address intent claimed = withDatabase st $ \c ->
  immediately c $
    identityOf c claimed.provider claimed.subject >>= \case
      Just found -> do
        refreshIdentity c claimed.provider claimed.subject claimed.email claimed.name
        case intent of
          LinkTo me
            | found.user /= me -> pure (Left AnotherUsers)
            | otherwise -> maybe (Left NoOneToLink) (Right . Linked . (\a -> a.user)) <$> active c me
          _ ->
            active c found.user >>= \case
              Nothing -> pure (Left DisabledAccount)
              Just a ->
                totpEnabled c a.user.id >>= \case
                  True -> pure (Right (SecondFactorFor a.user))
                  False -> Right . (\token -> SignedInAs a.user token False) <$> startSession c now a.user.id address
      Nothing -> case intent of
        LinkTo me ->
          active c me >>= \case
            Nothing -> pure (Left NoOneToLink)
            Just a -> do
              theirs <- identitiesOf c me
              if any (\i -> i.provider == claimed.provider) theirs
                then pure (Left HasOneThere)
                else do
                  insertIdentity c now me claimed.provider claimed.subject claimed.email claimed.name
                  pure (Right (Linked a.user))
        Invited token ->
          pendingInvitation c now (tokenHash token.text) >>= \case
            Nothing -> pure (Left UnusableInvitation)
            Just (i, _) -> do
              made <- newAccount c [("invitation", i.text)]
              void (deleteInvitation c i)
              pure (Right made)
        SignInOnly -> do
          settings <- settingsWith st c
          if takesNewAccounts settings.access
            then Right <$> newAccount c []
            else pure (Left ClosedWiki)
  where
    -- A user who may sign in: exists, and is not disabled.
    active c u = mfilter (\a -> not a.disabled) <$> loadAccount c u
    -- An account for the identity, with the first of its candidate logins
    -- that nobody has, and no password; recorded in the audit log as
    -- created by its owner, with the provider, like one with a password.
    newAccount c detail = do
      settings <- settingsWith st c
      uid <- UserId . UUID.toText <$> generateV4
      let tries = take 100 (loginCandidates claimed)
          made login =
            makeAccount c now address settings (uid, login, fromMaybe login (mfilter (not . T.null) (T.strip <$> claimed.name)), Nothing)
          go = \case
            [] -> do
              -- A hundred are taken: use one with a random suffix, which
              -- nobody has.
              suffix <- T.take 8 . T.filter (/= '-') . UUID.toText <$> generateV4
              made (fromMaybe "user" (head tries) <> "-" <> suffix)
            l : rest -> made l >>= either (const (go rest)) (pure . Right)
      go tries >>= \case
        Left e -> panic ("no login could be made for an identity: " <> show e)
        Right (user, token) -> do
          insertIdentity c now user.id claimed.provider claimed.subject claimed.email claimed.name
          _ <- recordMade c address "user.register" (("provider", claimed.provider) : detail) (Right (user, token) :: Either () (User, Text))
          pure (SignedInAs user token True)

-- | The logins to try for an account created with a provider's account;
-- the first that nobody has is taken. The base is the person's user name
-- at the provider, else their e-mail address's local part, else their
-- name, turned into something a login can be (lower case, letters, digits,
-- dots and underscores, with dashes between words, at most 40
-- characters), else @user@; then the same with @-2@, @-3@ and so on after
-- it.
loginCandidates :: Claimed -> [Text]
loginCandidates claimed = base : [base <> "-" <> show n | n <- [2 :: Int ..]]
  where
    -- A login that is an e-mail address (Microsoft's are) gives its local
    -- part.
    base = fromMaybe "user" (find (not . T.null) (map loginOf (catMaybes [localPart <$> claimed.login, localPart <$> claimed.email, claimed.name])))
    localPart = T.takeWhile (/= '@')
    loginOf = T.take 40 . T.intercalate "-" . filter (not . T.null) . T.split (not . allowed) . T.toLower
    allowed ch = isAscii ch && (isAlphaNum ch || ch == '.' || ch == '_')

-- | How a user signs in: whether with a password, and their identities.
signInMethods :: Storage -> UserId -> IO (Either WikiError SignInMethods)
signInMethods st u = withDatabase st (`methodsOf` u)

methodsOf :: Connection -> UserId -> IO (Either WikiError SignInMethods)
methodsOf c u =
  loadAccount c u >>= \case
    Nothing -> pure (Left NotFound)
    Just a -> do
      theirs <- identitiesOf c u
      pure (Right SignInMethods {password = a.hasPassword, identities = map (\i -> i.identity) theirs})

-- | A user disconnects their identity at a provider. The result is how
-- they sign in afterwards. 'NotFound' if they have none there, 'Conflict'
-- if it is their last way to sign in.
unlinkIdentity :: Storage -> UserId -> Text -> IO (Either WikiError SignInMethods)
unlinkIdentity st u provider = withDatabase st $ \c -> immediately c $ runExceptT $ do
  before <- ExceptT (methodsOf c u)
  unless (any (\i -> i.provider == provider) before.identities) (throwError NotFound)
  let after = withoutIdentity provider before
  unless (signsInSomehow after) $
    throwError (Conflict "This is the only way you have to sign in: connect another account first, or ask an administrator for a password.")
  _ <- liftIO (deleteIdentity c u provider)
  pure after

--------------------------------------------------------------------------------
-- One's own password

-- | Why a user's change of their own password was refused.
data PasswordRefusal
  = -- | They have a password, and the one they gave as the current one is
    -- wrong (or they gave none).
    WrongCurrent
  | -- | Any other failure: the new password is not valid ('Invalid'), the
    -- user no longer exists ('NotFound'), or someone else changed the
    -- password meanwhile ('Conflict').
    PasswordRefused WikiError
  deriving stock (Eq, Show)

-- | A user changes their own password, giving their current one if they
-- have one ('WrongCurrent' if it is wrong). The result is how they sign in
-- afterwards. A user without a password who signs in with a server
-- provider is refused ('Invalid'): they have no password to set. Every
-- session of theirs ends except the one with this id (from the request's
-- cookie), if any. The new password is checked before anything is hashed,
-- and hashed before the connection is taken.
changePassword :: Storage -> UserId -> Maybe Text -> Maybe Text -> Text -> IO (Either PasswordRefusal SignInMethods)
changePassword st u keep current new = runExceptT $ do
  password <- either (throwError . PasswordRefused . Invalid) pure (checkPassword new)
  -- Read before the connection is taken, since reading them may take it.
  configured <- liftIO (providerNames <$> readServerSettings st)
  before <- liftIO (withDatabase st (`passwordHashOf` u)) >>= maybe (throwError (PasswordRefused NotFound)) pure
  none <- liftIO (withDatabase st (\c -> noPasswordToSet c configured u))
  when none $
    throwError (PasswordRefused (Invalid "You sign in with a provider, and have no password to set: sign in there."))
  for_ before $ \phc ->
    unless (maybe False (verifyPassword phc) current) (throwError WrongCurrent)
  phc <- liftIO (hashPassword password)
  ExceptT . withDatabase st $ \c -> immediately c $ do
    now <- passwordHashOf c u
    if now /= Just before
      then pure (Left (PasswordRefused (Conflict "Your password was changed meanwhile: sign in again with the new one.")))
      else do
        updatePasswordHash c u phc
        case keep of
          Just token -> execute c "DELETE FROM sessions WHERE user_id = ? AND id_hash <> ?" (u.text, tokenHash token)
          Nothing -> deleteSessionsOf c u
        first PasswordRefused <$> methodsOf c u

-- | Whether a given password is a user's current one, for what a session
-- alone may not do (WP4.11 of docs/PLAN.md). 'Just True' for the right
-- one, and for a user who has none (who signs in only with a provider's
-- account, and gives none); 'Nothing' for a user who does not exist.
currentPasswordIs :: Storage -> UserId -> Maybe Text -> IO (Maybe Bool)
currentPasswordIs st u given =
  fmap (maybe True (\phc -> maybe False (verifyPassword phc) given)) <$> withDatabase st (`passwordHashOf` u)

-- | A user's password hash, if they exist: 'Nothing' for a user who does
-- not, @Just Nothing@ for one without a password.
passwordHashOf :: Connection -> UserId -> IO (Maybe (Maybe Text))
passwordHashOf c u = head . map fromOnly <$> query c "SELECT password_hash FROM users WHERE id = ?" (Only u.text)

--------------------------------------------------------------------------------
-- Sessions

-- | How long an unused session lasts: two weeks, so that someone who reads
-- the wiki now and then stays signed in, and a session left on a machine
-- no longer used ends by itself.
idleTime :: NominalDiffTime
idleTime = 14 * 24 * 60 * 60

-- | How long after its end was last moved later a use moves it again (and
-- the cookie is sent again with the new lifetime): an hour.
refreshEvery :: NominalDiffTime
refreshEvery = 60 * 60

-- | How long after its last recorded use a session's use is recorded
-- again, with the address it came from, for the account panel's "last
-- seen": a minute, so that a session in use costs at most a write a minute.
seenEvery :: NominalDiffTime
seenEvery = 60

-- | Why signing in failed.
data SignInFailure
  = -- | No user has that login and password, or their account cannot sign
    -- in (it has no password, or it is disabled); the answer does not say
    -- which.
    NoSuchAccount
  | -- | The password is not one the server accepts (too long).
    BadPassword
  | -- | The login and password are right, and the user has a second
    -- factor: no session until they give a code.
    SecondFactorWanted User
  deriving stock (Eq, Show)

-- | Sign in with a login and a password, from a network address. The
-- result is the user, and the id of their new session for the cookie. An
-- unknown login costs the same hashing as a known one, so that the time
-- the answer takes does not reveal whether a login exists. Sessions that
-- have ended by themselves are deleted along the way.
signIn :: Storage -> UTCTime -> Text -> Text -> Text -> IO (Either SignInFailure (User, Text))
signIn st now address login password
  | T.length password > 1024 = pure (Left BadPassword)
  | otherwise = do
      found <- withDatabase st $ \c ->
        head <$> query c (selectAccounts "WHERE login = ? COLLATE NOCASE") (Only (T.strip login))
      let hashOf :: AccountRow -> Maybe Text
          hashOf (_, _, _, phc, _) = phc
          matches = verifyPassword (fromMaybe unknownHash (found >>= hashOf)) password
      case found of
        Just row@(_, _, _, Just _, 0) | matches -> do
          let user = (accountFromRow row).user
          withDatabase st $ \c ->
            totpEnabled c user.id >>= \case
              True -> pure (Left (SecondFactorWanted user))
              False -> Right . (user,) <$> startSession c now user.id address
        _ -> pure (Left NoSuchAccount)

-- | Create a new session for a user, from now and from a network address.
-- The result is the id its cookie is to carry. Sessions that have ended by
-- themselves are deleted along the way.
startSession :: Connection -> UTCTime -> UserId -> Text -> IO Text
startSession c now u address = do
  token <- newToken
  publicId <- newPublicId
  execute c "DELETE FROM sessions WHERE expires_at <= ?" (Only (Stamp now))
  execute
    c
    "INSERT INTO sessions (id_hash, user_id, created_at, last_seen_at, expires_at, public_id, address) VALUES (?, ?, ?, ?, ?, ?, ?)"
    (tokenHash token, u.text, Stamp now, Stamp now, Stamp (addUTCTime idleTime now), publicId, address)
  pure token

-- | A hash of nobody's password, to check a password against when the
-- login belongs to no user or has no password, so that the answer takes as
-- long.
unknownHash :: Text
unknownHash = "$argon2id$v=19$m=19456,t=2,p=1$bm8gc3VjaCB1c2Vy$7J1aqbF9XWbPBHCGdFP2N5tTqYlUvlEkB5qe2PAU4p0"

-- | A session, found by the id its cookie carries.
data Resolved = Resolved
  { user :: UserId
  , refreshed :: Bool
  -- ^ Whether this use moved its end later, so that the cookie should be
  -- sent again with the new lifetime.
  }
  deriving stock (Eq, Show)

-- | The session a cookie's id names, if it has not ended, used now from a
-- network address. A session that has ended (idle too long, its user
-- disabled) is deleted, and belongs to nobody. Its use is recorded at most
-- every 'seenEvery', and its end moved later at most every 'refreshEvery'
-- (the last such move is its end minus 'idleTime').
--
-- Every request asks for its session, so the session is read on one of
-- the storage's readers ('withReadConnection'), which does not wait for
-- writes. Only deleting a session or recording its use takes the writer,
-- for that one statement. If the user signs out in another tab between
-- the read and the write, the write changes no row, and this request is
-- still answered as signed in. That is the same answer as when the
-- sign-out comes just after the request.
resolveSession :: Storage -> UTCTime -> Text -> Text -> IO (Maybe Resolved)
resolveSession st now address token = do
  let key = tokenHash token
      write :: (ToRow q) => Query -> q -> IO ()
      write statement params = withDatabase st (\c -> execute c statement params)
  rows <-
    withReadConnection st $ \c ->
      query
        c
        "SELECT s.user_id, s.last_seen_at, s.expires_at, u.disabled FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id_hash = ?"
        (Only key)
  case rows of
    [(uid, Stamp seen, Stamp expires, disabled)]
      | expires <= now || disabled /= (0 :: Int) -> do
          write "DELETE FROM sessions WHERE id_hash = ?" (Only key)
          pure Nothing
      | diffUTCTime now (addUTCTime (negate idleTime) expires) >= refreshEvery -> do
          write "UPDATE sessions SET last_seen_at = ?, address = ?, expires_at = ? WHERE id_hash = ?" (Stamp now, address, Stamp (addUTCTime idleTime now), key)
          pure (Just Resolved {user = UserId uid, refreshed = True})
      | otherwise -> do
          when (diffUTCTime now seen >= seenEvery) $
            write "UPDATE sessions SET last_seen_at = ?, address = ? WHERE id_hash = ?" (Stamp now, address, key)
          pure (Just Resolved {user = UserId uid, refreshed = False})
    _ -> pure Nothing

-- | End the session a cookie's id names, if there is one.
endSession :: Storage -> Text -> IO ()
endSession st token = withDatabase st $ \c -> execute c "DELETE FROM sessions WHERE id_hash = ?" (Only (tokenHash token))

--------------------------------------------------------------------------------
-- One's own sessions

-- | A user's sessions that have not ended, the most recently used first,
-- with the one with this id (from the request's cookie, if any) marked as
-- current.
listSessions :: Storage -> UTCTime -> UserId -> Maybe Text -> IO [SessionSummary]
listSessions st now u token = withDatabase st (\c -> sessionsOf c now u token)

sessionsOf :: Connection -> UTCTime -> UserId -> Maybe Text -> IO [SessionSummary]
sessionsOf c now u token = do
  rows <-
    query
      c
      "SELECT public_id, created_at, last_seen_at, expires_at, address, id_hash FROM sessions WHERE user_id = ? AND public_id IS NOT NULL ORDER BY last_seen_at DESC, created_at DESC"
      (Only u.text)
  pure
    [ SessionSummary {id = SessionRef ref, createdAt, lastSeenAt, address, current = Just key == (tokenHash <$> token)}
    | (ref, Stamp createdAt, Stamp lastSeenAt, Stamp expires, address, key) <- rows
    , expires > now
    ]

-- | End one of a user's sessions, by its id. The result is their sessions
-- afterwards. 'NotFound' for a session that is not theirs (or has ended),
-- 'Invalid' for the current one, which should sign out instead.
endSessionOf :: Storage -> UTCTime -> UserId -> Maybe Text -> SessionRef -> IO (Either WikiError [SessionSummary])
endSessionOf st now u token ref = withDatabase st $ \c -> immediately c $ do
  theirs <- sessionsOf c now u token
  case find (\s -> s.id == ref) theirs of
    Nothing -> pure (Left NotFound)
    Just s
      | s.current -> pure (Left (Invalid "This is the session you are using: sign out instead."))
      | otherwise -> do
          execute c "DELETE FROM sessions WHERE user_id = ? AND public_id = ?" (u.text, ref.text)
          Right <$> sessionsOf c now u token

-- | End every session of a user's except the one with this id (the
-- current one). The result is their sessions afterwards.
endOtherSessions :: Storage -> UTCTime -> UserId -> Maybe Text -> IO [SessionSummary]
endOtherSessions st now u token = withDatabase st $ \c -> do
  case token of
    Just t -> execute c "DELETE FROM sessions WHERE user_id = ? AND id_hash <> ?" (u.text, tokenHash t)
    Nothing -> deleteSessionsOf c u
  sessionsOf c now u token
