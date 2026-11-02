-- | The contract tests of 'MonadStars': what every backend does with a
-- user's starred pages, as tests of the rules of "Wiki.App.Backend.Stars",
-- checked against the demo's content ("Wiki.App.Demo"). Its @admin@ holds
-- the global administer; its @editor@ may edit the public blog; its
-- @reader@ may only read the blog (because it is public) and, of the
-- team's spaces, only its projects.
--
-- Like the backend's contract ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), it runs against the in-memory backend, the server's
-- storage, and the HTTP backend against the server's API.
module Wiki.App.Backend.Contract.Stars (spec) where

import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.Api.Stars (StarredPage (..), maxStars)
import Wiki.App.Backend
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.App.Backend.Stars
import Wiki.Core.Id
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as in
-- "Wiki.App.Backend.Contract".
spec :: forall m -> (MonadWiki m, MonadStars m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadStars contract" $ do
  listing
  refusing
  following
  limiting

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

-- | Someone's starred pages, as their ids.
starredBy :: (HasCallStack, MonadStars m) => Run m -> As -> IO [PageId]
starredBy run who = map (\s -> s.page) <$> (run who starred >>= ok)

--------------------------------------------------------------------------------
-- Listing

listing :: (MonadWiki m, MonadStars m) => SpecWith (Fixture m)
listing = describe "the list" $ do
  it "is refused to someone not signed in, and empty at first" $ \(Fixture run) -> do
    run Anonymous starred >>= (`shouldFailWith` Forbidden)
    run reader starred `shouldReturn` Right []

  it "holds the pages starred, in the order they were starred, each with its title and where it is" $ \(Fixture run) -> do
    blog <- spaceAt run "blog"
    notes <- pageAt run "blog" "notes-on-haskell"
    hello <- pageAt run "blog" "hello-world"
    _ <- run reader (setStarred notes.id True) >>= ok
    listed <- run reader (setStarred hello.id True) >>= ok
    listed
      `shouldBe` [ StarredPage {page = notes.id, space = blog.id, title = "Notes on Haskell", location = PageLocation {space = path "blog", page = path "notes-on-haskell"}}
                 , StarredPage {page = hello.id, space = blog.id, title = "Hello, world", location = PageLocation {space = path "blog", page = path "hello-world"}}
                 ]
    run reader starred `shouldReturn` Right listed
    -- Starring a page again keeps its place.
    run reader (setStarred notes.id True) `shouldReturn` Right listed

  it "takes a star away, and taking it away again changes nothing" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    hello <- pageAt run "blog" "hello-world"
    _ <- run reader (setStarred notes.id True) >>= ok
    _ <- run reader (setStarred hello.id True) >>= ok
    map (\s -> s.page) <$> (run reader (setStarred notes.id False) >>= ok) `shouldReturn` [hello.id]
    map (\s -> s.page) <$> (run reader (setStarred notes.id False) >>= ok) `shouldReturn` [hello.id]
    starredBy run reader `shouldReturn` [hello.id]

  it "keeps each user's stars to that user" $ \(Fixture run) -> do
    notes <- pageAt run "blog" "notes-on-haskell"
    handbook <- pageAt run "team" "team-handbook"
    _ <- run reader (setStarred notes.id True) >>= ok
    _ <- run admin (setStarred handbook.id True) >>= ok
    starredBy run reader `shouldReturn` [notes.id]
    starredBy run admin `shouldReturn` [handbook.id]
    starredBy run editor `shouldReturn` []

--------------------------------------------------------------------------------
-- Refusing

refusing :: (MonadWiki m, MonadStars m) => SpecWith (Fixture m)
refusing = describe "starring" $ do
  it "refuses a page one may not view as one that is not there, and someone not signed in" $ \(Fixture run) -> do
    handbook <- pageAt run "team" "team-handbook"
    notes <- pageAt run "blog" "notes-on-haskell"
    run reader (setStarred handbook.id True) >>= (`shouldFailWith` NotFound)
    run reader (setStarred (PageId "no-such-page") True) >>= (`shouldFailWith` NotFound)
    run Anonymous (setStarred handbook.id True) >>= (`shouldFailWith` NotFound)
    run Anonymous (setStarred notes.id True) >>= (`shouldFailWith` Forbidden)
    starredBy run reader `shouldReturn` []

--------------------------------------------------------------------------------
-- Following the pages

following :: (MonadWiki m, MonadStars m) => SpecWith (Fixture m)
following = describe "a starred page" $ do
  it "is listed where it is now after it moves, and no longer once it is deleted" $ \(Fixture run) -> do
    blog <- spaceAt run "blog"
    docs <- spaceAt run "docs"
    notes <- pageAt run "blog" "notes-on-haskell"
    plans <- run editor (createPage blog.id Nothing "Plans" "What comes next.") >>= ok
    _ <- run reader (setStarred plans.id True) >>= ok
    _ <- run reader (setStarred notes.id True) >>= ok
    _ <- run admin (movePage plans.id docs.id Nothing) >>= ok
    run reader starred
      >>= ok
      >>= (`shouldBe` [(plans.id, docs.id, path "docs", path "plans"), (notes.id, blog.id, path "blog", path "notes-on-haskell")])
        . map (\s -> (s.page, s.space, s.location.space, s.location.page))
    _ <- run admin (movePage plans.id blog.id (Just notes.id)) >>= ok
    map (\s -> s.location.page) <$> (run reader starred >>= ok) `shouldReturn` [path "notes-on-haskell/plans", path "notes-on-haskell"]
    _ <- run admin (deletePage plans.id) >>= ok
    starredBy run reader `shouldReturn` [notes.id]

  it "is left out while one may not view it, and listed again once one may" $ \(Fixture run) -> do
    blog <- spaceAt run "blog"
    notes <- pageAt run "blog" "notes-on-haskell"
    _ <- run reader (setStarred notes.id True) >>= ok
    _ <- run admin (setSpacePublic blog.id False) >>= ok
    starredBy run reader `shouldReturn` []
    _ <- run admin (setSpacePublic blog.id True) >>= ok
    starredBy run reader `shouldReturn` [notes.id]

--------------------------------------------------------------------------------
-- The most stars

limiting :: (MonadWiki m, MonadStars m) => SpecWith (Fixture m)
limiting = describe "the most stars" $ do
  it "refuses a star more than the most, until one is taken away" $ \(Fixture run) -> do
    blog <- spaceAt run "blog"
    made <- for [1 .. maxStars + 1] $ \i ->
      run editor (createPage blog.id Nothing ("Page " <> show i) "A page to star.") >>= ok
    let (allowed, extra) = splitAt maxStars made
    for_ allowed $ \p -> run reader (setStarred p.id True) >>= ok
    for_ extra $ \p ->
      run reader (setStarred p.id True) >>= \case
        Left (Invalid _) -> pass
        other -> expectationFailure ("expected the star to be refused, got " <> show (map (\s -> s.page) <$> other))
    -- Starring a page starred already is no star more.
    for_ (take 1 allowed) $ \p -> void (run reader (setStarred p.id True) >>= ok)
    for_ (take 1 allowed) $ \p -> void (run reader (setStarred p.id False) >>= ok)
    for_ extra $ \p -> void (run reader (setStarred p.id True) >>= ok)
    length <$> starredBy run reader `shouldReturn` maxStars
