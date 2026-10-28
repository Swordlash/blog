-- | Mentions, watching and notifications in a browser (WP4.13 of
-- docs/PLAN.md). Over the demo: a mention in a comment is a link to whoever
-- it names; the user mentioned, switched to, finds it under the header's
-- bell, which counts it, lists it with a link to its page and marks it
-- read; a page's and a space's "Watch" button chooses; the account panel's
-- notifications, mail disabled in a demo. Over the backend over HTTP with a
-- server in fetch's place: a notification told over the live channel
-- counted at once, with no page subscribed to.
module Test.Browser.Notifications (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (serveDemo, serverStarts, serverStops, startServer, tellServer)
import Test.Browser.Mount (clickButton, slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Events (ServerMessage (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), Notification (..), PageLocation (..))
import Wiki.Core.Version (Author (..))

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  demo m
  live m

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | Be someone else, from the demo's menu, staying where one is.
switchTo :: Mounted s q o n -> Text -> PageM s ()
switchTo ui login = do
  find ui ".user-switcher-toggle" >>= click
  find ui (".user-menu button[data-login=" <> login <> "]") >>= click

hello :: Route
hello = Page (slugs ["blog"]) (slugs ["hello-world"])

demo :: forall m -> (Specs m) => Spec
demo m = describe "over the demo" $ do
  it "links a mention, and tells whom it names under the bell, which lists it and marks it read" $ runPage $ do
    ui <- start m (Just "user-admin") hello
    -- Nothing yet for anyone.
    length <$> findAll ui ".notifications-count" `shouldReturn` 0
    text <- find ui ".page-comments .comment-new textarea"
    typeText text "Have a look, @editor."
    clickButton ui ".page-comments .comment-new button" "Comment"
    mention <- find ui ".page-comments a.mention"
    mention `shouldHaveText` "@editor"
    getAttribute mention "title" `shouldReturn` Just "Edgar Editor"
    -- The editor is told: counted under the bell, listed with a link to
    -- the post's thread.
    switchTo ui "editor"
    find ui ".notifications-count" >>= (`shouldHaveText` "1")
    find ui ".notifications-toggle" >>= click
    item <- find ui ".notification-list .notification.unread"
    find ui ".notification-list .notification-what" >>= (`shouldHaveText` "Ada Admin mentioned you")
    find ui ".notification-list .notification-page" >>= (`shouldHaveText` "Hello, world")
    item `shouldContainText` "Have a look, @editor."
    linked <- find ui ".notification-list a.notification-link"
    getAttribute linked "href" >>= (`shouldSatisfy` maybe False (T.isInfixOf "/s/blog/p/hello-world/#comment-thread-"))
    clickButton ui ".notification-list .notification-read" "Mark read"
    eventually (length <$> findAll ui ".notifications-count" `shouldReturn` 0)
    length <$> findAll ui ".notification-list .notification.unread" `shouldReturn` 0
    unmount ui

  it "writes a mention of nobody, and every mention to someone not signed in, as text" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["tour"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    length <$> findAll ui "a.mention" `shouldReturn` 0
    find ui ".page-body" >>= (`shouldContainText` "@editor is told of it")
    length <$> findAll ui ".notifications" `shouldReturn` 0
    switchTo ui "reader"
    find ui ".page-body a.mention" >>= (`shouldHaveText` "@editor")
    unmount ui

  it "watches a page and a space with their buttons, a blog's too" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    button <- find ui ".page-actions .watch-toggle"
    getAttribute button "aria-pressed" `shouldReturn` Just "false"
    click button
    eventually (find ui ".page-actions .watch-toggle" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "true")
    find ui ".page-actions .watch-toggle" >>= (`shouldContainText` "Watching")
    unmount ui
    spaceUi <- start m (Just "user-reader") (SpacePages (slugs ["blog"]))
    spaceButton <- find spaceUi ".space-view .watch-toggle"
    getAttribute spaceButton "aria-pressed" `shouldReturn` Just "false"
    click spaceButton
    eventually (find spaceUi ".space-view .watch-toggle" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "true")
    unmount spaceUi
    -- A space shown as a blog has the button too, among its actions.
    blogUi <- start m (Just "user-reader") (Space (slugs ["blog"]))
    blogButton <- find blogUi ".blog-view .actions .watch-toggle"
    was <- getAttribute blogButton "aria-pressed"
    click blogButton
    eventually (find blogUi ".blog-view .watch-toggle" >>= \b -> getAttribute b "aria-pressed" >>= (`shouldNotBe` was))
    unmount blogUi

  it "shows the account panel's notifications, with mail disabled in the demo" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    find ui ".user-switcher-toggle" >>= click
    find ui ".demo-account-toggle" >>= click
    eventually (length <$> findAll ui ".notification-settings" `shouldReturn` 1)
    fieldset <- find ui ".notification-mail"
    getAttribute fieldset "disabled" `shouldReturn` Just ""
    find ui ".notification-mail-note" >>= (`shouldContainText` "sends no mail")
    own <- find ui ".notification-watch-own input"
    getProperty own "checked" `shouldReturn` "true"
    click own
    eventually (find ui ".notification-watch-own input" >>= (`getProperty` "checked") >>= (`shouldBe` "false"))
    unmount ui

live :: forall m -> (Specs m) => Spec
live m = describe "over the backend over HTTP" $
  it "counts a notification the live channel tells of, with no page shown" $
    runPage $ do
      serverStarts
      serveDemo
      ui <- startServer m Home
      find ui ".notifications-toggle" >>= (`shouldHaveText` "🔔")
      length <$> findAll ui ".notifications-count" `shouldReturn` 0
      let told =
            Notification
              { id = NotificationId "n1"
              , kind = Replied
              , page = PageId "page-hello"
              , thread = Nothing
              , actor = Author {id = UserId "user-reader", name = "Rita Reader"}
              , title = "Hello, world"
              , excerpt = "Thanks."
              , createdAt = UTCTime (fromGregorian 2026 10 26) 0
              , read = False
              , location = Just PageLocation {space = slugs ["blog"], page = slugs ["hello-world"]}
              }
      eventually $ do
        tellServer (Notified told)
        find ui ".notifications-count" >>= (`shouldHaveText` "1")
      find ui ".notifications-toggle" >>= click
      find ui ".notification-list .notification-what" >>= (`shouldHaveText` "Rita Reader replied in a thread of yours")
      unmount ui
      serverStops
