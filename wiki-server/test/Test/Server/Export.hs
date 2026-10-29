-- | Pages and spaces exported as documents with pandoc (WP4.16 of
-- docs/PLAN.md): what a page's Markdown becomes as pandoc's document
-- (headings, tables, math and its macros, images, raw HTML through the
-- allowlist, the islands, links, decks cut into slides, a space's pages as
-- one document), natively; then each format over HTTP, from a server with
-- the demo's wiki, checked for its media type, its name and what its file
-- holds; who may export what; one export at a time each; and the PDFs, where
-- the machine has @xelatex@ (skipped, saying so, where it has not).
module Test.Server.Export (spec) where

import Codec.Compression.Zlib qualified as Zlib
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Types (methodPost)
import Protolude
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (demoArchive)
import Text.Pandoc.Builder qualified as B
import Text.Pandoc.Definition qualified as P
import Text.Pandoc.Walk (query)
import Wiki.Api (PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Export (ExportFormat (..), formatMediaType)
import Wiki.Api.Links (attachmentUrl, links)
import Wiki.Api.Types (NewPage (..), SessionInfo (exports))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Export.Zip (unzipFiles)
import Wiki.Core.Id (AttachmentId (..), BlobId (..), PageId)
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Markdown.Box (BoxColour (..), BoxIcon (..), BoxKind (..))
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Page (Page (..), PageSummary (..), pageTreeOrder)
import Wiki.Core.Slides (Deck (..), Slide (..), deckOf)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Server.Export (availableFormats, newExports, oneAtATime, restrictTeX, texEngine, texLimits)
import Wiki.Server.Export.Document

spec :: Backing -> Spec
spec backing = describe "export with pandoc" $ do
  reading
  slides
  spaces
  overHttp backing
  oneAtATimeEach
  pdfs backing

-- | An image attachment, whose bytes are in the media bag.
tree :: Attachment
tree = Attachment {id = AttachmentId "a1", name = FileName "tree.png", mediaType = MimeType "image/png", size = 3, source = SourceBlob (BlobId "b1")}

-- | A PDF attachment, which a document links to.
paper :: Attachment
paper = Attachment {id = AttachmentId "a2", name = FileName "paper.pdf", mediaType = MimeType "application/pdf", size = 3, source = SourceBlob (BlobId "b2")}

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
    , publicUrl = Just (Url "https://wiki.example.org/")
    , inDocument = \_ _ -> Nothing
    , idPrefix = ""
    , macros = Macros []
    , boxes = []
    }
  where
    docsPages = [p | p <- demoArchive.pages, Just s <- [find (\s -> s.id == p.space) demoArchive.spaces], s.slug == slug "docs"]

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

