-- | What every 'MonadWiki' backend does, as tests: the laws the class's
-- Haddock states, checked against the demo's content
-- ("Wiki.App.Demo") as each of its users sees it.
--
-- The spec is written once and run against each backend: the in-memory one
-- here (@Test.Backend.Mem@), and the HTTP one in Phase 2, given a 'Fixture'
-- that starts it with the demo's content and signs in as each user.
module Test.Backend.Contract
  ( spec
  , Fixture (..)
  , As (..)
  , Run
  )
where

import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.App.Backend
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath, renderPath)
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), searchQuery, snippetText)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (User (..))

-- | Who a request is made as: nobody, or the demo's user with this login
-- (@admin@, @editor@, @reader@).
data As = Anonymous | As Text
  deriving stock (Eq, Show)

-- | Run a program against the backend, as someone.
type Run m = forall a. As -> m a -> IO a

-- | A backend with the demo's content in it, the same for every example
-- that runs against it: each example is given a fresh one.
newtype Fixture m = Fixture (Run m)

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example.
spec :: forall m -> (MonadWiki m) => IO (Fixture m) -> Spec
spec _ newFixture = before newFixture $ describe "MonadWiki contract" $ do
  sessions
  readingSpaces
  readingPages
  creatingSpaces
  changingSpaces
  mathMacros
  movingSpaces
  deletingSpaces
  ordering
  creatingPages
  savingPages
  movingPages
  deletingPages
  attachments
  searching
  neverThrown

--------------------------------------------------------------------------------
-- Helpers

-- | The value of a 'Right', or a failed test that says what the 'Left' was.
ok :: (HasCallStack) => Either WikiError a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

-- | A path written as text.
path :: (HasCallStack) => Text -> [Slug]
path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)

-- | The space at a path, which must be there.
spaceAt :: (HasCallStack, MonadWiki m) => Run m -> As -> Text -> IO Space
spaceAt run who p = run who (getSpace (path p)) >>= ok

-- | The page at a path in the space at a path, which must be there.
pageAt :: (HasCallStack, MonadWiki m) => Run m -> As -> Text -> Text -> IO Page
pageAt run who s p = do
  space <- spaceAt run admin s
  run who (getPage space.id (path p)) >>= ok

-- | What a request for a page gives.
getPageAt :: (MonadWiki m) => Run m -> As -> Text -> Text -> IO (Either WikiError Page)
getPageAt run who s p = do
  space <- spaceAt run admin s
  run who (getPage space.id (path p))

-- | The names of the spaces someone sees.
spaceNames :: (MonadWiki m) => Run m -> As -> IO [Text]
spaceNames run who = map (\s -> s.name) <$> run who listSpaces

-- | The titles of a space's pages.
pageTitles :: (HasCallStack, MonadWiki m) => Run m -> As -> Text -> IO [Text]
pageTitles run who s = do
  space <- spaceAt run admin s
  map (\p -> p.title) <$> (run who (listPages space.id) >>= ok)

-- | Whether a 'Left' is the error expected.
shouldFailWith :: (HasCallStack, Show a) => Either WikiError a -> WikiError -> Expectation
shouldFailWith result e = case result of
  Left e' -> e' `shouldBe` e
  Right a -> expectationFailure ("expected " <> show e <> ", got Right " <> show a)

-- | Whether a 'Left' is an 'Invalid'.
shouldBeInvalid :: (HasCallStack, Show a) => Either WikiError a -> Expectation
shouldBeInvalid = \case
  Left (Invalid _) -> pass
  other -> expectationFailure ("expected Invalid, got " <> show other)

slugOf :: Space -> Text
slugOf s = slugText s.slug

--------------------------------------------------------------------------------
-- Sessions

sessions :: (MonadWiki m) => SpecWith (Fixture m)
sessions = describe "session" $ do
  it "is nobody's when nobody is signed in" $ \(Fixture run) -> do
    s <- run Anonymous session
    s `shouldBe` anonymous
    run Anonymous currentUser `shouldReturn` Nothing

  it "names the user who is signed in" $ \(Fixture run) -> do
    for_ ["admin", "editor", "reader"] $ \login -> do
      u <- run (As login) currentUser
      (\x -> x.login) <$> u `shouldBe` Just login

  it "has the user's global grants" $ \(Fixture run) -> do
    a <- run admin session
    map (\g -> g.permission) a.grants.global `shouldBe` [Administer]
    e <- run editor session
    map (\g -> g.permission) e.grants.global `shouldBe` [CreateSpaces]
    r <- run reader session
    r.grants.global `shouldBe` []

  it "has the grants given to the user's groups" $ \(Fixture run) -> do
    e <- run editor session
    Set.size e.groups `shouldBe` 1
    blog <- spaceAt run editor "blog"
    [(g.space, g.permission) | g <- e.grants.spaces] `shouldBe` [(blog.id, Edit)]

  it "leaves out the grants given to others" $ \(Fixture run) -> do
    r <- run reader session
    projects <- spaceAt run admin "team/projects"
    [(g.space, g.permission) | g <- r.grants.spaces] `shouldBe` [(projects.id, View)]

--------------------------------------------------------------------------------
-- Reading spaces

readingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
readingSpaces = describe "listSpaces and getSpace" $ do
  it "list the public spaces to nobody" $ \(Fixture run) ->
    spaceNames run Anonymous `shouldReturn` ["Blog", "Docs"]

  it "list every space to the administrator, by name, each followed by its subspaces" $ \(Fixture run) ->
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Projects"]

  it "list the ancestors of a space someone may view, though not the ancestors' pages" $ \(Fixture run) -> do
    spaceNames run reader `shouldReturn` ["Blog", "Docs", "Team", "Projects"]
    team <- spaceAt run admin "team"
    run reader (getSpace (path "team")) `shouldReturn` Left Forbidden
    run reader (listPages team.id) `shouldReturn` Left Forbidden

  it "list a whole tree: every parent of a listed space is listed" $ \(Fixture run) ->
    for_ [Anonymous, admin, editor, reader] $ \who -> do
      spaces <- run who listSpaces
      let ids = Set.fromList (map (\s -> s.id) spaces)
      for_ spaces $ \s -> for_ s.parent $ \p -> p `Set.member` ids `shouldBe` True

  it "resolve paths of slugs" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    projects <- spaceAt run admin "team/projects"
    (projects.name, slugOf projects, projects.parent) `shouldBe` ("Projects", "projects", Just team.id)
    docs <- spaceAt run Anonymous "docs"
    docs.public `shouldBe` True

  it "give NotFound for a path that leads nowhere" $ \(Fixture run) -> do
    run admin (getSpace (path "nowhere")) `shouldReturn` Left NotFound
    run admin (getSpace (path "blog/nowhere")) `shouldReturn` Left NotFound
    run admin (getSpace (path "projects")) `shouldReturn` Left NotFound
    run admin (getSpace []) `shouldReturn` Left NotFound

  it "give Forbidden for a space someone may not view" $ \(Fixture run) -> do
    run Anonymous (getSpace (path "team")) `shouldReturn` Left Forbidden
    run Anonymous (getSpace (path "team/projects")) `shouldReturn` Left Forbidden
    run editor (getSpace (path "team/projects")) `shouldReturn` Left Forbidden
    void (spaceAt run reader "team/projects")

  it "make the subspaces of a public space public" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    sub <- run admin (createSpace (Just docs.id) "Internals") >>= ok
    sub.public `shouldBe` False
    found <- spaceAt run Anonymous "docs/internals"
    found.id `shouldBe` sub.id

--------------------------------------------------------------------------------
-- Reading pages

readingPages :: (MonadWiki m) => SpecWith (Fixture m)
readingPages = describe "listPages and getPage" $ do
  it "list a space's pages, by title, each followed by the pages under it" $ \(Fixture run) -> do
    pageTitles run Anonymous "docs" `shouldReturn` ["Markdown guide", "Diagrams", "Mathematics", "Tour"]
    docs <- spaceAt run admin "docs"
    pages <- run Anonymous (listPages docs.id) >>= ok
    map (\p -> p.space) pages `shouldSatisfy` all (== docs.id)

  it "resolve paths of slugs within a space" $ \(Fixture run) -> do
    guide <- pageAt run Anonymous "docs" "markdown-guide"
    diagrams <- pageAt run Anonymous "docs" "markdown-guide/diagrams"
    (diagrams.title, diagrams.parent) `shouldBe` ("Diagrams", Just guide.id)

  it "give NotFound for a path that leads nowhere, and for no path" $ \(Fixture run) -> do
    getPageAt run admin "docs" "nowhere" `shouldReturn` Left NotFound
    getPageAt run admin "docs" "diagrams" `shouldReturn` Left NotFound
    getPageAt run admin "docs" "" `shouldReturn` Left NotFound
    getPageAt run admin "blog" "tour" `shouldReturn` Left NotFound

  it "give NotFound for a space that is not there" $ \(Fixture run) -> do
    run admin (listPages (SpaceId "no-such-space")) `shouldReturn` Left NotFound
    run admin (getPage (SpaceId "no-such-space") (path "tour")) `shouldReturn` Left NotFound

  it "give Forbidden for the pages of a space someone may not view" $ \(Fixture run) -> do
    getPageAt run Anonymous "team" "team-handbook" `shouldReturn` Left Forbidden
    getPageAt run editor "team" "team-handbook" `shouldReturn` Left Forbidden
    getPageAt run reader "team" "team-handbook" `shouldReturn` Left Forbidden
    void (pageAt run reader "team/projects" "the-wiki")
    void (pageAt run admin "team" "team-handbook/on-call")

--------------------------------------------------------------------------------
-- Creating spaces

creatingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
creatingSpaces = describe "createSpace" $ do
  it "at the top level takes CreateSpaces" $ \(Fixture run) -> do
    run Anonymous (createSpace Nothing "Mine") >>= (`shouldFailWith` Forbidden)
    run reader (createSpace Nothing "Mine") >>= (`shouldFailWith` Forbidden)
    e <- run editor (createSpace Nothing "Mine") >>= ok
    a <- run admin (createSpace Nothing "Ours") >>= ok
    (e.parent, a.parent) `shouldBe` (Nothing, Nothing)

  it "makes a private space with a slug from its name, at its path" $ \(Fixture run) -> do
    s <- run editor (createSpace Nothing "  Zażółć gęślą jaźń  ") >>= ok
    (s.name, slugOf s, s.public) `shouldBe` ("Zażółć gęślą jaźń", "zazolc-gesla-jazn", False)
    found <- spaceAt run editor "zazolc-gesla-jazn"
    found `shouldBe` s
    run Anonymous (getSpace (path "zazolc-gesla-jazn")) `shouldReturn` Left Forbidden
    run reader (getSpace (path "zazolc-gesla-jazn")) `shouldReturn` Left Forbidden

  it "lets its creator administer it" $ \(Fixture run) -> do
    s <- run editor (createSpace Nothing "Mine") >>= ok
    void (run editor (renameSpace s.id "Still mine") >>= ok)
    sess <- run editor session
    [g.permission | g <- sess.grants.spaces, g.space == s.id] `shouldBe` [AdministerSpace]

  it "makes slugs unique among siblings" $ \(Fixture run) -> do
    a <- run admin (createSpace Nothing "Blog") >>= ok
    b <- run admin (createSpace Nothing "Blog") >>= ok
    (slugOf a, slugOf b) `shouldBe` ("blog-2", "blog-3")
    team <- spaceAt run admin "team"
    c <- run admin (createSpace (Just team.id) "Blog") >>= ok
    slugOf c `shouldBe` "blog"
    found <- spaceAt run admin "team/blog"
    found.id `shouldBe` c.id

  it "gives a name with no slug in it a slug all the same" $ \(Fixture run) -> do
    a <- run admin (createSpace Nothing "日本語") >>= ok
    b <- run admin (createSpace Nothing "!!!") >>= ok
    (slugOf a, slugOf b) `shouldBe` ("space", "space-2")

  it "under a parent takes CreateSpaces or AdministerSpace there, and seeing it" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    team <- spaceAt run admin "team"
    projects <- spaceAt run admin "team/projects"
    sub <- run editor (createSpace (Just docs.id) "Drafts") >>= ok
    sub.parent `shouldBe` Just docs.id
    run editor (createSpace (Just team.id) "Drafts") >>= (`shouldFailWith` Forbidden)
    run reader (createSpace (Just projects.id) "Drafts") >>= (`shouldFailWith` Forbidden)
    run Anonymous (createSpace (Just docs.id) "Drafts") >>= (`shouldFailWith` Forbidden)
    void (run admin (createSpace (Just team.id) "Drafts") >>= ok)

  it "refuses a parent that is not there, and a blank name" $ \(Fixture run) -> do
    run admin (createSpace (Just (SpaceId "no-such-space")) "Drafts") >>= (`shouldFailWith` NotFound)
    run admin (createSpace Nothing "  ") >>= shouldBeInvalid
    -- Permissions first: nobody learns whether a request they may not make
    -- would have been valid.
    run Anonymous (createSpace Nothing "  ") >>= (`shouldFailWith` Forbidden)

