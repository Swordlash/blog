-- | The wiki's server.
--
-- > wiki-server [serve] --data DIR [--listen HOST:PORT] [--admin-listen HOST:PORT]
-- >                     [--base-path PATH] [--static DIR] [--secure-cookies] …
-- > wiki-server backup --data DIR [--keep N]
-- > wiki-server restore BACKUP --data DIR [--attachments DIR]
-- > wiki-server users (list | add | password | admin | disable) --data DIR …
-- > wiki-server oidc check --data DIR [NAME]
-- > wiki-server --version
--
-- @serve@ (also what runs with no command) serves the wiki from the data
-- directory on its two listeners ("Wiki.Server", "Wiki.Server.Options");
-- @backup@ copies the database aside into DIR/backups, keeping the last N
-- copies ("Wiki.Server.Storage.Backup"), which the deploy script runs before
-- it starts a new server; @restore@ puts one back as the database of a
-- data directory no server is running on, the attachments' files it lacks
-- brought from a copy if one is given; @users@ makes and changes the wiki's users and
-- their passwords ("Wiki.Server.Console"), which is how the first
-- administrator is made; @oidc check@ asks the providers the
-- administration has set how to sign in, and prints the redirect URI to
-- register with each.
module Main (main) where

import Options.Applicative
import Protolude
import Wiki.Server (ServerError (..), serve)
import Wiki.Server.Console (OidcCheck, Users, oidcCheckParser, readPassword, restoreParser, runOidcCheck, runUsers, usersParser)
import Wiki.Server.Options (ServeOptions, serveOptions)
import Wiki.Server.Storage.Backup (Restore, backup, defaultKeep, restore)
import Wiki.Server.Version (serverVersion)

-- | What the server is asked to do.
data Command
  = -- | Serve the wiki.
    Serve ServeOptions
  | -- | Back the database of a data directory up, keeping this many.
    Backup FilePath Int
  | -- | Put a backup back as a data directory's database.
    Restore Restore
  | -- | Make or change a user.
    Users Users
  | -- | Check the providers to sign in with.
    Oidc OidcCheck

commands :: ParserInfo Command
commands =
  info
    ( ( hsubparser
          ( command "serve" (info (Serve <$> serveOptions) (progDesc "Serve the wiki (the default command)"))
              <> command "backup" (info backupCommand (progDesc "Copy the database aside into DIR/backups, keeping the last few copies"))
              <> command "restore" (info (Restore <$> restoreParser) (progDesc "Restore a backup into a data directory no server is running on"))
              <> command "users" (info (Users <$> usersParser) (progDesc "List, make and change the wiki's users: the first administrator is made here"))
              <> command "oidc" (info (Oidc <$> oidcCheckParser) (progDesc "Check the providers people sign in with, and print their redirect URIs"))
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
        <$> strOption (long "data" <> metavar "DIR" <> help "The server's data directory")
        <*> option auto (long "keep" <> metavar "N" <> value defaultKeep <> showDefault <> help "How many backups to keep")

main :: IO ()
main =
  execParser commands >>= \case
    Serve options ->
      serve options `catch` \(ServerError reasons) -> do
        for_ reasons $ \r -> putErrText ("wiki-server: " <> r)
        exitWith (ExitFailure 2)
    Backup dataDir keep ->
      backup dataDir keep >>= \case
        Just file -> putText ("Backed up into " <> toS file)
        Nothing -> putText "There is no database to back up yet."
    Restore r ->
      restore r >>= \case
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
    Oidc c -> do
      (fine, lines') <- runOidcCheck c
      traverse_ putText lines'
      unless fine (exitWith (ExitFailure 1))
