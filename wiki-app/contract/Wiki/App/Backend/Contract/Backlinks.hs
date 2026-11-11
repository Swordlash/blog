-- | The contract tests of a page's backlinks ('pageBacklinks', issue
-- #189): the pages that link to a page, as "Wiki.App.Backlinks" counts a
-- link. The demo's backend finds them by following every page's links
-- each time; the server keeps them in a table and follows a link again
-- when a change to the tree may lead it elsewhere. Each case here is a
-- sequence of changes after which the two must still agree: the list is
-- always what following the links now gives.
--
-- Like the backend's contract ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), it runs against the in-memory backend, the server's
-- storage on each database, and the HTTP backend against the server's API.
-- The demo's @admin@ may do anything; its @editor@ may edit the public
-- blog; its @reader@ may read the blog and the docs, and of the team's
-- spaces only its projects.
module Wiki.App.Backend.Contract.Backlinks (spec) where

import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.App.Backend
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.Core.Backlink (Backlink (..))
import Wiki.Core.Id
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (VersionInfo (..), VersionsQuery (VersionsQuery))

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as in
-- "Wiki.App.Backend.Contract".
spec :: forall m -> (MonadWiki m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "pageBacklinks contract" $ do
  forms
  creating
  movingTargets
  movingSources
  deletingTargets
  movingSpaces
  savingSources
  reading
  counting

--------------------------------------------------------------------------------
-- Helpers

ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

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

-- | A new page, made by the administrator at the top of a space's pages.
made :: (HasCallStack, MonadWiki m) => Run m -> Space -> Text -> Text -> IO Page
made run space title body = run admin (createPage space.id Nothing title body) >>= ok

-- | A new page under another.
madeUnder :: (HasCallStack, MonadWiki m) => Run m -> Page -> Text -> Text -> IO Page
madeUnder run parent title body = run admin (createPage parent.space (Just parent.id) title body) >>= ok

-- | The ids of the pages that link to a page, as someone reads them.
linking :: (HasCallStack, MonadWiki m) => Run m -> As -> Page -> IO [PageId]
linking run who p = map (\b -> b.page) <$> (run who (pageBacklinks p.id) >>= ok)

-- | A page's permanent address, which names it by its id.
byId :: Page -> Text
byId p = "/l/" <> p.id.text <> "/"

--------------------------------------------------------------------------------
-- What counts as a link

forms :: (MonadWiki m) => SpecWith (Fixture m)
forms = describe "what counts as a link" $ do
  it "counts every form of a link to a page the page shows, and nothing else" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" ""
    let counts =
          [ ("a wiki link", "See [[Target]].")
          , ("a relative path", "See [it](target).")
          , ("a path from the top", "See [it](/docs/target).")
          , ("the page's own address", "See [it](/s/docs/p/target/).")
          , ("a permanent address", "See [it](" <> byId target <> ").")
          , ("a permanent address of a version", "See [it](" <> byId target <> "?version=2026-11-01T10:00:00Z).")
          , ("a path with a fragment", "See [it](target#section).")
          , ("an embed of the page", "![it](target)")
          , ("a link in raw HTML", "<a href=\"target\">it</a>")
          , ("a link in a raw block", "<div>\n<a href=\"/docs/target\">it</a>\n</div>")
          ]
        none =
          [ ("a link in code", "`[it](target)`")
          , ("a link in a fence", "```\n[it](target)\n```")
          , -- Its links are in its frame, not on the page (WP5.89).
            ("a link in an html fence", "```html\n<a href=\"target\">it</a>\n```")
          , ("a link in a latex fence", "```latex\n\\href{target}{it}\n```")
          , ("a link in a listing made with norender", "```html {.norender}\n<a href=\"target\">it</a>\n```")
          , ("a fragment on the same page", "See [it](#target).")
          , ("an external URL", "See [it](https://example.com/docs/target).")
          , ("an attachment", "See [it](attachment:target).")
          , ("an image's source in raw HTML", "<img src=\"target\">")
          , ("a link to another page", "See [[Markdown guide]].")
          ]
    sources <- for (counts <> none) $ \(title, body) -> (title,) <$> made run docs title body
    found <- linking run admin target
    sort found `shouldBe` sort [p.id | (title, p) <- sources, title `elem` map fst counts]

  it "lists a page that links twice once, and not a page's link to itself" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" "Myself: [[Target]], [me](target)."
    twice <- made run docs "Twice" ("[[Target]], [again](/docs/target), [by id](" <> byId target <> ").")
    run admin (pageBacklinks target.id)
      `shouldReturn` Right [Backlink {page = twice.id, title = "Twice", location = PageLocation {space = path "docs", page = path "twice"}}]
    linking run admin twice `shouldReturn` []

--------------------------------------------------------------------------------
-- Changes to the tree

creating :: (MonadWiki m) => SpecWith (Fixture m)
creating = describe "a page created" $ do
  it "lists a page that linked to its path before it was there" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    source <- made run docs "Source" "Not written yet: [[Later]], [later](/docs/later/below)."
    later <- made run docs "Later" ""
    linking run admin later `shouldReturn` [source.id]
    below <- madeUnder run later "Below" ""
    linking run admin below `shouldReturn` [source.id]

  -- The route codec decodes a page's own address; the name the server
  -- marks the link by must be the slug it decodes to.
  it "lists a page that linked to its own address, percent-encoded, before it was there" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    source <- made run docs "Source" "[it](/s/docs/p/%74arget/), [again](/s/docs/p/t%61rget/b%65low/)"
    target <- made run docs "Target" ""
    linking run admin target `shouldReturn` [source.id]
    below <- madeUnder run target "Below" ""
    linking run admin below `shouldReturn` [source.id]

  it "takes a link that an old address led elsewhere, once a page is at that address as written" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    tour <- pageAt run "docs" ""
    -- The home page's slug, before a page's own: an old address, read
    -- again without the home page's segment.
    source <- made run docs "Source" ("[it](" <> slugText tour.slug <> "/spot)")
    spot <- made run docs "Spot" ""
    linking run admin spot `shouldReturn` [source.id]
    -- A page with the home page's slug, and one under it at the address.
    homonym <- made run docs tour.title ""
    exact <- madeUnder run homonym "Spot" ""
    linking run admin exact `shouldReturn` [source.id]
    linking run admin spot `shouldReturn` []

movingTargets :: (MonadWiki m) => SpecWith (Fixture m)
movingTargets = describe "a page moved" $ do
  it "no longer lists a link by its old path, and still lists a link by its id" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    team <- spaceAt run "team"
    target <- made run docs "Target" ""
    byPath <- made run docs "By path" "[[Target]]"
    byIdSource <- made run docs "By id" ("[it](" <> byId target <> ")")
    sort <$> linking run admin target `shouldReturn` sort [byPath.id, byIdSource.id]
    aside <- made run docs "Aside" ""
    void (run admin (movePage target.id docs.id (Just aside.id)) >>= ok)
    linking run admin target `shouldReturn` [byIdSource.id]
    -- A page now at the old path is the one the path leads to.
    again <- made run docs "Target" ""
    linking run admin again `shouldReturn` [byPath.id]
    void (run admin (movePage target.id team.id Nothing) >>= ok)
    linking run admin target `shouldReturn` [byIdSource.id]

  it "lists a link that its new path is written as" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    aside <- made run docs "Aside" ""
    target <- made run docs "Target" ""
    source <- made run docs "Source" "[it](aside/target)"
    linking run admin target `shouldReturn` []
    void (run admin (movePage target.id docs.id (Just aside.id)) >>= ok)
    linking run admin target `shouldReturn` [source.id]

movingSources :: (MonadWiki m) => SpecWith (Fixture m)
movingSources = describe "a linking page moved" $ do
  it "has its relative links read from where it is now" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    folder <- made run docs "Folder" ""
    sibling <- made run docs "Sibling" ""
    source <- made run docs "Source" "[[Sibling]] and [here](.)"
    linking run admin sibling `shouldReturn` [source.id]
    linking run admin folder `shouldReturn` []
    void (run admin (movePage source.id docs.id (Just folder.id)) >>= ok)
    linking run admin sibling `shouldReturn` []
    -- The links now name pages under the folder, and @.@ the folder.
    linking run admin folder `shouldReturn` [source.id]
    under <- madeUnder run folder "Sibling" ""
    linking run admin under `shouldReturn` [source.id]

  it "has the links of the pages under it read from where they are now" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    team <- spaceAt run "team"
    parent <- made run docs "Parent" ""
    child <- madeUnder run parent "Child" "[[Neighbour]]"
    neighbour <- madeUnder run parent "Neighbour" ""
    linking run admin neighbour `shouldReturn` [child.id]
    void (run admin (movePage neighbour.id docs.id Nothing) >>= ok)
    linking run admin neighbour `shouldReturn` []
    moved <- run admin (movePage parent.id team.id Nothing) >>= ok
    teamNeighbour <- madeUnder run moved "Neighbour" ""
    linking run admin teamNeighbour `shouldReturn` [child.id]

deletingTargets :: (MonadWiki m) => SpecWith (Fixture m)
deletingTargets = describe "a page deleted" $ do
  it "lists the links to its path on the page made there next, and is listed nowhere" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" "[[Other]]"
    other <- made run docs "Other" ""
    source <- made run docs "Source" "[[Target]]"
    linking run admin target `shouldReturn` [source.id]
    linking run admin other `shouldReturn` [target.id]
    run admin (deletePage target.id) >>= ok
    run admin (pageBacklinks target.id) `shouldReturn` Left NotFound
    linking run admin other `shouldReturn` []
    again <- made run docs "Target" ""
    linking run admin again `shouldReturn` [source.id]

  it "goes with its space, and the links to it with it" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    gone <- run admin (createSpace Nothing "Gone") >>= ok
    inside <- made run gone "Inside" "[[/docs/kept]]"
    kept <- made run docs "Kept" ""
    source <- made run docs "Source" ("[it](/gone/inside) [again](" <> byId inside <> ")")
    linking run admin kept `shouldReturn` [inside.id]
    linking run admin inside `shouldReturn` [source.id]
    run admin (deleteSpace gone.id) >>= ok
    linking run admin kept `shouldReturn` []
    again <- run admin (createSpace Nothing "Gone") >>= ok
    another <- made run again "Inside" ""
    linking run admin another `shouldReturn` [source.id]

movingSpaces :: (MonadWiki m) => SpecWith (Fixture m)
movingSpaces = describe "a space moved" $ do
  it "no longer lists the links by its pages' old addresses, and still lists those by id" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    team <- spaceAt run "team"
    alpha <- run admin (createSpace Nothing "Alpha") >>= ok
    gamma <- made run alpha "Gamma" ""
    byPath <- made run docs "By path" "[it](/alpha/gamma) and [its space](/alpha)"
    byIdSource <- made run docs "By id" ("[it](" <> byId gamma <> ")")
    sort <$> linking run admin gamma `shouldReturn` sort [byPath.id, byIdSource.id]
    home <- run admin (getPage alpha.id []) >>= ok
    linking run admin home `shouldReturn` [byPath.id]
    void (run admin (moveSpace alpha.id (Just team.id)) >>= ok)
    linking run admin gamma `shouldReturn` [byIdSource.id]
    linking run admin home `shouldReturn` []
    -- The links by its new address.
    newPath <- made run docs "New path" "[it](/team/alpha/gamma)"
    sort <$> linking run admin gamma `shouldReturn` sort [byIdSource.id, newPath.id]

  it "lists a link by a path from the top once a space is there" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    source <- made run docs "Source" "[it](/beta/delta)"
    beta <- run admin (createSpace Nothing "Beta") >>= ok
    delta <- made run beta "Delta" ""
    linking run admin delta `shouldReturn` [source.id]

--------------------------------------------------------------------------------
-- Changes to the linking page's text

savingSources :: (MonadWiki m) => SpecWith (Fixture m)
savingSources = describe "a linking page saved" $ do
  it "drops a link saved away, and lists it again once a version that has it is restored" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" ""
    source <- made run docs "Source" "[[Target]]"
    linking run admin target `shouldReturn` [source.id]
    saved <- run admin (savePage source.id source.updatedAt "Source" "No link now.") >>= ok
    linking run admin target `shouldReturn` []
    versions <- run admin (listVersions source.id (VersionsQuery Nothing 10)) >>= ok
    first' <- maybe (assertFailure "no first version") pure (lastMay versions)
    void (run admin (restoreVersion source.id first'.updatedAt saved.updatedAt) >>= ok)
    linking run admin target `shouldReturn` [source.id]

  it "lists a link added by a save" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" ""
    source <- made run docs "Source" ""
    void (run admin (savePage source.id source.updatedAt "Source" "Now: [[Target]]") >>= ok)
    linking run admin target `shouldReturn` [source.id]

--------------------------------------------------------------------------------
-- Who reads the list

reading :: (MonadWiki m) => SpecWith (Fixture m)
reading = describe "who reads the list" $ do
  it "holds only the pages the reader may view, and says nothing of the others" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    team <- spaceAt run "team"
    projects <- spaceAt run "team/projects"
    target <- made run docs "Target" ""
    secret <- made run team "Secret" "[[/docs/target]]"
    shared <- made run projects "Shared" "[[/docs/target]]"
    open <- made run docs "Open" "[[Target]]"
    sort <$> linking run admin target `shouldReturn` sort [secret.id, shared.id, open.id]
    sort <$> linking run reader target `shouldReturn` sort [shared.id, open.id]
    linking run Anonymous target `shouldReturn` [open.id]
    linking run editor target `shouldReturn` [open.id]

  -- A click follows a path from the top among the spaces whose paths the
  -- reader can see: where a space they may not see would take the path,
  -- the list must follow it as their click does, or it would tell them
  -- the space is there.
  it "follows a path as the reader's click does, so that a space they may not see changes nothing" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    hidden <- run admin (createSpace (Just docs.id) "Hidden") >>= ok
    void (run admin (setSpaceSealed hidden.id True) >>= ok)
    homonym <- made run docs "Hidden" ""
    inner <- made run hidden "Inner" ""
    source <- made run docs "Source" "[a](/docs/hidden) and [b](/docs/hidden/inner)"
    hiddenHome <- run admin (getPage hidden.id []) >>= ok
    -- For whoever sees the subspace, the paths lead into it.
    linking run admin homonym `shouldReturn` []
    linking run admin hiddenHome `shouldReturn` [source.id]
    linking run admin inner `shouldReturn` [source.id]
    -- For whoever does not, the first leads to the page of Docs, as their
    -- click does, and the second nowhere.
    for_ [Anonymous, editor, reader] $ \who ->
      linking run who homonym `shouldReturn` [source.id]

  it "is not found for a page the reader may not view, as for a page that is not there" $ \(Fixture run) -> do
    team <- spaceAt run "team"
    secret <- made run team "Secret" ""
    for_ [Anonymous, editor, reader] $ \who -> do
      run who (pageBacklinks secret.id) `shouldReturn` Left NotFound
      run who (pageBacklinks (PageId "no-such-page")) `shouldReturn` Left NotFound

  it "lists each page with its title and where it is now, by title" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    target <- made run docs "Target" ""
    folder <- made run docs "Folder" ""
    b <- madeUnder run folder "Page 10" "[[/docs/target]]"
    a <- made run docs "Page 9" "[[Target]]"
    run reader (pageBacklinks target.id)
      `shouldReturn` Right
        [ Backlink {page = a.id, title = "Page 9", location = PageLocation {space = path "docs", page = path "page-9"}}
        , Backlink {page = b.id, title = "Page 10", location = PageLocation {space = path "docs", page = path "folder/page-10"}}
        ]

--------------------------------------------------------------------------------
-- Pages that have no list

counting :: (MonadWiki m) => SpecWith (Fixture m)
counting = describe "pages that have no list" $ do
  it "gives the front page none" $ \(Fixture run) -> do
    (_, home) <- run admin getHomeDocument >>= ok
    run admin (pageBacklinks home.id) `shouldReturn` Right []

  it "gives a page nothing links to an empty list" $ \(Fixture run) -> do
    docs <- spaceAt run "docs"
    lonely <- made run docs "Lonely" ""
    run Anonymous (pageBacklinks lonely.id) `shouldReturn` Right []