blocksOf :: (HasCallStack) => Output -> Place -> Text -> IO [P.Block]
blocksOf output at source = either (\e -> panic ("pandoc: " <> show e)) pure (pageBlocks output at (readPage source))

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

  it "leaves out [[toc]], which the document's own table of contents stands for, but not a link to a page of that name" $ do
    bs <- blocksOf ToOther place "# A\n\n[[toc]]\n\nText, and [[toc]] here.\n"
    length bs `shouldBe` 2
    headers bs `shouldBe` [(1, "a")]

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

  it "makes a box of any kind a div of its class, titled with the title given, the kind's label or its name" $ do
    let titles = query (\case P.Div (_, ["title"], _) [P.Para xs] -> [xs]; _ -> [])
        boxClasses bs = [cls | P.Div (_, cls, _) _ <- bs]
    noted <- blocksOf ToOther place "> [!NOTE] Read me first\n> Careful.\n"
    boxClasses noted `shouldBe` [["note", "alert"]]
    titles noted `shouldBe` [[P.Str "Read", P.Space, P.Str "me", P.Space, P.Str "first"]]
    query (\case P.Para xs -> [xs]; _ -> []) noted `shouldBe` [[P.Str "Read", P.Space, P.Str "me", P.Space, P.Str "first"], [P.Str "Careful."]]
    plainBox <- blocksOf ToOther place "> [!FUN-FACT]\n> Owls.\n"
    boxClasses plainBox `shouldBe` [["alert-fun-fact"]]
    titles plainBox `shouldBe` [[P.Str "Fun", P.Space, P.Str "fact"]]
    let defined = place {boxes = [BoxKind {name = "exercise", label = "Try it", colour = Teal, icon = Pencil}]}
    exercise <- blocksOf ToOther defined "> [!EXERCISE]\n>\n> - Prove it.\n\n> [!exercise] Exercise 3\n> Again.\n"
    boxClasses exercise `shouldBe` [["alert-exercise"], ["alert-exercise"]]
    titles exercise `shouldBe` [[P.Str "Try", P.Space, P.Str "it"], [P.Str "Exercise", P.Space, P.Str "3"]]
    [() | P.BulletList _ <- query (\case b@P.BulletList {} -> [b]; _ -> []) exercise] `shouldBe` [()]
    quote <- blocksOf ToOther place "> [!NOTE]s are text\n\n> [!TODO2]\n> x\n"
    boxClasses quote `shouldBe` []
    [() | P.BlockQuote _ <- quote] `shouldBe` [(), ()]

  it "finds the boxes the page has and no others, with the title as the page shows it" $ do
    let titles = query (\case P.Div (_, ["title"], _) [P.Para xs] -> [xs]; _ -> [])
        boxClasses bs = query (\case P.Div (_, cls, _) _ | cls /= ["title"] -> [cls]; _ -> []) bs :: [[Text]]
    -- No space after the marker: a quotation on the page, so in the
    -- document too, its text kept.
    glued <- blocksOf ToOther place "> [!NOTE]**x**\n"
    boxClasses glued `shouldBe` []
    [() | P.BlockQuote _ <- glued] `shouldBe` [()]
    -- An escaped marker is text.
    escaped <- blocksOf ToOther place "> \\[!NOTE]\n> y\n"
    boxClasses escaped `shouldBe` []
    query (\case P.Str t -> [t]; _ -> []) escaped `shouldSatisfy` elem "[!NOTE]"
    -- In code, a marker is code.
    fenced <- blocksOf ToOther place "```\n> [!NOTE]\n```\n"
    boxClasses fenced `shouldBe` []
    -- The title is the text written, as the page shows it, not Markdown.
    written <- blocksOf ToOther place "> [!NOTE] Read *this* &amp; that\n> Body.\n"
    titles written `shouldBe` [B.toList (B.text "Read *this* &amp; that")]
    -- Nested in a list, and the second of two, each where the page has it.
    nested <- blocksOf ToOther place "- item\n\n  > [!TIP] One\n  > a\n\n> [!EXERCISE] Two\n> b\n"
    boxClasses nested `shouldBe` [["tip", "alert"], ["alert-exercise"]]
    titles nested `shouldBe` [[P.Str "One"], [P.Str "Two"]]
    show nested `shouldNotSatisfy` T.isInfixOf "wikibox"

  it "starts a box's content where the page does, whatever the first block is" $ do
    let boxClasses bs = query (\case P.Div (_, cls, _) _ | cls /= ["title"] -> [cls]; _ -> []) bs :: [[Text]]
        inBox bs = concat [rest | P.Div (_, ["note", "alert"], _) (_ : rest) <- bs]
    table <- blocksOf ToOther place "> [!NOTE]\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n"
    [() | P.Table {} <- inBox table] `shouldBe` [()]
    fencedDiv <- blocksOf ToOther place "> [!NOTE]\n> ::: summary\n> x\n> :::\n"
    [cls | P.Div (_, cls, _) _ <- inBox fencedDiv] `shouldBe` [["summary"]]
    html <- blocksOf ToOther place "> [!NOTE]\n> <div>x</div>\n"
    boxClasses html `shouldBe` [["note", "alert"]]
    [() | P.Para _ <- inBox html] `shouldBe` []
    show html `shouldNotSatisfy` T.isInfixOf "div>"
    -- In a numbered list item, the box stays in the one item.
    listed <- blocksOf ToOther place "1. > [!NOTE] T\n   > x\n"
    [length items | P.OrderedList _ items <- listed] `shouldBe` [1]
    boxClasses listed `shouldBe` [["note", "alert"]]

  it "reads a box whatever the page's line endings" $ do
    let boxTitles bs = [xs | P.Div (_, ["note", "alert"], _) (P.Div (_, ["title"], _) [P.Para xs] : _) <- bs]
    crlf <- blocksOf ToOther place "> [!NOTE] T\r\n> x\r\n"
    boxTitles crlf `shouldBe` [[P.Str "T"]]
    cr <- blocksOf ToOther place "> [!NOTE] T\r> x\r\r> [!NOTE] U\r> y\r"
    boxTitles cr `shouldBe` [[P.Str "T"], [P.Str "U"]]

  it "shows a marker as written where pandoc does not read a quotation, and no placeholder" $ do
    let boxClasses bs = query (\case P.Div (_, cls, _) _ | cls /= ["title"] -> [cls]; _ -> []) bs :: [[Text]]
    -- A tab after the first quotation mark: the wiki reads a box, pandoc
    -- code; the code shows the marker.
    tabbed <- blocksOf ToOther place ">\t> [!NOTE] A\n"
    boxClasses tabbed `shouldBe` []
    show tabbed `shouldNotSatisfy` T.isInfixOf "wikibox"
    show tabbed `shouldSatisfy` T.isInfixOf "[!NOTE] A"
    -- A placeholder spelled with an entity is not one: its digits depend
    -- on the whole page, so the page cannot hold them, and the box keeps
    -- its own title.
    spelled <- blocksOf ToOther place "> [!NOTE] Mine\n> x\n\n> wiki&#98;ox1z\n> y\n"
    boxClasses spelled `shouldBe` [["note", "alert"]]
    query (\case P.Div (_, ["title"], _) [P.Para xs] -> [xs]; _ -> []) spelled `shouldBe` [[P.Str "Mine"]]
    [() | P.BlockQuote _ <- spelled] `shouldBe` [()]

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

  it "keeps a deck's pauses and incremental boxes for Beamer, where the wiki reads them, and the rest as text" $ do
    bs <- blocksOf ToBeamer place stepsDeck
    let latex = [t | P.RawBlock (P.Format "latex") t <- query (\case b@P.RawBlock {} -> [b]; _ -> []) bs]
    -- The pause after "One", and the one that starts slide B: after a
    -- break, the count of items starts again.
    length (query pauses bs) `shouldBe` 2
    latex `shouldBe` ["\\pause[\\value{beamerpauses}]"]
    divClasses bs `shouldSatisfy` elem ["incremental"]
    [inner | P.BlockQuote inner <- query (\case b@P.BlockQuote {} -> [b]; _ -> []) bs]
      `shouldBe` [[P.Div ("", ["nonincremental"], []) [P.Para [P.Str ". . ."], P.BulletList [[P.Plain [P.Str "q"]]]]]]
    [inner | P.Div (_, ["notes"], _) inner <- query (\case b@P.Div {} -> [b]; _ -> []) bs]
      `shouldBe` [[P.Para [P.Str "Say."], P.Para [P.Str "More."]]]
    query (\case P.Note inner -> [inner]; _ -> []) bs `shouldBe` [[P.Para [P.Str ". . ."]]]

  it "leaves a deck's pauses out of PowerPoint, which has none, and keeps its incremental boxes" $ do
    bs <- blocksOf ToPowerPoint place stepsDeck
    length (query pauses bs) `shouldBe` 0
    raw bs `shouldBe` []
    divClasses bs `shouldSatisfy` elem ["incremental"]

  it "leaves the pauses out of any other document, where the three dots in a quotation or a footnote are text" $
    for_ [ToTeX, ToOther] $ \output -> do
      bs <- blocksOf output place stepsDeck
      [b | b <- bs, isPause b] `shouldBe` []
      query pauses (filter (\case P.BlockQuote _ -> False; _ -> True) bs) `shouldBe` [()]
      query (\case P.Note inner -> [inner]; _ -> []) bs `shouldBe` [[P.Para [P.Str ".", P.Space, P.Str ".", P.Space, P.Str "."]]]
      divClasses bs `shouldSatisfy` elem ["incremental"]

  it "gives a deck its title and its look" $ do
    let P.Pandoc (P.Meta meta) _ = slidesDocument "Deck" [("aspectratio", P.MetaString "43")] []
    Map.lookup "aspectratio" meta `shouldBe` Just (P.MetaString "43")
    Map.lookup "title" meta `shouldBe` Just (P.MetaInlines [P.Str "Deck"])

