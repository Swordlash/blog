-- | The wiki's server.
--
-- > wiki-server [serve] --data DIR [DATABASE] [--listen HOST:PORT] [--admin-listen HOST:PORT]
-- >                     [--base-path PATH] [--static DIR] [--secure-cookies] …
-- > wiki-server backup --data DIR [DATABASE] [--keep N]
-- > wiki-server restore BACKUP --data DIR [DATABASE] [--attachments DIR]
-- > wiki-server users (list | add | password | admin | disable) --data DIR [DATABASE] …
-- > wiki-server oidc check --data DIR [DATABASE] [NAME]
-- > wiki-server guide (install | update) --data DIR [DATABASE]
-- > wiki-server --version
--
-- DATABASE is @--database postgres:\/\/USER\@HOST\/NAME
-- [--database-password-file FILE]@ for a PostgreSQL database, or @--sqlite
-- FILE@; without either, the URL in @WIKI_DATABASE_URL@ if it is set, else
-- the SQLite file @DIR\/wiki.sqlite@ ("Wiki.Server.Options").
--
-- @serve@ (also what runs with no command) serves the wiki from the data
-- directory on its two listeners ("Wiki.Server", "Wiki.Server.Options").
-- @backup@ copies the database into DIR/backups, keeping the last N copies
-- ("Wiki.Server.Storage.Backup"); the deploy script runs it before it
-- starts a new server. @restore@ restores a backup as the database of a
-- data directory no server is running on, bringing the attachment files it
-- lacks from a copy if one is given. @users@ creates and changes the wiki's
-- users and their passwords ("Wiki.Server.Console"), which is how the first
-- administrator is created. @oidc check@ asks the providers the
-- administration has set how to sign in, and prints the redirect URI to
-- register with each. @guide install@ puts the guide, the wiki's
-- documentation as a public space, back into a wiki that has none, and
-- @guide update@ gives its pages this version's text ("Wiki.Server.Guide").
module Main (main) where

import Options.Applicative
import Protolude
import Sel (secureMain)
import Wiki.Server (ServerError (..), serve)
import Wiki.Server.Console (BackupOutcome (..), GuideCommand, OidcCheck, RestoreCommand, Users, guideParser, oidcCheckParser, readPassword, restoreParser, runBackup, runGuide, runOidcCheck, runRestore, runUsers, usersParser)
import Wiki.Server.Options (PlaceOptions, ServeOptions, placeOptions, serveOptions)
import Wiki.Server.Storage.Backup (defaultKeep)
import Wiki.Server.Version (serverVersion)

-- | What the server is asked to do.
data Command
  = -- | Serve the wiki.
    Serve ServeOptions
  | -- | Back up a data directory's database, keeping this many backups.
    Backup PlaceOptions Int
  | -- | Restore a backup as a data directory's database.
    Restore RestoreCommand
  | -- | Create or change a user.
    Users Users
  | -- | Check the providers to sign in with.
    Oidc OidcCheck
  | -- | Install the guide, or bring it up to this version.
    Guide GuideCommand

commands :: ParserInfo Command
commands =
  info
    ( ( hsubparser
          ( command "serve" (info (Serve <$> serveOptions) (progDesc "Serve the wiki (the default command)"))
              <> command "backup" (info backupCommand (progDesc "Copy the database aside into DIR/backups, keeping the last few copies"))
              <> command "restore" (info (Restore <$> restoreParser) (progDesc "Restore a backup into a data directory no server is running on"))
              <> command "users" (info (Users <$> usersParser) (progDesc "List, make and change the wiki's users: the first administrator is made here"))
              <> command "oidc" (info (Oidc <$> oidcCheckParser) (progDesc "Check the providers people sign in with, and print their redirect URIs"))
              <> command "guide" (info (Guide <$> guideParser) (progDesc "Install the guide, the wiki's documentation, or give its pages this version's text"))
          )
          <|> (Serve <$> serveOptions)
      )
        <**> simpleVersioner (toS serverVersion)
        <**> helper
    )
    (fullDesc <> progDesc "The wiki's server" <> header (toS serverVersion))
  where
    backupCommand =
      Backup
        <$> placeOptions
        <*> option auto (long "keep" <> metavar "N" <> value defaultKeep <> showDefault <> help "How many backups to keep")

main :: IO ()
main =
  -- libsodium is initialised first: the second factor's codes need it
  -- (Wiki.Server.Totp, over one-time-password and sel).
  secureMain $
    execParser commands >>= \case
      Serve options ->
        serve options `catch` \(ServerError reasons) -> do
          for_ reasons $ \r -> putErrText ("wiki-server: " <> r)
          exitWith (ExitFailure 2)
      Backup place keep ->
        runBackup place keep >>= \case
          BackedUp line -> putText line
          BackupFailed why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
          OfEarlierServer why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 3)
      Restore r ->
        runRestore r >>= \case
          Right lines' -> traverse_ putText lines'
          Left why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
      Users u ->
        runUsers readPassword u >>= \case
          Right lines' -> traverse_ putText lines'
          Left why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
      Guide g ->
        runGuide g >>= \case
          Right lines' -> traverse_ putText lines'
          Left why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
      Oidc c -> do
        (fine, lines') <- runOidcCheck c
        traverse_ putText lines'
        unless fine (exitWith (ExitFailure 1))
