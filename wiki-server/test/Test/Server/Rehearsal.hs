-- | The upgrade's rehearsal (WP5.75 of docs/PLAN.md, "Wiki.Server.Rehearsal"):
-- the pages check's comparison of the pages read before the migration
-- with those read after. The rehearsal itself runs two programs, and is
-- tested end to end by toolchain/rehearse-ci.sh in CI.
module Test.Server.Rehearsal (unitSpec, spec) where

import Data.Aeson (encode)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (hContentType)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing, withConnectionTo, withEmptyPlace)
import Test.Hspec
import Test.Server.Fixture (Reply (status), Running (..), cookie, givePassword, send, signInAs, withDemoRunning)
import Wiki.Api.Types (PersonalSpaceSwitch (..))
import Wiki.Server.Rehearsal (PageRead (..), Server (..), comparePages, isolateCopy, readPages)
import Wiki.Server.Storage (migrateDatabase)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (settingsLike, storeSetting)

unitSpec :: Spec
unitSpec = describe "the upgrade's rehearsal, the pages check" $ do
  let first' = PageRead {space = "s1", page = "p1", title = "First", body = "# First\n\nText."}
      second' = PageRead {space = "s1", page = "p2", title = "Second", body = "More."}
  it "passes when every page reads the same, in whatever order" $
    comparePages [first', second'] [second', first'] `shouldBe` Right ()
  it "names a page whose source changed, one whose title changed, one gone and one new" $ do
    let changed = first' {body = "# First\n\nOther text."}
        renamed = second' {title = "Second, renamed"}
        third = PageRead {space = "s2", page = "p3", title = "Third", body = ""}
        why = either identity (const "") (comparePages [first', second'] [changed, renamed, third])
    why `shouldSatisfy` T.isInfixOf "page p1 (First) has another source"
    why `shouldSatisfy` T.isInfixOf "page p2 (Second) has another title: Second, renamed"
    why `shouldSatisfy` T.isInfixOf "page p3 (Third) is new"
    comparePages [first', second'] [first'] `shouldSatisfy` isLeft
  it "tells the same page id in two spaces apart" $
    comparePages [first'] [first' {space = "s2"}] `shouldSatisfy` isLeft
  it "names five differences and counts the rest" $ do
    let pages = [PageRead {space = "s", page = show i, title = "t", body = "b"} | i <- [1 .. 8 :: Int]]
        why = either identity (const "") (comparePages pages [])
    why `shouldSatisfy` T.isInfixOf "and 3 more"

-- | The copy is cut off from the outside before a server starts on it: no
-- scheduled backup to the running wiki's destination, no notification
-- mail through its mail server.
spec :: Backing -> Spec
spec backing = describe "the upgrade's rehearsal, its copy of the wiki" $ do
  it "reads every page an administrator may read, and leaves out the spaces nobody may" $ withDemoRunning backing identity $ \r -> do
    manager <- newManager defaultManagerSettings
    let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public}
    withoutPersonal <- readPages manager server
    withoutPersonal `shouldSatisfy` isRight
    -- The editor's personal space makes the container of personal spaces,
    -- which the list of spaces names and nobody may read.
    givePassword r "user-editor" "editor's password"
    token <- signInAs r "editor" "editor's password"
    turnedOn <- send r "PUT" (r.public <> "/api/v1/account/personal-space") [(hContentType, "application/json"), cookie token] (encode PersonalSpaceSwitch {enabled = True})
    turnedOn.status `shouldBe` 200
    withPersonal <- readPages manager server
    withPersonal `shouldSatisfy` isRight
  it "loses its backup and mail settings, and keeps the rest" $
    withSystemTempDirectory "wiki-rehearsal" $ \dir -> withEmptyPlace backing dir $ \place -> do
      _ <- migrateDatabase place
      withConnectionTo place $ \c ->
        runDb c $
          traverse_
            (uncurry storeSetting)
            [ ("backup-enabled", "1")
            , ("backup-schedule", "every 1")
            , ("backup-directory", "/mnt/backup/wiki")
            , ("backup-last", "{}")
            , ("mail-host", "smtp.example.org")
            , ("mail-from", "wiki@example.org")
            , ("access", "closed")
            ]
      isolateCopy place
      left <- withConnectionTo place $ \c -> runDb c (concat <$> traverse settingsLike ["backup-", "mail-", "access"])
      sort left `shouldBe` [("access", "closed"), ("backup-last", "{}")]