-- | A deck with steps: pauses, an incremental box, and three dots where
-- they are text (a quotation, the notes, a footnote).
stepsDeck :: Text
stepsDeck =
  T.unlines
    [ "## A"
    , ""
    , "One"
    , ""
    , ". . ."
    , ""
    , "Two"
    , ""
    , "::: incremental"
    , "- a"
    , "- b"
    , ":::"
    , ""
    , ". . ."
    , ""
    , "Three"
    , ""
    , "> . . ."
    , ">"
    , "> - q"
    , ""
    , "::: notes"
    , "Say."
    , ""
    , ". . ."
    , ""
    , "More."
    , ":::"
    , ""
    , "See[^1]."
    , ""
    , "[^1]: . . ."
    , ""
    , "---"
    , ""
    , "## B"
    , ""
    , ". . ."
    , ""
    , "Four"
    ]

pauses :: P.Block -> [()]
pauses b = [() | isPause b]

divClasses :: [P.Block] -> [[Text]]
divClasses = query $ \case
  P.Div (_, cls, _) _ -> [cls]
  _ -> []

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
docsIds :: Running -> IO (Space, Map Text PageSummary)
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
pagesOf :: (HasCallStack) => Running -> Space -> IO [PageSummary]
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

overHttp :: Backing -> Spec
overHttp backing = describe "over HTTP" $ do
  it "exports a page as DOCX: a zip with its document, its image in it and its math as Word's" $ withDemoRunning backing identity $ \r -> do
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

  it "exports a page as one HTML file holding its title, its image and its formulas as MathML, sandboxed" $ withDemoRunning backing identity $ \r -> do
    (_, pages) <- docsIds r
    reply <- getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Markdown guide").id Html)
    html <- decodeUtf8 <$> exported reply Html
    html `shouldSatisfy` T.isInfixOf "<title>Markdown guide</title>"
    html `shouldSatisfy` T.isInfixOf "data:image/png;base64,"
    header "Content-Security-Policy" reply `shouldSatisfy` maybe False (\c -> "sandbox" `T.isInfixOf` decodeUtf8 c)
    maths' <- decodeUtf8 <$> exported' r (pages Map.! "Mathematics").id Html
    maths' `shouldSatisfy` T.isInfixOf "<math"

  it "exports a page as EPUB" $ withDemoRunning backing identity $ \r -> do
    (_, pages) <- docsIds r
    files <- zipped =<< exported' r (pages Map.! "Tour").id Epub
    Map.lookup "mimetype" files `shouldBe` Just "application/epub+zip"

  it "exports a deck as PowerPoint, a slide a slide with the speaker's notes, and as Beamer's LaTeX" $ withDemoRunning backing identity $ \r -> do
    (_, pages) <- docsIds r
    let deck = pages Map.! "Presentations"
    files <- zipped =<< exported' r deck.id Pptx
    -- The title slide pandoc makes from the title, and the deck's nine.
    length [n | n <- Map.keys files, "ppt/slides/slide" `T.isPrefixOf` n, ".xml" `T.isSuffixOf` n] `shouldBe` 10
    [n | n <- Map.keys files, "ppt/notesSlides/" `T.isPrefixOf` n] `shouldSatisfy` (not . null)
    tex <- decodeUtf8 <$> exported' r deck.id BeamerTex
    tex `shouldSatisfy` T.isInfixOf "\\documentclass[\n  ignorenonframetext,\n  aspectratio=169,\n]{beamer}"
    tex `shouldSatisfy` T.isInfixOf "\\usetheme[]{Madrid}"
    tex `shouldSatisfy` T.isInfixOf "\\begin{frame}"
    tex `shouldSatisfy` T.isInfixOf "\\note{"
    tex `shouldSatisfy` T.isInfixOf "\\int_{-\\infty}^{\\infty}"

  it "exports a deck's steps as Beamer's overlays and PowerPoint's animation, and leaves them out elsewhere" $ withDemoRunning backing identity $ \r -> do
    pid <- newPage r "Steps" stepsDeck
    let export format = getUrl r (r.admin <> "/admin/" <> links.pages.export pid format) >>= (`exported` format)
    tex <- decodeUtf8 <$> export BeamerTex
    tex `shouldSatisfy` T.isInfixOf "\\pause\n"
    tex `shouldSatisfy` T.isInfixOf "\\pause[\\value{beamerpauses}]"
    tex `shouldSatisfy` T.isInfixOf "\\begin{itemize}[<+->]"
    slideFiles <- Map.filterWithKey (\n _ -> "ppt/slides/slide" `T.isPrefixOf` n && ".xml" `T.isSuffixOf` n) <$> (zipped =<< export Pptx)
    -- The title slide, the deck's two and pandoc's slide of footnotes: a
    -- pause makes no slide.
    Map.size slideFiles `shouldBe` 4
    -- The incremental list is built item by item; no pause is written out,
    -- and the quotation's and the footnote's three dots are text.
    filter ("<p:bldP" `BS.isInfixOf`) (Map.elems slideFiles) `shouldSatisfy` ((== 1) . length)
    sum (map (T.count ". . ." . decodeUtf8) (Map.elems slideFiles)) `shouldBe` 2
    document <- (`entryText` "word/document.xml") =<< zipped =<< export Docx
    -- Only the quotation's and the footnote's three dots, which are text.
    T.count ". . ." document `shouldBe` 1
    html <- decodeUtf8 <$> export Html
    T.count ". . ." html `shouldBe` 2

  it "offers presentations only of a deck, and refuses a format it cannot make, saying why" $ withDemoRunning backing identity $ \r -> do
    (docs, pages) <- docsIds r
    getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Tour").id Pptx) >>= jsonAs 400 >>= (`shouldBe` Invalid "Only a page written as slides exports as a presentation.")
    getUrl r (r.public <> "/" <> links.spaces.export docs.id BeamerTex) >>= jsonAs 400 >>= (`shouldBe` Invalid "A space exports as a document, not a presentation.")

  it "exports a space as one DOCX: a title page, a table of contents and every page in order" $ withDemoRunning backing identity $ \r -> do
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

  it "is for whoever may read the page or the space" $ withDemoRunning backing identity $ \r -> do
    team <- spaceAt r "team"
    handbook <- fromMaybe (panic "no handbook") . find (\p -> p.title == "Team handbook") <$> pagesOf r team
    getUrl r (r.public <> "/" <> links.pages.export handbook.id Docx) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    getUrl r (r.public <> "/" <> links.spaces.export team.id Docx) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    -- The operator, on the admin listener, may read every page.
    getUrl r (r.admin <> "/admin/" <> links.pages.export handbook.id Docx) >>= (`exported` Docx) >>= zipped >>= (`entryText` "word/document.xml") >>= (`shouldSatisfy` T.isInfixOf "Team handbook")