--------------------------------------------------------------------------------
-- Renaming and making public

changingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
changingSpaces = describe "renameSpace and setSpacePublic" $ do
  it "rename a space and keep its slug, so that its address stays" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    renamed <- run admin (renameSpace blog.id "Weblog") >>= ok
    (renamed.name, slugOf renamed) `shouldBe` ("Weblog", "blog")
    found <- spaceAt run Anonymous "blog"
    found.name `shouldBe` "Weblog"

  it "take AdministerSpace" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    team <- spaceAt run admin "team"
    run editor (renameSpace blog.id "Weblog") >>= (`shouldFailWith` Forbidden)
    run editor (setSpacePublic blog.id False) >>= (`shouldFailWith` Forbidden)
    run Anonymous (renameSpace blog.id "Weblog") >>= (`shouldFailWith` Forbidden)
    run reader (setSpacePublic team.id True) >>= (`shouldFailWith` Forbidden)
    run admin (renameSpace (SpaceId "no-such-space") "X") >>= (`shouldFailWith` NotFound)
    run admin (renameSpace blog.id "") >>= shouldBeInvalid

  it "make a space and its subspaces readable by everyone, and private again" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    s <- run admin (setSpacePublic team.id True) >>= ok
    s.public `shouldBe` True
    void (pageAt run Anonymous "team" "team-handbook")
    void (pageAt run Anonymous "team/projects" "the-wiki")
    spaceNames run Anonymous `shouldReturn` ["Blog", "Docs", "Team", "Projects"]
    void (run admin (setSpacePublic team.id False) >>= ok)
    getPageAt run Anonymous "team" "team-handbook" `shouldReturn` Left Forbidden

mathMacros :: (MonadWiki m) => SpecWith (Fixture m)
mathMacros = describe "setSpaceMathMacros" $ do
  it "gives a space math macros, which every reader of the space sees" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    let block = "\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\newcommand{\\Hom}{\\operatorname{Hom}}"
    s <- run admin (setSpaceMathMacros blog.id block) >>= ok
    (s.mathMacros, s.name, slugOf s, s.public) `shouldBe` (block, blog.name, slugOf blog, blog.public)
    found <- spaceAt run Anonymous "blog"
    found.mathMacros `shouldBe` block
    listed <- run Anonymous listSpaces
    [x.mathMacros | x <- listed, x.id == blog.id] `shouldBe` [block]

  it "keeps the block as written, but for blank lines at its ends, and takes them away with a blank one" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    s <- run admin (setSpaceMathMacros blog.id "\n  \n\\def\\a{1}\n\n  \\def\\b{2}  \n\n") >>= ok
    s.mathMacros `shouldBe` "\\def\\a{1}\n\n  \\def\\b{2}  "
    cleared <- run admin (setSpaceMathMacros blog.id " \n ") >>= ok
    cleared.mathMacros `shouldBe` ""

  it "keeps a block KaTeX may not read: that is the browser's to say" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    s <- run admin (setSpaceMathMacros blog.id "\\newcommand{\\x}{\\frac{") >>= ok
    s.mathMacros `shouldBe` "\\newcommand{\\x}{\\frac{"

  it "keeps a space's macros when it is renamed, made public and moved" $ \(Fixture run) -> do
    projects <- spaceAt run admin "team/projects"
    _ <- run admin (setSpaceMathMacros projects.id "\\def\\x{1}") >>= ok
    _ <- run admin (renameSpace projects.id "Plans") >>= ok
    _ <- run admin (setSpacePublic projects.id True) >>= ok
    moved <- run admin (moveSpace projects.id Nothing) >>= ok
    moved.mathMacros `shouldBe` "\\def\\x{1}"

  it "takes AdministerSpace" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    team <- spaceAt run admin "team"
    run editor (setSpaceMathMacros blog.id "\\def\\x{1}") >>= (`shouldFailWith` Forbidden)
    run Anonymous (setSpaceMathMacros blog.id "\\def\\x{1}") >>= (`shouldFailWith` Forbidden)
    run reader (setSpaceMathMacros team.id "\\def\\x{1}") >>= (`shouldFailWith` Forbidden)
    run admin (setSpaceMathMacros (SpaceId "no-such-space") "") >>= (`shouldFailWith` NotFound)
    unchanged <- spaceAt run admin "blog"
    unchanged.mathMacros `shouldBe` ""

--------------------------------------------------------------------------------
-- Moving spaces

movingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
movingSpaces = describe "moveSpace" $ do
  it "moves a space with its subspaces and pages" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    docs <- spaceAt run admin "docs"
    moved <- run admin (moveSpace team.id (Just docs.id)) >>= ok
    moved.parent `shouldBe` Just docs.id
    run admin (getSpace (path "team")) `shouldReturn` Left NotFound
    void (spaceAt run admin "docs/team/projects")
    void (pageAt run admin "docs/team/projects" "the-wiki")
    void (pageAt run admin "docs/team" "team-handbook/on-call")

  it "moves a subspace to the top level" $ \(Fixture run) -> do
    projects <- spaceAt run admin "team/projects"
    moved <- run admin (moveSpace projects.id Nothing) >>= ok
    moved.parent `shouldBe` Nothing
    void (spaceAt run admin "projects")
    run admin (getSpace (path "team/projects")) `shouldReturn` Left NotFound

  it "refuses to make a space its own ancestor" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    projects <- spaceAt run admin "team/projects"
    run admin (moveSpace team.id (Just team.id)) >>= shouldBeInvalid
    run admin (moveSpace team.id (Just projects.id)) >>= shouldBeInvalid
    -- Nothing moved.
    void (spaceAt run admin "team/projects")

  it "gives the space a fresh slug among its new siblings" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    other <- run admin (createSpace (Just docs.id) "Projects") >>= ok
    projects <- spaceAt run admin "team/projects"
    moved <- run admin (moveSpace projects.id (Just docs.id)) >>= ok
    (slugOf other, slugOf moved) `shouldBe` ("projects", "projects-2")
    found <- spaceAt run admin "docs/projects-2"
    found.id `shouldBe` projects.id

  it "keeps the slug when the space stays where it is" $ \(Fixture run) -> do
    projects <- spaceAt run admin "team/projects"
    moved <- run admin (moveSpace projects.id projects.parent) >>= ok
    moved `shouldBe` projects

  it "takes AdministerSpace on the space, and on the new parent or CreateSpaces for the top level" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    docs <- spaceAt run admin "docs"
    run editor (moveSpace blog.id (Just docs.id)) >>= (`shouldFailWith` Forbidden)
    mine <- run editor (createSpace Nothing "Mine") >>= ok
    other <- run editor (createSpace Nothing "Other") >>= ok
    run editor (moveSpace mine.id (Just docs.id)) >>= (`shouldFailWith` Forbidden)
    under <- run editor (moveSpace mine.id (Just other.id)) >>= ok
    under.parent `shouldBe` Just other.id
    back <- run editor (moveSpace mine.id Nothing) >>= ok
    back.parent `shouldBe` Nothing
    run reader (moveSpace mine.id Nothing) >>= (`shouldFailWith` Forbidden)
    run Anonymous (moveSpace blog.id Nothing) >>= (`shouldFailWith` Forbidden)

  it "gives NotFound for a space or a parent that is not there" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    run admin (moveSpace blog.id (Just (SpaceId "no-such-space"))) >>= (`shouldFailWith` NotFound)
    run admin (moveSpace (SpaceId "no-such-space") Nothing) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Deleting spaces

deletingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
deletingSpaces = describe "deleteSpace" $ do
  it "deletes a space with its subspaces, their pages and the grants on them" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    projects <- spaceAt run admin "team/projects"
    wiki <- pageAt run admin "team/projects" "the-wiki"
    run admin (deleteSpace team.id) >>= ok
    run admin (getSpace (path "team")) `shouldReturn` Left NotFound
    run admin (getSpace (path "team/projects")) `shouldReturn` Left NotFound
    run admin (listPages projects.id) `shouldReturn` Left NotFound
    run admin (savePage wiki.id wiki.updatedAt "The wiki" "") >>= (`shouldFailWith` NotFound)
    spaceNames run admin `shouldReturn` ["Blog", "Docs"]
    r <- run reader session
    r.grants.spaces `shouldBe` []

  it "takes AdministerSpace" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    projects <- spaceAt run admin "team/projects"
    run editor (deleteSpace blog.id) >>= (`shouldFailWith` Forbidden)
    run reader (deleteSpace projects.id) >>= (`shouldFailWith` Forbidden)
    run Anonymous (deleteSpace blog.id) >>= (`shouldFailWith` Forbidden)
    run admin (deleteSpace (SpaceId "no-such-space")) >>= (`shouldFailWith` NotFound)
    mine <- run editor (createSpace Nothing "Mine") >>= ok
    run editor (deleteSpace mine.id) >>= ok
    void (spaceAt run admin "blog")

--------------------------------------------------------------------------------
-- Order

