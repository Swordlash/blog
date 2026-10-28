-- | The administration's "Activity" and the Server section's "Status", in
-- a browser (WP4.10 of docs/PLAN.md, "Wiki.App.View.Activity",
-- "Wiki.App.View.Status"): over the demo's wiki, both say what the demo
-- does not have; over HTTP, the log's entries newest first in words, the
-- next page and a person's own, and the last errors the server logged.
module Test.Browser.Activity (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, quietServer, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AdminApi (..), WikiApi (..))
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin (LoggedError (..), ServerStatus (..))
import Wiki.Api.Links (links)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Id (UserId (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = describe "the activity and the server's status" $ do
  demo m
  overHttp m

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | Choose the option at this index of a menu, from the keyboard.
choose :: Mounted s q o m -> Text -> Int -> PageM s ()
choose ui selector n = do
  menu <- find ui selector
  focus menu
  press "Home"
  replicateM_ n (press "ArrowDown")

demo :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
demo m = describe "over the demo's wiki" $
  it "says that the demo keeps no log and has no server" $
    runPage $ do
      ui <- start m (Just "user-admin") Admin
      find ui ".admin-activity .activity-unavailable" >>= (`shouldContainText` "The demo keeps no activity log")
      find ui ".server-status .status-unavailable" >>= (`shouldContainText` "The demo has no server")
      unmount ui

at :: Int -> UTCTime
at h = UTCTime (fromGregorian 2026 10 25) (fromIntegral (h * 3600))

ada, operator :: Actor
ada = Actor {id = UserId "u1", login = "ada"}
operator = Actor {id = UserId "~administrator", login = "administrator"}

entry :: Text -> Int -> Actor -> Text -> Subject -> [(Text, Text)] -> Text -> AuditEntry
entry i h actor action subject detail address = AuditEntry {id = i, at = at h, actor, action, subject, detail = Map.fromList detail, address}

overHttp :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
overHttp m = describe "over HTTP" $
  it "lists the log newest first in words, pages through it and filters it by person, and shows the server's last errors" $
    runPage $ do
      serverStarts
      serveDemo
      let granted = entry "e3" 9 ada "space.grant" Subject {kind = "space", id = Just "s1", name = "Docs"} [("to", "group writers"), ("permission", "edit")] "100.64.0.7"
          made = entry "e2" 8 operator "user.create" Subject {kind = "user", id = Just "u1", name = "ada"} [("login", "ada")] "console"
          older = entry "e1" 7 operator "settings.wiki" Subject {kind = "settings", id = Nothing, name = "whom the wiki lets in"} [("access", "closed")] "127.0.0.1"
          firstPage = Activity {available = True, entries = [granted, made], more = True, actors = [ada, operator]}
      answerWith "GET" (links.admin.activity Nothing Nothing Nothing) 200 firstPage
      answerWith "GET" (links.admin.activity Nothing Nothing (Just "e2")) 200 firstPage {entries = [older], more = False}
      answerWith "GET" (links.admin.activity (Just ada.id) Nothing Nothing) 200 firstPage {entries = [granted], more = False}
      answerWith "GET" links.admin.status 200 quietServer {errors = [LoggedError {at = at 10, route = "/api/v1/pages/:page", message = "SQLite3 returned ErrorIO"}]}
      ui <- startServer m Admin
      rows <- eventually $ do
        rs <- findAll ui ".activity-row"
        length rs `shouldBe` 2
        pure rs
      case rows of
        newest : _ -> do
          newest `shouldContainText` "ada"
          newest `shouldContainText` "Granted a permission on a space: Docs"
          newest `shouldContainText` "permission: edit; to: group writers"
          newest `shouldContainText` "100.64.0.7"
          newest `shouldContainText` "2026-10-25 09:00 UTC"
        [] -> pass
      find ui ".activity-range" >>= (`shouldHaveText` "1–2")
      find ui ".activity-newer" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
      -- The next page.
      find ui ".activity-older" >>= click
      eventually (find ui ".activity-row" >>= (`shouldContainText` "Changed whom the wiki lets in"))
      find ui ".activity-older" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
      find ui ".activity-range" >>= (`shouldHaveText` "51–51")
      -- One person's, from the first page again.
      choose ui ".activity-filter select" 1
      eventually $ do
        urls <- map (\r -> r.url) . filter (\r -> r.method == "GET") <$> asked
        urls `shouldSatisfy` elem (links.admin.activity (Just ada.id) Nothing Nothing)
      eventually $ do
        rs <- findAll ui ".activity-row"
        length rs `shouldBe` 1
      find ui ".activity-row" >>= (`shouldContainText` "Granted a permission on a space")
      -- The server's status, with its last error.
      find ui ".server-status .status-schema" >>= (`shouldHaveText` "Version 9")
      find ui ".server-status .status-error-route" >>= (`shouldHaveText` "/api/v1/pages/:page")
      find ui ".server-status .status-error-message" >>= (`shouldHaveText` "SQLite3 returned ErrorIO")
      -- Read again by "Refresh", with nothing to say any more.
      answerWith "GET" links.admin.status 200 quietServer
      find ui ".status-refresh" >>= click
      eventually (find ui ".status-no-errors" >>= (`shouldHaveText` "None since the server started."))
      unmount ui
      serverStops