-- | An export from the public listener, which must have been made.
-- | A new page at the top of the Docs space, made by the operator.
newPage :: (HasCallStack) => Running -> Text -> Text -> IO PageId
newPage r title body = do
  docs <- spaceAt r "docs"
  made <- sendJson r methodPost (r.admin <> "/admin/" <> links.spaces.createPage docs.id) NewPage {parent = Nothing, title, body} >>= jsonAs 201
  pure (made :: Page).id

exported' :: (HasCallStack) => Running -> PageId -> ExportFormat -> IO ByteString
exported' r pid format = getUrl r (r.public <> "/" <> links.pages.export pid format) >>= (`exported` format)

-- | How many pages a PDF has: its page objects, counted in its bytes and in
-- every stream that inflates, since TeX's PDFs keep their objects in
-- compressed object streams.
pdfPages :: ByteString -> IO Int
pdfPages pdf = do
  inflated <- for (streams pdf) $ \stream -> either (const "") identity <$> (try @SomeException (evaluate (BSL.toStrict (Zlib.decompress (BSL.fromStrict stream)))))
  pure (sum (map pagesIn (pdf : inflated)))
  where
    streams bytes = case BS.breakSubstring "stream" bytes of
      (_, rest)
        | BS.null rest -> []
        | otherwise ->
            let body = BS.dropWhile (`elem` [10, 13]) (BS.drop 6 rest)
                (content, rest') = BS.breakSubstring "endstream" body
             in content : streams (BS.drop 9 rest')
    -- @/Type/Page@ or @/Type /Page@, but not @/Pages@.
    pagesIn bytes = case BS.breakSubstring "/Type" bytes of
      (_, rest)
        | BS.null rest -> 0
        | otherwise ->
            let kind = BS.dropWhile (== 32) (BS.drop 5 rest)
                page = "/Page" `BS.isPrefixOf` kind && not ("/Pages" `BS.isPrefixOf` kind)
             in fromEnum page + pagesIn (BS.drop 5 rest)

-- | Whether the TeX engine's trees hold a file, by kpathsea's own lookup, as
-- the engine would find it.
texHas :: Text -> IO Bool
texHas file = do
  (code, out, _) <- readProcessWithExitCode "kpsewhich" [toS file] ""
  pure (code == ExitSuccess && not (T.null (T.strip (toS out))))

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

pdfs :: Backing -> Spec
pdfs backing = describe "PDFs, typeset by xelatex" $ do
  it "keep TeX to its working directory, with no programs, through kpathsea's variables" $ do
    restrictTeX
    for_ texLimits $ \(name, value) -> lookupEnv name `shouldReturn` Just value
    texLimits `shouldBe` [("openin_any", "p"), ("openout_any", "p"), ("shell_escape", "f")]

  it "do not let a page's formula read the server's files into the PDF" $ withDemoRunning backing identity $ \r -> do
    tex <- texEngine
    when (isNothing tex) (pendingWith "xelatex is not on this machine: TeX's limits were not tested against it")
    docs <- spaceAt r "docs"
    made <- sendJson r methodPost (r.admin <> "/admin/" <> links.spaces.createPage docs.id) NewPage {parent = Nothing, title = "Prying", body = "Here: $\\input{/etc/passwd}$ and\n\n```tikz\n\\node {\\input{/etc/passwd}};\n```\n"} >>= jsonAs 201
    reply <- getUrl r (r.admin <> "/admin/" <> links.pages.export (made :: Page).id Pdf)
    -- Refused, as TeX cannot open the file; or made without it.
    BSL.toStrict reply.body `shouldSatisfy` (not . ("root:" `BS.isInfixOf`))
    when (reply.status == 200) (BS.take 5 (BSL.toStrict reply.body) `shouldBe` "%PDF-")

  it "are offered exactly where the machine has xelatex" $ withRunning backing $ \r -> do
    tex <- isJust <$> texEngine
    formats <- availableFormats
    session <- ok200 (getUrl r (r.public <> "/" <> links.session))
    (session :: SessionInfo).exports `shouldBe` formats
    (Pdf `elem` formats, BeamerPdf `elem` formats) `shouldBe` (tex, tex)

  it "are refused, saying why, where it has not" $ withDemoRunning backing identity $ \r -> do
    tex <- texEngine
    when (isJust tex) (pendingWith "xelatex is on this machine, so the PDFs are made, not refused")
    (_, pages) <- docsIds r
    getUrl r (r.public <> "/" <> links.pages.export (pages Map.! "Tour").id Pdf) >>= jsonAs 400 >>= (`shouldBe` Invalid "PDF needs xelatex, which this server's machine does not have.")

  it "are made of a page that needs nothing beyond LaTeX where it has" $ withDemoRunning backing identity $ \r -> do
    tex <- texEngine
    when (isNothing tex) (pendingWith "xelatex is not on this machine: the PDFs were not tested")
    (_, pages) <- docsIds r
    bytes <- exported' r (pages Map.! "Tour").id Pdf
    BS.take 5 bytes `shouldBe` "%PDF-"

  it "are made of a page, a deck and a space where it has, with the packages they load" $ withDemoRunning backing identity $ \r -> do
    tex <- texEngine
    when (isNothing tex) (pendingWith "xelatex is not on this machine: the PDFs were not tested")
    -- The demo's Mathematics page writes chemistry (mhchem), its guide draws
    -- a TikZ picture and strikes text out (pandoc sets that with soul), and
    -- its deck is a Beamer presentation: the engine must have those
    -- packages, which Debian's texlive-xetex alone does not bring.
    missing <- filterM (fmap not . texHas) ["mhchem.sty", "tikz.sty", "soul.sty", "beamer.cls"]
    unless (null missing) $
      pendingWith ("xelatex is on this machine, but without " <> toS (T.intercalate ", " missing) <> " (Debian: texlive-science, texlive-pictures, texlive-plain-generic, texlive-latex-recommended), so the demo's PDFs were not tested")
    (docs, pages) <- docsIds r
    for_ [((pages Map.! "Mathematics").id, Pdf), ((pages Map.! "Presentations").id, BeamerPdf)] $ \(pid, format) -> do
      bytes <- exported' r pid format
      BS.take 5 bytes `shouldBe` "%PDF-"
    reply <- getUrl r (r.public <> "/" <> links.spaces.export docs.id Pdf)
    bytes <- exported reply Pdf
    BS.take 5 bytes `shouldBe` "%PDF-"
    -- A page for each step of the deck, after the title's page: the steps
    -- the browser shows.
    pid <- newPage r "Steps" stepsDeck
    pdf <- getUrl r (r.admin <> "/admin/" <> links.pages.export pid BeamerPdf) >>= (`exported` BeamerPdf)
    pdfPages pdf `shouldReturn` (1 + sum (map (\s -> s.steps) (either (panic . show) deckOf (parseMarkdown stepsDeck)).slides))
    -- The headers say nothing a browser would act on but the download.
    lookup "X-Content-Type-Options" reply.headers `shouldBe` Just "nosniff"
