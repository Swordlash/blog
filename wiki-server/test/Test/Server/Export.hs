-- | Pages and spaces exported as documents with pandoc (WP4.16 of
-- docs/PLAN.md): what a page's Markdown becomes as pandoc's document
-- (headings, tables, math and its macros, images, raw HTML through the
-- allowlist, the islands, links, decks cut into slides, a space's pages as
-- one document), natively; then each format over HTTP, from a server with
-- the demo's wiki, checked for its media type, its name and what its file
-- holds; who may export what; one export at a time each; and the PDFs, where
-- the machine has @xelatex@ (skipped, saying so, where it has not).
module Test.Server.Export (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Types (methodPost)
import Protolude
import System.Environment (lookupEnv)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (demoArchive)
import Text.Pandoc.Definition qualified as P
import Text.Pandoc.Walk (query)
import Wiki.Api (PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Export (ExportFormat (..), formatMediaType)
import Wiki.Api.Links (attachmentUrl, links)
import Wiki.Api.Types (NewPage (..), SessionInfo (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Export.Zip (unzipFiles)
import Wiki.Core.Id (AttachmentId (..), BlobId (..), PageId)
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Page (Page (..), pageTreeOrder)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Export (availableFormats, newExports, oneAtATime, restrictTeX, texEngine, texLimits)
import Wiki.Server.Export.Document

spec :: Spec
spec = describe "export with pandoc" $ do
  reading
  slides
  spaces
  overHttp
  oneAtATimeEach
  pdfs

-- | An image attachment, whose bytes are in the media bag.
tree :: Attachment
tree = Attachment {id = AttachmentId "a1", name = "tree.png", mediaType = "image/png", size = 3, source = SourceBlob (BlobId "b1")}

-- | A PDF attachment, which a document links to.
paper :: Attachment
paper = Attachment {id = AttachmentId "a2", name = "paper.pdf", mediaType = "application/pdf", size = 3, source = SourceBlob (BlobId "b2")}

-- | A page of the demo's Docs space, the Tour, with two attachments, in a
-- wiki at a public address.
place :: Place
place =
  Place
    { spaces = demoArchive.spaces
    , spacePath = [slug "docs"]
    , pages = docsPages
    , pagePath = [slug "markdown-guide"]
    , attachments = [tree, paper]
    , stored = (== tree.id)
    , attachmentAddress = attachmentUrl
    , publicUrl = Just "https://wiki.example.org/"
    , inDocument = \_ _ -> Nothing
    , idPrefix = ""
    , macros = Macros []
    }
  where
    docsPages = [p | p <- demoArchive.pages, Just s <- [find (\s -> s.id == p.space) demoArchive.spaces], s.slug == slug "docs"]

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

blocksOf :: (HasCallStack) => Output -> Place -> Text -> IO [P.Block]
blocksOf output at source = either (\e -> panic ("pandoc: " <> show e)) pure (pageBlocks output at source)

maths :: [P.Block] -> [(P.MathType, Text)]
maths = query $ \case
  P.Math kind tex -> [(kind, tex)]
  _ -> []

images :: [P.Block] -> [Text]
images = query $ \case
  P.Image _ _ (target, _) -> [target]
  _ -> []

linkTargets :: [P.Block] -> [Text]
linkTargets = query $ \case
  P.Link _ _ (target, _) -> [target]
  _ -> []

headers :: [P.Block] -> [(Int, Text)]
headers = query $ \case
  P.Header l (i, _, _) _ -> [(l, i)]
  _ -> []

raw :: [P.Block] -> [Text]
raw bs = query (\case P.RawBlock f t -> [show f <> t]; _ -> []) bs <> query (\case P.RawInline f t -> [show f <> t]; _ -> []) bs

reading :: Spec
reading = describe "a page's Markdown, as pandoc's document" $ do
  it "keeps headings with their identifiers, emphasis and tables" $ do
    bs <- blocksOf ToOther place "# Title {#top}\n\nSome *text*.\n\n## Next one\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n"
    headers bs `shouldBe` [(1, "top"), (2, "next-one")]
    [() | P.Table {} <- bs] `shouldBe` [()]
    query (\case P.Emph xs -> [xs]; _ -> []) bs `shouldBe` [[P.Str "text"]]

  it "reads math between each of the wiki's delimiters, and a math fence" $ do
    bs <- blocksOf ToOther place "$a$ and \\(b\\)\n\n\\[c\\]\n\n$$d$$\n\n```math\ne\n```\n"
    maths bs `shouldBe` [(P.InlineMath, "a"), (P.InlineMath, "b"), (P.DisplayMath, "c"), (P.DisplayMath, "d"), (P.DisplayMath, "e")]

  it "expands the space's macros and the page's own into each formula, and drops a formula that only defines" $ do
    bs <- blocksOf ToOther place {macros = Macros ["\\newcommand{\\R}{\\mathbb{R}}"]} "$\\newcommand{\\vect}[1]{\\mathbf{#1}}$\n\nThen $\\vect{v} \\in \\R$.\n"
    maths bs `shouldBe` [(P.InlineMath, "{\\mathbf{v}} \\in {\\mathbb{R}}")]
    length bs `shouldBe` 1

  it "lets a page's macro win over its space's" $ do
    bs <- blocksOf ToOther place {macros = Macros ["\\newcommand{\\eps}{\\varepsilon}"]} "$\\renewcommand{\\eps}{\\epsilon}$ $\\eps$\n"
    maths bs `shouldBe` [(P.InlineMath, "{\\epsilon}")]

  it "puts an attachment's image in, links to other attachments and to the web, and keeps what it cannot reach as text" $ do
    bs <- blocksOf ToOther place "![A tree](attachment:tree.png)\n\n![The paper](attachment:paper.pdf)\n\n![Earth](https://example.org/earth.jpg)\n\n![Lost](attachment:lost.png)\n"
    images bs `shouldBe` ["attachments/a1/tree.png"]
    linkTargets bs `shouldBe` ["https://wiki.example.org/api/v1/attachments/a2/paper.pdf", "https://example.org/earth.jpg"]
    query (\case P.Span _ xs -> [xs]; _ -> []) bs `shouldBe` [[P.Str "Lost"]]

  it "links a page of the wiki under its public address, and keeps it as text without one" $ do
    bs <- blocksOf ToOther place "See [[Tour]], [the diagrams](markdown-guide/diagrams#flow) and [the top](#intro).\n"
    linkTargets bs `shouldBe` ["https://wiki.example.org/s/docs/p/tour/", "https://wiki.example.org/s/docs/p/markdown-guide/diagrams/#flow", "#intro"]
    offline <- blocksOf ToOther place {publicUrl = Nothing} "See [[Tour]].\n"
    linkTargets offline `shouldBe` []

  it "lets through only what the allowlist keeps of raw HTML, and reads it as pandoc's own" $ do
    bs <- blocksOf ToOther place "<script>alert('no')</script>\n\nPress <kbd>Ctrl</kbd> and <b onclick=\"steal()\">this</b>.\n\n<div class=\"box\"><img src=\"tree.png\" alt=\"A tree\" onerror=\"steal()\"></div>\n"
    raw bs `shouldBe` []
    show bs `shouldNotSatisfy` T.isInfixOf "alert"
    show bs `shouldNotSatisfy` T.isInfixOf "steal"
    query (\case P.Code _ t -> [t]; _ -> []) bs `shouldBe` ["Ctrl"]
    query (\case P.Strong xs -> [xs]; _ -> []) bs `shouldBe` [[P.Str "this"]]
    images bs `shouldBe` ["attachments/a1/tree.png"]

  it "makes GitHub's alerts boxes, and leaves the deck's options out" $ do
    bs <- blocksOf ToOther place "> [!WARNING]\n> Careful.\n\n::: {.slides theme=dark}\n:::\n"
    [cls | P.Div (_, cls, _) _ <- bs] `shouldBe` [["warning", "alert"]]

  it "notes a Mermaid diagram with its source, and a TikZ picture unless LaTeX draws it" $ do
    let source = "```mermaid\nflowchart LR\n  a --> b\n```\n\n```tikz\n\\usetikzlibrary{arrows}\n\\draw (0,0) -- (1,1);\n```\n"
    other <- blocksOf ToOther place source
    [cls | P.Div (_, cls, _) _ <- other] `shouldBe` [["island-note"], ["island-note"]]
    query (\case P.CodeBlock _ t -> [t]; _ -> []) other `shouldBe` ["flowchart LR\n  a --> b", "\\usetikzlibrary{arrows}\n\\draw (0,0) -- (1,1);"]
    tex <- blocksOf ToTeX place source
    tikzPreamble tex `shouldBe` ["\\usepackage{tikz}", "\\usetikzlibrary{arrows}"]
    case [t | P.RawBlock (P.Format "latex") t <- query (\case b@P.RawBlock {} -> [b]; _ -> []) tex] of
      [picture] -> do
        picture `shouldSatisfy` T.isInfixOf "\\begin{tikzpicture}"
        picture `shouldSatisfy` T.isInfixOf "\\draw (0,0) -- (1,1);"
      other' -> expectationFailure ("one picture, not " <> show other')

slides :: Spec
slides = describe "a deck, as pandoc's slide writers read it" $ do
  it "cuts at the breaks, titles each slide with its first heading, and keeps the notes" $ do
    bs <- blocksOf ToTeX place "# The deck\n\nBy me.\n\n---\n\n### A small title\n\nText.\n\n## Not the title\n\n::: notes\nSay this.\n:::\n\n---\n\nNo title here.\n"
    let out = slideBlocks bs
    [l | P.Header l _ _ <- out] `shouldBe` [1, 2, 2, 3, 2]
    query (\case P.Header _ _ xs -> [xs]; _ -> []) out `shouldBe` [[P.Str "The", P.Space, P.Str "deck"], [], [P.Str "A", P.Space, P.Str "small", P.Space, P.Str "title"], [P.Str "Not", P.Space, P.Str "the", P.Space, P.Str "title"], []]
    [cls | P.Div (_, cls, _) _ <- out] `shouldBe` [["notes"]]

  it "gives a deck its title and its look" $ do
    let P.Pandoc (P.Meta meta) _ = slidesDocument "Deck" [("aspectratio", P.MetaString "43")] []
    Map.lookup "aspectratio" meta `shouldBe` Just (P.MetaString "43")
    Map.lookup "title" meta `shouldBe` Just (P.MetaInlines [P.Str "Deck"])

spaces :: Spec
spaces = describe "a space, as one document" $ do
  it "puts each page under its title, as deep as it is, with its headings and identifiers below it" $ do
    first' <- blocksOf ToOther place {idPrefix = "page-1-"} "# The tour\n\n## Intro\n\nSee [below](#intro).\n"
    second' <- blocksOf ToOther place {idPrefix = "page-2-"} "## Intro\n"
    let docs = fromMaybe (panic "no Docs") (find (\s -> s.slug == slug "docs") demoArchive.spaces)
        page title = fromMaybe (panic "no page") (find (\p -> p.title == title) demoArchive.pages)
        P.Pandoc (P.Meta meta) bs =
          spaceDocument docs "Exported today" [DocumentPage (page "Tour") 0 "page-1" first', DocumentPage (page "Mathematics") 1 "page-2" second']
    -- The Tour titled with its own first heading, as the page shows it.
    headers bs `shouldBe` [(1, "page-1"), (3, "page-1-intro"), (2, "page-2"), (4, "page-2-intro")]
    query (\case P.Header _ _ xs -> [xs]; _ -> []) bs `shouldSatisfy` \case
      (P.Str "The" : _) : _ -> True
      _ -> False
    linkTargets bs `shouldBe` ["#page-1-intro"]
    Map.lookup "title" meta `shouldBe` Just (P.MetaInlines [P.Str "Docs"])
    Map.member "abstract" meta `shouldBe` True

-- | The ids of the demo's Docs space and of its pages, by title, as the
-- administrator reads them.
docsIds :: Running -> IO (Space, Map Text Page)
docsIds r = do
  docs <- spaceAt r "docs"
  pages <- pagesOf r docs
  pure (docs, Map.fromList [(p.title, p) | p <- pages])

-- | A top-level space by its slug, as the operator reads it.
spaceAt :: (HasCallStack) => Running -> Text -> IO Space
spaceAt r name = do
  all' :: [Space] <- ok200 (getUrl r (r.admin <> "/admin/" <> links.spaces.list))
  maybe (panic ("no space " <> name)) pure (find (\s -> s.slug == slug name) all')

-- | A space's pages, as the operator reads them.
pagesOf :: (HasCallStack) => Running -> Space -> IO [Page]
pagesOf r space = ok200 (getUrl r (r.admin <> "/admin/" <> links.spaces.listPages space.id))

-- | The bytes of an export, which must have been made, with its media type.
exported :: (HasCallStack) => Reply -> ExportFormat -> IO ByteString
exported reply format = do
  (reply.status, header "Content-Type" reply) `shouldBe` (200, Just (encodeUtf8 (formatMediaType format)))
  header "Content-Disposition" reply `shouldSatisfy` maybe False ("attachment; filename=\"" `BS.isPrefixOf`)
  BSL.length reply.body `shouldSatisfy` (> 0)
  pure (BSL.toStrict reply.body)

zipped :: (HasCallStack) => ByteString -> IO (Map Text ByteString)
zipped bytes = either (\e -> panic ("not a zip: " <> e)) pure (unzipFiles bytes)

entryText :: (HasCallStack) => Map Text ByteString -> Text -> IO Text
entryText files name = maybe (panic ("no " <> name <> " among " <> show (Map.keys files))) (pure . decodeUtf8) (Map.lookup name files)

overHttp :: Spec
overHttp = describe "over HTTP" $ do
  it "exports a page as DOCX: a zip with its document, its image in it and its math as Word's" $ withDemoRunning identity $ \r -> do
    (_, pages) <- docsIds r
    let guide = pages Map.! "Markdown guide"
        maths' = pages Map.! "Mathematics"
    reply <- getUrl r (r.public <> "/" <> links.pages.export guide.id Docx)
    header "Content-Disposition" reply `shouldBe` Just "attachment; filename=\"markdown-guide.docx\""
    files <- zipped =<< exported reply Docx
    document <- entryText files "word/document.xml"
    document `shouldSatisfy` T.isInfixOf "Markdown guide"
    [name | name <- Map.keys files, "word/media/" `T.isPrefixOf` name] `shouldSatisfy` (not . null)
    mathsDocument <- (`entryText` "word/document.xml") =<< zipped =<< exported' r maths'.id Docx
    mathsDocument `shouldSatisfy` T.isInfixOf "<m:oMath"

  it "exports a page as one HTML file holding its title, its image and its formulas as MathML, sandboxed" $ withDemoRunning identity $ \r -> do
    (_, pages) <- docsIds r
    reply <- getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Markdown guide").id Html)
    html <- decodeUtf8 <$> exported reply Html
    html `shouldSatisfy` T.isInfixOf "<title>Markdown guide</title>"
    html `shouldSatisfy` T.isInfixOf "data:image/png;base64,"
    header "Content-Security-Policy" reply `shouldSatisfy` maybe False (\c -> "sandbox" `T.isInfixOf` decodeUtf8 c)
    maths' <- decodeUtf8 <$> exported' r (pages Map.! "Mathematics").id Html
    maths' `shouldSatisfy` T.isInfixOf "<math"

  it "exports a page as EPUB" $ withDemoRunning identity $ \r -> do
    (_, pages) <- docsIds r
    files <- zipped =<< exported' r (pages Map.! "Tour").id Epub
    Map.lookup "mimetype" files `shouldBe` Just "application/epub+zip"

  it "exports a deck as PowerPoint, a slide a slide with the speaker's notes, and as Beamer's LaTeX" $ withDemoRunning identity $ \r -> do
    (_, pages) <- docsIds r
    let deck = pages Map.! "Presentations"
    files <- zipped =<< exported' r deck.id Pptx
    -- The title slide pandoc makes from the title, and the deck's seven.
    length [n | n <- Map.keys files, "ppt/slides/slide" `T.isPrefixOf` n, ".xml" `T.isSuffixOf` n] `shouldBe` 8
    [n | n <- Map.keys files, "ppt/notesSlides/" `T.isPrefixOf` n] `shouldSatisfy` (not . null)
    tex <- decodeUtf8 <$> exported' r deck.id BeamerTex
    tex `shouldSatisfy` T.isInfixOf "\\documentclass[\n  ignorenonframetext,\n  aspectratio=169,\n]{beamer}"
    tex `shouldSatisfy` T.isInfixOf "\\usetheme[]{Madrid}"
    tex `shouldSatisfy` T.isInfixOf "\\begin{frame}"
    tex `shouldSatisfy` T.isInfixOf "\\note{"
    tex `shouldSatisfy` T.isInfixOf "\\int_{-\\infty}^{\\infty}"

  it "offers presentations only of a deck, and refuses a format it cannot make, saying why" $ withDemoRunning identity $ \r -> do
    (docs, pages) <- docsIds r
    getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Tour").id Pptx) >>= jsonAs 400 >>= (`shouldBe` Invalid "Only a page written as slides exports as a presentation.")
    getUrl r (r.public <> "/" <> links.spaces.export docs.id BeamerTex) >>= jsonAs 400 >>= (`shouldBe` Invalid "A space exports as a document, not a presentation.")

  it "exports a space as one DOCX: a title page, a table of contents and every page in order" $ withDemoRunning identity $ \r -> do
    (docs, pages) <- docsIds r
    reply <- getUrl r (r.public <> "/" <> links.spaces.export docs.id Docx)
    header "Content-Disposition" reply `shouldBe` Just "attachment; filename=\"docs.docx\""
    document <- (`entryText` "word/document.xml") =<< zipped =<< exported reply Docx
    document `shouldSatisfy` T.isInfixOf "Exported from the wiki on"
    document `shouldSatisfy` T.isInfixOf "TOC \\o"
    -- A title is a run's whole text, wherever it is first.
    let run title = ">" <> title <> "</w:t>"
        at title = T.length (fst (T.breakOn (run title) document))
        found title = run title `T.isInfixOf` document
    for_ (Map.keys pages) $ \title -> (title, found title) `shouldBe` (title, True)
    -- In the space's order: each page after the one before it.
    let ordered = map (\p -> p.title) (pageTreeOrder docs.pageOrder (Map.elems pages))
        positions = map at ordered
    ordered `shouldBe` ["Markdown guide", "Diagrams", "Mathematics", "Presentations", "Tour"]
    and (zipWith (<) positions (drop 1 positions)) `shouldBe` True

  it "is for whoever may read the page or the space" $ withDemoRunning identity $ \r -> do
    team <- spaceAt r "team"
    handbook <- fromMaybe (panic "no handbook") . find (\p -> p.title == "Team handbook") <$> pagesOf r team
    getUrl r (r.public <> "/" <> links.pages.export handbook.id Docx) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    getUrl r (r.public <> "/" <> links.spaces.export team.id Docx) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    -- The operator, on the admin listener, may read every page.
    getUrl r (r.admin <> "/admin/" <> links.pages.export handbook.id Docx) >>= (`exported` Docx) >>= zipped >>= (`entryText` "word/document.xml") >>= (`shouldSatisfy` T.isInfixOf "Team handbook")

-- | An export from the public listener, which must have been made.
exported' :: (HasCallStack) => Running -> PageId -> ExportFormat -> IO ByteString
exported' r pid format = getUrl r (r.public <> "/" <> links.pages.export pid format) >>= (`exported` format)

oneAtATimeEach :: Spec
oneAtATimeEach = describe "one export at a time" $ do
  it "refuses a second export of someone's while their first is made, but not someone else's" $ do
    exports <- newExports
    inner <- oneAtATime exports "user:ada" $ do
      again <- oneAtATime exports "user:ada" (pure (Right ()))
      other <- oneAtATime exports "user:bob" (pure (Right ()))
      pure (Right (again, other))
    case inner of
      Right (again, other) -> do
        again `shouldSatisfy` \case
          Left (TooManyRequests _) -> True
          _ -> False
        other `shouldBe` Right ()
      Left e -> expectationFailure (show e)
    -- Done, it may export again.
    oneAtATime exports "user:ada" (pure (Right ())) `shouldReturn` Right ()

pdfs :: Spec
pdfs = describe "PDFs, typeset by xelatex" $ do
  it "keep TeX to its working directory, with no programs, through kpathsea's variables" $ do
    restrictTeX
    for_ texLimits $ \(name, value) -> lookupEnv name `shouldReturn` Just value
    texLimits `shouldBe` [("openin_any", "p"), ("openout_any", "p"), ("shell_escape", "f")]

  it "do not let a page's formula read the server's files into the PDF" $ withDemoRunning identity $ \r -> do
    tex <- texEngine
    when (isNothing tex) (pendingWith "xelatex is not on this machine: TeX's limits were not tested against it")
    docs <- spaceAt r "docs"
    made <- sendJson r methodPost (r.admin <> "/admin/" <> links.spaces.createPage docs.id) NewPage {parent = Nothing, title = "Prying", body = "Here: $\\input{/etc/passwd}$ and\n\n```tikz\n\\node {\\input{/etc/passwd}};\n```\n"} >>= jsonAs 201
    reply <- getUrl r (r.admin <> "/admin/" <> links.pages.export (made :: Page).id Pdf)
    -- Refused, as TeX cannot open the file; or made without it.
    BSL.toStrict reply.body `shouldSatisfy` (not . ("root:" `BS.isInfixOf`))
    when (reply.status == 200) (BS.take 5 (BSL.toStrict reply.body) `shouldBe` "%PDF-")

  it "are offered exactly where the machine has xelatex" $ withRunning $ \r -> do
    tex <- isJust <$> texEngine
    formats <- availableFormats
    session <- ok200 (getUrl r (r.public <> "/" <> links.session))
    (session :: SessionInfo).exports `shouldBe` formats
    (Pdf `elem` formats, BeamerPdf `elem` formats) `shouldBe` (tex, tex)

  it "are refused, saying why, where it has not" $ withDemoRunning identity $ \r -> do
    tex <- texEngine
    when (isJust tex) (pendingWith "xelatex is on this machine, so the PDFs are made, not refused")
    (_, pages) <- docsIds r
    getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Tour").id Pdf) >>= jsonAs 400 >>= (`shouldBe` Invalid "PDF needs xelatex, which this server's machine does not have.")

  it "are made of a page, a deck and a space where it has" $ withDemoRunning identity $ \r -> do
    tex <- texEngine
    when (isNothing tex) (pendingWith "xelatex is not on this machine: the PDFs were not tested")
    (docs, pages) <- docsIds r
    for_ [((pages Map.! "Mathematics").id, Pdf), ((pages Map.! "Presentations").id, BeamerPdf)] $ \(pid, format) -> do
      bytes <- exported' r pid format
      BS.take 5 bytes `shouldBe` "%PDF-"
    reply <- getUrl r (r.public <> "/" <> links.spaces.export docs.id Pdf)
    bytes <- exported reply Pdf
    BS.take 5 bytes `shouldBe` "%PDF-"
    -- The headers say nothing a browser would act on but the download.
    lookup "X-Content-Type-Options" reply.headers `shouldBe` Just "nosniff"
