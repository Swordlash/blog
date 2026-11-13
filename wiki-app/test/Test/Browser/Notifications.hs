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
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, hangUp, holdAt, release, serveDemo, serverStarts, serverStops, startServer, tellServer)
import Test.Browser.Mount (clickButton, slugs, start, startChanged)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Events (ServerMessage (..))
import Wiki.Api.Notifications (Notifications (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), Notification (..), PageLocation (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Space (Space (homePage, name))
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

  it "leads a notification about a comment on a blog's home page to the comment, on the blog" $ runPage $ do
    -- The blog's home page, written: the blog shows it above its posts,
    -- with its page view, comments and all (WP5.78 of docs/PLAN.md).
    let written st =
          let blogHome = (\s -> s.homePage) =<< head (filter (\s -> s.name == "Blog") (Map.elems st.spaces))
           in st {pages = Map.mapWithKey (\k p -> if Just k == blogHome then p {P.body = "# About\n\nWhat this blog is about."} else p) st.pages}
    ui <- startChanged m written (Just "user-admin") (Space (slugs ["blog"]))
    text <- find ui ".blog-home .page-comments .comment-new textarea"
    typeText text "Have a look at the about, @editor."
    clickButton ui ".blog-home .page-comments .comment-new button" "Comment"
    _ <- find ui ".blog-home .page-comments a.mention"
    switchTo ui "editor"
    find ui ".notifications-count" >>= (`shouldHaveText` "1")
    find ui ".notifications-toggle" >>= click
    linked <- find ui ".notification-list a.notification-link"
    -- The home page's address is the blog's.
    getAttribute linked "href" >>= (`shouldSatisfy` maybe False (T.isInfixOf "/s/blog/#comment-thread-"))
    click linked
    _ <- find ui ".blog-view .post-list"
    thread <- find ui ".blog-view .blog-home [id^='comment-thread-']"
    thread `shouldContainText` "Have a look at the about"
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
    -- The demo has no feed of notifications, and says why.
    eventually (find ui ".notification-feed-note" >>= (`shouldContainText` "demo"))
    length <$> findAll ui ".notification-feed-renew" `shouldReturn` 0
    own <- find ui ".notification-watch-own input"
    getProperty own "checked" `shouldReturn` "true"
    click own
    eventually (find ui ".notification-watch-own input" >>= (`getProperty` "checked") >>= (`shouldBe` "false"))
    unmount ui

live :: forall m -> (Specs m) => Spec
live m = describe "over the backend over HTTP" $ do
  -- #213, the review's P2: the server's list is the truth for every
  -- notification told before it was asked for. One whose page the reader
  -- may no longer read, which the server leaves out, goes; one told while
  -- the list was fetched, which the answer cannot hold yet, stays.
  it "keeps of what the live channel told only what came while the list was fetched" $
    runPage $ do
      serverStarts
      serveDemo
      answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 0, items = []}
      ui <- startServer m Home
      find ui ".notifications-toggle" >>= (`shouldHaveText` "🔔")
      length <$> findAll ui ".notifications-count" `shouldReturn` 0
      let told i title =
            Notification
              { id = NotificationId i
              , kind = Replied
              , page = PageId "page-hello"
              , thread = Nothing
              , actor = Author {id = UserId "user-reader", name = "Rita Reader", avatar = Nothing}
              , title
              , excerpt = "Thanks."
              , createdAt = UTCTime (fromGregorian 2026 10 26) 0
              , read = False
              , location = Just PageLocation {space = slugs ["blog"], page = slugs ["hello-world"]}
              }
          fetches = length . filter (\r -> r.method == "GET" && "api/v1/notifications" `T.isSuffixOf` r.url) <$> asked
      eventually $ do
        tellServer (Notified (told "n1" "Lost since"))
        find ui ".notifications-count" >>= (`shouldHaveText` "1")
      -- The channel opens again; the list is fetched again, without it.
      before <- fetches
      hangUp
      eventuallyWithin 5000 (fetches >>= (`shouldSatisfy` (> before)))
      eventually (length <$> findAll ui ".notifications-count" `shouldReturn` 0)
      -- Told while the list is fetched: kept.
      holdAt "GET" "api/v1/notifications"
      again <- fetches
      hangUp
      eventuallyWithin 5000 (fetches >>= (`shouldSatisfy` (> again)))
      eventually $ do
        tellServer (Notified (told "n2" "Told meanwhile"))
        find ui ".notifications-count" >>= (`shouldHaveText` "1")
      release
      unsafeIOToPageM (threadDelay 300_000)
      (traverse textContent =<< findAll ui ".notifications-count") `shouldReturn` ["1"]
      -- The server has it now: opened, the list holds it once.
      answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 1, items = [told "n2" "Told meanwhile"]}
      find ui ".notifications-toggle" >>= click
      eventually ((traverse textContent =<< findAll ui ".notification-page") `shouldReturn` ["Told meanwhile"])
      unmount ui
      serverStops

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
              , actor = Author {id = UserId "user-reader", name = "Rita Reader", avatar = Nothing}
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
