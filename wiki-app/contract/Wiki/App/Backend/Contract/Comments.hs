-- | The contract tests of 'MonadComments': what every comments backend
-- does, as tests of the rules of "Wiki.App.Backend.Comments", checked
-- against the demo's content ("Wiki.App.Demo"), on the public blog's
-- "Notes on Haskell" (which has no comments) and the private team's
-- handbook. The demo's @admin@ holds the global administer, and so
-- administers every space; its @editor@ may edit the blog; its @reader@
-- may only read it, and of the team's spaces may read only its projects.
--
-- Like the backend's contract ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), it runs against the in-memory backend, the server's
-- SQLite storage, and the HTTP backend against the server's API.
module Wiki.App.Backend.Contract.Comments (spec) where

import Data.Text qualified as T
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.App.Backend
import Wiki.App.Backend.Comments
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (User (..))
import Wiki.Core.Version (Author (..))

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as in
-- "Wiki.App.Backend.Contract".
spec :: forall m -> (MonadWiki m, MonadComments m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadComments contract" $ do
  reading
  opening
  replying
  editing
  deleting
  resolving
  refusing

--------------------------------------------------------------------------------
-- Helpers

ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

shouldFailWith :: (HasCallStack, Show a) => Either WikiError a -> WikiError -> Expectation
shouldFailWith result e = case result of
  Left e' -> e' `shouldBe` e
  Right a -> expectationFailure ("expected " <> show e <> ", got Right " <> show a)

shouldBeInvalid :: (HasCallStack, Show a) => Either WikiError a -> Expectation
shouldBeInvalid = \case
  Left (Invalid _) -> pass
  other -> expectationFailure ("expected Invalid, got " <> show other)

-- | The page at a path in the space at a path, as the administrator finds it.
pageAt :: (HasCallStack, MonadWiki m) => Run m -> Text -> Text -> IO Page
pageAt run s p = do
  space <- run admin (getSpace (path s)) >>= ok
  run admin (getPage space.id (path p)) >>= ok
  where
    path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)

-- | The blog's page with no comments, which everyone may read.
notes :: (HasCallStack, MonadWiki m) => Run m -> IO PageId
notes run = (\p -> p.id) <$> pageAt run "blog" "notes-on-haskell"

-- | The team's handbook, which only the administrator may read.
handbook :: (HasCallStack, MonadWiki m) => Run m -> IO PageId
handbook run = (\p -> p.id) <$> pageAt run "team" "team-handbook"

quote :: Anchor
quote = Anchor {exact = "Haskell", prefix = "Notes on ", suffix = ""}

-- | The display name of the demo's user with this login.
nameOf :: (HasCallStack, MonadWiki m) => Run m -> As -> IO Text
nameOf run who = run who currentUser >>= maybe (assertFailure ("nobody is signed in as " <> show who)) (pure . (\u -> u.displayName))

-- | The bodies of each thread's comments.
bodies :: [Thread] -> [[Text]]
bodies = map (map (\c -> c.body) . (\t -> t.comments))

-- | A thread the reader opened on the notes, with a reply by the editor.
discussed :: (HasCallStack, MonadComments m) => Run m -> PageId -> IO (Thread, Comment)
discussed run p = do
  t <- run reader (openThread p (Just quote) "Which Haskell?") >>= ok
  r <- run editor (reply p t.id "GHC's.") >>= ok
  pure (t, r)

--------------------------------------------------------------------------------
-- Reading

reading :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
reading = describe "listThreads" $ do
  it "gives a page no one has commented on no threads, to anyone who may read it" $ \(Fixture run) -> do
    p <- notes run
    run Anonymous (listThreads p) `shouldReturn` Right []
    run reader (listThreads p) `shouldReturn` Right []

  it "refuses a page one may not read, and one that is not there" $ \(Fixture run) -> do
    p <- handbook run
    run reader (listThreads p) >>= (`shouldFailWith` Forbidden)
    run Anonymous (listThreads p) >>= (`shouldFailWith` Forbidden)
    run admin (listThreads p) `shouldReturn` Right []
    run reader (listThreads (PageId "no-such-page")) >>= (`shouldFailWith` NotFound)

  it "lists threads in the order they were opened, each with its comments in order, to anyone who may read the page" $ \(Fixture run) -> do
    p <- notes run
    (t, _) <- discussed run p
    later <- run editor (openThread p Nothing "A fine page.") >>= ok
    threads <- run Anonymous (listThreads p) >>= ok
    map (\x -> x.id) threads `shouldBe` [t.id, later.id]
    bodies threads `shouldBe` [["Which Haskell?", "GHC's."], ["A fine page."]]
    map (\x -> x.anchor) threads `shouldBe` [Just quote, Nothing]

