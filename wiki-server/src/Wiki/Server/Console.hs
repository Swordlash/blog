{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE MultiWayIf #-}

-- | @wiki-server users …@: the wiki's users from the machine it runs on
-- (decision 11 of docs/PLAN.md and its addition of 2026-10-25), so that the
-- first administrator is made before there is a panel to make one with,
-- and an installation whose administrators are all locked out is recovered
-- without a browser.
--
-- > wiki-server users list     --data DIR
-- > wiki-server users add      --data DIR LOGIN [--display-name NAME] [--admin] [--no-password]
-- > wiki-server users password --data DIR LOGIN
-- > wiki-server users admin    --data DIR LOGIN (--on | --off)
-- > wiki-server users disable  --data DIR LOGIN (--on | --off)
--
-- Each runs on the data directory, as @backup@ does, and may while the
-- server runs on it: the database waits for the server's writes rather
-- than fail, and nothing else in the directory is touched
-- ('Wiki.Server.Storage.withStorageAside'). Being able to read and write
-- the data directory is the credential, as being able to reach the admin
-- listener is.
--
-- A password is never an argument, where it would stay in the shell's
-- history and show in the list of processes: it is asked for on the
-- terminal, twice and not echoed, or read as the first line of standard
-- input when that is not a terminal (@printf '%s\\n' "$pw" | wiki-server
-- users add …@).
module Wiki.Server.Console
  ( -- * Commands
    Users (..)
  , UsersCommand (..)
  , usersParser
  , runUsers

    -- * Passwords
  , readPassword
  )
where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
import Protolude
import System.IO (hFlush, hGetEcho, hIsTerminalDevice, hSetEcho)
import Wiki.Api.Account (Account (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.User (User (..))
import Wiki.Server.Accounts (accountByLogin, createAccount, listAccounts, setAdministrator, setDisabled, setPassword)
import Wiki.Server.Storage (Storage, withStorageAside)

-- | A command, on a data directory.
data Users = Users
  { dataDir :: FilePath
  , command :: UsersCommand
  }
  deriving stock (Eq, Show)

data UsersCommand
  = -- | Every user, with what they may do.
    ListUsers
  | -- | Make a user: their login, their display name (their login if not
    -- given), whether they are an administrator, and whether they sign in
    -- with a password (asked for) or cannot sign in until given one.
    AddUser Text (Maybe Text) Bool Bool
  | -- | Give a user a new password (asked for), which signs them out.
    SetUserPassword Text
  | -- | Make a user an administrator, or not.
    SetUserAdministrator Text Bool
  | -- | Disable a user's login, which signs them out, or enable it.
    SetUserDisabled Text Bool
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
    )
  where
    users c = Users <$> strOption (long "data" <> metavar "DIR" <> help "The server's data directory") <*> c
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

-- | Run a command, with this way of reading a password: the lines to show,
-- or why it could not be done.
runUsers :: (Text -> IO (Either Text Text)) -> Users -> IO (Either Text [Text])
runUsers askPassword u = withStorageAside u.dataDir $ \st -> runExceptT $ case u.command of
  ListUsers -> do
    accounts <- liftIO (listAccounts st)
    pure $
      if null accounts
        then ["There are no users yet: make the first administrator with", "  wiki-server users add --data " <> toS u.dataDir <> " LOGIN --admin"]
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
  where
    wiki :: IO (Either WikiError a) -> ExceptT Text IO a
    wiki = withExceptT explain . ExceptT
    explain = \case
      NotFound -> "There is no such user."
      Forbidden -> "That is not allowed."
      Conflict why -> why
      Invalid why -> why
      Unreachable why -> why

-- | A user by login, or that there is none.
found :: Storage -> Text -> ExceptT Text IO Account
found st login = maybe (throwError ("There is no user with the login " <> login <> ".")) pure =<< liftIO (accountByLogin st login)

describe :: User -> Text
describe user = user.login <> " (" <> user.displayName <> ")"

-- | The users as a table: login, name, and what they may do.
listing :: [(Account, Bool)] -> [Text]
listing accounts = row heading : map (row . cells) accounts
  where
    heading :: (Text, Text, Text, Text)
    heading = ("LOGIN", "NAME", "ADMINISTRATOR", "SIGNS IN")
    cells :: (Account, Bool) -> (Text, Text, Text, Text)
    cells (a, admin) =
      ( a.user.login
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

-- | A user's password: asked for twice on the terminal, without echoing
-- it, or, when standard input is not a terminal, its first line.
readPassword :: Text -> IO (Either Text Text)
readPassword login = do
  terminal <- hIsTerminalDevice stdin
  if terminal
    then do
      first' <- silently ("Password for " <> login <> ": ")
      second' <- silently "Again, to be sure: "
      pure (if first' == second' then Right first' else Left "The two passwords differ; nothing was changed.")
    else do
      line <- try @IOException (TIO.hGetLine stdin)
      pure $ case line of
        Right l | not (T.null (T.dropWhileEnd (== '\r') l)) -> Right (T.dropWhileEnd (== '\r') l)
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
