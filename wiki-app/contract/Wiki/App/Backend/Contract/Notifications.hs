-- | The contract tests of 'MonadNotifications': what every notifications
-- backend does, as tests of the rules of "Wiki.App.Backend.Notifications"
-- (themselves the rules of "Wiki.Core.Notification"), checked against the
-- demo's content ("Wiki.App.Demo"). Its @admin@ holds the global
-- administer; its @editor@ may edit the public blog; its @reader@ may only
-- read it, and of the team's spaces may read only its projects. The demo's
-- pages were created by nobody known, so the examples create the pages
-- that need a known creator.
--
-- Like the backend's contract ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), it runs against the in-memory backend, the server's
-- SQLite storage, and the HTTP backend against the server's API.
module Wiki.App.Backend.Contract.Notifications (spec) where

import Data.Map.Strict qualified as Map
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark (..))
import Wiki.App.Backend
import Wiki.App.Backend.Comments
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.App.Backend.Notifications
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), MailMode (..), Notification (..), PageLocation (..), Watch (..), WatchReason (..), WatchTarget (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (User (..))
import Wiki.Core.Version (Author (..))

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as in
-- "Wiki.App.Backend.Contract".
spec :: forall m -> (MonadWiki m, MonadComments m, MonadNotifications m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadNotifications contract" $ do
  mentioning
  telling
  watchingPages
  reading
  choosing

--------------------------------------------------------------------------------
-- Helpers

ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

shouldFailWith :: (HasCallStack, Show a) => Either WikiError a -> WikiError -> Expectation
shouldFailWith result e = case result of
  Left e' -> e' `shouldBe` e
  Right a -> expectationFailure ("expected " <> show e <> ", got Right " <> show a)

path :: Text -> [Slug]
path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)

-- | The space at a path, as the administrator finds it.
spaceAt :: (HasCallStack, MonadWiki m) => Run m -> Text -> IO Space
spaceAt run s = run admin (getSpace (path s)) >>= ok

-- | The page at a path in the space at a path, as the administrator finds it.
pageAt :: (HasCallStack, MonadWiki m) => Run m -> Text -> Text -> IO Page
pageAt run s p = do
  space <- spaceAt run s
  run admin (getPage space.id (path p)) >>= ok

-- | Save a page with a new body, as someone, over the page as it is now.
saveAs :: (HasCallStack, MonadWiki m) => Run m -> As -> Page -> Text -> IO Page
saveAs run who page body = do
  pages <- run admin (listPages page.space) >>= ok
  p <- maybe (assertFailure "no such page") pure (find (\x -> x.id == page.id) pages)
  run who (savePage p.id p.updatedAt p.title body) >>= ok

-- | Someone's notifications: their kind, by whom, and about which page.
toldOf :: (HasCallStack, MonadNotifications m) => Run m -> As -> IO [(Kind, Text, PageId)]
toldOf run who = map (\n -> (n.kind, n.actor.name, n.page)) . (\ns -> ns.items) <$> (run who notifications >>= ok)

nameOf :: (HasCallStack, MonadWiki m) => Run m -> As -> IO Text
nameOf run who = run who currentUser >>= maybe (assertFailure ("nobody is signed in as " <> show who)) (pure . (\u -> u.displayName))

-- | A page the editor creates on the blog, so that they are its creator.
editorsPage :: (HasCallStack, MonadWiki m) => Run m -> IO Page
editorsPage run = do
  blog <- spaceAt run "blog"
  run editor (createPage blog.id Nothing "Plans" "What comes next.") >>= ok

--------------------------------------------------------------------------------
-- Mentions

mentioning :: (MonadWiki m, MonadComments m, MonadNotifications m) => SpecWith (Fixture m)
mentioning = describe "mentions" $ do
  it "names the users among the logins asked for, to someone signed in, and nobody to anyone else" $ \(Fixture run) -> do
    named <- run reader (mentionable ["editor", "nobody", "admin"])
    Map.keys named `shouldBe` ["admin", "editor"]
    editorName <- nameOf run editor
    (\a -> a.name) <$> Map.lookup "editor" named `shouldBe` Just editorName
    run Anonymous (mentionable ["editor"]) `shouldReturn` mempty

  it "tells whom a save mentions, once, and where the page is" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    _ <- saveAs run editor notes "Thanks, @reader, and @nobody."
    editorName <- nameOf run editor
    toldOf run reader `shouldReturn` [(Mentioned, editorName, notes.id)]
    ns <- run reader notifications >>= ok
    map (\n -> n.location) ns.items `shouldBe` [Just PageLocation {space = path "blog", page = path "notes-on-haskell"}]
    map (\n -> n.title) ns.items `shouldBe` [notes.title]
    ns.unread `shouldBe` 1
    -- Saved again with the same mention: nothing new.
    _ <- saveAs run editor notes "Thanks, @reader, again."
    length <$> toldOf run reader `shouldReturn` 1
    toldOf run editor `shouldReturn` []

  it "tells whom a new page mentions" $ \(Fixture run) -> do
    blog <- spaceAt run "blog"
    made <- run editor (createPage blog.id Nothing "Thanks" "Thanks, @reader.") >>= ok
    editorName <- nameOf run editor
    toldOf run reader `shouldReturn` [(Mentioned, editorName, made.id)]

  it "tells whom a comment mentions, and whom an edit of it newly mentions" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    t <- run reader (openThread notes.id Nothing "What do you think, @editor?") >>= ok
    readerName <- nameOf run reader
    toldOf run editor `shouldReturn` [(Mentioned, readerName, notes.id)]
    ns <- run editor notifications >>= ok
    map (\n -> (n.thread, n.excerpt)) ns.items `shouldBe` [(Just t.id, "What do you think, @editor?")]
    first' <- maybe (assertFailure "no comment") pure (head t.comments)
    _ <- run reader (editComment notes.id t.id first'.id "What do you think, @editor and @admin?") >>= ok
    length <$> toldOf run editor `shouldReturn` 1
    toldOf run admin `shouldReturn` [(Mentioned, readerName, notes.id)]

  it "tells nobody mentioned on a page they may not read" $ \(Fixture run) -> do
    handbook <- pageAt run "team" "team-handbook"
    _ <- saveAs run admin handbook "Ask @reader and @editor."
    toldOf run reader `shouldReturn` []

--------------------------------------------------------------------------------
-- Comments and saves

telling :: (MonadWiki m, MonadComments m, MonadNotifications m) => SpecWith (Fixture m)
telling = describe "who is told" $ do
  it "tells whoever made a page of a comment on it, and of a save of it by someone else" $ \(Fixture run) -> do
    plans <- editorsPage run
    readerName <- nameOf run reader
    adminName <- nameOf run admin
    _ <- run reader (openThread plans.id Nothing "Looks good.") >>= ok
    toldOf run editor `shouldReturn` [(Commented, readerName, plans.id)]
    _ <- saveAs run admin plans "What comes after."
    toldOf run editor `shouldReturn` [(Changed, adminName, plans.id), (Commented, readerName, plans.id)]
    -- Their own save notifies them of nothing.
    _ <- saveAs run editor plans "What comes after that."
    length <$> toldOf run editor `shouldReturn` 2

  it "tells those in a thread of a reply in it" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    t <- run reader (openThread notes.id Nothing "A question.") >>= ok
    _ <- run editor (reply notes.id t.id "An answer.") >>= ok
    editorName <- nameOf run editor
    toldOf run reader `shouldReturn` [(Replied, editorName, notes.id)]
    _ <- run reader (reply notes.id t.id "Thanks.") >>= ok
    readerName <- nameOf run reader
    toldOf run editor `shouldReturn` [(Replied, readerName, notes.id)]

--------------------------------------------------------------------------------
-- Watching

watchingPages :: (MonadWiki m, MonadNotifications m) => SpecWith (Fixture m)
watchingPages = describe "watching" $ do
  it "watches one's own pages, and nothing else, until one chooses" $ \(Fixture run) -> do
    plans <- editorsPage run
    notes <- pageAt run "blog" "notes-on-haskell"
    blog <- spaceAt run "blog"
    run editor (watching (WatchPage plans.id)) `shouldReturn` Right (Watch True OwnPage)
    run editor (watching (WatchPage notes.id)) `shouldReturn` Right (Watch False Unchosen)
    run editor (watching (WatchSpace blog.id)) `shouldReturn` Right (Watch False Unchosen)

  it "tells whoever watches a space of a save of a page in it, until they turn that page off" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    blog <- spaceAt run "blog"
    run reader (setWatching (WatchSpace blog.id) True) `shouldReturn` Right (Watch True Chosen)
    run reader (watching (WatchPage notes.id)) `shouldReturn` Right (Watch True (FromSpace blog.id))
    _ <- saveAs run editor notes "Changed."
    editorName <- nameOf run editor
    toldOf run reader `shouldReturn` [(Changed, editorName, notes.id)]
    run reader (setWatching (WatchPage notes.id) False) `shouldReturn` Right (Watch False Chosen)
    _ <- saveAs run editor notes "Changed again."
    length <$> toldOf run reader `shouldReturn` 1

  it "refuses a page or a space one may not view, one that is not there, and someone not signed in" $ \(Fixture run) -> do
    handbook <- pageAt run "team" "team-handbook"
    notes <- pageAt run "blog" "notes-on-haskell"
    run reader (watching (WatchPage handbook.id)) >>= (`shouldFailWith` Forbidden)
    run reader (setWatching (WatchPage handbook.id) True) >>= (`shouldFailWith` Forbidden)
    run reader (watching (WatchPage (PageId "no-such-page"))) >>= (`shouldFailWith` NotFound)
    run reader (watching (WatchSpace (SpaceId "no-such-space"))) >>= (`shouldFailWith` NotFound)
    run Anonymous (watching (WatchPage notes.id)) >>= (`shouldFailWith` Forbidden)

--------------------------------------------------------------------------------
-- Reading and marking

reading :: (MonadWiki m, MonadComments m, MonadNotifications m) => SpecWith (Fixture m)
reading = describe "notifications" $ do
  it "are refused to someone not signed in, and none at first" $ \(Fixture run) -> do
    run Anonymous notifications >>= (`shouldFailWith` Forbidden)
    run reader notifications `shouldReturn` Right Notifications {unread = 0, items = []}

  it "are listed the newest first, and marked read one by one or all at once" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    _ <- saveAs run editor notes "For @reader."
    _ <- run editor (openThread notes.id Nothing "Again, @reader.") >>= ok
    ns <- run reader notifications >>= ok
    map (\n -> n.excerpt) ns.items `shouldBe` ["Again, @reader.", ""]
    ns.unread `shouldBe` 2
    newest <- maybe (assertFailure "none") pure (head ns.items)
    marked <- run reader (markRead ReadMark {ids = [newest.id], everything = False}) >>= ok
    marked.unread `shouldBe` 1
    map (\n -> n.read) marked.items `shouldBe` [True, False]
    run reader notifications `shouldReturn` Right marked
    everything <- run reader (markRead ReadMark {ids = [], everything = True}) >>= ok
    everything.unread `shouldBe` 0
    run Anonymous (markRead ReadMark {ids = [], everything = True}) >>= (`shouldFailWith` Forbidden)

  it "leaves out a page the user may no longer read" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    _ <- saveAs run editor notes "For @reader."
    blog <- spaceAt run "blog"
    _ <- run admin (setSpacePublic blog.id False) >>= ok
    run reader notifications >>= \case
      Right ns -> ns.items `shouldBe` []
      Left e -> expectationFailure (show e)

--------------------------------------------------------------------------------
-- Choices

choosing :: (MonadWiki m, MonadComments m, MonadNotifications m) => SpecWith (Fixture m)
choosing = describe "settings" $ do
  it "watch one's own by default, and stop when turned off" $ \(Fixture run) -> do
    s <- run editor notificationSettings >>= ok
    s.watchOwn `shouldBe` True
    plans <- editorsPage run
    s' <- run editor (setNotificationSettings NotificationSettingsChange {mail = MailOff, watchOwn = False}) >>= ok
    (s'.watchOwn, s'.mail) `shouldBe` (False, MailOff)
    run editor (watching (WatchPage plans.id)) `shouldReturn` Right (Watch False Unchosen)
    _ <- run reader (openThread plans.id Nothing "Looks good.") >>= ok
    toldOf run editor `shouldReturn` []
    run Anonymous notificationSettings >>= (`shouldFailWith` Forbidden)

  it "mail nobody without a verified address" $ \(Fixture run) -> do
    s <- run reader notificationSettings >>= ok
    (s.verifiedEmail, s.mail) `shouldBe` (False, MailOff)