--------------------------------------------------------------------------------
-- Opening

opening :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
opening = describe "openThread" $ do
  it "opens an inline thread, with its quote and first comment, named after its author" $ \(Fixture run) -> do
    p <- notes run
    rita <- nameOf run reader
    t <- run reader (openThread p (Just quote) "Which Haskell?") >>= ok
    t.page `shouldBe` p
    t.anchor `shouldBe` Just quote
    t.resolved `shouldBe` False
    map (\c -> (c.author.name, c.body, c.editedAt, c.thread)) t.comments `shouldBe` [(rita, "Which Haskell?", Nothing, t.id)]
    run Anonymous (listThreads p) `shouldReturn` Right [t]

  it "opens a thread about the whole page" $ \(Fixture run) -> do
    p <- notes run
    t <- run editor (openThread p Nothing "A fine page.") >>= ok
    t.anchor `shouldBe` Nothing

  it "cuts a quote's context to its length" $ \(Fixture run) -> do
    p <- notes run
    t <- run reader (openThread p (Just quote {prefix = T.replicate 40 "a"}) "Long.") >>= ok
    (\a -> T.length a.prefix) <$> t.anchor `shouldBe` Just 32

  it "lets someone who may only read a page comment on it, and nobody who is not signed in" $ \(Fixture run) -> do
    p <- notes run
    run Anonymous (openThread p Nothing "Hello.") >>= (`shouldFailWith` Forbidden)
    void (run reader (openThread p Nothing "Hello.") >>= ok)

--------------------------------------------------------------------------------
-- Replying

replying :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
replying = describe "reply" $ do
  it "adds a comment at the end of a thread" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    edgar <- nameOf run editor
    (r.thread, r.author.name, r.body) `shouldBe` (t.id, edgar, "GHC's.")
    third <- run reader (reply p t.id "Thanks.") >>= ok
    threads <- run reader (listThreads p) >>= ok
    map (\c -> c.id) . (\x -> x.comments) <$> head threads `shouldBe` Just [maybe (CommentId "") (\c -> c.id) (head t.comments), r.id, third.id]

  it "refuses a thread that is not on the page, and someone not signed in" $ \(Fixture run) -> do
    p <- notes run
    (t, _) <- discussed run p
    other <- (\x -> x.id) <$> pageAt run "blog" "hello-world"
    run reader (reply other t.id "Here?") >>= (`shouldFailWith` NotFound)
    run reader (reply p (CommentThreadId "no-such-thread") "Here?") >>= (`shouldFailWith` NotFound)
    run Anonymous (reply p t.id "Me too.") >>= (`shouldFailWith` Forbidden)

--------------------------------------------------------------------------------
-- Editing

editing :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
editing = describe "editComment" $ do
  it "lets the author edit their comment, which says it was edited" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    edited <- run editor (editComment p t.id r.id "GHC's, 9.14.") >>= ok
    (edited.id, edited.body, edited.createdAt, isJust edited.editedAt) `shouldBe` (r.id, "GHC's, 9.14.", r.createdAt, True)
    threads <- run reader (listThreads p) >>= ok
    bodies threads `shouldBe` [["Which Haskell?", "GHC's, 9.14."]]

  it "lets nobody else edit it, the space's administrator included" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    run reader (editComment p t.id r.id "Mine now.") >>= (`shouldFailWith` Forbidden)
    run admin (editComment p t.id r.id "Mine now.") >>= (`shouldFailWith` Forbidden)
    run Anonymous (editComment p t.id r.id "Mine now.") >>= (`shouldFailWith` Forbidden)
    run editor (editComment p t.id (CommentId "no-such-comment") "?") >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Deleting

