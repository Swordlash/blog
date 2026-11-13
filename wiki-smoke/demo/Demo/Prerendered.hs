-- | The first part of the demo's smoke test: every page the build wrote,
-- as a static host serves it, adopted by the program; the islands drawn;
-- TikZ's letters and the first picture in a fresh browser; the licences,
-- the Content Security Policy and TikZJax's files as served; and a page
-- left while its picture is still being drawn.
module Demo.Prerendered (spec) where

import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON (..), withObject, (.:))
import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Demo.Site
import GHC.Clock (getMonotonicTime)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import System.Directory (doesDirectoryExist, getFileSize, listDirectory)
import System.FilePath (makeRelative, splitDirectories, (</>))
import Text.Printf (printf)
import Wiki.Smoke.Adoption
import Wiki.Smoke.Demo

spec :: Site -> [Text] -> ProgramGate -> SpecWith Playwright
spec site paths visitorGate = do
  describe "every prerendered page" $ onOnePage demoContext (holdProgram visitorGate) $ do
    -- A space's home page is at the space's address, and so are its source
    -- and history (WP5.78 of docs/PLAN.md); a page under it at its own. A
    -- home page's old address is not written: the static host serves the
    -- application's own page there (404.html), which reads it as the page.
    it "is in the build: at least ten, the routes the wiki must have, and no home page's old address" $ \_ -> do
      expect (length paths >= 10) ("only " <> show (length paths) <> " pages were prerendered")
      forM_ ["/", "/search/", "/s/docs/", "/s/docs/pages/", "/s/docs/source/", "/s/docs/history/", "/s/team/projects/", "/s/docs/p/markdown-guide/", "/s/docs/p/markdown-guide/source/", "/s/team/p/on-call/"] $ \path ->
        expect (path `elem` paths) (Text.unpack path <> " was not prerendered")
      forM_ ["/s/docs/p/tour/", "/s/team/p/team-handbook/"] $ \path ->
        expect (path `notElem` paths) (Text.unpack path <> ", a home page's old address, was prerendered")
      -- The pages with a TikZ picture, which alone may fetch TikZJax (each
      -- page's example checks that the others do not).
      pictured <- length . filter hasTikz <$> mapM (fmap snd . fetchText site) paths
      report (tshow pictured <> " of the " <> tshow (length paths) <> " pages have a TikZ picture")

    -- Each page as a server sends it, before any script runs, then loaded
    -- with app.wasm held back until it has been seen and every node of it
    -- marked; the program has to adopt it as the same route, with nothing
    -- to repair outside the islands, which their libraries fill.
    forM_ paths $ \path ->
      it ("is adopted at " <> Text.unpack path <> " as the same route, every node kept, footer included") $ \page -> do
        gate <- gateOf visitorGate
        (_, html) <- fetchText site path
        let base = basePath site.demo
        expect (("<base href=\"" <> base <> "\">") `Text.isInfixOf` html) (Text.unpack path <> ": no <base href=\"" <> Text.unpack base <> "\">")
        expect ("<div id=\"app\"><div class=\"wiki\">" `Text.isInfixOf` html) (Text.unpack path <> ": not prerendered")
        expect (footerHtml `Text.isInfixOf` html) (Text.unpack path <> ": no footer prerendered")
        before <- length <$> requests (pageContext page)
        adopted <- load site gate page path
        asked <- map (\r -> r.url) . drop before <$> requests (pageContext page)
        -- TikZJax is fetched by a page with a picture, and by no other.
        unless (hasTikz html) $
          [a | a <- asked, "/islands/tikz.js" `Text.isInfixOf` a || "/tikzjax/" `Text.isInfixOf` a] `shouldBe` []
        -- CodeMirror is the editor's, and no reader's page fetches it.
        [a | a <- asked, "/islands/editor.js" `Text.isInfixOf` a] `shouldBe` []
        when (path /= "/") $ expect (adopted.before.title /= "Wiki") (Text.unpack path <> ": no title of its own")
        -- The program shows the same route, on the same nodes.
        shown page `shouldReturn` adopted.before
        unless (null adopted.objectUrls) $
          report ("attachments the browser serves from object URLs: " <> Text.intercalate "; " (map describeRepair adopted.objectUrls))
        unless (noRepairs adopted) $ expectationFailure (Text.unpack path <> ": adopting the page repaired it:\n" <> describeRepairs adopted.repairs)
        footerShown page path
        nothingWrong page

    -- A page's islands are prerendered as their sources, and drawn once the
    -- program has loaded. What they draw is their libraries', not the
    -- program's: each is waited for as a condition.
    it "draws a page's islands: KaTeX with its fonts, Mermaid, TikZ with TeX's fonts, highlight.js" $ \page -> do
      gate <- gateOf visitorGate
      (_, maths) <- fetchText site "/s/docs/p/markdown-guide/mathematics/"
      expect ("<span class=\"wiki-math wiki-math-inline\">" `Text.isInfixOf` maths) "the page has no formula's source"
      _ <- load site gate page "/s/docs/p/markdown-guide/"
      -- KaTeX.
      waitFor (first (locator page "#app .wiki-math-inline .katex")) Visible
      waitFor (first (locator page "#app .wiki-math-display .katex-display")) Visible
      -- Mermaid, whose own bundle is fetched for the first diagram.
      waitFor (first (locator page "#app .wiki-mermaid > svg")) Visible
      -- highlight.js.
      waitFor (first (locator page "#app .wiki-code code.hljs.language-haskell .hljs-type")) Visible
      -- KaTeX's fonts, which the browser loads.
      waitForFunction page "document.fonts.check('16px \"KaTeX_Main\"')"
      -- The guide's TikZ picture, with its labels in TeX's fonts.
      let label = first (locator page "#app .wiki-tikz > svg text")
      waitFor label Attached
      settle page
      text <- textContent label
      expect (not (Text.null text)) "the TikZ picture's label is empty"
      -- TeX's fonts, which the browser loads once the picture uses them.
      waitForFunction page "document.fonts.check('10px cmr10')"
      nothingWrong page

    -- Letters beyond ASCII in pictures, through the real TikZJax: every
    -- letter web/src/tikz-letters.mjs lists as drawable, in a node and in
    -- a pgfplots label, drawn with no error. The SVG holds the glyphs that
    -- were missing before web/src/tikz-patch.mjs: the stroke of "ł"
    -- (U+F0C3) and the umlaut (U+F0C4). A letter the fonts do not have (the
    -- euro sign: TeX looks for a TS1 font TikZJax lacks) and a glyph
    -- dvi2html cannot find after TeX has finished each give the readable
    -- error, and a picture after them is drawn again. Five runs of TeX in
    -- its worker, called in the page: a longer timeout.
    it "draws letters beyond ASCII in a TikZ node and a plot's label, and names one it cannot draw" $ \page -> do
      pictures :: Pictures <- evaluateWith (withTimeout 180000 page) letterPictures [site.letters]
      forM_ [("node", pictures.node), ("plot", pictures.plot), ("after", pictures.after)] $ \(name, picture) -> do
        expect (isNothing picture.failure) ("the picture of letters (" <> name <> ") failed: " <> show picture.failure)
        expect (maybe False ("\xf0c3" `Text.isInfixOf`) picture.glyphs) ("the picture of letters (" <> name <> ") has no stroke of \"ł\"")
      expect (maybe False ("\xf0c4" `Text.isInfixOf`) pictures.node.glyphs) "the picture of letters has no umlaut"
      (firstLine <$> pictures.euro.failure) `shouldBe` Just "! The fonts TeX has here cannot draw '€' (line 2)."
      (firstLine <$> pictures.glyph.failure)
        `shouldBe` Just "! The fonts TeX has here cannot draw a character of this picture (Cannot read properties of undefined (reading 'toString'))."
      report ("TikZ draws " <> tshow (Text.length site.letters) <> " letters beyond ASCII, in a node and a plot's label")
      nothingWrong page

    -- The Mathematics page sets every formula with the macros it uses: the
    -- built-in ones, Docs' own, the page's \dist, and mhchem's \ce. KaTeX
    -- shows a macro it does not know in red, and what it cannot parse in a
    -- .katex-error.
    it "sets the Mathematics page's formulas with built-in, space and page macros, and \\ce" $ \page -> do
      gate <- gateOf visitorGate
      _ <- load site gate page "/s/docs/p/markdown-guide/mathematics/"
      -- KaTeX sets them: a condition on its work.
      waitForFunction
        page
        "(() => {\
        \  const all = document.querySelectorAll('#app .page-body .wiki-math');\
        \  return all.length >= 20 && document.querySelectorAll('#app .page-body .wiki-math .katex').length === all.length;\
        \})()"
      settle page
      unset :: [Text] <-
        evaluate
          page
          "Array.from(document.querySelectorAll('#app .page-body .wiki-math'))\
          \  .filter((f) => f.querySelector('.katex-error') || f.innerHTML.includes('#cc0000'))\
          \  .map((f) => f.querySelector('annotation')?.textContent ?? f.textContent)"
      unset `shouldBe` []
      nothingWrong page

  -- The first TikZ picture, in a browser that has fetched nothing yet: how
  -- long it takes, and what it fetches (TikZJax's worker, TeX, the format,
  -- the TeX files and fonts the picture uses). The bytes are the files'
  -- sizes as built, which are what the server sends.
  it "draws the first TikZ picture in a browser that has fetched nothing yet" $ onDemoPage demoContext $ \page -> do
    start <- getMonotonicTime
    visit page (address site.demo "/s/docs/p/markdown-guide/")
    -- TikZJax draws it, in its worker: a condition.
    waitFor (first (locator page "#app .wiki-tikz > svg")) Visible
    drawn <- getMonotonicTime
    asked <- filter tikzFile . map (\r -> r.url) <$> requests (pageContext page)
    expect (any ("core.dump.bin" `Text.isSuffixOf`) asked) ("TikZJax's format was not fetched: " <> show asked)
    sizes <- mapM (fileSize site) asked
    report
      ( Text.pack
          ( printf
              "the first TikZ picture was drawn %d ms after the page was asked for, with nothing cached; TikZJax's files fetched for it: %d, %d KiB"
              (round ((drawn - start) * 1000) :: Int)
              (length asked)
              (sum sizes `div` 1024)
          )
      )
    nothingWrong page

  -- TikZJax is GPL and its fonts are BaKoMa's: a page that serves them
  -- serves their licences' texts beside them (web/bundle.sh), as conveying
  -- them requires. Its compressed files are zlib streams named .bin,
  -- served as application/octet-stream, since a corporate proxy may refuse
  -- to download a gzip archive (web/src/tikz-files.mjs): no .gz ships
  -- under tikzjax/, so nothing there goes out as application/gzip.
  it "serves TikZJax's licence and its fonts' beside them, its compressed files as .bin, and none as gzip" $ \_ -> do
    forM_
      [ ("/tikzjax/LICENSE.txt", "GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007")
      , ("/tikzjax/fonts/LICENCE.txt", "BaKoMa Fonts Licence")
      , ("/tikzjax/NOTICE.txt", "Licence: GPL-3.0-or-later, whose text is LICENSE.txt")
      ]
      $ \(path, says) -> do
        (status, text) <- fetchText site path
        expect (status == 200) (Text.unpack path <> " is not served")
        expect (says `Text.isInfixOf` text) (Text.unpack path <> " does not say " <> show says)
    let tikzjax = site.demo.dir </> "tikzjax"
    shipped <- map (Text.pack . joinSlashes . splitDirectories . makeRelative tikzjax) <$> filesUnder tikzjax
    filter (".gz" `Text.isSuffixOf`) shipped `shouldBe` []
    let bins = filter (".bin" `Text.isSuffixOf`) shipped
    forM_ ["tex.wasm.bin", "core.dump.bin", "tex_files/tikzlibrarycalc.code.tex.bin"] $ \name ->
      expect (name `elem` bins) ("tikzjax/" <> Text.unpack name <> " is not built")
    forM_ shipped $ \name -> do
      kind <- contentType site ("/tikzjax/" <> name)
      expect (kind /= Just "application/gzip") ("tikzjax/" <> Text.unpack name <> " is served as gzip")
      when (".bin" `Text.isSuffixOf` name) $ kind `shouldBe` Just "application/octet-stream"
    report ("TikZJax's " <> tshow (length bins) <> " compressed files are .bin, served as application/octet-stream")

  -- The page's Content Security Policy (Wiki.Api.ContentPolicy), which
  -- GitHub Pages, sending no headers of its own, gets from the page: every
  -- page and the offline page carry it, and every page here runs under it
  -- (a violation is a console error, which fails the example it is in).
  it "carries the Content Security Policy on every page, the offline page too" $ \_ ->
    forM_ ["/", "/404.html", "/offline.html", "/s/docs/", "/s/docs/p/markdown-guide/"] $ \path -> do
      (_, html) <- fetchText site path
      let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; "
          (_, from) = Text.breakOn policy html
      expect (not (Text.null from) && "\">" `Text.isInfixOf` Text.drop (Text.length policy) from) (Text.unpack path <> " carries no Content Security Policy")

  -- The notices of what esbuild bundled into the page's scripts and styles
  -- (web/src/licenses.mjs), each with its licence's text: the libraries the
  -- README's licence section names, and Mermaid's own dependencies,
  -- DOMPurify among them.
  it "serves licenses.txt with the notices of the npm packages bundled into the page" $ \_ -> do
    (status, notices) <- fetchText site "/licenses.txt"
    expect (status == 200) "licenses.txt is not served"
    let entries = Text.splitOn ("\n" <> Text.replicate 78 "=" <> "\n") notices
    forM_
      [ ("katex", "The MIT License")
      , ("highlight.js", "BSD 3-Clause License")
      , ("@codemirror/view", "MIT License")
      , ("@lezer/highlight", "MIT License")
      , ("fflate", "MIT License")
      , ("mermaid", "The MIT License")
      , ("dompurify", "Apache License")
      , ("@bjorn3/browser_wasi_shim", "Permission is hereby granted")
      ]
      $ \(name, says) -> case filter ((name <> " ") `Text.isPrefixOf`) entries of
        entry : _ -> expect (says `Text.isInfixOf` entry) ("licenses.txt's " <> Text.unpack name <> " does not say " <> show says)
        [] -> expectationFailure ("licenses.txt does not list " <> Text.unpack name)
    report ("licenses.txt carries the notices of the " <> tshow (length entries - 1) <> " npm packages bundled into the page")

  -- A page left while its picture is still being drawn: the next page shows
  -- at once. (When an island's component waited for its drawing, following
  -- a link then left the page as it was; see Wiki.App.Islands.Monad.)
  -- TeX's format is held back until the end, so that the picture is still
  -- being drawn when the links are followed; nothing here may wait for it,
  -- and each view is read once its action has settled and its content has
  -- been read.
  it "gives way to the next page at once while a TikZ picture is being drawn" $ onDemoPage demoContext $ \page -> do
    -- Held on the context: the request is TikZJax's worker's, which a
    -- page's route may not see.
    format <- hold (pageContext page) "**/tikzjax/core.dump.bin"
    visit page (address site.demo "/s/docs/p/markdown-guide/")
    waitQuiet page
    -- TikZJax's worker has asked for TeX's format, which is held: the
    -- picture is being drawn, and stays so until the end.
    waitHeld format
    count (locator page "#app .wiki-tikz > svg") `shouldReturn` 0
    click (withText "Edit" (locator page "#app .page-view .actions a"))
    waitQuiet page
    (\s -> s.view) <$> shown page `shouldReturn` Just "editor"
    editorReady page
    goBack page
    waitQuiet page
    textContent (locator page "#app .page-view h1") `shouldReturn` "Markdown guide"
    click (withText "Mathematics" (locator page "#app .wiki-sidebar .page-tree a"))
    waitQuiet page
    textContent (locator page "#app .page-view h1") `shouldReturn` "Mathematics"
    count (locator page "#app .wiki-tikz > svg") `shouldReturn` 0
    release format
    nothingWrong page
  where
    hasTikz = Text.isInfixOf "<div class=\"wiki-tikz\">"
    tikzFile a = "/islands/tikz.js" `Text.isInfixOf` a || "/tikzjax/" `Text.isInfixOf` a
    firstLine = Text.takeWhile (/= '\n')
    joinSlashes = foldr1 (\a b -> a <> "/" <> b)
    fileSize s address' = case Text.stripPrefix s.demo.url (Text.takeWhile (/= '?') address') of
      Just rel -> fromIntegral <$> getFileSize (s.demo.dir </> Text.unpack rel) :: IO Int
      Nothing -> pure 0

