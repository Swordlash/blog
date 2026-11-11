{-# LANGUAGE TemplateHaskell #-}

-- | An html fence in a browser (WP5.89 of docs/PLAN.md, issue #196), over
-- the demo's wiki: a frame whose document has the author's styles and the
-- wiki's classes as the page has them, as high as its content (and no
-- higher than the stylesheet's cap), where no script runs, neither one the
-- allowlist would drop nor one written straight into the frame's document
-- past it; the live preview showing the frame and following the text; a
-- @latex@ fence set as @$$@ sets the same formula; and @{.norender}@ a
-- listing. What a frame shows is read through its document (the page may
-- read it: the frame keeps the page's origin; test/jsbits/test-frame.js).
module Test.Browser.HtmlBlock (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (decodeStrict)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (adopt, slugs, start, startChanged, startWith)
import Test.Browser.Text (setMarkdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), insertPage)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (Island (..), MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Markdown.Frame (frameDocument)
import Wiki.Core.Space qualified as Core

$( browserJS
     ["jsbits/test-frame.js", "jsbits/test-style.js", "jsbits/test-markup.js"]
     [ ("js_frame_style", "wiki_test_frame_style", Safe, [t|JSText -> JSText -> JSText -> IO JSText|])
     , ("js_frame_count", "wiki_test_frame_count", Safe, [t|JSText -> JSText -> IO Int|])
     , ("js_frame_text", "wiki_test_frame_text", Safe, [t|JSText -> IO JSText|])
     , ("js_frame_heights", "wiki_test_frame_heights", Safe, [t|JSText -> IO JSText|])
     , ("js_frame_flag", "wiki_test_frame_flag", Safe, [t|IO JSText|])
     , ("js_formulas", "wiki_test_formulas", Safe, [t|JSText -> IO JSText|])
     , ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_frame_mark", "wiki_test_frame_mark", Safe, [t|JSText -> IO Bool|])
     , ("js_frame_marked", "wiki_test_frame_marked", Safe, [t|JSText -> IO Bool|])
     , ("js_markup", "wiki_test_markup", Safe, [t|IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = describe "an html fence" $ do
  it "shows a frame with the author's styles, and the wiki's classes as the page has them" $ runPage $ do
    ui <- page m styled
    _ <- find ui ".page-body iframe.wiki-html"
    eventually $ frameStyle ".card" "border-top-width" `shouldReturn` "3px"
    frameStyle "#styled" "color" `shouldReturn` "rgb(4, 5, 6)"
    -- The author's rule wins over the wiki's, however specific the
    -- wiki's: the wiki's stylesheet is in a layer of its own.
    frameStyle "h2" "border-bottom-style" `shouldReturn` "none"
    outside <- computedStyle ".page-body > p > span.c-red" "color"
    outside `shouldSatisfy` (not . T.null)
    frameStyle ".card span.c-red" "color" `shouldReturn` outside
    -- The frame shows the page's background, without a border.
    computedStyle ".page-body iframe.wiki-html" "border-top-style" `shouldReturn` "none"
    frameStyle "body" "background-color" `shouldReturn` "rgba(0, 0, 0, 0)"

  it "is as high as its content, and no higher than most of the window, scrolling beyond" $ runPage $ do
    ui <- page m (styled <> "\n\n```html\n" <> T.concat (replicate 120 "<p>A line of a long block.</p>\n") <> "```\n")
    _ <- find ui ".page-body iframe.wiki-html"
    eventually $ do
      (high, content, _) <- heights ".page-body iframe.wiki-html"
      content `shouldSatisfy` (> 0)
      abs (high - content) `shouldSatisfy` (<= 1)
    eventually $ do
      (high, content, cap) <- heights ".page-body iframe.wiki-html ~ iframe.wiki-html"
      content `shouldSatisfy` (> cap)
      abs (high - cap) `shouldSatisfy` (<= 1)

  it "runs no script: the allowlist leaves none in the frame's document" $ runPage $ do
    ui <- page m hostile
    _ <- find ui ".page-body iframe.wiki-html"
    eventually $ frameText `shouldReturn` "shown"
    frameCount "script" `shouldReturn` 0
    frameCount "[onerror], [onload], [onclick]" `shouldReturn` 0
    frameCount ".page-body :is(iframe, form, meta, base, link, style)" `shouldReturn` 0
    -- The head is the wiki's: the character set, and the stylesheet's
    -- import.
    frameCount "head > *" `shouldReturn` 2
    flag `shouldReturn` ""

  it "runs no script even written straight into the frame's document: the sandbox forbids it" $ runPage $ do
    ui <- mount m (Islands.component @(Const Void) @Void) (HtmlFrame (frameDocument "<p>shown</p><script>parent.wikiFrameScriptRan = 'script'</script><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'handler'\">"))
    _ <- find ui "iframe.wiki-html"
    eventually $ frameCountIn "iframe.wiki-html" "script" `shouldReturn` 1
    -- The image's error has come and gone by the time the frame loaded.
    eventually $ frameCountIn "iframe.wiki-html" "img" `shouldReturn` 1
    flag `shouldReturn` ""

  it "shows the frame in the live preview, following the text" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".editor-side-by-side" >>= click
    find ui ".editor-preview" >>= shouldBeVisible
    setMarkdown ui ("# Hello, world\n\n" <> styled)
    _ <- find ui ".editor-preview iframe.wiki-html"
    eventually $ frameStyleIn ".editor-preview iframe.wiki-html" ".card" "border-top-width" `shouldReturn` "3px"
    setMarkdown ui "# Hello, world\n\n```html\n<p class=\"changed\">Changed.</p>\n```\n"
    eventually $ frameCountIn ".editor-preview iframe.wiki-html" "p.changed" `shouldReturn` 1
    eventually $ do
      (high, content, _) <- heights ".editor-preview iframe.wiki-html"
      abs (high - content) `shouldSatisfy` (<= 1)

  it "is adopted with the page that arrives with it, keeping the document it loaded" $ runPage $ do
    -- The Markdown guide's frame, in the shell's HTML written out as the
    -- prerender writes it (test/jsbits/test-markup.js), parsed back.
    let guide = Page (slugs ["docs"]) (slugs ["markdown-guide"])
    shown <- start m Nothing guide
    _ <- find shown frame
    html <- fromJSText <$> unsafeIOToPageM js_markup
    unmount shown
    arrived <- htmlContainer html
    framed <- findIn arrived frame
    eventually $ unsafeIOToPageM (js_frame_mark (toJSText frame)) `shouldReturn` True
    ui <- adopt m arrived Nothing guide
    find ui frame >>= (`shouldBeSameElement` framed)
    -- The program has measured it, so it has filled the island.
    eventually $ do
      (high, content, _) <- heights frame
      abs (high - content) `shouldSatisfy` (<= 1)
    settle
    settle
    unsafeIOToPageM (js_frame_marked (toJSText frame)) `shouldReturn` True

  it "sets a latex fence as $$ sets the same formula" $ runPage $ do
    ui <- page m "$$\\frac{n(n+1)}{2}$$\n\n```latex\n\\frac{n(n+1)}{2}\n```\n"
    eventually $ do
      -- What KaTeX draws; its MathML holds the TeX as written, the fence's
      -- with the line break it ends with.
      formulas <- unsafeIOToPageM (decodeStrict . encodeUtf8 . fromJSText <$> js_formulas (toJSText (".page-body .wiki-math-display .katex-html" :: Text)))
      case formulas :: Maybe [Text] of
        Just [dollars, fence] -> do
          dollars `shouldSatisfy` T.isInfixOf "mfrac"
          fence `shouldBe` dollars
        other -> expectationFailure ("not two formulas: " <> show other)
    length <$> findAll ui ".page-body pre.wiki-code" `shouldReturn` 0

  it "shows a fence with {.norender} as a listing of its language" $ runPage $ do
    ui <- page m "```html {.norender}\n<b>bold</b>\n```\n\n```latex {.norender}\n\\frac{1}{2}\n```\n"
    _ <- find ui ".page-body pre.wiki-code > code.hljs.language-html span.hljs-tag"
    _ <- find ui ".page-body pre.wiki-code > code.hljs.language-latex"
    length <$> findAll ui ".page-body iframe.wiki-html, .page-body .wiki-math-display" `shouldReturn` 0

-- | The page's frame, when it has one.
frame :: Text
frame = ".page-body iframe.wiki-html"

-- | A property the page's frame's styles give an element in it.
frameStyle :: Text -> Text -> PageM s Text
frameStyle = frameStyleIn frame

-- | How many elements of the page's frame a selector finds.
frameCount :: Text -> PageM s Int
frameCount = frameCountIn frame

-- | A property a frame's styles give the first element a selector finds in
-- it ('wiki_test_frame_style').
frameStyleIn :: Text -> Text -> Text -> PageM s Text
frameStyleIn f selector property = unsafeIOToPageM (fromJSText <$> js_frame_style (toJSText f) (toJSText selector) (toJSText property))

-- | How many elements a selector finds in a frame; -1 before it loaded.
frameCountIn :: Text -> Text -> PageM s Int
frameCountIn f selector = unsafeIOToPageM (js_frame_count (toJSText f) (toJSText selector))

-- | The text of the page's frame.
frameText :: PageM s Text
frameText = unsafeIOToPageM (T.strip . fromJSText <$> js_frame_text (toJSText frame))

-- | What a script in a frame would have set, had it run ('wiki_test_frame_flag').
flag :: PageM s Text
flag = unsafeIOToPageM (fromJSText <$> js_frame_flag)

-- | A property the page's stylesheet gives an element of the page.
computedStyle :: Text -> Text -> PageM s Text
computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))

-- | A frame's height, its content's and the stylesheet's cap
-- ('wiki_test_frame_heights'); the test fails until the frame has loaded.
heights :: Text -> PageM s (Int, Int, Int)
heights f = do
  written <- unsafeIOToPageM (fromJSText <$> js_frame_heights (toJSText f))
  case mapMaybe readMaybe (T.words written) of
    [a, b, c] -> pure (a, b, c)
    _ -> expectationFailure ("no heights yet: " <> show written)

-- | A block with a style element, a style attribute and one of the
-- wiki's colours, beside the same colour in the page.
styled :: Text
styled =
  T.unlines
    [ "Outside: <span class=\"c-red\">red</span>."
    , ""
    , "```html"
    , "<style>.card { border: 3px solid rgb(1, 2, 3); } h2 { border-bottom: none; }</style>"
    , "<div class=\"card\"><h2>A card</h2><p>Inside: <span class=\"c-red\">red</span>.</p>"
    , "<p id=\"styled\" style=\"color: rgb(4, 5, 6)\">styled</p></div>"
    , "```"
    ]

-- | A block of what the allowlist drops, each of which would set a flag on
-- the page if it ran.
hostile :: Text
hostile =
  T.unlines
    [ "```html"
    , "<p>shown</p><script>parent.wikiFrameScriptRan = 'script'</script>"
    , "<img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'handler'\">"
    , "<iframe srcdoc=\"&lt;script&gt;parent.parent.wikiFrameScriptRan = 'frame'&lt;/script&gt;\"></iframe>"
    , "<form action=\"javascript:parent.wikiFrameScriptRan = 'form'\"></form>"
    , "<meta http-equiv=\"refresh\" content=\"0;url=javascript:parent.wikiFrameScriptRan='meta'\">"
    , "<base href=\"https://evil.example/\"><link rel=\"stylesheet\" href=\"https://evil.example/x.css\">"
    , "```"
    ]

-- | The demo's Projects space with a page of this text, shown to an
-- administrator.
page
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> PageM s (Mounted s Shell.Query Void m)
page m body = startChanged m withPage (Just "user-admin") (Page (slugs ["team", "projects"]) (slugs ["html-blocks"]))
  where
    withPage st = case head (filter (\s -> s.name == "Projects") (Map.elems st.spaces)) of
      Just (s :: Core.Space) -> fst (insertPage s.id Nothing "HTML blocks" body demoNow st)
      Nothing -> panic "the demo has no space Projects"
