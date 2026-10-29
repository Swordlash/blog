{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE MultiWayIf #-}

-- | The console commands @wiki-server users …@: managing the wiki's users
-- from the machine it runs on (decision 11 of docs/PLAN.md and its
-- addition of 2026-10-25). They create the first administrator before
-- there is a panel to do it with, and recover an installation whose
-- administrators are all locked out, without a browser.
--
-- > wiki-server users list     --data DIR
-- > wiki-server users add      --data DIR LOGIN [--display-name NAME] [--admin] [--no-password]
-- > wiki-server users password --data DIR LOGIN
-- > wiki-server users admin    --data DIR LOGIN (--on | --off)
-- > wiki-server users disable  --data DIR LOGIN (--on | --off)
-- > wiki-server users second-factor-remove --data DIR LOGIN
--
-- Each runs on the data directory, as @backup@ does, and may do so while
-- the server runs on it: the database waits for the server's writes
-- instead of failing, and nothing else in the directory is touched
-- ('Wiki.Server.Storage.withStorageAside'). Being able to read and write
-- the data directory is the credential, as being able to reach the admin
-- listener is.
--
-- A password is never an argument, where it would stay in the shell's
-- history and show in the process list. It is asked for on the terminal,
-- twice and not echoed, or read as the first line of standard input when
-- that is not a terminal (@printf '%s\\n' "$pw" | wiki-server users add
-- …@).
--
-- @wiki-server restore@ is also a console command ('restoreParser',
-- 'Wiki.Server.Storage.Backup.restore'): it restores a backup as a data
-- directory's database, into a directory no server has open.
--
-- @wiki-server oidc check@ is also a console command ('runOidcCheck'): it
-- asks the providers the administration has set (WP3.6, WP4.4) how to sign
-- in, before anyone tries, and prints the redirect URI to register with
-- each, reading them from the data directory as the server does.
module Wiki.Server.Console
  ( -- * Commands
    Users (..)
  , UsersCommand (..)
  , usersParser
  , runUsers

    -- * Passwords
  , readPassword

    -- * Providers
  , OidcCheck (..)
  , oidcCheckParser
  , runOidcCheck

    -- * Backing up and restoring
  , RestoreCommand (..)
  , restoreParser
  , runRestore
  , runBackup
  , BackupOutcome (..)
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
import Protolude
import System.IO (hFlush, hGetEcho, hIsTerminalDevice, hSetEcho)
import Wiki.Api.Account (Account (..))
import Wiki.Api.ServerSettings (ProviderSettingsOf (..), ServerSettingsOf (..), kindName, providerLabel, providerProblems, redirectUri)
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (removeSecondFactor))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Server.Accounts (accountByLogin, createAccount, listAccounts, setAdministrator, setDisabled, setPassword)
import Wiki.Server.Oidc (Endpoints (..), endpointsOf, freshProvider, newProviderCache, optionOf)
import Wiki.Server.Options (PlaceOptions (..), placeOptions, resolvePlace)
import Wiki.Server.Secret (Kept, revealed)
import Wiki.Server.Storage (Place (..), Storage, Who (..), readServerSettings, runStoredWikiFrom, withStorageAside)
import Wiki.Server.Storage.Audit (consoleAddress)
import Wiki.Server.Storage.Backup (Restore (..), backupNow, restore)
import Wiki.Server.Storage.Migrate (OldSchema)

-- | A @wiki-server users@ command, on a data directory.
data Users = Users
  { place :: PlaceOptions
  , command :: UsersCommand
  }
  deriving stock (Eq, Show)

data UsersCommand
  = -- | Every user, with what they may do.
    ListUsers
  | -- | Create a user: their login, their display name (the login if not
    -- given), whether they are an administrator, and whether they sign in
    -- with a password (asked for) or cannot sign in until given one.
    AddUser Text (Maybe Text) Bool Bool
  | -- | Give a user a new password (asked for), which signs them out.
    SetUserPassword Text
  | -- | Make a user an administrator, or not.
    SetUserAdministrator Text Bool
  | -- | Disable a user's login, which signs them out, or enable it.
    SetUserDisabled Text Bool
  | -- | Remove a user's second factor (WP4.11 of docs/PLAN.md), for someone
    -- who has lost it and whose administrators cannot sign in either.
    RemoveSecondFactor Text
  deriving stock (Eq, Show)

-- | The options of @wiki-server users@.
usersParser :: Parser Users
usersParser =
  hsubparser
    ( command "list" (info (users (pure ListUsers)) (progDesc "List the users, with who is an administrator and who may sign in"))
        <> command "add" (info (users add) (progDesc "Make a user, with a password read from the terminal or standard input"))
        <> command "password" (info (users (SetUserPassword <$> login)) (progDesc "Give a user a new password, read from the terminal or standard input; it signs them out"))
        <> command "admin" (info (users (SetUserAdministrator <$> login <*> onOff "an administrator")) (progDesc "Make a user an administrator (--on), or not (--off)"))
        <> command "disable" (info (users (SetUserDisabled <$> login <*> onOff "disabled")) (progDesc "Disable a user's login (--on), which signs them out, or enable it again (--off)"))
        <> command "second-factor-remove" (info (users (RemoveSecondFactor <$> login)) (progDesc "Take a user's second factor away, so that they sign in with their password alone"))
    )
  where
    users c = Users <$> placeOptions <*> c
    login = strArgument (metavar "LOGIN" <> help "The user's login")
    add = do
      l <- login
      name <- optional (strOption (long "display-name" <> metavar "NAME" <> help "What pages show them as (their login if not given)"))
      admin <- switch (long "admin" <> help "Make them an administrator")
      noPassword <- switch (long "no-password" <> help "Give them no password: they cannot sign in until one is set")
      pure (AddUser l name admin (not noPassword))
    onOff what =
      flag' True (long "on" <> help ("Make them " <> what))
        <|> flag' False (long "off" <> help ("Make them not " <> what))

-- | Run a command, with this way of reading a password. The result is the
-- lines to show, or why it could not be done.
runUsers :: (Text -> IO (Either Text Password)) -> Users -> IO (Either Text [Text])
runUsers askPassword u = (`onPlace` u.place) $ \at -> withStorageAside at $ \st -> runExceptT $ case u.command of
  ListUsers -> do
    accounts <- liftIO (listAccounts st)
    pure $
      if null accounts
        then ["There are no users yet: make the first administrator with", "  wiki-server users add --data " <> toS u.place.dataDir <> " LOGIN --admin"]
        else listing accounts
  AddUser login name admin withPassword -> do
    password <- if withPassword then Just <$> ExceptT (askPassword login) else pure Nothing
    made <- wiki (createAccount st login (fromMaybe "" name) password)
    when admin $ void (wiki (setAdministrator st made.user.id True))
    pure
      [ "Made " <> describe made.user <> (if admin then ", an administrator" else "") <> "."
      , if withPassword then "They sign in with the password given." else "They cannot sign in until they are given a password (wiki-server users password)."
      ]
  SetUserPassword login -> do
    a <- found st login
    password <- ExceptT (askPassword login)
    _ <- wiki (setPassword st a.user.id password)
    pure ["Gave " <> describe a.user <> " a new password; their sessions have ended."]
  SetUserAdministrator login yes -> do
    a <- found st login
    _ <- wiki (setAdministrator st a.user.id yes)
    pure [describe a.user <> (if yes then " is an administrator." else " is not an administrator any more (what their groups are granted stays).")]
  SetUserDisabled login yes -> do
    a <- found st login
    _ <- wiki (setDisabled st a.user.id yes)
    pure [describe a.user <> (if yes then " cannot sign in any more; their sessions have ended." else " can sign in again.")]
  RemoveSecondFactor login -> do
    a <- found st login
    -- The user exists: what is missing is their second factor.
    _ <- withExceptT (const (describe a.user <> " has no second factor.")) (ExceptT (runStoredWikiFrom st Administrator consoleAddress (removeSecondFactor a.user.id)))
    pure [describe a.user <> " signs in with their password alone now."]
  where
    wiki :: IO (Either WikiError a) -> ExceptT Text IO a
    wiki = withExceptT explain . ExceptT
    explain = \case
      NotFound -> "There is no such user."
      Forbidden -> "That is not allowed."
      Conflict why -> why
      Invalid why -> why
      Unreachable why -> why

-- | A user by login, or an error saying there is none.
found :: Storage -> Text -> ExceptT Text IO Account
found st login = maybe (throwError ("There is no user with the login " <> login <> ".")) pure =<< liftIO (accountByLogin st login)

describe :: User -> Text
describe user = user.login.text <> " (" <> user.displayName <> ")"

-- | The users as a table: login, name, and what they may do.
listing :: [(Account, Bool)] -> [Text]
listing accounts = row heading : map (row . cells) accounts
  where
    heading :: (Text, Text, Text, Text)
    heading = ("LOGIN", "NAME", "ADMINISTRATOR", "SIGNS IN")
    cells :: (Account, Bool) -> (Text, Text, Text, Text)
    cells (a, admin) =
      ( a.user.login.text
      , a.user.displayName
      , if admin then "yes" else "no"
      , if
          | a.disabled -> "no (disabled)"
          | not a.hasPassword -> "no (no password)"
          | otherwise -> "yes"
      )
    width f = maximum (map (T.length . f) (heading : map cells accounts))
    loginWidth = width (\(l, _, _, _) -> l)
    nameWidth = width (\(_, n, _, _) -> n)
    adminWidth = width (\(_, _, x, _) -> x)
    row (l, n, x, s) = T.stripEnd (T.justifyLeft loginWidth ' ' l <> "  " <> T.justifyLeft nameWidth ' ' n <> "  " <> T.justifyLeft adminWidth ' ' x <> "  " <> s)

-- | Read a user's password: asked for twice on the terminal, without
-- echoing it, or, when standard input is not a terminal, its first line.
readPassword :: Text -> IO (Either Text Password)
readPassword login = do
  terminal <- hIsTerminalDevice stdin
  if terminal
    then do
      first' <- silently ("Password for " <> login <> ": ")
      second' <- silently "Again, to be sure: "
      pure (if first' == second' then Right (Password first') else Left "The two passwords differ; nothing was changed.")
    else do
      line <- try @IOException (TIO.hGetLine stdin)
      pure $ case line of
        Right l | not (T.null (T.dropWhileEnd (== '\r') l)) -> Right (Password (T.dropWhileEnd (== '\r') l))
        _ -> Left "No password on standard input: give it as the first line, or run this on a terminal to be asked."
  where
    silently :: Text -> IO Text
    silently prompt = do
      TIO.hPutStr stderr prompt
      hFlush stderr
      echo <- hGetEcho stdin
      line <- bracket_ (hSetEcho stdin False) (hSetEcho stdin echo) (TIO.hGetLine stdin)
      TIO.hPutStrLn stderr ""
      pure line

--------------------------------------------------------------------------------
-- Providers

-- | @wiki-server oidc check --data DIR [NAME]@: ask the providers the
-- administration has set how to sign in (discovery), and show the redirect
-- URI each must have registered, and whether its secret is set. Nobody is
-- signed in, and no secret is shown.
data OidcCheck = OidcCheck
  { place :: PlaceOptions
  , only :: Maybe Text
  -- ^ The one provider to check, if not all.
  }
  deriving stock (Eq, Show)

oidcCheckParser :: Parser OidcCheck
oidcCheckParser =
  hsubparser
    ( command
        "check"
        ( info
            ( OidcCheck
                <$> placeOptions
                <*> optional (strArgument (metavar "NAME" <> help "Check only this provider"))
            )
            (progDesc "Ask each provider set in the administration how to sign in, and print the redirect URI to register with it")
        )
    )

-- | Check the providers. The result is the lines to show, and whether
-- every provider checked can be used to sign in.
runOidcCheck :: OidcCheck -> IO (Bool, [Text])
runOidcCheck c =
  resolvePlace c.place.dataDir c.place.database c.place.programs >>= \case
    Left why -> pure (False, [why])
    Right at -> withStorageAside at readServerSettings >>= checkProviders c

-- | 'runOidcCheck' with the server's settings read.
checkProviders :: OidcCheck -> Kept -> IO (Bool, [Text])
checkProviders c kept = do
  let chosen = maybe kept.providers (\n -> filter (\p -> p.name == n) kept.providers) c.only
  cache <- newProviderCache
  if
    | null chosen ->
        pure (False, [maybe "No provider is set: add one in the administration's Server section." (\n -> "No provider is named " <> n <> ".") c.only])
    | otherwise -> do
        reports <- for chosen $ \p -> do
          let problems = providerProblems p
              secretLine = case p.secret of
                Just _ -> "  client secret: set"
                Nothing -> "  client secret: NOT SET, set it in the administration's Server section"
          asked <- case problems of
            why : _ -> pure (Left why)
            [] -> freshProvider cache (fromMaybe (Url "") kept.publicUrl) (optionOf p) (maybe "" revealed p.secret) >>= endpointsOf
          let label = p.name <> " (" <> providerLabel p.kind p.name <> ", kind " <> kindName p.kind <> ", client " <> p.clientId <> ")"
              lines' = case asked of
                Left why -> ["  cannot be asked how to sign in: " <> why]
                Right e ->
                  ["  issuer: " <> e.issuer, "  authorization: " <> e.authorization, "  token: " <> e.token]
                    <> ["  user info: " <> u | Just u <- [e.userinfo]]
              redirect = case kept.publicUrl of
                Just u -> "  redirect URI to register: " <> (redirectUri u p.name).text
                Nothing -> "  redirect URI: none until the wiki's public address is set in the administration's Server section"
          pure
            ( isRight asked && isJust p.secret && isJust kept.publicUrl
            , [label, redirect, secretLine] <> lines'
            )
        pure (all fst reports, concatMap snd reports)

--------------------------------------------------------------------------------
-- Restoring a backup

-- | @wiki-server restore BACKUP --data DIR [--attachments DIR]@, with the
-- options that name the database to restore into.
data RestoreCommand = RestoreCommand
  { backupFile :: FilePath
  , place :: PlaceOptions
  , attachments :: Maybe FilePath
  }
  deriving stock (Eq, Show)

-- | The options of @wiki-server restore@.
restoreParser :: Parser RestoreCommand
restoreParser =
  RestoreCommand
    <$> strArgument (metavar "BACKUP" <> help "The backup to restore: a file of DIR/backups, or one copied off the machine")
    <*> placeOptions
    <*> optional (strOption (long "attachments" <> metavar "DIR" <> help "A copy of the attachments' files (an off-site copy's attachments directory), to bring the missing ones from"))

-- | Restore a backup ('Wiki.Server.Storage.Backup.restore'). The result is
-- the lines to show, or why nothing was done.
runRestore :: RestoreCommand -> IO (Either Text [Text])
runRestore r = (`onPlace` r.place) $ \at ->
  restore Restore {backupFile = r.backupFile, dataDir = at.dataDir, database = at.database, programs = at.programs, attachments = r.attachments}

-- | What @wiki-server backup@ did: the line to show, and how the program
-- ends.
data BackupOutcome
  = -- | A backup was made, or there is no wiki to back up yet.
    BackedUp Text
  | -- | No backup could be made, for this reason.
    BackupFailed Text
  | -- | The database is an earlier wiki-server's, which this one does not
    -- read: the deploy scripts tell this apart from a failure (the
    -- program's exit code 3), and stop.
    OfEarlierServer Text
  deriving stock (Eq, Show)

-- | Back up the database, keeping this many backups
-- ('Wiki.Server.Storage.Backup.backupNow').
runBackup :: PlaceOptions -> Int -> IO BackupOutcome
runBackup options keep =
  try @OldSchema made <&> \case
    Left old -> OfEarlierServer (toS (displayException old))
    Right (Left why) -> BackupFailed why
    Right (Right line) -> BackedUp line
  where
    made = (`onPlace` options) $ \at ->
      fmap (maybe "There is no database to back up yet." (\file -> "Backed up into " <> toS file)) <$> backupNow at.programs at.database at.dataDir keep

-- | Run something where the options say the wiki is; why not, when they
-- name a password file that cannot be read.
onPlace :: (Place -> IO (Either Text a)) -> PlaceOptions -> IO (Either Text a)
onPlace act options = resolvePlace options.dataDir options.database options.programs >>= either (pure . Left) act
