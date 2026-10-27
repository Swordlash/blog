-- | The "Backups" part of the administration's Server section, in a browser
-- (WP4.9 of docs/PLAN.md, "Wiki.App.View.Backups"): over the demo's wiki,
-- shown disabled with a note, since the demo makes none; over the backend
-- over HTTP, turned on from its form with an rclone configuration that is
-- never shown again, and "Back up now" waited for while the server says it
-- is under way, until the last backup's time, size and result show.
module Test.Browser.Backups (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (eitherDecodeStrict')
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (start)
import Test.Browser.Server (oneColumn)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AdminApi (..), WikiApi (..))
import Wiki.Api.Backups
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (SecretState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
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

demo :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m) => Spec
demo m = describe "over the demo's wiki" $
  it "shows the backups disabled, saying that the demo makes none" $
    runPage $ do
      ui <- start m (Just "user-admin") Admin
      find ui ".backups-unavailable" >>= (`shouldContainText` "The demo makes no backups")
      find ui ".backups-body" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
      find ui ".backups-state" >>= (`shouldContainText` "Off: the server makes no backups by itself.")
      find ui ".backups-last" >>= (`shouldHaveText` "None made yet.")
      unmount ui

overHttp :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
overHttp m = describe "over HTTP" $
  it "turns backups on with an rclone remote whose configuration it never shows again, and waits for one made by hand" $
    runPage $ do
      serverStarts
      serveDemo
      let config = "[b2]\ntype = b2\naccount = do-not-show-me"
          onEverySix = BackupSettings {enabled = True, schedule = EveryHours 6, keep = Retention {daily = 7, weekly = 4}, destination = Just (ToRclone "b2:wiki" Set)}
          at h = UTCTime (fromGregorian 2026 10 25) (fromIntegral (h * 3600 :: Int))
          off = Backups {available = True, settings = defaultBackupSettings, last = Nothing, running = False, next = Nothing, kept = 0}
          turnedOn = off {settings = onEverySix, next = Just (at 3)} :: Backups
          made = BackupRecord {startedAt = at 9, finishedAt = at 9, trigger = Manual, file = Just "20261025T090000.000Z.sqlite", size = Just 1253376, failure = Nothing, offSite = Just OffSite {to = "b2:wiki", problem = Nothing}}
      answerWith "GET" links.admin.backups 200 off
      answerWith "PUT" links.admin.setBackups 200 turnedOn
      ui <- startServer m Admin
      eventually (find ui ".backups-state") >>= (`shouldContainText` "Off")
      find ui ".backups-now" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
      -- Turned on, every six hours, to an rclone remote with its
      -- configuration.
      find ui ".backups-edit" >>= click
      find ui ".backups-form input[name=enabled]" >>= click
      choose ui ".backups-form select[name=schedule]" 1
      find ui ".backups-form input[name=hours]" >>= (`getProperty` "value") >>= (`shouldBe` "6")
      choose ui ".backups-form select[name=destination]" 2
      find ui ".backups-form input[name=remote]" >>= (`typeText` "b2:wiki")
      find ui ".backups-form textarea[name=config]" >>= (`typeText` config)
      -- In one column, as every form of the administration (WP5.5).
      oneColumn ".backups-form"
      find ui ".backups-form button[type=submit]" >>= click
      eventually $ do
        puts <- filter (\r -> r.method == "PUT") <$> asked
        map (\r -> (r.url, eitherDecodeStrict' (encodeUtf8 r.body))) puts
          `shouldBe` [(links.admin.setBackups, Right (BackupSettings {enabled = True, schedule = EveryHours 6, keep = Retention {daily = 7, weekly = 4}, destination = Just (ToRclone "b2:wiki" (Just config))} :: BackupSettingsChange))]
      eventually (find ui ".backups-state" >>= (`shouldContainText` "On: every 6 hours"))
      find ui ".backups-state" >>= (`shouldContainText` "copied to b2:wiki.")
      find ui ".backups-next" >>= (`shouldHaveText` "2026-10-25 03:00 UTC")
      -- Its configuration is set, and never shown: changing the settings
      -- offers to replace it or clear it.
      find ui ".backups-edit" >>= click
      length <$> findAll ui ".backups-form textarea" `shouldReturn` 0
      find ui ".backups-form .server-secret-state" >>= (`shouldHaveText` "Set")
      find ui ".admin-server" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "do-not-show-me"))
      find ui ".backups-cancel" >>= click
      -- Back up now: the server says it is under way, and the part reads
      -- them again until it is done.
      answerWith "POST" links.admin.backUpNow 200 turnedOn {running = True}
      answerWith "GET" links.admin.backups 200 turnedOn {running = True}
      eventually (find ui ".backups-now") >>= click
      eventually (find ui ".backups-running") >>= (`shouldContainText` "Making a backup")
      -- Still under way when read again (every two seconds); then done.
      eventuallyWithin 10_000 $ do
        looked <- filter (\r -> r.method == "GET" && r.url == links.admin.backups) <$> asked
        length looked `shouldSatisfy` (>= 3)
      find ui ".backups-running" >>= (`shouldContainText` "Making a backup")
      answerWith "GET" links.admin.backups 200 turnedOn {last = Just made, kept = 3}
      eventuallyWithin 10_000 (find ui ".backups-last" >>= (`shouldHaveText` "2026-10-25 09:00 UTC, by hand: made, 1.2 MB, and copied to b2:wiki."))
      length <$> findAll ui ".backups-running" `shouldReturn` 0
      find ui ".backups-kept" >>= (`shouldHaveText` "3 backups in the data directory.")
      unmount ui
      serverStops
