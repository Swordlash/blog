-- | The wiki's server. Phase 2 of docs/PLAN.md writes it: the storage is in
-- (the library, "Wiki.Server.Storage"), the HTTP server comes with WP2.3.
-- What runs today is the one command the deploy script needs of it already:
--
-- > wiki-server backup --data DIR [--keep N]
--
-- which copies the database aside into DIR/backups, keeping the last N
-- copies ("Wiki.Server.Storage.Backup").
module Main (main) where

import Options.Applicative
import Protolude
import Wiki.Server.Storage.Backup (backup, defaultKeep)

-- | What the server is asked to do.
data Command
  = -- | Back the database of a data directory up, keeping this many.
    Backup FilePath Int

commands :: ParserInfo (Maybe Command)
commands =
  info
    (optional (hsubparser (command "backup" (info backupCommand (progDesc "Copy the database aside into DIR/backups, keeping the last few copies")))) <**> helper)
    (fullDesc <> progDesc "The wiki's server")
  where
    backupCommand =
      Backup
        <$> strOption (long "data" <> metavar "DIR" <> help "The server's data directory")
        <*> option auto (long "keep" <> metavar "N" <> value defaultKeep <> showDefault <> help "How many backups to keep")

main :: IO ()
main =
  execParser commands >>= \case
    Just (Backup dataDir keep) ->
      backup dataDir keep >>= \case
        Just file -> putText ("Backed up into " <> toS file)
        Nothing -> putText "There is no database to back up yet."
    Nothing -> putText "wiki-server: there is no server yet (WP2.3); `wiki-server backup --data DIR` backs its database up."