ordering :: (MonadWiki m) => SpecWith (Fixture m)
ordering = describe "setSpaceOrder, shiftSpace and shiftPage" $ do
  it "list children by name in natural order unless told otherwise, a number as a number" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    blog.pageOrder `shouldBe` ByName
    blog.subspaceOrder `shouldBe` ByName
    for_ ["Part 11", "Part 2", "part 1"] $ \t -> run admin (createPage blog.id Nothing t "") >>= ok
    pageTitles run Anonymous "blog" `shouldReturn` ["Hello, world", "Notes on Haskell", "part 1", "Part 2", "Part 11"]

  it "list a space's pages by date, newest or oldest first, for every reader" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    newest <- run admin (setSpaceOrder blog.id ChildPages NewestFirst) >>= ok
    (newest.pageOrder, newest.subspaceOrder, newest.name) `shouldBe` (NewestFirst, ByName, blog.name)
    pageTitles run Anonymous "blog" `shouldReturn` ["Notes on Haskell", "Hello, world"]
    (\s -> s.pageOrder) <$> spaceAt run Anonymous "blog" `shouldReturn` NewestFirst
    void (run admin (setSpaceOrder blog.id ChildPages OldestFirst) >>= ok)
    pageTitles run Anonymous "blog" `shouldReturn` ["Hello, world", "Notes on Haskell"]
    void (run admin (setSpaceOrder blog.id ChildPages ByName) >>= ok)
    pageTitles run Anonymous "blog" `shouldReturn` ["Hello, world", "Notes on Haskell"]

  it "list a space's subspaces in its own order, and the top-level spaces by name" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    void (run admin (createSpace (Just team.id) "Archive") >>= ok)
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Archive", "Projects"]
    void (run admin (setSpaceOrder team.id ChildSpaces OldestFirst) >>= ok)
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Projects", "Archive"]
    void (run admin (setSpaceOrder team.id ChildSpaces NewestFirst) >>= ok)
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Archive", "Projects"]

  it "order the pages under a page as the space orders its pages" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    void (run admin (setSpaceOrder docs.id ChildPages ByHand) >>= ok)
    maths <- pageAt run admin "docs" "markdown-guide/mathematics"
    void (run admin (shiftPage maths.id ShiftUp) >>= ok)
    pageTitles run Anonymous "docs" `shouldReturn` ["Markdown guide", "Mathematics", "Diagrams", "Tour"]

  it "keep the order a space showed when it is switched to by hand, and put a new child last" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    void (run admin (setSpaceOrder blog.id ChildPages NewestFirst) >>= ok)
    void (run admin (setSpaceOrder blog.id ChildPages ByHand) >>= ok)
    pageTitles run Anonymous "blog" `shouldReturn` ["Notes on Haskell", "Hello, world"]
    void (run editor (createPage blog.id Nothing "Aardvarks" "") >>= ok)
    pageTitles run Anonymous "blog" `shouldReturn` ["Notes on Haskell", "Hello, world", "Aardvarks"]

  it "move a page up, down, to the top and to the bottom, keeping its address" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    void (run admin (setSpaceOrder blog.id ChildPages ByHand) >>= ok)
    for_ ["C", "D"] $ \t -> run editor (createPage blog.id Nothing t "") >>= ok
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "Notes on Haskell", "C", "D"]
    c <- pageAt run editor "blog" "c"
    up <- run editor (shiftPage c.id ShiftUp) >>= ok
    (up.id, up.slug) `shouldBe` (c.id, c.slug)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "C", "Notes on Haskell", "D"]
    void (run editor (shiftPage c.id ShiftToTop) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["C", "Hello, world", "Notes on Haskell", "D"]
    void (run editor (shiftPage c.id ShiftDown) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "C", "Notes on Haskell", "D"]
    void (run editor (shiftPage c.id ShiftToBottom) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "Notes on Haskell", "D", "C"]
    found <- pageAt run Anonymous "blog" "c"
    found.id `shouldBe` c.id

  it "do nothing, and succeed, moving past either end" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    void (run admin (setSpaceOrder blog.id ChildPages ByHand) >>= ok)
    hello <- pageAt run editor "blog" "hello-world"
    notes <- pageAt run editor "blog" "notes-on-haskell"
    void (run editor (shiftPage hello.id ShiftUp) >>= ok)
    void (run editor (shiftPage hello.id ShiftToTop) >>= ok)
    void (run editor (shiftPage notes.id ShiftDown) >>= ok)
    void (run editor (shiftPage notes.id ShiftToBottom) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "Notes on Haskell"]

  it "keep the order of the rest when a page is deleted, and move past the gap" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    void (run admin (setSpaceOrder blog.id ChildPages ByHand) >>= ok)
    for_ ["C", "D"] $ \t -> run editor (createPage blog.id Nothing t "") >>= ok
    notes <- pageAt run editor "blog" "notes-on-haskell"
    void (run editor (deletePage notes.id) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "C", "D"]
    d <- pageAt run editor "blog" "d"
    void (run editor (shiftPage d.id ShiftUp) >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "D", "C"]
    void (run editor (createPage blog.id Nothing "E" "") >>= ok)
    pageTitles run editor "blog" `shouldReturn` ["Hello, world", "D", "C", "E"]

  it "put a page moved under another parent last there, and keep the order under it" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    void (run admin (setSpaceOrder docs.id ChildPages ByHand) >>= ok)
    guide <- pageAt run admin "docs" "markdown-guide"
    aardvarks <- run admin (createPage docs.id Nothing "Aardvarks" "") >>= ok
    void (run admin (createPage docs.id (Just aardvarks.id) "Zebras" "") >>= ok)
    void (run admin (createPage docs.id (Just aardvarks.id) "Antelopes" "") >>= ok)
    void (run admin (movePage aardvarks.id docs.id (Just guide.id)) >>= ok)
    pageTitles run admin "docs" `shouldReturn` ["Markdown guide", "Diagrams", "Mathematics", "Aardvarks", "Zebras", "Antelopes", "Tour"]

  it "put a space moved under another parent last there" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    blog <- spaceAt run admin "blog"
    void (run admin (setSpaceOrder team.id ChildSpaces ByHand) >>= ok)
    alpha <- run admin (createSpace (Just blog.id) "Alpha") >>= ok
    void (run admin (moveSpace alpha.id (Just team.id)) >>= ok)
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Projects", "Alpha"]

  it "move a subspace among its siblings, as someone who edits its parent" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    void (run admin (setSpaceOrder team.id ChildSpaces ByHand) >>= ok)
    archive <- run admin (createSpace (Just team.id) "Archive") >>= ok
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Projects", "Archive"]
    moved <- run admin (shiftSpace archive.id ShiftToTop) >>= ok
    (moved.id, moved.slug) `shouldBe` (archive.id, archive.slug)
    spaceNames run admin `shouldReturn` ["Blog", "Docs", "Team", "Archive", "Projects"]
    void (spaceAt run admin "team/archive")
    run editor (shiftSpace archive.id ShiftDown) >>= (`shouldFailWith` Forbidden)
    run reader (shiftSpace archive.id ShiftDown) >>= (`shouldFailWith` Forbidden)

  it "refuse a move by hand where the order is not by hand, and for a top-level space" $ \(Fixture run) -> do
    hello <- pageAt run editor "blog" "hello-world"
    run editor (shiftPage hello.id ShiftDown) >>= shouldBeInvalid
    projects <- spaceAt run admin "team/projects"
    run admin (shiftSpace projects.id ShiftUp) >>= shouldBeInvalid
    blog <- spaceAt run admin "blog"
    run admin (shiftSpace blog.id ShiftDown) >>= shouldBeInvalid
    run Anonymous (shiftSpace blog.id ShiftDown) >>= shouldBeInvalid

  it "take AdministerSpace to choose an order, and Edit to move a page" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    team <- spaceAt run admin "team"
    run editor (setSpaceOrder blog.id ChildPages ByHand) >>= (`shouldFailWith` Forbidden)
    run Anonymous (setSpaceOrder blog.id ChildPages ByHand) >>= (`shouldFailWith` Forbidden)
    run reader (setSpaceOrder team.id ChildSpaces ByHand) >>= (`shouldFailWith` Forbidden)
    (\s -> s.pageOrder) <$> spaceAt run admin "blog" `shouldReturn` ByName
    void (run admin (setSpaceOrder blog.id ChildPages ByHand) >>= ok)
    hello <- pageAt run admin "blog" "hello-world"
    run reader (shiftPage hello.id ShiftDown) >>= (`shouldFailWith` Forbidden)
    run Anonymous (shiftPage hello.id ShiftDown) >>= (`shouldFailWith` Forbidden)
    pageTitles run admin "blog" `shouldReturn` ["Hello, world", "Notes on Haskell"]
    void (run editor (shiftPage hello.id ShiftDown) >>= ok)
    pageTitles run admin "blog" `shouldReturn` ["Notes on Haskell", "Hello, world"]

  it "give NotFound for a space or a page that is not there" $ \(Fixture run) -> do
    run admin (setSpaceOrder (SpaceId "no-such-space") ChildPages ByHand) >>= (`shouldFailWith` NotFound)
    run admin (shiftSpace (SpaceId "no-such-space") ShiftUp) >>= (`shouldFailWith` NotFound)
    run admin (shiftPage (PageId "no-such-page") ShiftUp) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Creating pages

creatingPages :: (MonadWiki m) => SpecWith (Fixture m)
creatingPages = describe "createPage" $ do
  it "makes a page with a slug from its title, at its path" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    p <- run editor (createPage blog.id Nothing "A new post!" "Hello.") >>= ok
    (p.title, slugText p.slug, p.body, p.space, p.parent) `shouldBe` ("A new post!", "a-new-post", "Hello.", blog.id, Nothing)
    p.createdAt `shouldBe` p.updatedAt
    p.attachments `shouldBe` []
    found <- pageAt run Anonymous "blog" "a-new-post"
    found `shouldBe` p

  it "makes slugs unique among siblings, and only among them" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    guide <- pageAt run admin "docs" "markdown-guide"
    a <- run admin (createPage docs.id Nothing "Tour" "") >>= ok
    b <- run admin (createPage docs.id (Just guide.id) "Tour" "") >>= ok
    (slugText a.slug, slugText b.slug) `shouldBe` ("tour-2", "tour")
    found <- pageAt run admin "docs" "markdown-guide/tour"
    found.id `shouldBe` b.id

  it "takes Edit on the space" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    docs <- spaceAt run admin "docs"
    projects <- spaceAt run admin "team/projects"
    run Anonymous (createPage blog.id Nothing "Post" "") >>= (`shouldFailWith` Forbidden)
    run reader (createPage projects.id Nothing "Post" "") >>= (`shouldFailWith` Forbidden)
    run editor (createPage docs.id Nothing "Post" "") >>= (`shouldFailWith` Forbidden)
    void (run admin (createPage projects.id Nothing "Post" "") >>= ok)

  it "refuses a parent elsewhere, a space or a parent that is not there, and a blank title" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    tour <- pageAt run admin "docs" "tour"
    run admin (createPage blog.id (Just tour.id) "Post" "") >>= shouldBeInvalid
    run admin (createPage blog.id (Just (PageId "no-such-page")) "Post" "") >>= (`shouldFailWith` NotFound)
    run admin (createPage (SpaceId "no-such-space") Nothing "Post" "") >>= (`shouldFailWith` NotFound)
    run admin (createPage blog.id Nothing " " "") >>= shouldBeInvalid
    run Anonymous (createPage blog.id Nothing " " "") >>= (`shouldFailWith` Forbidden)

--------------------------------------------------------------------------------
-- Saving pages

savingPages :: (MonadWiki m) => SpecWith (Fixture m)
savingPages = describe "savePage" $ do
  it "changes the title and the body, keeps the slug, and moves updatedAt on" $ \(Fixture run) -> do
    p <- pageAt run admin "blog" "hello-world"
    saved <- run editor (savePage p.id p.updatedAt "Hello again" "New body") >>= ok
    (saved.title, saved.body, saved.slug, saved.createdAt) `shouldBe` ("Hello again", "New body", p.slug, p.createdAt)
    saved.updatedAt `shouldSatisfy` (> p.updatedAt)
    found <- pageAt run Anonymous "blog" "hello-world"
    found `shouldBe` saved

  it "moves updatedAt on with every save, however quick" $ \(Fixture run) -> do
    p <- pageAt run admin "blog" "hello-world"
    let saveFrom :: UTCTime -> Int -> IO UTCTime
        saveFrom base n = (\q -> q.updatedAt) <$> (run editor (savePage p.id base "Hello" (show n)) >>= ok)
    times <- foldM (\acc n -> (: acc) <$> saveFrom (fromMaybe p.updatedAt (head acc)) n) [] [1 .. 5 :: Int]
    reverse times `shouldSatisfy` (\ts -> and (zipWith (<) (p.updatedAt : ts) ts))

  it "refuses a save based on an older version" $ \(Fixture run) -> do
    p <- pageAt run admin "blog" "hello-world"
    saved <- run editor (savePage p.id p.updatedAt "First" "") >>= ok
    run admin (savePage p.id p.updatedAt "Second" "") >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected Conflict, got " <> show other)
    void (run admin (savePage p.id saved.updatedAt "Second" "") >>= ok)

  it "takes Edit on the space, and a title" $ \(Fixture run) -> do
    tour <- pageAt run admin "docs" "tour"
    wiki <- pageAt run admin "team/projects" "the-wiki"
    hello <- pageAt run admin "blog" "hello-world"
    run editor (savePage tour.id tour.updatedAt "Tour" "") >>= (`shouldFailWith` Forbidden)
    run reader (savePage wiki.id wiki.updatedAt "Wiki" "") >>= (`shouldFailWith` Forbidden)
    run Anonymous (savePage hello.id hello.updatedAt "Hello" "") >>= (`shouldFailWith` Forbidden)
    run editor (savePage hello.id hello.updatedAt "" "") >>= shouldBeInvalid
    run editor (savePage (PageId "no-such-page") hello.updatedAt "Hello" "") >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Moving pages

movingPages :: (MonadWiki m) => SpecWith (Fixture m)
movingPages = describe "movePage" $ do
  it "moves a page with the pages under it within its space" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    guide <- pageAt run admin "docs" "markdown-guide"
    tour <- pageAt run admin "docs" "tour"
    moved <- run admin (movePage guide.id docs.id (Just tour.id)) >>= ok
    (moved.parent, moved.slug) `shouldBe` (Just tour.id, guide.slug)
    void (pageAt run admin "docs" "tour/markdown-guide/diagrams")
    getPageAt run admin "docs" "markdown-guide" `shouldReturn` Left NotFound

  it "moves a page with the pages under it to another space" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    guide <- pageAt run admin "docs" "markdown-guide"
    moved <- run admin (movePage guide.id blog.id Nothing) >>= ok
    moved.space `shouldBe` blog.id
    diagrams <- pageAt run admin "blog" "markdown-guide/diagrams"
    diagrams.space `shouldBe` blog.id
    pageTitles run admin "docs" `shouldReturn` ["Tour"]
    pageTitles run admin "blog" `shouldReturn` ["Hello, world", "Markdown guide", "Diagrams", "Mathematics", "Notes on Haskell"]

  it "refuses to put a page under itself or a page under it" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    guide <- pageAt run admin "docs" "markdown-guide"
    diagrams <- pageAt run admin "docs" "markdown-guide/diagrams"
    run admin (movePage guide.id docs.id (Just guide.id)) >>= shouldBeInvalid
    run admin (movePage guide.id docs.id (Just diagrams.id)) >>= shouldBeInvalid
    void (pageAt run admin "docs" "markdown-guide/diagrams")

  it "gives the page a fresh slug among its new siblings" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    tour <- pageAt run admin "docs" "tour"
    _ <- run admin (createPage blog.id Nothing "Tour" "") >>= ok
    moved <- run admin (movePage tour.id blog.id Nothing) >>= ok
    slugText moved.slug `shouldBe` "tour-2"

  it "refuses a parent in another space, and what is not there" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    docs <- spaceAt run admin "docs"
    tour <- pageAt run admin "docs" "tour"
    hello <- pageAt run admin "blog" "hello-world"
    run admin (movePage tour.id docs.id (Just hello.id)) >>= shouldBeInvalid
    run admin (movePage tour.id (SpaceId "no-such-space") Nothing) >>= (`shouldFailWith` NotFound)
    run admin (movePage tour.id blog.id (Just (PageId "no-such-page"))) >>= (`shouldFailWith` NotFound)
    run admin (movePage (PageId "no-such-page") blog.id Nothing) >>= (`shouldFailWith` NotFound)

  it "takes Edit on both spaces" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    docs <- spaceAt run admin "docs"
    hello <- pageAt run admin "blog" "hello-world"
    notes <- pageAt run admin "blog" "notes-on-haskell"
    tour <- pageAt run admin "docs" "tour"
    run editor (movePage hello.id docs.id Nothing) >>= (`shouldFailWith` Forbidden)
    run editor (movePage tour.id blog.id Nothing) >>= (`shouldFailWith` Forbidden)
    run Anonymous (movePage hello.id blog.id (Just notes.id)) >>= (`shouldFailWith` Forbidden)
    moved <- run editor (movePage hello.id blog.id (Just notes.id)) >>= ok
    moved.parent `shouldBe` Just notes.id

--------------------------------------------------------------------------------
-- Deleting pages

deletingPages :: (MonadWiki m) => SpecWith (Fixture m)
deletingPages = describe "deletePage" $ do
  it "deletes a page with the pages under it" $ \(Fixture run) -> do
    guide <- pageAt run admin "docs" "markdown-guide"
    run admin (deletePage guide.id) >>= ok
    pageTitles run admin "docs" `shouldReturn` ["Tour"]
    run admin (deletePage guide.id) >>= (`shouldFailWith` NotFound)

  it "takes Edit on the space" $ \(Fixture run) -> do
    tour <- pageAt run admin "docs" "tour"
    hello <- pageAt run admin "blog" "hello-world"
    run editor (deletePage tour.id) >>= (`shouldFailWith` Forbidden)
    run Anonymous (deletePage hello.id) >>= (`shouldFailWith` Forbidden)
    run editor (deletePage hello.id) >>= ok
    getPageAt run admin "blog" "hello-world" `shouldReturn` Left NotFound

--------------------------------------------------------------------------------
-- Attachments

attachments :: (MonadWiki m) => SpecWith (Fixture m)
attachments = describe "uploadAttachment, deleteAttachment and attachmentUrl" $ do
  let bytes = BS.pack [0 .. 255]

  it "attach a file that the page then has by name" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    a <- run editor (uploadAttachment hello.id "notes.bin" "application/octet-stream" bytes) >>= ok
    (a.name, a.mediaType, a.size) `shouldBe` ("notes.bin", "application/octet-stream", 256)
    found <- pageAt run Anonymous "blog" "hello-world"
    findAttachment "notes.bin" found.attachments `shouldBe` Just a
    found.updatedAt `shouldBe` hello.updatedAt
    url <- run Anonymous (attachmentUrl a)
    url `shouldSatisfy` (not . T.null)

  it "replace an attachment of the same name" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    _ <- run editor (uploadAttachment hello.id "a.png" "image/png" bytes) >>= ok
    b <- run editor (uploadAttachment hello.id "a.png" "image/png" (BS.take 10 bytes)) >>= ok
    found <- pageAt run admin "blog" "hello-world"
    filter (\x -> x.name == "a.png") found.attachments `shouldBe` [b]
    b.size `shouldBe` 10

  it "show the demo's attachments" $ \(Fixture run) -> do
    wiki <- pageAt run reader "team/projects" "the-wiki"
    tree <- maybe (assertFailure "the wiki page has no tree.png") pure (findAttachment "tree.png" wiki.attachments)
    tree.mediaType `shouldBe` "image/png"
    url <- run reader (attachmentUrl tree)
    url `shouldSatisfy` (not . T.null)

  it "delete an attachment" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    a <- run editor (uploadAttachment hello.id "a.png" "image/png" bytes) >>= ok
    run editor (deleteAttachment a.id) >>= ok
    found <- pageAt run admin "blog" "hello-world"
    findAttachment "a.png" found.attachments `shouldBe` Nothing
    run editor (deleteAttachment a.id) >>= (`shouldFailWith` NotFound)

  it "go with their page" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    a <- run editor (uploadAttachment hello.id "a.png" "image/png" bytes) >>= ok
    run editor (deletePage hello.id) >>= ok
    run admin (deleteAttachment a.id) >>= (`shouldFailWith` NotFound)

  it "take Edit on the page's space" $ \(Fixture run) -> do
    tour <- pageAt run admin "docs" "tour"
    wiki <- pageAt run admin "team/projects" "the-wiki"
    hello <- pageAt run admin "blog" "hello-world"
    run editor (uploadAttachment tour.id "a.png" "image/png" bytes) >>= (`shouldFailWith` Forbidden)
    run reader (uploadAttachment wiki.id "a.png" "image/png" bytes) >>= (`shouldFailWith` Forbidden)
    run Anonymous (uploadAttachment hello.id "a.png" "image/png" bytes) >>= (`shouldFailWith` Forbidden)
    tree <- maybe (assertFailure "the wiki page has no tree.png") pure (findAttachment "tree.png" wiki.attachments)
    run reader (deleteAttachment tree.id) >>= (`shouldFailWith` Forbidden)
    run admin (uploadAttachment (PageId "no-such-page") "a.png" "image/png" bytes) >>= (`shouldFailWith` NotFound)
    run admin (deleteAttachment (AttachmentId "no-such-attachment")) >>= (`shouldFailWith` NotFound)

  it "refuse a blank name, a name with a slash, and a file too large" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    run editor (uploadAttachment hello.id " " "image/png" bytes) >>= shouldBeInvalid
    run editor (uploadAttachment hello.id "a/b.png" "image/png" bytes) >>= shouldBeInvalid
    let tooLarge = BS.replicate (fromIntegral maxAttachmentSize + 1) 0
    run editor (uploadAttachment hello.id "big.bin" "application/octet-stream" tooLarge) >>= shouldBeInvalid

--------------------------------------------------------------------------------
-- Search

-- | What someone finds: each hit's space path and title, in order.
hitsFor :: (MonadWiki m) => Run m -> As -> SearchQuery -> IO [(Text, Text)]
hitsFor run who q = map (\h -> (renderPath h.spacePath, snippetText h.title)) <$> run who (searchPages q)

-- | The paths of the spaces someone finds hits in.
spacesFound :: (MonadWiki m) => Run m -> As -> SearchQuery -> IO (Set Text)
spacesFound run who q = Set.fromList . map fst <$> hitsFor run who q

-- | A query for these words in a space, with or without its subspaces.
inSpace :: SpaceId -> Bool -> Text -> SearchQuery
inSpace sid includeSubspaces text = SearchQuery {text, space = Just sid, includeSubspaces, limit = 50}

searching :: (MonadWiki m) => SpecWith (Fixture m)
searching = describe "searchPages" $ do
  it "finds only what someone may view" $ \(Fixture run) -> do
    hitsFor run admin (searchQuery "handbook") `shouldReturn` [("team", "Team handbook")]
    hitsFor run Anonymous (searchQuery "handbook") `shouldReturn` []
    hitsFor run reader (searchQuery "handbook") `shouldReturn` []
    spacesFound run Anonymous (searchQuery "the") `shouldReturn` Set.fromList ["blog", "docs"]
    spacesFound run editor (searchQuery "the") `shouldReturn` Set.fromList ["blog", "docs"]

  it "finds in a subspace someone may view, under a space they may not" $ \(Fixture run) -> do
    spacesFound run reader (searchQuery "the") `shouldReturn` Set.fromList ["blog", "docs", "team/projects"]
    spacesFound run admin (searchQuery "the") `shouldReturn` Set.fromList ["blog", "docs", "team", "team/projects"]
    hitsFor run reader (searchQuery "milestones") `shouldReturn` [("team/projects", "The wiki")]

  it "keeps to one space, with or without its subspaces" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    spacesFound run admin (inSpace team.id True "the") `shouldReturn` Set.fromList ["team", "team/projects"]
    spacesFound run admin (inSpace team.id False "the") `shouldReturn` Set.fromList ["team"]
    spacesFound run reader (inSpace team.id True "the") `shouldReturn` Set.fromList ["team/projects"]
    spacesFound run reader (inSpace team.id False "the") `shouldReturn` Set.empty
    docs <- spaceAt run admin "docs"
    spacesFound run Anonymous (inSpace docs.id True "the") `shouldReturn` Set.fromList ["docs"]

  it "ranks a match in the title above one in the text" $ \(Fixture run) -> do
    hits <- hitsFor run Anonymous (searchQuery "diagrams")
    take 1 hits `shouldBe` [("docs", "Diagrams")]
    map snd (drop 1 hits) `shouldSatisfy` all (not . T.isInfixOf "iagrams")
    length hits `shouldSatisfy` (> 1)

  it "finds nothing for no words, in a space that is not there, or past its limit" $ \(Fixture run) -> do
    hitsFor run admin (searchQuery "  ") `shouldReturn` []
    hitsFor run admin (inSpace (SpaceId "no-such-space") True "the") `shouldReturn` []
    length <$> hitsFor run admin (searchQuery "the") {limit = 2} `shouldReturn` 2

  it "finds a page by what it was last saved with" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    p <- run editor (createPage blog.id Nothing "Marsupials" "The quokka smiles.") >>= ok
    hitsFor run Anonymous (searchQuery "QUOKKA") `shouldReturn` [("blog", "Marsupials")]
    void (run editor (savePage p.id p.updatedAt "Marsupials" "The wombat digs.") >>= ok)
    hitsFor run Anonymous (searchQuery "quokka") `shouldReturn` []
    hitsFor run Anonymous (searchQuery "wombat") `shouldReturn` [("blog", "Marsupials")]

--------------------------------------------------------------------------------
-- Errors are values

-- | Every method, asked about what is not there or by someone who may not,
-- returns its error rather than throwing it.
neverThrown :: (MonadWiki m) => SpecWith (Fixture m)
neverThrown = describe "errors" $ do
  it "are returned, never thrown" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    let s = SpaceId "no-such-space"
        p = PageId "no-such-page"
        calls =
          [ void <$> getSpace (path "no-such-space")
          , void <$> createSpace (Just s) "X"
          , void <$> renameSpace s "X"
          , void <$> setSpacePublic s True
          , void <$> setSpaceMathMacros s "\\newcommand{\\x}{1}"
          , void <$> moveSpace s Nothing
          , deleteSpace s
          , void <$> setSpaceOrder s ChildPages ByHand
          , void <$> shiftSpace s ShiftUp
          , void <$> shiftPage p ShiftUp
          , void <$> listPages s
          , void <$> getPage s (path "x")
          , void <$> createPage s Nothing "X" ""
          , void <$> savePage p hello.updatedAt "X" ""
          , void <$> movePage p s Nothing
          , deletePage p
          , void <$> uploadAttachment p "x" "text/plain" ""
          , deleteAttachment (AttachmentId "no-such-attachment")
          ]
    for_ [Anonymous, admin] $ \who -> for_ (zip [0 :: Int ..] calls) $ \(i, call) -> do
      result <- try (run who call >>= evaluate)
      case result of
        Left (e :: SomeException) -> expectationFailure ("call " <> show i <> " threw " <> show e)
        Right (Left _) -> pass
        Right (Right ()) -> expectationFailure ("call " <> show i <> " succeeded")
