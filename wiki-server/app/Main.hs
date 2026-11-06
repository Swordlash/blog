-- | The wiki's server.
--
-- > wiki-server [serve] --data DIR [DATABASE] [--listen HOST:PORT] [--admin-listen HOST:PORT]
-- >                     [--base-path PATH] [--static DIR] [--secure-cookies] …
-- > wiki-server backup --data DIR [DATABASE] [--keep N]
-- > wiki-server restore BACKUP --data DIR [DATABASE] [--attachments DIR]
-- > wiki-server users (list | add | password | admin | disable) --data DIR [DATABASE] …
-- > wiki-server oidc check --data DIR [DATABASE] [NAME]
-- > wiki-server guide (install | update) --data DIR [DATABASE]
-- > wiki-server compress DIR
-- > wiki-server --version
--
-- DATABASE is @--database postgres:\/\/USER\@HOST\/NAME
-- [--database-password-file FILE]@ for a PostgreSQL database, or @--sqlite
-- FILE@; without either, the URL in @WIKI_DATABASE_URL@ if it is set, else
-- the SQLite file @DIR\/wiki.sqlite@ ("Wiki.Server.Options").
-- A wiki-server built without PostgreSQL (the cabal flag @postgres@ off)
-- refuses a PostgreSQL database at start; @--version@ prints, after the
-- version, the databases it was built for (@backends: sqlite@).
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
-- @compress@ writes a gzip copy beside each of the application's files
-- worth compressing, for a deployment made without Node
-- ("Wiki.Server.Compress").
module Main (main) where

import Options.Applicative
import Protolude
import Sel (secureMain)
import System.Directory (doesDirectoryExist)
import Wiki.Server (ServerError (..), serve)
import Wiki.Server.Compress (compressDirectory)
import Wiki.Server.Console (BackupOutcome (..), CheckOutcome (..), GuideCommand, MigrateOutcome (..), OidcCheck, RestoreCommand, Users, guideParser, oidcCheckParser, readPassword, restoreParser, runBackup, runCheck, runGuide, runMigrate, runOidcCheck, runRestore, runUsers, usersParser)
import Wiki.Server.Options (PlaceOptions, ServeOptions, placeOptions, serveOptions)
import Wiki.Server.Storage.Backup (defaultKeep)
import Wiki.Server.Version (serverVersion, versionReport)

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
  | -- | Write the gzip copies of the application's files in a directory.
    Compress FilePath
  | -- | Apply the schema's pending steps to a database, and nothing else.
    Migrate PlaceOptions
  | -- | Read the whole database, as the deploy does after a migration.
    Check PlaceOptions

commands :: ParserInfo Command
commands =
  info
    ( ( hsubparser
          ( command "serve" (info (Serve <$> serveOptions) (progDesc "Serve the wiki (the default command)"))
              <> command "backup" (info backupCommand (progDesc "Copy the database aside into DIR/backups, keeping the last few copies"))
              <> command "restore" (info (Restore <$> restoreParser) (progDesc "Restore a backup into a data directory no server is running on"))
              <> command "migrate" (info (Migrate <$> placeOptions) (progDesc "Bring the database to this program's version of the schema, and do nothing else"))
              <> command "check" (info (Check <$> placeOptions) (progDesc "Read every row of every table as this program does, and change nothing"))
              <> command "users" (info (Users <$> usersParser) (progDesc "List, make and change the wiki's users: the first administrator is made here"))
              <> command "oidc" (info (Oidc <$> oidcCheckParser) (progDesc "Check the providers people sign in with, and print their redirect URIs"))
              <> command "guide" (info (Guide <$> guideParser) (progDesc "Install the guide, the wiki's documentation, or give its pages this version's text"))
              <> command "compress" (info compressCommand (progDesc "Write a gzip copy beside each of the application's files worth compressing, for the server to send"))
          )
          <|> (Serve <$> serveOptions)
      )
        <**> simpleVersioner (toS versionReport)
        <**> helper
    )
    (fullDesc <> progDesc "The wiki's server" <> header (toS serverVersion))
  where
    backupCommand =
      Backup
        <$> placeOptions
        <*> option auto (long "keep" <> metavar "N" <> value defaultKeep <> showDefault <> help "How many backups to keep")
    compressCommand =
      Compress <$> strArgument (metavar "DIR" <> help "The application's directory, as --static names it")

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
      Migrate place ->
        runMigrate place >>= \case
          MigratedTo line -> putText line
          MigrateFailed why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
          MigrateOfEarlierServer why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 3)
      Check place ->
        runCheck place >>= \case
          CheckPassed lines' -> traverse_ putText lines'
          CheckNotMigrated why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 4)
          CheckUnreadable lines' -> do
            traverse_ (putErrText . ("wiki-server: " <>)) lines'
            exitWith (ExitFailure 5)
          CheckFailed why -> do
            putErrText ("wiki-server: " <> why)
            exitWith (ExitFailure 1)
      Compress dir -> do
        exists <- doesDirectoryExist dir
        unless exists $ do
          putErrText ("wiki-server: there is no directory " <> toS dir)
          exitWith (ExitFailure 1)
        written <- compressDirectory dir
        putText ("Wrote " <> show written <> " gzip copies in " <> toS dir <> ".")
      Oidc c -> do
        (fine, lines') <- runOidcCheck c
        traverse_ putText lines'
        unless fine (exitWith (ExitFailure 1))
