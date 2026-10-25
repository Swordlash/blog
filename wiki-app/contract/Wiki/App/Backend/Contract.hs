-- | What every 'MonadWiki' backend does, as tests: the laws the class's
-- Haddock states, checked against the demo's content
-- ("Wiki.App.Demo") as each of its users sees it.
--
-- The spec is written once and run against each backend, given a 'Fixture'
-- that starts it with the demo's content and signs in as each user: the
-- in-memory one (@Test.Backend.Mem@ in @wiki-app-test@), the server's SQLite
-- storage (@Test.Storage.Contract@ in @wiki-server-test@), and the one over
-- HTTP against the server's API (@Test.Server.Http@ there). It is a library of its own, @wiki-app:contract@, for that.
module Wiki.App.Backend.Contract
  ( spec
  , Fixture (..)
  , As (..)
  , Run
  )
where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.App.Backend
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath, renderPath)
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), searchQuery, snippetText)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..), maxIconSize)
import Wiki.Core.User (Group (..), Standing (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..))

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

-- | The contract, for a backend made afresh for each example: the action
-- given runs an example with a fixture it makes for it, and lets go of
-- whatever the fixture holds (a database, a directory) once the example is
-- done, as hspec's 'around' wants.
spec :: forall m -> (MonadWiki m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadWiki contract" $ do
  sessions
  readingSpaces
  readingPages
  creatingSpaces
  changingSpaces
  spacePermissions
  mathMacros
  profiles
  movingSpaces
  deletingSpaces
  ordering
  creatingPages
  savingPages
  movingPages
  deletingPages
  attachments
  searching
  drafts
  history
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

-- | The id of the demo's user with this login, as they see themself.
userId :: (HasCallStack, MonadWiki m) => Run m -> As -> IO UserId
userId run who = run who currentUser >>= maybe (assertFailure ("nobody is signed in as " <> show who)) (pure . (\u -> u.id))

slugOf :: Space -> Text
slugOf s = slugText s.slug

--------------------------------------------------------------------------------
-- Sessions

sessions :: (MonadWiki m) => SpecWith (Fixture m)
sessions = describe "session" $ do
  it "is nobody's when nobody is signed in" $ \(Fixture run) -> do
    s <- run Anonymous session
    -- What the backend exports in is its own, not the asker's: a server
    -- makes documents for nobody signed in as for anyone else.
    s {exports = []} `shouldBe` anonymous
    run Anonymous currentUser `shouldReturn` Nothing

  it "names the user who is signed in" $ \(Fixture run) -> do
    for_ ["admin", "editor", "reader"] $ \login -> do
      u <- run (As login) currentUser
      (\x -> x.login) <$> u `shouldBe` Just login

  it "says that the user is signed in, and nobody is not" $ \(Fixture run) -> do
    e <- run editor session
    e.standing `shouldBe` SignedIn
    n <- run Anonymous session
    n.standing `shouldBe` NotSignedIn

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
    pageTitles run Anonymous "docs" `shouldReturn` ["Markdown guide", "Diagrams", "Mathematics", "Presentations", "Tour"]
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

spacePermissions :: (MonadWiki m) => SpecWith (Fixture m)
spacePermissions = describe "spaceAccess and setSpaceGrant" $ do
  it "list a space's own grants, then those it inherits, with whom one may be given to" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    projects <- spaceAt run admin "team/projects"
    readerId <- userId run reader
    access <- run admin (spaceAccess projects.id) >>= ok
    [(g.space, g.subject, g.permission) | g <- access.grants] `shouldBe` [(projects.id, SubjectUser readerId, View)]
    map (\u -> u.login) access.users `shouldBe` ["admin", "editor", "reader"]
    map (\g -> g.name) access.groups `shouldBe` ["writers"]
    run admin (setSpaceGrant team.id (SubjectUser readerId) Edit True) >>= ok
    inherited <- run admin (spaceAccess projects.id) >>= ok
    [(g.space, g.permission) | g <- inherited.grants] `shouldBe` [(projects.id, View), (team.id, Edit)]

  it "give a user a private space, its subspaces with it, and take it back" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    editorId <- userId run editor
    getPageAt run editor "team" "team-handbook" `shouldReturn` Left Forbidden
    run admin (setSpaceGrant team.id (SubjectUser editorId) View True) >>= ok
    void (pageAt run editor "team" "team-handbook")
    void (pageAt run editor "team/projects" "the-wiki")
    projects <- spaceAt run admin "team/projects"
    run editor (createPage projects.id Nothing "Mine" "") >>= (`shouldFailWith` Forbidden)
    run admin (setSpaceGrant team.id (SubjectUser editorId) Edit True) >>= ok
    void (run editor (createPage projects.id Nothing "Mine" "") >>= ok)
    -- Their session has the grants, which is what the client hides by.
    held <- run editor session
    sort [g.permission | g <- held.grants.spaces, g.space == team.id] `shouldBe` [View, Edit]
    run admin (setSpaceGrant team.id (SubjectUser editorId) Edit False) >>= ok
    run admin (setSpaceGrant team.id (SubjectUser editorId) View False) >>= ok
    getPageAt run editor "team" "team-handbook" `shouldReturn` Left Forbidden
    getPageAt run editor "team/projects" "the-wiki" `shouldReturn` Left Forbidden

  it "grant to a group's members, and change nothing more when asked twice" $ \(Fixture run) -> do
    team <- spaceAt run admin "team"
    writers <- (\a -> maybe (panic "no writers") (\g -> g.id) (head a.groups)) <$> (run admin (spaceAccess team.id) >>= ok)
    run admin (setSpaceGrant team.id (SubjectGroup writers) View True) >>= ok
    run admin (setSpaceGrant team.id (SubjectGroup writers) View True) >>= ok
    void (pageAt run editor "team" "team-handbook")
    access <- run admin (spaceAccess team.id) >>= ok
    length [g | g <- access.grants, g.subject == SubjectGroup writers] `shouldBe` 1
    run admin (setSpaceGrant team.id (SubjectGroup writers) View False) >>= ok
    run admin (setSpaceGrant team.id (SubjectGroup writers) View False) >>= ok
    getPageAt run editor "team" "team-handbook" `shouldReturn` Left Forbidden

  it "let whoever administers the space do it, themself included, and nobody else" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    team <- spaceAt run admin "team"
    editorId <- userId run editor
    readerId <- userId run reader
    for_ [Anonymous, editor, reader] $ \who -> do
      run who (spaceAccess blog.id) >>= (`shouldFailWith` Forbidden)
      run who (setSpaceGrant blog.id (SubjectUser editorId) AdministerSpace True) >>= (`shouldFailWith` Forbidden)
    run reader (spaceAccess team.id) >>= (`shouldFailWith` Forbidden)
    run admin (spaceAccess (SpaceId "no-such-space")) >>= (`shouldFailWith` NotFound)
    run admin (setSpaceGrant (SpaceId "no-such-space") (SubjectUser editorId) View True) >>= (`shouldFailWith` NotFound)
    -- Granted to administer the blog, the editor may grant on it, and take
    -- that from themself.
    run admin (setSpaceGrant blog.id (SubjectUser editorId) AdministerSpace True) >>= ok
    run editor (setSpaceGrant blog.id (SubjectUser readerId) Edit True) >>= ok
    void (run editor (spaceAccess blog.id) >>= ok)
    run editor (setSpaceGrant blog.id (SubjectUser editorId) AdministerSpace False) >>= ok
    run editor (spaceAccess blog.id) >>= (`shouldFailWith` Forbidden)

  it "refuse to grant to a user or a group that is not there" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    run admin (setSpaceGrant blog.id (SubjectUser (UserId "user-nobody")) View True) >>= shouldBeInvalid
    run admin (setSpaceGrant blog.id (SubjectGroup (GroupId "group-nothing")) View True) >>= shouldBeInvalid
    -- Taking one away from nobody changes nothing.
    run admin (setSpaceGrant blog.id (SubjectUser (UserId "user-nobody")) View False) >>= ok

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
    pageTitles run Anonymous "docs" `shouldReturn` ["Markdown guide", "Mathematics", "Diagrams", "Presentations", "Tour"]

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
    pageTitles run admin "docs" `shouldReturn` ["Markdown guide", "Diagrams", "Mathematics", "Presentations", "Aardvarks", "Zebras", "Antelopes", "Tour"]

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
    pageTitles run admin "blog" `shouldReturn` ["Hello, world", "Markdown guide", "Diagrams", "Mathematics", "Presentations", "Notes on Haskell"]

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
-- Drafts

drafts :: (MonadWiki m) => SpecWith (Fixture m)
drafts = describe "getDraft, saveDraft and discardDraft" $ do
  it "keep the signed-in user's unsaved work on a page, and give it back to them" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    run editor (getDraft hello.id) `shouldReturn` Right Nothing
    d <- run editor (saveDraft hello.id hello.updatedAt "Hello, draft" "Half a thought") >>= ok
    (d.page, d.title, d.body, d.base) `shouldBe` (hello.id, "Hello, draft", "Half a thought", hello.updatedAt)
    editorUser <- run editor currentUser
    Just d.author `shouldBe` ((\u -> u.id) <$> editorUser)
    run editor (getDraft hello.id) `shouldReturn` Right (Just d)

  it "keep one draft of a page for each user, the last one saved" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    older <- run editor (saveDraft hello.id hello.updatedAt "Hello" "First") >>= ok
    newer <- run editor (saveDraft hello.id hello.updatedAt "Hello" "Second") >>= ok
    newer.savedAt `shouldSatisfy` (>= older.savedAt)
    run editor (getDraft hello.id) `shouldReturn` Right (Just newer)

  it "keep a blank title, since a draft is not a page yet" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    d <- run editor (saveDraft hello.id hello.updatedAt "  " "") >>= ok
    d.title `shouldBe` "  "

  it "are private to their author, and never shown to readers of the page" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    _ <- run editor (saveDraft hello.id hello.updatedAt "Secret title" "zebracorn") >>= ok
    run admin (getDraft hello.id) `shouldReturn` Right Nothing
    pageAt run Anonymous "blog" "hello-world" `shouldReturn` hello
    pageAt run editor "blog" "hello-world" `shouldReturn` hello
    run editor (searchPages (searchQuery "zebracorn")) `shouldReturn` []

  it "are discarded by their author, and discarding none is no error" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    _ <- run editor (saveDraft hello.id hello.updatedAt "Hello" "Gone soon") >>= ok
    _ <- run admin (saveDraft hello.id hello.updatedAt "Hello" "The admin's") >>= ok
    run editor (discardDraft hello.id) >>= ok
    run editor (getDraft hello.id) `shouldReturn` Right Nothing
    run editor (discardDraft hello.id) >>= ok
    (fmap (fmap (\d -> d.body)) <$> run admin (getDraft hello.id)) `shouldReturn` Right (Just "The admin's")

  it "go when their author saves the page, and stay for others" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    _ <- run editor (saveDraft hello.id hello.updatedAt "Hello" "The editor's") >>= ok
    _ <- run admin (saveDraft hello.id hello.updatedAt "Hello" "The admin's") >>= ok
    _ <- run editor (savePage hello.id hello.updatedAt "Hello" "The editor's") >>= ok
    run editor (getDraft hello.id) `shouldReturn` Right Nothing
    -- The admin's is still there, from a version saved over since.
    (fmap (fmap (\d -> (d.body, d.base))) <$> run admin (getDraft hello.id)) `shouldReturn` Right (Just ("The admin's", hello.updatedAt))

  it "stay with a page that is moved, and go with one that is deleted" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    hello <- pageAt run admin "blog" "hello-world"
    notes <- pageAt run admin "blog" "notes-on-haskell"
    d <- run editor (saveDraft hello.id hello.updatedAt "Hello" "Kept") >>= ok
    _ <- run editor (movePage hello.id blog.id (Just notes.id)) >>= ok
    run editor (getDraft hello.id) `shouldReturn` Right (Just d)
    _ <- run editor (deletePage notes.id) >>= ok
    run editor (getDraft hello.id) >>= (`shouldFailWith` NotFound)
    -- A page made again gets a new id, and no draft.
    again <- run editor (createPage blog.id Nothing "Hello, world" "") >>= ok
    run editor (getDraft again.id) `shouldReturn` Right Nothing

  it "go with a space that is deleted" $ \(Fixture run) -> do
    guide <- pageAt run admin "docs" "markdown-guide"
    docs <- spaceAt run admin "docs"
    _ <- run admin (saveDraft guide.id guide.updatedAt "Guide" "Kept") >>= ok
    run admin (deleteSpace docs.id) >>= ok
    run admin (getDraft guide.id) >>= (`shouldFailWith` NotFound)

  it "take someone signed in with Edit on the page's space" $ \(Fixture run) -> do
    tour <- pageAt run admin "docs" "tour"
    wiki <- pageAt run admin "team/projects" "the-wiki"
    hello <- pageAt run admin "blog" "hello-world"
    for_ [(editor, tour), (reader, wiki), (Anonymous, hello)] $ \(who, p) -> do
      run who (getDraft p.id) >>= (`shouldFailWith` Forbidden)
      run who (saveDraft p.id p.updatedAt "X" "") >>= (`shouldFailWith` Forbidden)
      run who (discardDraft p.id) >>= (`shouldFailWith` Forbidden)
    run editor (getDraft (PageId "no-such-page")) >>= (`shouldFailWith` NotFound)
    run Anonymous (saveDraft (PageId "no-such-page") hello.updatedAt "X" "") >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- History

-- | A page's history as someone sees it, which must be there to see.
versionsOf :: (HasCallStack, MonadWiki m) => Run m -> As -> PageId -> IO [VersionInfo]
versionsOf run who p = run who (listVersions p) >>= ok

-- | Who someone is, as a history names them.
authorAs :: (HasCallStack, MonadWiki m) => Run m -> As -> IO Author
authorAs run who =
  run who currentUser >>= \case
    Just u -> pure Author {id = u.id, name = u.displayName}
    Nothing -> assertFailure "expected someone signed in"

history :: (MonadWiki m) => SpecWith (Fixture m)
history = describe "listVersions, getVersion and restoreVersion" $ do
  it "start a page's history with the page as it is, saved by nobody known" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    versionsOf run Anonymous hello.id
      `shouldReturn` [VersionInfo {page = hello.id, updatedAt = hello.updatedAt, title = hello.title, author = Nothing}]
    run Anonymous (getVersion hello.id hello.updatedAt)
      `shouldReturn` Right Version {page = hello.id, updatedAt = hello.updatedAt, title = hello.title, body = hello.body, author = Nothing}

  it "keep a version for a page made and for every save, the latest first, each with its author" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    made <- run editor (createPage blog.id Nothing "Kept" "First") >>= ok
    twice <- run editor (savePage made.id made.updatedAt "Kept" "Second") >>= ok
    third <- run admin (savePage made.id twice.updatedAt "Kept, again" "Third") >>= ok
    edgar <- authorAs run editor
    ada <- authorAs run admin
    vs <- versionsOf run reader made.id
    map (\v -> (v.updatedAt, v.title, v.author)) vs
      `shouldBe` [(third.updatedAt, "Kept, again", Just ada), (twice.updatedAt, "Kept", Just edgar), (made.updatedAt, "Kept", Just edgar)]
    bodies <- for vs $ \v -> (\x -> x.body) <$> (run Anonymous (getVersion made.id v.updatedAt) >>= ok)
    bodies `shouldBe` ["Third", "Second", "First"]

  it "make no version for a move or an attachment, and go with a page deleted" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    hello <- pageAt run admin "blog" "hello-world"
    notes <- pageAt run admin "blog" "notes-on-haskell"
    _ <- run editor (movePage hello.id blog.id (Just notes.id)) >>= ok
    _ <- run editor (uploadAttachment hello.id "a.txt" "text/plain" "a") >>= ok
    length <$> versionsOf run editor hello.id `shouldReturn` 1
    run editor (deletePage notes.id) >>= ok
    run editor (listVersions hello.id) >>= (`shouldFailWith` NotFound)
    run editor (getVersion hello.id hello.updatedAt) >>= (`shouldFailWith` NotFound)

  it "restore a version as a new save of its title and body, keeping every version" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    changed <- run editor (savePage hello.id hello.updatedAt "Changed" "Changed body") >>= ok
    restored <- run editor (restoreVersion hello.id hello.updatedAt changed.updatedAt) >>= ok
    (restored.title, restored.body, restored.slug) `shouldBe` (hello.title, hello.body, hello.slug)
    restored.updatedAt `shouldSatisfy` (> changed.updatedAt)
    pageAt run Anonymous "blog" "hello-world" `shouldReturn` restored
    edgar <- authorAs run editor
    map (\v -> (v.updatedAt, v.title, v.author)) <$> versionsOf run editor hello.id
      `shouldReturn` [(restored.updatedAt, hello.title, Just edgar), (changed.updatedAt, "Changed", Just edgar), (hello.updatedAt, hello.title, Nothing)]

  it "discard the restorer's draft, as a save does, and keep others'" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    changed <- run editor (savePage hello.id hello.updatedAt "Changed" "") >>= ok
    _ <- run editor (saveDraft hello.id changed.updatedAt "Changed" "Unsaved") >>= ok
    _ <- run admin (saveDraft hello.id changed.updatedAt "Changed" "The admin's") >>= ok
    _ <- run editor (restoreVersion hello.id hello.updatedAt changed.updatedAt) >>= ok
    run editor (getDraft hello.id) `shouldReturn` Right Nothing
    (fmap (fmap (\d -> d.body)) <$> run admin (getDraft hello.id)) `shouldReturn` Right (Just "The admin's")

  it "refuse a restore against a version saved over since, and change nothing" $ \(Fixture run) -> do
    hello <- pageAt run admin "blog" "hello-world"
    changed <- run editor (savePage hello.id hello.updatedAt "Changed" "") >>= ok
    run admin (restoreVersion hello.id hello.updatedAt hello.updatedAt) >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected Conflict, got " <> show other)
    pageAt run Anonymous "blog" "hello-world" `shouldReturn` changed
    length <$> versionsOf run admin hello.id `shouldReturn` 2

  it "show a history to whoever may view the page, and restore for whoever may edit it" $ \(Fixture run) -> do
    handbook <- pageAt run admin "team" "team-handbook"
    wiki <- pageAt run admin "team/projects" "the-wiki"
    tour <- pageAt run admin "docs" "tour"
    hello <- pageAt run admin "blog" "hello-world"
    -- Whoever may not view the page learns nothing of its history, not
    -- even whether a time is one of its versions.
    run Anonymous (listVersions handbook.id) >>= (`shouldFailWith` Forbidden)
    run Anonymous (getVersion handbook.id handbook.updatedAt) >>= (`shouldFailWith` Forbidden)
    run Anonymous (getVersion handbook.id hello.updatedAt) >>= (`shouldFailWith` Forbidden)
    run reader (listVersions wiki.id) >>= void . ok
    run reader (getVersion wiki.id wiki.updatedAt) >>= void . ok
    run reader (getVersion wiki.id hello.updatedAt) >>= (`shouldFailWith` NotFound)
    run reader (restoreVersion wiki.id wiki.updatedAt wiki.updatedAt) >>= (`shouldFailWith` Forbidden)
    run editor (restoreVersion tour.id tour.updatedAt tour.updatedAt) >>= (`shouldFailWith` Forbidden)
    run Anonymous (restoreVersion hello.id hello.updatedAt hello.updatedAt) >>= (`shouldFailWith` Forbidden)
    run Anonymous (restoreVersion hello.id tour.updatedAt hello.updatedAt) >>= (`shouldFailWith` Forbidden)
    run editor (restoreVersion hello.id tour.updatedAt hello.updatedAt) >>= (`shouldFailWith` NotFound)
    run editor (listVersions (PageId "no-such-page")) >>= (`shouldFailWith` NotFound)
    run editor (restoreVersion (PageId "no-such-page") hello.updatedAt hello.updatedAt) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Profiles

-- | A profile with these fields.
profile :: Text -> Maybe Icon -> Maybe PageId -> SpaceProfile
profile description icon homePage = SpaceProfile {description, icon, homePage}

-- | A 1×1 PNG, as an icon's bytes.
png :: ByteString
png =
  BS.pack
    [ 0x89
    , 0x50
    , 0x4e
    , 0x47
    , 0x0d
    , 0x0a
    , 0x1a
    , 0x0a
    , 0x00
    , 0x00
    , 0x00
    , 0x0d
    , 0x49
    , 0x48
    , 0x44
    , 0x52
    , 0x00
    , 0x00
    , 0x00
    , 0x01
    , 0x00
    , 0x00
    , 0x00
    , 0x01
    , 0x08
    , 0x06
    , 0x00
    , 0x00
    , 0x00
    , 0x1f
    , 0x15
    , 0xc4
    , 0x89
    , 0x00
    , 0x00
    , 0x00
    , 0x0d
    , 0x49
    , 0x44
    , 0x41
    , 0x54
    , 0x78
    , 0x9c
    , 0x63
    , 0xf8
    , 0xcf
    , 0xc0
    , 0xf0
    , 0x1f
    , 0x00
    , 0x05
    , 0x00
    , 0x01
    , 0xff
    , 0x89
    , 0x99
    , 0x3d
    , 0x1d
    , 0x00
    , 0x00
    , 0x00
    , 0x00
    , 0x49
    , 0x45
    , 0x4e
    , 0x44
    , 0xae
    , 0x42
    , 0x60
    , 0x82
    ]

profiles :: (MonadWiki m) => SpecWith (Fixture m)
profiles = describe "home pages, setSpaceProfile, uploadSpaceIcon and pageCounts" $ do
  it "gives the demo's spaces the home pages it chose" $ \(Fixture run) -> do
    docs <- spaceAt run Anonymous "docs"
    tour <- pageAt run Anonymous "docs" "tour"
    docs.homePage `shouldBe` Just tour.id

  it "makes a new space with a home page, made by its creator" $ \(Fixture run) -> do
    s <- run editor (createSpace Nothing "Team notes") >>= ok
    pages <- run editor (listPages s.id) >>= ok
    map (\p -> (p.title, slugText p.slug)) pages `shouldBe` [("Home", "home")]
    s.homePage `shouldBe` (\p -> p.id) <$> head pages
    for_ (head pages) $ \home -> do
      home.body `shouldSatisfy` T.isInfixOf "Team notes"
      versions <- versionsOf run editor home.id
      me <- authorAs run editor
      map (\v -> v.author) versions `shouldBe` [Just me]
    (s.description, s.icon) `shouldBe` ("", Nothing)
    found <- spaceAt run editor "team-notes"
    found `shouldBe` s

  it "sets a space's description, icon and home page, which every reader sees" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    guide <- pageAt run admin "docs" "markdown-guide"
    s <- run admin (setSpaceProfile docs.id (profile "  How to write here.  " (Just (IconEmoji " 📘")) (Just guide.id))) >>= ok
    (s.description, s.icon, s.homePage) `shouldBe` ("How to write here.", Just (IconEmoji "📘"), Just guide.id)
    (s.name, slugOf s, s.public, s.mathMacros) `shouldBe` (docs.name, slugOf docs, docs.public, docs.mathMacros)
    found <- spaceAt run Anonymous "docs"
    found `shouldBe` s
    listed <- run Anonymous listSpaces
    [x | x <- listed, x.id == docs.id] `shouldBe` [s]
    coloured <- run admin (setSpaceProfile docs.id (profile "" (Just (IconColour "teal")) Nothing)) >>= ok
    (coloured.description, coloured.icon, coloured.homePage) `shouldBe` ("", Just (IconColour "teal"), Nothing)

  it "refuses a home page of another space, a colour not in the palette, a blank emoji and an image not uploaded" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    hello <- pageAt run admin "blog" "hello-world"
    run admin (setSpaceProfile docs.id (profile "" Nothing (Just hello.id))) >>= shouldBeInvalid
    run admin (setSpaceProfile docs.id (profile "" Nothing (Just (PageId "no-such-page")))) >>= shouldBeInvalid
    run admin (setSpaceProfile docs.id (profile "" (Just (IconColour "#123456")) Nothing)) >>= shouldBeInvalid
    run admin (setSpaceProfile docs.id (profile "" (Just (IconEmoji " ")) Nothing)) >>= shouldBeInvalid
    run admin (setSpaceProfile docs.id (profile "" (Just (IconImage (BlobId "elsewhere") "image/png")) Nothing)) >>= shouldBeInvalid
    run admin (setSpaceProfile docs.id (profile (T.replicate 501 "x") Nothing Nothing)) >>= shouldBeInvalid
    unchanged <- spaceAt run admin "docs"
    unchanged `shouldBe` docs

  it "takes AdministerSpace, checked before the profile" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    team <- spaceAt run admin "team"
    let bad = profile "" (Just (IconColour "nope")) Nothing
    run editor (setSpaceProfile blog.id bad) >>= (`shouldFailWith` Forbidden)
    run Anonymous (setSpaceProfile blog.id bad) >>= (`shouldFailWith` Forbidden)
    run reader (setSpaceProfile team.id bad) >>= (`shouldFailWith` Forbidden)
    run editor (uploadSpaceIcon blog.id "image/png" png) >>= (`shouldFailWith` Forbidden)
    run Anonymous (uploadSpaceIcon blog.id "text/html" "<p>") >>= (`shouldFailWith` Forbidden)
    run admin (setSpaceProfile (SpaceId "no-such-space") bad) >>= (`shouldFailWith` NotFound)
    run admin (uploadSpaceIcon (SpaceId "no-such-space") "image/png" png) >>= (`shouldFailWith` NotFound)
    mine <- run editor (createSpace Nothing "Mine") >>= ok
    void (run editor (setSpaceProfile mine.id (profile "Mine alone." Nothing mine.homePage)) >>= ok)

  it "pictures a space with an uploaded image, at an address of the backend's, until the profile drops it" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    run admin (spaceIconUrl blog) `shouldReturn` ""
    s <- run admin (uploadSpaceIcon blog.id "image/png" png) >>= ok
    case s.icon of
      Just (IconImage _ mediaType) -> mediaType `shouldBe` "image/png"
      other -> expectationFailure ("expected an image, got " <> show other)
    (s.description, s.homePage) `shouldBe` (blog.description, blog.homePage)
    seen <- spaceAt run Anonymous "blog"
    seen.icon `shouldBe` s.icon
    run Anonymous (spaceIconUrl seen) >>= (`shouldSatisfy` (not . T.null))
    -- Kept as it is when the profile names it, let go when it does not.
    kept <- run admin (setSpaceProfile blog.id (profile "Posts." s.icon s.homePage)) >>= ok
    kept.icon `shouldBe` s.icon
    dropped <- run admin (setSpaceProfile blog.id (profile "Posts." (Just (IconEmoji "✍️")) s.homePage)) >>= ok
    dropped.icon `shouldBe` Just (IconEmoji "✍️")
    run admin (spaceIconUrl dropped) `shouldReturn` ""

  it "refuses an icon that is not an image a browser shows, an empty one and one too large" $ \(Fixture run) -> do
    blog <- spaceAt run admin "blog"
    run admin (uploadSpaceIcon blog.id "image/svg+xml" "<svg/>") >>= shouldBeInvalid
    run admin (uploadSpaceIcon blog.id "text/html" "<p>") >>= shouldBeInvalid
    run admin (uploadSpaceIcon blog.id "image/png" "") >>= shouldBeInvalid
    run admin (uploadSpaceIcon blog.id "image/png" (BS.replicate (fromIntegral maxIconSize + 1) 0)) >>= shouldBeInvalid
    unchanged <- spaceAt run admin "blog"
    unchanged.icon `shouldBe` blog.icon

  it "leaves a space without a home page when the page is deleted or moved to another space" $ \(Fixture run) -> do
    docs <- spaceAt run admin "docs"
    blog <- spaceAt run admin "blog"
    tour <- pageAt run admin "docs" "tour"
    guide <- pageAt run admin "docs" "markdown-guide"
    -- Moved within the space, it stays the home page.
    _ <- run admin (movePage tour.id docs.id (Just guide.id)) >>= ok
    (\x -> x.homePage) <$> spaceAt run admin "docs" `shouldReturn` Just tour.id
    _ <- run admin (movePage tour.id blog.id Nothing) >>= ok
    (\x -> x.homePage) <$> spaceAt run admin "docs" `shouldReturn` Nothing
    _ <- run admin (setSpaceProfile docs.id (profile "" Nothing (Just guide.id))) >>= ok
    -- A page under the home page moved away takes nothing with it.
    diagrams <- pageAt run admin "docs" "markdown-guide/diagrams"
    _ <- run admin (movePage diagrams.id blog.id Nothing) >>= ok
    (\x -> x.homePage) <$> spaceAt run admin "docs" `shouldReturn` Just guide.id
    run admin (deletePage guide.id) >>= ok
    (\x -> x.homePage) <$> spaceAt run admin "docs" `shouldReturn` Nothing

  it "count the pages of each space someone may view" $ \(Fixture run) -> do
    let countsOf who = do
          counts <- run who pageCounts
          spaces <- run who listSpaces
          pure (sort [(x.name, n) | x <- spaces, Just n <- [Map.lookup x.id counts]])
    countsOf Anonymous `shouldReturn` [("Blog", 2), ("Docs", 5)]
    countsOf admin `shouldReturn` [("Blog", 2), ("Docs", 5), ("Projects", 1), ("Team", 2)]
    -- Team is listed to the reader for its name only.
    countsOf reader `shouldReturn` [("Blog", 2), ("Docs", 5), ("Projects", 1)]
    s <- run editor (createSpace Nothing "Mine") >>= ok
    counts <- run editor pageCounts
    Map.lookup s.id counts `shouldBe` Just 1

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
          , void <$> setSpaceProfile s SpaceProfile {description = "", icon = Nothing, homePage = Nothing}
          , void <$> uploadSpaceIcon s "image/png" png
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
          , void <$> getDraft p
          , void <$> saveDraft p hello.updatedAt "X" ""
          , discardDraft p
          , void <$> listVersions p
          , void <$> getVersion p hello.updatedAt
          , void <$> restoreVersion p hello.updatedAt hello.updatedAt
          ]
    for_ [Anonymous, admin] $ \who -> for_ (zip [0 :: Int ..] calls) $ \(i, call) -> do
      result <- try (run who call >>= evaluate)
      case result of
        Left (e :: SomeException) -> expectationFailure ("call " <> show i <> " threw " <> show e)
        Right (Left _) -> pass
        Right (Right ()) -> expectationFailure ("call " <> show i <> " succeeded")
