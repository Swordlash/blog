-- | 'Maker.Deploy.Rehearse' is the deploy's rehearsal of an upgrade (WP5.75
-- of docs/PLAN.md, issue #205): before the running deployment is touched,
-- the new wiki-server rehearses the upgrade on a copy of the wiki's
-- database (@wiki-server rehearse@, "Wiki.Server.Rehearsal" in
-- wiki-server). The old program serves the copy first, the new one
-- migrates and serves it after, and each check compares what the two
-- read. The running wiki keeps running throughout: the copy is made the
-- way a backup is, while it runs.
--
-- A failed check stops the deploy, with nothing to undo. An old program
-- the rehearsal cannot drive (one from before the options it is started
-- with) is not a failed check: the deploy stops all the same, and says
-- that @--no-rehearsal@ deploys without the rehearsal, this once.
--
-- The scratch copy is in the state directory, readable only by its owner,
-- and deleted afterwards. On PostgreSQL the copy is a database of its own,
-- @wiki_rehearsal@, in the deployment's container: dropped before (a
-- rehearsal that was killed may have left it) and after.
module Maker.Deploy.Rehearse
  ( rehearse
  , rehearsalDatabase
  )
where

import Control.Exception (finally)
import Control.Monad (unless, when)
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (pgCompose, pgWrapperFor)
import Maker.Deploy.Unit (dbUrl)
import System.Directory (doesFileExist, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- | The PostgreSQL database the copy is restored into, beside the
-- deployment's own @wiki@ in its container.
rehearsalDatabase :: String
rehearsalDatabase = "wiki_rehearsal"

-- | Rehearse the upgrade, when there is one to rehearse: a deployment of
-- the server that is replaced by a new one on the same kind of database.
-- A first deploy, a change of database or @--fresh@ (both of which start
-- an empty wiki) and @--no-rehearsal@ go without.
rehearse :: Plan -> IO ()
rehearse p = do
  let v = get p
      name = v "name"
      dir = v "dir"
      oldBin = dir </> "bin" </> "wiki-server"
      newBin = v "server_bin"
      db = v "db"
      dbPort = v "db_port"
      pgDir = v "state_dir" </> (name <> ".postgres")
      scratch = v "state_dir" </> (name <> ".rehearsal")
  oldThere <- doesFileExist oldBin
  let wanted = v "mode" == "server" && oldThere && not (has p "incompatible")
  when (wanted && has p "no_rehearsal") $
    warn "--no-rehearsal: the upgrade is not rehearsed on a copy of the wiki first"
  when (wanted && not (has p "no_rehearsal")) $ do
    say "rehearsing the upgrade on a copy of the wiki (wiki-server rehearse), which keeps running meanwhile"
    removePathForcibly scratch
    let postgres = db == "postgres"
        dropScratch = when postgres (psql ("DROP DATABASE IF EXISTS " <> rehearsalDatabase))
        liveArgs
          | postgres = ["--database", dbUrl dbPort, "--database-password-file", pgDir </> "db-password", "--pg-dump", pgDir </> "pg_dump", "--pg-restore", pgDir </> "pg_restore"]
          | otherwise = ["--sqlite", dir </> "data" </> "wiki.sqlite"]
        scratchRestore = v "state_dir" </> (name <> ".rehearsal-pg_restore")
        scratchArgs
          | postgres =
              [ "--scratch-database"
              , scratchUrl dbPort
              , "--scratch-database-password-file"
              , pgDir </> "db-password"
              , "--scratch-pg-restore"
              , scratchRestore
              ]
          | otherwise = []
        psql statement = do
          code <- pgCompose name pgDir dbPort ["exec", "-T", "postgres", "psql", "--quiet", "--username=wiki", "--dbname=wiki", "--command", statement]
          unless (code == ExitSuccess) (die ("the rehearsal's scratch database could not be prepared (" <> statement <> "); the running wiki is as it was"))
    when postgres $ do
      dropScratch
      psql ("CREATE DATABASE " <> rehearsalDatabase)
      writeFile scratchRestore (pgWrapperFor name pgDir dbPort "pg_restore" rehearsalDatabase)
      setFileMode scratchRestore 0o700
    code <-
      runInherit newBin (["rehearse", "--old", oldBin, "--data", dir </> "data"] <> liveArgs <> ["--scratch", scratch] <> scratchArgs)
        `finally` (removePathForcibly scratch >> when postgres (removePathForcibly scratchRestore >> dropScratch))
    case code of
      ExitSuccess -> say "the rehearsal passed: the new program reads the wiki as the old one did"
      ExitFailure 6 -> die "the rehearsal of the upgrade failed (see above): the new program does not read the wiki as the old one did. The running wiki is as it was; nothing was changed"
      ExitFailure 7 ->
        die
          "the rehearsal could not drive the program the wiki runs now (see above), so the upgrade was not rehearsed. The running wiki is as it was. To deploy without the rehearsal this once, run the deploy again with --no-rehearsal"
      ExitFailure _ -> die "the rehearsal of the upgrade could not be done (see above). The running wiki is as it was; nothing was changed. To deploy without the rehearsal this once, run the deploy again with --no-rehearsal"
  where
    scratchUrl port = "postgres://wiki@127.0.0.1:" <> (if null port then "5433" else port) <> "/" <> rehearsalDatabase