-- | Every file under a directory, by its path.
filesUnder :: FilePath -> IO [FilePath]
filesUnder dir = do
  names <- sort <$> listDirectory dir
  concat
    <$> mapM
      ( \name -> do
          let path = dir </> name
          isDir <- doesDirectoryExist path
          if isDir then filesUnder path else pure [path]
      )
      names

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | The pictures of 'letterPictures', each its error or its glyphs.
data Picture = Picture {failure :: Maybe Text, glyphs :: Maybe Text}

instance FromJSON Picture where
  parseJSON = withObject "Picture" $ \o -> Picture <$> o .: "error" <*> o .: "glyphs"

data Pictures = Pictures {node :: Picture, plot :: Picture, euro :: Picture, glyph :: Picture, after :: Picture}

instance FromJSON Pictures where
  parseJSON = withObject "Pictures" $ \o -> Pictures <$> o .: "node" <*> o .: "plot" <*> o .: "euro" <*> o .: "glyph" <*> o .: "after"

-- | Five pictures drawn by the page's TikZJax (islands/tikz.js), one after
-- another: the letters in a node, in a plot's label, the euro sign, a glyph
-- TeX's fonts lack, and a picture after them.
letterPictures :: Text
letterPictures =
  "async ([letters]) => {\
  \  const tikz = await import(new URL('islands/tikz.js', document.baseURI).href);\
  \  const glyphs = (result) => (result?.svg ? [...result.svg.querySelectorAll('text')].map((t) => t.textContent).join('') : null);\
  \  const draw = async (preamble, picture) => {\
  \    const result = await tikz.draw(preamble, picture);\
  \    return { error: result?.error ?? null, glyphs: glyphs(result) };\
  \  };\
  \  const plots = String.raw`\\usepackage{pgfplots}\\pgfplotsset{compat=1.18}`;\
  \  return {\
  \    node: await draw('', String.raw`\\begin{tikzpicture}\\node[text width=8cm] {${letters}};\\end{tikzpicture}`),\
  \    plot: await draw(plots, String.raw`\\begin{tikzpicture}\\begin{axis}[ylabel={payoff (zł) ${letters}}]\\addplot {x};\\end{axis}\\end{tikzpicture}`),\
  \    euro: await draw('', '\\\\begin{tikzpicture}\\\\draw (0,0) -- (1,0);\\n\\\\node {5 €};\\n\\\\end{tikzpicture}'),\
  \    glyph: await draw('', String.raw`\\begin{tikzpicture}\\node {\\font\\x=cmtex10\\x\\char2};\\end{tikzpicture}`),\
  \    after: await draw('', String.raw`\\begin{tikzpicture}\\node {Łódź};\\end{tikzpicture}`),\
  \  };\
  \}"