deleting :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
deleting = describe "deleteComment and deleteThread" $ do
  it "lets the author delete their reply" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    run editor (deleteComment p t.id r.id) >>= ok
    bodies <$> (run reader (listThreads p) >>= ok) `shouldReturn` [["Which Haskell?"]]

  it "lets the space's administrator delete anyone's comment, and nobody else" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    run reader (deleteComment p t.id r.id) >>= (`shouldFailWith` Forbidden)
    run Anonymous (deleteComment p t.id r.id) >>= (`shouldFailWith` Forbidden)
    run admin (deleteComment p t.id r.id) >>= ok
    bodies <$> (run reader (listThreads p) >>= ok) `shouldReturn` [["Which Haskell?"]]

  it "takes a thread with its first comment, but not while it has replies" $ \(Fixture run) -> do
    p <- notes run
    (t, r) <- discussed run p
    let opening' = maybe (CommentId "") (\c -> c.id) (head t.comments)
    run reader (deleteComment p t.id opening') >>= shouldBeInvalid
    run editor (deleteComment p t.id r.id) >>= ok
    run reader (deleteComment p t.id opening') >>= ok
    run reader (listThreads p) `shouldReturn` Right []

  it "lets the space's administrator delete a whole thread, and its opener only while it is all theirs" $ \(Fixture run) -> do
    p <- notes run
    (t, _) <- discussed run p
    run reader (deleteThread p t.id) >>= (`shouldFailWith` Forbidden)
    run editor (deleteThread p t.id) >>= (`shouldFailWith` Forbidden)
    run admin (deleteThread p t.id) >>= ok
    run reader (listThreads p) `shouldReturn` Right []
    alone <- run reader (openThread p Nothing "Mine alone.") >>= ok
    run reader (deleteThread p alone.id) >>= ok
    run reader (deleteThread p alone.id) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Resolving

resolving :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
resolving = describe "setResolved" $ do
  it "lets anyone who may comment resolve an inline thread, and reopen it" $ \(Fixture run) -> do
    p <- notes run
    (t, _) <- discussed run p
    resolved <- run editor (setResolved p t.id True) >>= ok
    (resolved.id, resolved.resolved, length resolved.comments) `shouldBe` (t.id, True, 2)
    map (\x -> x.resolved) <$> (run Anonymous (listThreads p) >>= ok) `shouldReturn` [True]
    void (run editor (setResolved p t.id True) >>= ok)
    reopened <- run reader (setResolved p t.id False) >>= ok
    reopened.resolved `shouldBe` False
    run Anonymous (setResolved p t.id True) >>= (`shouldFailWith` Forbidden)

  it "does not resolve a thread about the whole page" $ \(Fixture run) -> do
    p <- notes run
    t <- run reader (openThread p Nothing "A fine page.") >>= ok
    run reader (setResolved p t.id True) >>= shouldBeInvalid

--------------------------------------------------------------------------------
-- Refusals

refusing :: (MonadWiki m, MonadComments m) => SpecWith (Fixture m)
refusing = describe "refusals" $ do
  it "refuses a blank comment, a blank quote and one too long" $ \(Fixture run) -> do
    p <- notes run
    run reader (openThread p Nothing "  \n ") >>= shouldBeInvalid
    run reader (openThread p (Just quote {exact = "   "}) "Hm.") >>= shouldBeInvalid
    run reader (openThread p (Just quote {exact = T.replicate 2001 "x"}) "Hm.") >>= shouldBeInvalid
    (t, r) <- discussed run p
    run reader (reply p t.id "") >>= shouldBeInvalid
    run editor (editComment p t.id r.id " ") >>= shouldBeInvalid

  it "says whoever may not read the page is forbidden before anything else" $ \(Fixture run) -> do
    p <- handbook run
    t <- run admin (openThread p Nothing "Internal.") >>= ok
    let c = maybe (CommentId "") (\x -> x.id) (head t.comments)
    run reader (openThread p Nothing "") >>= (`shouldFailWith` Forbidden)
    run reader (reply p (CommentThreadId "no-such-thread") "") >>= (`shouldFailWith` Forbidden)
    run reader (reply p t.id "Hi.") >>= (`shouldFailWith` Forbidden)
    run reader (editComment p t.id c "Hi.") >>= (`shouldFailWith` Forbidden)
    run reader (deleteComment p t.id c) >>= (`shouldFailWith` Forbidden)
    run reader (deleteThread p t.id) >>= (`shouldFailWith` Forbidden)
    run reader (setResolved p t.id True) >>= (`shouldFailWith` Forbidden)
    run reader (openThread (PageId "no-such-page") Nothing "Hi.") >>= (`shouldFailWith` NotFound)
    run Anonymous (openThread p Nothing "") >>= (`shouldFailWith` Forbidden)

  it "names a comment's author by their id as well" $ \(Fixture run) -> do
    p <- notes run
    t <- run editor (openThread p Nothing "By Edgar.") >>= ok
    u <- run editor currentUser
    (\c -> c.author.id) <$> head t.comments `shouldBe` (\x -> x.id) <$> u
