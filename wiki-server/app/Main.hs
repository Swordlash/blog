-- | The wiki's server.
--
-- > wiki-server [serve] --data DIR [--listen HOST:PORT] [--admin-listen HOST:PORT]
-- >                     [--trust-network] [--base-path PATH] [--static DIR] …
-- > wiki-server backup --data DIR [--keep N]
-- > wiki-server --version
--
-- @serve@ (also what runs with no command) serves the wiki from the data
-- directory on its two listeners ("Wiki.Server", "Wiki.Server.Options");
-- @backup@ copies the database aside into DIR/backups, keeping the last N
-- copies ("Wiki.Server.Storage.Backup"), which the deploy script runs before
-- it starts a new server.
module Main (main) where

import Options.Applicative
import Protolude
import Wiki.Server (ServerError (..), serve)
import Wiki.Server.Options (ServeOptions, serveOptions)
import Wiki.Server.Storage.Backup (backup, defaultKeep)
import Wiki.Server.Version (serverVersion)

-- | What the server is asked to do.
data Command
  = -- | Serve the wiki.
    Serve ServeOptions
  | -- | Back the database of a data directory up, keeping this many.
    Backup FilePath Int

commands :: ParserInfo Command
commands =
  info
    ( ( hsubparser
          ( command "serve" (info (Serve <$> serveOptions) (progDesc "Serve the wiki (the default command)"))
              <> command "backup" (info backupCommand (progDesc "Copy the database aside into DIR/backups, keeping the last few copies"))
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
