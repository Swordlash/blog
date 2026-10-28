-- | What the storage does so that it keeps up with many users and many
-- pages (WP5.16a of docs/PLAN.md, "docs/scalability-audit.md"): reads run
-- beside a long read and beside a write, on the storage's readers.
module Test.Storage.Scale (spec) where

import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Connection, Query, execute_)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.Core.Space (Space (..))
import Wiki.Server.Accounts (Resolved (..), resolveSession, startSession)
import Wiki.Server.Storage

spec :: Spec
spec = describe "the storage, at scale" $ do
  readers

-- | An action that must end within two seconds: one that waits for a lock
-- another operation holds does not.
soon :: (HasCallStack) => IO a -> IO a
soon act = timeout 2_000_000 act >>= maybe (assertFailure "still waiting after two seconds") pure

-- | Hold a transaction open on a connection of the storage's, after a
-- statement in it, until the action given is done: what a long operation
-- does to everything else.
holding :: ((Connection -> IO ()) -> IO ()) -> Query -> Query -> IO a -> IO a
holding onConnection begin statement act = do
  started <- newEmptyMVar
  done <- newEmptyMVar
  held <- async . onConnection $ \c -> do
    execute_ c begin
    execute_ c statement
    putMVar started ()
    takeMVar done
    execute_ c "ROLLBACK"
  takeMVar started
  act `finally` (putMVar done () >> wait held)

readers :: Spec
readers = describe "reads" $ do
  let signedIn st = do
        who <- whoFor st (As "reader")
        u <- case who of
          AsUser u -> pure u
          _ -> assertFailure "the reader is nobody"
        now <- getCurrentTime
        token <- withDatabase st (\c -> startSession c now u "127.0.0.1")
        pure (who, u, now, token)
      blog st who = soon (runSqliteWiki st who (getSpace (path "blog"))) >>= ok

  it "run beside a long read, and so does finding whose a session is" $ withDemo $ \st -> do
    (who, u, now, token) <- signedIn st
    -- A read, so that the transaction holds a snapshot.
    holding (withReadConnection st) "BEGIN" "SELECT count(*) FROM pages" $ do
      s <- blog st who
      s.name `shouldBe` "Blog"
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a long write, and see what was committed before it" $ withDemo $ \st -> do
    (who, u, now, token) <- signedIn st
    committed <- blog st who
    holding (withDatabase st) "BEGIN IMMEDIATE" "UPDATE spaces SET name = 'Renamed' WHERE slug = 'blog'" $ do
      s <- blog st who
      s `shouldBe` committed
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a backup, and a backup runs beside a long write" $ withDemo $ \st ->
    withSystemTempDirectory "wiki-scale-test" $ \dir -> do
      (who, _, _, _) <- signedIn st
      holding (withDatabase st) "BEGIN IMMEDIATE" "UPDATE spaces SET name = 'Renamed' WHERE slug = 'blog'" $ do
        soon (copyDatabase st (dir </> "copy.sqlite"))
        void (blog st who)
