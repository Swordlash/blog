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
import Wiki.Core.Markdown.Frame (FrameScheme (..), frameDocument)
import Wiki.Core.Markdown.Html (allowedElements)
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
     , ("js_frame_outside", "wiki_test_frame_outside", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_frame_remeasure", "wiki_test_frame_remeasure", Safe, [t|JSText -> IO JSText|])
     , ("js_frame_fit", "wiki_test_frame_fit", Safe, [t|JSText -> IO JSText|])
     , ("js_window_height", "wiki_test_window_height", Safe, [t|Int -> IO ()|])
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
    notAllowed `shouldReturn` ""
    frameCount ".page-body :is(iframe, form, meta, base, link, style)" `shouldReturn` 0
    -- The head is the wiki's: the character set, and the stylesheet's
    -- import.
    frameCount "head > *" `shouldReturn` 2
    flag `shouldReturn` ""

  it "keeps what the browser reads as text in its element, and swallows nothing after it" $ runPage $ do
    ui <- page m rawText
    _ <- find ui ".page-body iframe.wiki-html"
    -- Every line's paragraph after it is there: the element before it
    -- ended where the browser ends it.
    eventually $ frameCount ".page-body p.after" `shouldReturn` length rawTextLines
    frameCount "script" `shouldReturn` 0
    frameCount "[onerror], [onload]" `shouldReturn` 0
    notAllowed `shouldReturn` ""
    -- The two styles kept, their CSS as written.
    frameCount ".page-body style" `shouldReturn` 2
    frameStyle ".shown-by-css" "background-image" >>= (`shouldSatisfy` T.isPrefixOf "url(\"data:image/svg+xml")
    flag `shouldReturn` ""

  it "is as high as its content, measured with the frame at its largest, the same when measured again" $ runPage $ do
    ui <- page m (T.intercalate "\n\n" (map (\(_, b, _) -> "```html\n" <> b <> "\n```") sized))
    _ <- find ui ".page-body iframe.wiki-html"
    for_ (zip [1 :: Int ..] sized) $ \(n, (name, _, expected)) -> do
      let frameN = ".page-body iframe.wiki-html:nth-of-type(" <> show n <> ")"
      eventually $ do
        (high, _, cap) <- heights frameN
        (name, high, abs (high - expected cap) <= 2) `shouldSatisfy` (\(_, _, ok) -> ok)
      -- The postcondition: nothing to scroll to below the height, unless
      -- the frame is at its cap.
      (scrolled, given, cap) <- fit frameN
      (name, scrolled <= given + 1 || given >= cap - 1) `shouldBe` (name, True)
      -- Measured again, the frame keeps its height: nothing of a measure
      -- depends on the height the last one gave.
      again <- unsafeIOToPageM (fromJSText <$> js_frame_remeasure (toJSText frameN))
      case mapMaybe readMaybe (T.words again) :: [Int] of
        [before, after] -> (name, after) `shouldBe` (name, before)
        _ -> expectationFailure ("no heights for " <> name <> ": " <> again)

  it "is fitted again to the window's new height" $ runPage $ do
    ui <- page m "```html\n<div style=\"height: 3000px\">tall</div>\n```\n"
    _ <- find ui frame
    (_, fitted, cap) <- eventually $ do
      found@(_, given, cap) <- fit frame
      given `shouldBe` cap
      pure found
    -- The window made 200px higher, as far as the page's scripts can tell:
    -- the frame follows the new cap, in an animation frame.
    unsafeIOToPageM (js_window_height (round (fromIntegral cap / 0.8 :: Double) + 200))
    eventually $ do
      (_, given, higherCap) <- fit frame
      higherCap `shouldSatisfy` (> cap)
      given `shouldBe` higherCap
    unsafeIOToPageM (js_window_height 0)
    eventually $ do
      (_, given, _) <- fit frame
      given `shouldBe` fitted

  describe "on a slide, drawn in the slide's colours, whatever the system's" $ do
    let slides = PageSlides (slugs ["team", "projects"]) (slugs ["html-blocks"]) 1 1
        onSlide = ".slide-frame.current .slide iframe.wiki-html"
        deck theme extra = "[[!slides]]{theme=" <> theme <> "}\n\n## A slide\n\n```html\n" <> extra <> "<p id=\"text\">Readable</p>\n```\n"
    it "is light text on a dark slide under the system's light scheme" $ runPage $ do
      ui <- pageAt m (deck "dark" "") slides
      _ <- find ui onSlide
      slideText <- computedStyle ".slide-frame.current .slide" "color"
      slideText `shouldBe` "rgb(230, 237, 243)"
      eventually $ frameStyleIn onSlide "#text" "color" `shouldReturn` slideText
    it "is dark text on a light slide whatever the root's palette, as under the system's dark scheme" $ runPage $ do
      -- The runner's system is light; the dark scheme gives the root the
      -- dark palette, which the block's own rule does here.
      ui <- pageAt m (deck "light" "<style>:root { --text: rgb(230, 237, 243) }</style>\n") slides
      _ <- find ui onSlide
      slideText <- computedStyle ".slide-frame.current .slide" "color"
      slideText `shouldBe` "rgb(31, 35, 40)"
      eventually $ frameStyleIn onSlide "#text" "color" `shouldReturn` slideText
    it "is the page's colours on a page" $ runPage $ do
      ui <- page m "```html\n<p id=\"text\">Readable</p>\n```\n"
      _ <- find ui ".page-body iframe.wiki-html"
      pageText <- computedStyle ".page-body" "color"
      eventually $ frameStyle "#text" "color" `shouldReturn` pageText
      frameCount "body.html-frame-light, body.html-frame-dark" `shouldReturn` 0

  it "runs no script even written straight into the frame's document: the sandbox forbids it" $ runPage $ do
    ui <- mount m (Islands.component @(Const Void) @Void) (HtmlFrame (frameDocument SystemScheme "<p>shown</p><script>parent.wikiFrameScriptRan = 'script'</script><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'handler'\">"))
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

-- | The elements of the page's frame that are not among the allowlist's
-- (and the frame's style elements): "" when there are none.
notAllowed :: PageM s Text
notAllowed = unsafeIOToPageM (fromJSText <$> js_frame_outside (toJSText frame) (toJSText (T.intercalate "," ("style" : allowedElements))))

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

-- | The fitter's postcondition for a frame: the frame document's scroll
-- height, the height the fitter set, and the cap ('wiki_test_frame_fit');
-- the test fails until the frame has loaded.
fit :: Text -> PageM s (Int, Int, Int)
fit f = do
  written <- unsafeIOToPageM (fromJSText <$> js_frame_fit (toJSText f))
  case mapMaybe readMaybe (T.words written) of
    [a, b, c] -> pure (a, b, c)
    _ -> expectationFailure ("no fit yet: " <> show written)

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

-- | Elements the browser reads as text, each with HTML in it that would run
-- or swallow what follows were it read as HTML, and a paragraph after it:
-- a style with HTML in a string, a style with an SVG in a data address, a
-- textarea, a title, an xmp, a noscript, a style inside an svg and inside
-- math (where it is no text), a comment and CDATA.
rawTextLines :: [Text]
rawTextLines =
  map
    (<> "<p class=\"after\">after</p>")
    [ "<style>p::after { content: \"</style><script>parent.wikiFrameScriptRan = 'style'</script>\" }</style>"
    , "<style>.shown-by-css { background-image: url(\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' onload='parent.wikiFrameScriptRan = 1'></svg>\") }</style><p class=\"shown-by-css\">x</p>"
    , "<textarea><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'textarea'\"></textarea>"
    , "<title><script>parent.wikiFrameScriptRan = 'title'</script></title>"
    , "<xmp><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'xmp'\"></xmp>"
    , "<noscript><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'noscript'\"></noscript>"
    , "<svg><style><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'svg'\"></style></svg>"
    , "<math><style></style><mtext><img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'math'\"></mtext></math>"
    , "<!-- <script>parent.wikiFrameScriptRan = 'comment'</script> -->"
    , "<![CDATA[<img src=\"nowhere.png\" onerror=\"parent.wikiFrameScriptRan = 'cdata'\">]]>"
    ]

-- | 'rawTextLines' as one html fence.
rawText :: Text
rawText = "```html\n" <> T.unlines rawTextLines <> "```\n"

-- | Blocks, each with its name and the height the frame should have, from
-- the frame's cap (80% of the window): one whose height depends on the
-- frame's (in vh, in percent of the root), read against the frame at its
-- cap; content out of the flow (placed absolutely, fixed, floated, moved
-- by a transform); and nothing at all.
sized :: [(Text, Text, Int -> Int)]
sized =
  [ ("a box at most 100vh high that scrolls, holding a paragraph", "<div style=\"overflow: auto; max-height: 100vh\"><p>Visible</p></div>", const 56)
  , ("a box 50vh high", "<div style=\"height: 50vh\">half</div>", (`div` 2))
  , ("a box at least 100vh high", "<div style=\"min-height: 100vh\">full</div>", identity)
  , ("a box half as high as the root, which is the frame", "<style>html, body, .page-body { height: 100% }</style><div style=\"height: 50%\">half</div>", identity)
  , ("a box placed absolutely", "<div style=\"position: absolute; top: 0; height: 300px\">Visible</div>", min 300)
  , ("a box placed fixed", "<div style=\"position: fixed; top: 0; height: 250px\">Fixed</div>", min 250)
  , ("a floated box", "<div style=\"float: left; width: 50px; height: 120px\"></div>", min 120)
  , ("a box moved by a transform", "<p style=\"margin: 0; height: 80px\">a</p><div style=\"height: 80px; transform: translateY(400px)\">moved</div>", min 560)
  , ("nothing", "", const 0)
  , -- Generated content has no box a script can ask for; the check of the
    -- scroll height finds the first, the computed place the second.
    ("an ::after placed absolutely", "<style>.x::after { content: \"Hello\"; position: absolute; top: 0; height: 300px }</style><div class=\"x\"></div>", min 300)
  , ("a ::before placed fixed", "<style>.y::before { content: \"Fixed\"; position: fixed; top: 10px; height: 200px }</style><div class=\"y\"></div>", min 210)
  ]

-- | The demo's Projects space with a page of this text, shown to an
-- administrator.
page
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> PageM s (Mounted s Shell.Query Void m)
page m body = pageAt m body (Page (slugs ["team", "projects"]) (slugs ["html-blocks"]))

-- | 'page', at a route of its own: the page as slides, say.
pageAt
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
pageAt m body = startChanged m withPage (Just "user-admin")
  where
    withPage st = case head (filter (\s -> s.name == "Projects") (Map.elems st.spaces)) of
      Just (s :: Core.Space) -> fst (insertPage s.id Nothing "HTML blocks" body demoNow st)
      Nothing -> panic "the demo has no space Projects"
