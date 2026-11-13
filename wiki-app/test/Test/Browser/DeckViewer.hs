{-# LANGUAGE TemplateHaskell #-}

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
import Data.Aeson (FromJSON (..), decodeStrict, withObject, (.:))
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.Router.Duplex qualified as Duplex
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerRaw, asked, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (slugs, start, startOn, startWith)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (SpacesApi (..), WikiApi (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki, switchUser)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..), route)
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Id
  ( PageId (..)
  , UserId (..)
  )
import Wiki.Core.Page (Page (body, id, title, updatedAt))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Space (Space (id))

$( browserJS
     ["jsbits/test-slides.js"]
     [ ("js_ids_report", "wiki_test_ids_report", Safe, [t|IO JSText|])
     ]
 )

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
    -- The request starts when the browser's IntersectionObserver says the
    -- link has come near the window, which takes the browser its own time
    -- on a loaded machine: a long deadline, not the two seconds of
    -- 'eventually' (seen to run out in CI on 2026-11-12).
    eventuallyWithin 30000 $ ((\r -> r.url) <$>) <$> asked >>= (`shouldSatisfy` elem refused)
    -- The test's fetch answers at once, in promises; settle lets the tasks
    -- queued by then run (the program's handling of the answer among them,
    -- as a task of the wasm runtime) before anything is read. hspec-halogen
    -- has no wait for the program to be quiet; this is the nearest.
    settle
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
  it "drops a private deck it shows when the reader changes, holding none of its text, and reads it again for one who may" $ runPage $ do
    (opener, wiki) <- startWith m (Just "user-admin") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    unmount opener
    secret <- unsafeIOToPageM . runMemWiki wiki $ do
      team <- either (panic . show) identity <$> getSpace (slugs ["team"])
      made <- either (panic . show) identity <$> createPageOf Kind.Presentation team.id Nothing "Secret deck" "# Secret deck\n\n## Plans\n\nThe merger closes on Friday."
      hello <- either (panic . show) identity <$> getPage' "blog" ["hello-world"]
      void (savePage hello.id hello.updatedAt hello.title ("# Hello, world\n\n![Deck](/l/" <> made.id.text <> "/){.presentation}\n\n![Deck](/l/" <> made.id.text <> "/)\n"))
      pure made
    ui <- startOn m wiki (Page (slugs ["blog"]) (slugs ["hello-world"]))
    let theLink = "article.page-body > p > a[href*='/l/" <> secret.id.text <> "/']:only-child"
    find ui theLink >>= focus
    eventually $ find ui "article.page-body .deck-embed" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The merger closes on Friday.")
    -- Signed in as someone who may not read Team: the link, as the embed
    -- without the class, and none of the deck's text.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=reader]" >>= click
    eventually $ length <$> findAll ui ".deck-embed" `shouldReturn` 0
    find ui ".wiki" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "The merger"))
    eventually $ do
      paragraphs <- findAll ui "article.page-body > p" >>= traverse outerHTML
      case paragraphs of
        [embedded, plain] -> embedded `shouldBe` plain
        _ -> expectationFailure ("two paragraphs, not " <> show (length paragraphs))
    -- Back to one who may: read again, once near the window.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui theLink >>= focus
    eventually $ find ui "article.page-body .deck-embed" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The merger closes on Friday.")

  it "keeps its ids apart from the page's and from another viewer's, its footnotes' links in itself, and the contents' links in the page" $ runPage $ do
    (opener, wiki) <- startWith m (Just "user-admin") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    unmount opener
    unsafeIOToPageM . runMemWiki wiki $ do
      deck <- either (panic . show) identity <$> getPage' "docs" ["markdown-guide", "presentations"]
      void (savePage deck.id deck.updatedAt deck.title (deck.body <> "\n\n## Noted\n\nA claim[^c].\n\n[^c]: The source.\n"))
      hello <- either (panic . show) identity <$> getPage' "blog" ["hello-world"]
      let embed = "![Talk](/s/docs/p/markdown-guide/presentations/){.presentation}"
      void (savePage hello.id hello.updatedAt hello.title ("# Hello, world\n\n" <> embed <> "\n\nBetween.\n\n" <> embed <> "\n"))
    -- On the presentation's page, the viewer above the page.
    shown <- startOn m wiki (Page docs presentations)
    _ <- find shown ".page-deck .deck-embed"
    _ <- find shown ".page-contents"
    report `shouldReturn` Report [] [] []
    unmount shown
    -- Two viewers of one deck on one page.
    ui <- startOn m wiki (Page (slugs ["blog"]) (slugs ["hello-world"]))
    links <- findAll ui "article.page-body > p > a:only-child"
    for_ links focus
    eventually $ length <$> findAll ui "article.page-body .deck-embed" `shouldReturn` 2
    found <- report
    found `shouldBe` Report [] [] []
    length <$> findAll ui ".deck-embed .footnote-ref a" >>= (`shouldSatisfy` (>= 2))

  it "is the link for a version's permanent address, as the embed without the class" $ runPage $ do
    (opener, wiki) <- startWith m (Just "user-admin") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    unmount opener
    unsafeIOToPageM . runMemWiki wiki $ do
      deck <- either (panic . show) identity <$> getPage' "docs" ["markdown-guide", "presentations"]
      let versioned = Duplex.print route (PermanentLink deck.id (Just deck.updatedAt))
          current = Duplex.print route (PermanentLink deck.id Nothing)
      hello <- either (panic . show) identity <$> getPage' "blog" ["hello-world"]
      void (savePage hello.id hello.updatedAt hello.title (T.intercalate "\n\n" ["# Hello, world", "![Then](" <> versioned <> "){.presentation}", "![Then](" <> versioned <> ")", "![Now](" <> current <> "){.presentation}"]))
    ui <- startOn m wiki (Page (slugs ["blog"]) (slugs ["hello-world"]))
    findAll ui "article.page-body > p > a:only-child" >>= traverse_ focus
    -- The current page's viewer is shown; the version's is its link.
    eventually $ length <$> findAll ui "article.page-body .deck-embed" `shouldReturn` 1
    paragraphs <- findAll ui "article.page-body > p" >>= traverse outerHTML
    take 2 paragraphs `shouldSatisfy` \case
      [versioned, plain] -> versioned == plain
      _ -> False
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

-- | A page by its space's path and its own.
getPage' :: (MonadWiki n) => Text -> [Text] -> n (Either WikiError Page)
getPage' space path = getSpace (slugs [space]) >>= either (pure . Left) (\s -> getPage s.id (slugs path))

-- | What 'js_ids_report' finds: ids written twice, links in a viewer that
-- leave it, the contents' links that do not reach the page's text.
data Report = Report {duplicates :: [Text], outside :: [Text], contents :: [Text]}
  deriving stock (Eq, Show)

instance FromJSON Report where
  parseJSON = withObject "Report" $ \o -> Report <$> o .: "duplicates" <*> o .: "outside" <*> o .: "contents"

report :: PageM s Report
report = do
  json <- unsafeIOToPageM (fromJSText <$> js_ids_report)
  maybe (expectationFailure ("no report: " <> json)) pure (decodeStrict (encodeUtf8 json))
