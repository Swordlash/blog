-- | A presentation embedded in a page, and the page view of a
-- presentation (WP5.97 of docs/PLAN.md), in a browser, in the shell, over
-- the demo's wiki: the viewer is the link until it comes near the window,
-- then shows a slide at a time with its controls,
-- and its keys only while it has the focus; a page the reader may not
-- read, and a document, are what the embed shows without the class, with
-- nothing of the page in the page, in memory and over HTTP; a page that
-- embeds itself shows one viewer, with a link inside it; and the page view
-- of a presentation shows the viewer above the page as a document.
module Test.Browser.DeckViewer (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerRaw, asked, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (slugs, start, startOn, startWith)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (SpacesApi (..), WikiApi (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki, switchUser)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page (Page (body, id, title, updatedAt))
import Wiki.Core.Space (Space (id))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "shows a presentation embedded in a page a slide at a time, with its controls, and moves by its own keys only" $ runPage $ do
    ui <- start m Nothing (Page docs guide)
    -- Far down the page, it is the link until it comes near the window.
    length <$> findAll ui ".deck-embed" `shouldReturn` 0
    bringNear ui
    viewer <- find ui "article.page-body .deck-embed"
    position ui `shouldReturn` "1 / 9"
    cardTitle ui "article.page-body" `shouldReturn` "Presentations"
    find ui "article.page-body .deck-embed-present" >>= (`getAttribute` "href") >>= (`shouldSatisfy` maybe False (T.isInfixOf "/slides/"))
    find ui "article.page-body .deck-embed-last" >>= click
    eventually $ position ui `shouldReturn` "9 / 9"
    find ui "article.page-body .deck-embed-first" >>= click
    eventually $ position ui `shouldReturn` "1 / 9"
    -- Its keys, while it has the focus.
    focus viewer
    press "End"
    eventually $ position ui `shouldReturn` "9 / 9"
    press "Home"
    eventually $ position ui `shouldReturn` "1 / 9"
    replicateM_ 4 (press "ArrowRight")
    eventually $ position ui >>= (`shouldNotBe` "1 / 9")
    press "Home"
    eventually $ position ui `shouldReturn` "1 / 9"
    -- Not the page's: with the focus out of it, the keys move nothing.
    find ui "article.page-body > p" >>= click
    for_ ["End", "ArrowRight", "ArrowRight"] press
    position ui `shouldReturn` "1 / 9"

  it "is the link it is without the class for a page the reader cannot see or that is a document, with nothing of the page in the page" $ runPage $ do
    let embeds =
          T.intercalate
            "\n\n"
            [ "# Hello, world"
            , "![Handbook](/s/team/p/team-handbook/){.presentation}"
            , "![Handbook](/s/team/p/team-handbook/)"
            , "![Diagrams](/s/docs/p/markdown-guide/diagrams/){.presentation}"
            , "![Diagrams](/s/docs/p/markdown-guide/diagrams/)"
            , "![Talk](/s/docs/p/markdown-guide/presentations/){.presentation}"
            ]
    (ui, wiki) <- changed [(["blog"], ["hello-world"], embeds)] (Just "user-reader") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    -- The presentation the reader may read is shown, fetched with the
    -- others.
    _ <- find ui "article.page-body .deck-embed"
    paragraphs <- findAll ui "article.page-body > p" >>= traverse outerHTML
    case paragraphs of
      [handbook, handbookLink, diagrams, diagramsLink, _] -> do
        handbook `shouldBe` handbookLink
        diagrams `shouldBe` diagramsLink
      _ -> expectationFailure ("five paragraphs, not " <> show (length paragraphs))
    diagramsBody <- unsafeIOToPageM . runMemWiki wiki $ do
      space <- either (panic . show) identity <$> getSpace (slugs ["docs"])
      (\p -> p.body) . either (panic . show) identity <$> getPage space.id (slugs ["markdown-guide", "diagrams"])
    shown <- find ui ".wiki" >>= textContent
    [l | l <- map T.strip (T.lines diagramsBody), T.length l > 30, not (T.isPrefixOf "#" l), l `T.isInfixOf` shown] `shouldBe` []

  it "is the link it is without the class when the server refuses the page, over HTTP" $ runPage $ do
    serverStarts
    serveDemo
    docsId <- unsafeIOToPageM $ do
      demo <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
      runMemWiki demo ((\s -> s.id) . either (panic . show) identity <$> getSpace (slugs ["docs"]))
    let refused = endpointUrl (\e -> e.spaces.pageAt docsId (slugs ["markdown-guide", "presentations"]))
    answerRaw "GET" refused 403 "{\"error\":\"forbidden\",\"message\":\"Forbidden\"}"
    ui <- startServer m (Page docs guide)
    _ <- find ui "article.page-body h1"
    bringNear ui
    eventually $ ((\r -> r.url) <$>) <$> asked >>= (`shouldSatisfy` elem refused)
    -- Refused: the link, as without the class, and no banner.
    eventually $ find ui "article.page-body > p > a[href$='markdown-guide/presentations/']:only-child" >>= (`shouldHaveText` "Presentations")
    length <$> findAll ui ".deck-embed" `shouldReturn` 0
    length <$> findAll ui ".error, [role=alert]" `shouldReturn` 0
    find ui ".wiki" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "Euler's identity"))

  it "shows one viewer for a presentation that embeds itself, with its link inside it" $ runPage $ do
    (ui, wiki) <- changed [] Nothing (Page docs guide)
    unmount ui
    deck <- unsafeIOToPageM . runMemWiki wiki $ do
      space <- either (panic . show) identity <$> getSpace (slugs ["docs"])
      (\p -> p.body) . either (panic . show) identity <$> getPage space.id presentations
    (shown, _) <- changed [(["docs"], ["markdown-guide", "presentations"], deck <> "\n\n## Itself\n\n![Itself](/s/docs/p/markdown-guide/presentations/){.presentation}\n")] Nothing (Page docs presentations)
    _ <- find shown ".page-deck .deck-embed"
    find shown "article.page-body > p > a[href$='markdown-guide/presentations/']:only-child" >>= focus
    eventually $ length <$> findAll shown "article.page-body .deck-embed" `shouldReturn` 1
    length <$> findAll shown ".deck-embed .deck-embed" `shouldReturn` 0
    -- Inside each viewer, the embed is its link.
    length <$> findAll shown ".page-deck .deck-embed a[href$='markdown-guide/presentations/']" `shouldReturn` 1
    length <$> findAll shown "article.page-body .deck-embed a[href$='markdown-guide/presentations/']" `shouldReturn` 1

  it "shows a presentation's page as the viewer above the page as a document, with Present, its contents and its headings' links" $ runPage $ do
    ui <- start m Nothing (Page docs presentations)
    _ <- find ui ".page-deck .deck-embed"
    position ui `shouldReturn` "1 / 9"
    length <$> findAll ui ".page-actions a.page-present" `shouldReturn` 1
    -- The page as a document, under the viewer.
    length <$> findAll ui "article.page-body > h2" >>= (`shouldSatisfy` (> 0))
    length <$> findAll ui "article.page-body > h2 .heading-anchor" >>= (`shouldSatisfy` (> 0))
    length <$> findAll ui ".page-contents" `shouldReturn` 1
    order <- findAll ui ".page-deck, article.page-body" >>= traverse classes
    map (elem "page-deck") order `shouldBe` [True, False]
  where
    docs = slugs ["docs"]
    guide = slugs ["markdown-guide"]
    presentations = slugs ["markdown-guide", "presentations"]

    -- The shell at a route, as someone (or nobody), over the demo with
    -- these pages' texts saved first.
    changed :: forall s. [([Text], [Text], Text)] -> Maybe Text -> Route -> PageM s (Mounted s Shell.Query Void m, IORef MemState)
    changed changes who at = do
      (opener, wiki) <- startWith m (Just "user-admin") (Page (slugs ["blog"]) (slugs ["hello-world"]))
      unmount opener
      unsafeIOToPageM . runMemWiki wiki $ do
        for_ changes $ \(sp, pp, text) -> do
          space <- either (panic . show) identity <$> getSpace (slugs sp)
          p <- either (panic . show) identity <$> getPage space.id (slugs pp)
          void (savePage p.id p.updatedAt p.title text)
        switchUser (UserId <$> who)
      ui <- startOn m wiki at
      pure (ui, wiki)

-- | Bring the guide's embedded presentation near the window: the focus on
-- its link scrolls to it.
bringNear :: Mounted s q o m -> PageM s ()
bringNear ui = find ui "article.page-body > p > a[href$='markdown-guide/presentations/']:only-child" >>= focus

-- | The slide's number out of the deck's, as the page's first viewer
-- shows it.
position :: Mounted s q o m -> PageM s Text
position ui = find ui ".deck-embed .deck-embed-position" >>= textContent

-- | The title of the slide a viewer shows.
cardTitle :: Mounted s q o m -> Text -> PageM s Text
cardTitle ui within = find ui (within <> " .deck-embed .slide-frame:not(.slide-offstage) .slide-title") >>= textContent
