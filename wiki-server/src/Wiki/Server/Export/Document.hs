-- | Conversion of a page, or a space's pages, into a pandoc document
-- (WP4.16 of docs/PLAN.md): what "Wiki.Server.Export" passes to pandoc's
-- writers. It is pure, so that what a page becomes is tested without
-- writing a file.
--
-- = Reading
--
-- The input is the page's own Markdown, read by pandoc's Markdown reader
-- with the extensions that match the syntax the wiki reads
-- ("Wiki.Core.Markdown.Ast", 'wikiExtensions'): pipe tables, footnotes,
-- fenced divs, @$…$@ and @\\(…\\)@ math, GitHub's task lists,
-- strikethrough, bare links, emoji and wiki links, and attributes in
-- braces. Boxes, @> [!KIND]@, are found by the wiki's own parser, not by
-- pandoc's, whose reader knows only GitHub's five kinds and no title
-- after the marker ('withBoxes'), so a document has a box exactly where
-- the page has one, with the same title. Raw HTML is read as raw, and goes through the wiki's
-- allowlist ("Wiki.Core.Markdown.Html") before pandoc sees it. A raw block
-- is reduced to what the allowlist keeps, written out again and read by
-- pandoc's HTML reader. Tags in the text are read together with the text
-- between them, as the page's renderer reads them, and turned into
-- pandoc's inlines. Raw TeX is not read: a page is not a LaTeX document,
-- and nothing an author writes reaches the TeX engine except the math and
-- TikZ the page shows as well.
--
-- = What the wiki adds
--
-- * __Boxes__ ("Wiki.Core.Markdown.Box"): GitHub's five kinds become
--   pandoc's own alerts, a div with the kind's class and @alert@ that
--   starts with a @title@ div, and any other kind a div of the same shape
--   with the class @alert-@ and its name. So HTML, DOCX and a PDF show a
--   box with its title (the one written after the marker, else the kind's
--   label) whatever its kind.
-- * __Math macros__ ("Wiki.Core.Math"): pandoc's writers typeset each
--   formula on its own, so the macros it uses in the wiki (its space's,
--   and those defined by the formulas before it on the page) are expanded
--   into it here, with texmath's own macro reader; a formula that only
--   defines macros is removed. Only @\\newcommand@, @\\renewcommand@ and
--   @\\DeclareMathOperator@ are read, which is what a space's block and
--   nearly every page use.
-- * __Islands__: a @math@ fence is display math. A Mermaid diagram needs a
--   browser to be drawn, which the server does not have, so it becomes a
--   note with its source. A TikZ picture is LaTeX already: in a document
--   LaTeX produces (a PDF, a Beamer deck) it is inserted as it is, with
--   the packages it loads added to the preamble; elsewhere it becomes a
--   note with its source.
-- * __Links and embeds__ ("Wiki.Core.Markdown.Link"): an attachment's
--   image is put into the document (its bytes, from the blob store, go
--   into pandoc's media bag under 'mediaPath'). An attachment that is not
--   an image, and a page of the wiki, become links to their addresses
--   under the wiki's public address, or plain text where there is none. In
--   a space's document a link to one of its pages goes to that page's
--   section. An image on the web becomes a link to it: the server fetches
--   nothing while it writes a document.
-- * __Slides__ ("Wiki.Core.Slides"): a deck is cut where the wiki cuts
--   it, at the top-level thematic breaks, and each slide is titled with its
--   first heading, as pandoc's slide writers expect. A level-one heading
--   becomes a section's title slide, any other a slide's title (a
--   level-two heading at pandoc's slide level 2), and a slide without one
--   gets an untitled one. The other headings on a slide are kept below the
--   slide level. The @notes@ divs are what pandoc writes as the speaker's
--   notes (@\\note{}@ in Beamer).
-- * __Steps__ ("Wiki.Core.Slides"): a pause, @. . .@ alone in a paragraph,
--   and a box with the class @incremental@ are pandoc's own markers, so its
--   Beamer writer makes overlays of them (@\\pause@, and @[\<+->]@ on the
--   lists), one PDF page for each step the wiki shows ('slideSteps'). Its
--   PowerPoint writer animates an incremental list, but has no pauses. A
--   pause is read where the wiki reads one, and only there; everywhere else
--   in a deck the three dots stay text, and a quotation's lists are never
--   incremental, since the wiki shows a quotation whole. In any other
--   document a pause is left out ('withoutPauses'), and an incremental box
--   is an ordinary one.
module Wiki.Server.Export.Document
  ( -- * Reading a page
    Place (..)
  , Output (..)
  , wikiExtensions
  , pageBlocks

    -- * Documents
  , pageDocument
  , slidesDocument
  , spaceDocument
  , DocumentPage (..)

    -- * Pieces
  , PageRead (..)
  , readPage
  , normalLines
  , mediaPath
  , tikzPreamble
  , slideBlocks
  , slideSteps
  , withoutPauses
  , isPause
  , htmlBlocks
  , htmlInlines
  , writeHtmlNodes
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen.Router.Duplex qualified as Duplex
import Protolude
import Text.Pandoc (PandocError, ReaderOptions (..), def, readHtml, readMarkdown, runPure)
import Text.Pandoc.Builder qualified as B
import Text.Pandoc.Definition qualified as P
import Text.Pandoc.Extensions (Extension (..), Extensions, extensionsFromList)
import Text.Pandoc.Walk (query, walk, walkM)
import Text.TeXMath.Readers.TeX.Macros (Macro, applyMacros, parseMacroDefinitions)
import Wiki.App.Route (PageLink (..), Route (..), resolvePageLink, route)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MediaKind (..), attachmentKind, findAttachment)
import Wiki.Core.Id (AttachmentId (..))
import Wiki.Core.Markdown.Ast (Block, BoxMarker (..), ParseError, parseWithMarkers)
import Wiki.Core.Markdown.Box (AlertKind (..), BoxKind, alertKindName, boxLabel, definedKind)
import Wiki.Core.Markdown.Html qualified as Html
import Wiki.Core.Markdown.Link (Destination (..), classifyDestination)
import Wiki.Core.Markdown.Tikz (TikzDocument (..), tikzDocument)
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Page (Page (title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))

-- | Where a page is: what its links and embeds are resolved against.
data Place = Place
  { spaces :: [Space]
  -- ^ The spaces the reader may view, for links to them and their pages.
  , spacePath :: [Slug]
  -- ^ The path of the page's space.
  , pages :: [Page]
  -- ^ The pages of its space.
  , pagePath :: [Slug]
  -- ^ The page's own path in its space.
  , attachments :: [Attachment]
  -- ^ The page's attachments.
  , stored :: AttachmentId -> Bool
  -- ^ Whether an attachment's bytes are in the media bag, at 'mediaPath'.
  , attachmentAddress :: Attachment -> Text
  -- ^ The address of an attachment the document links to rather than
  -- shows, relative to the wiki's address.
  , publicUrl :: Maybe Url
  -- ^ The wiki's public address, which a link out of the document starts
  -- with; without one, such a link becomes its text.
  , inDocument :: [Slug] -> [Slug] -> Maybe Text
  -- ^ The identifier of a page's section in this document, by its space's
  -- path and its own, if the document contains it (a space's does).
  , idPrefix :: Text
  -- ^ The prefix of this page's identifiers, so that two pages of one
  -- document cannot share an identifier.
  , macros :: Macros
  -- ^ The math macros of the page's space and its ancestors.
  , boxes :: [BoxKind]
  -- ^ The kinds of box the administrator defined, for their labels.
  }

-- | The kind of document being written, as far as reading a page cares.
data Output
  = -- | A Beamer presentation, its LaTeX or its PDF: a TikZ picture is
    -- inserted as it is, and a pause is Beamer's.
    ToBeamer
  | -- | A PowerPoint presentation: an incremental list is animated, and a
    -- pause is left out.
    ToPowerPoint
  | -- | A document LaTeX produces, a PDF: a TikZ picture is inserted as it
    -- is.
    ToTeX
  | -- | Anything else.
    ToOther
  deriving stock (Eq, Show)

-- | The extensions of pandoc's Markdown reader that read what the wiki's
-- own reader reads ("Wiki.Core.Markdown.Ast"), and no others: in
-- particular no raw TeX, no Markdown inside HTML, and no divs or spans
-- made of HTML, so that every piece of HTML stays raw for the allowlist.
-- Nor @alerts@: the boxes are the wiki parser's ('withBoxes').
wikiExtensions :: Extensions
wikiExtensions =
  extensionsFromList
    [ Ext_all_symbols_escapable
    , Ext_autolink_bare_uris
    , Ext_backtick_code_blocks
    , Ext_emoji
    , Ext_escaped_line_breaks
    , Ext_fenced_code_attributes
    , Ext_fenced_code_blocks
    , Ext_fenced_divs
    , Ext_footnotes
    , Ext_gfm_auto_identifiers
    , Ext_auto_identifiers
    , Ext_header_attributes
    , Ext_inline_code_attributes
    , Ext_intraword_underscores
    , Ext_link_attributes
    , Ext_lists_without_preceding_blankline
    , Ext_pipe_tables
    , Ext_raw_html
    , Ext_shortcut_reference_links
    , Ext_space_in_atx_header
    , Ext_startnum
    , Ext_strikeout
    , Ext_task_lists
    , Ext_tex_math_dollars
    , Ext_tex_math_single_backslash
    , Ext_wikilinks_title_after_pipe
    ]

-- | Where an attachment's bytes are in pandoc's media bag: under its id,
-- so that two pages' attachments with one name are two files, with its
-- name last, from whose extension pandoc reads a type where it needs one.
mediaPath :: Attachment -> FilePath
mediaPath a = toS ("attachments/" <> a.id.text <> "/" <> T.map safe a.name.text)
  where
    safe c = if c == '/' || c == '\\' then '_' else c

-- | A page's Markdown as blocks, with everything the wiki adds applied.
pageBlocks :: Output -> Place -> PageRead -> Either PandocError [P.Block]
pageBlocks output place page = do
  read' <- withBoxesRead place.boxes page
  pure
    . expandMacros place.macros
    . walk (resolveInlines place)
    . walk (concatMap (islands output))
    . prefixIds place.idPrefix
    . walk (concatMap dropOptions)
    . walk htmlInlines
    . walk (concatMap htmlBlock)
    . steps
    $ filter (not . contentsMarker) read'
  where
    steps = case output of
      ToBeamer -> slideSteps True
      ToPowerPoint -> slideSteps False
      _ -> withoutPauses

-- | Whether a block is @[[toc]]@ alone in a paragraph, where the page
-- shows its table of contents ("Wiki.Core.Markdown.Toc"). Pandoc reads it
-- as a wiki link to a page called @toc@, and a document gets a table of
-- contents from the writer, so it is left out.
contentsMarker :: P.Block -> Bool
contentsMarker = \case
  P.Para [P.Link _ [P.Str label] (target, _)] -> T.toLower label == "toc" && T.toLower target == "toc"
  _ -> False

-- | A page, as a document of its own, titled as the page shows it
-- ('titled').
pageDocument :: Text -> [P.Block] -> P.Pandoc
pageDocument title blocks = P.Pandoc (P.Meta (Map.fromList [("title", P.MetaInlines heading)])) body
  where
    (heading, body) = titled title blocks

-- | A page's title and the rest of it, as the page shows them
-- ("Wiki.App.View.Body"): a page whose Markdown starts with a level-one
-- heading is titled with that heading, and any other with its title.
titled :: Text -> [P.Block] -> ([P.Inline], [P.Block])
titled title = \case
  P.Header 1 _ xs : rest -> (xs, rest)
  bs -> (B.toList (B.text title), bs)

-- | A deck, as a document for pandoc's slide writers: its title, the given
-- metadata (the theme's and the aspect ratio's), and its slides. A deck
-- that starts with a title slide (a level-one heading) is titled with it,
-- since pandoc makes the title slide from the title; any other deck is
-- titled as its page is.
slidesDocument :: Text -> [(Text, P.MetaValue)] -> [P.Block] -> P.Pandoc
slidesDocument title meta blocks = case slideBlocks blocks of
  P.Header 1 _ xs : rest -> deck xs rest
  bs -> deck (B.toList (B.text title)) bs
  where
    deck xs = P.Pandoc (P.Meta (Map.fromList (("title", P.MetaInlines xs) : meta)))

-- | One of the pages of a space's document.
data DocumentPage = DocumentPage
  { page :: Page
  , depth :: Int
  -- ^ How deep it is in the space's tree, the top level being 0.
  , anchor :: Text
  -- ^ Its section's identifier.
  , blocks :: [P.Block]
  -- ^ Its content ('pageBlocks').
  }

-- | A space's pages as one document, in the given order (the space's):
-- each page a section under its title ('titled'), as deep as the page is
-- in the tree, with its own headings below that. The title page and the
-- table of contents come from the writer ("Wiki.Server.Export"), from the
-- metadata.
spaceDocument :: Space -> Text -> [DocumentPage] -> P.Pandoc
spaceDocument space subtitle documentPages =
  P.Pandoc
    ( P.Meta
        ( Map.fromList
            ( [ ("title", P.MetaInlines (B.toList (B.text space.name)))
              , ("subtitle", P.MetaInlines (B.toList (B.text subtitle)))
              ]
                <> [("abstract", P.MetaBlocks [P.Para (B.toList (B.text space.description))]) | not (T.null (T.strip space.description))]
            )
        )
    )
    (concatMap section documentPages)
  where
    section p =
      let level = min 6 (p.depth + 1)
          (heading, body) = titled p.page.title p.blocks
       in P.Header level (p.anchor, [], []) heading : shiftHeadings level body

-- | Move every heading this many levels down, at most to level 6.
shiftHeadings :: Int -> [P.Block] -> [P.Block]
shiftHeadings by = walk $ \case
  P.Header l attr xs -> P.Header (min 6 (l + by)) attr xs
  b -> b

----------------------------------------------------------------------
-- Boxes

-- | 'PageRead' is a page's Markdown as the export reads it: the source,
-- with its line endings made @\\n@ ('normalLines'), and what the wiki's
-- parser makes of it, the blocks and the markers of the boxes
-- ("Wiki.Core.Markdown.Ast"'s 'parseWithMarkers'). The export parses a
-- page with the wiki's parser once, and the blocks say whether it is a
-- deck and how its slides look, the markers where its boxes are.
data PageRead = PageRead
  { source :: Text
  , blocks :: Either ParseError [Block]
  , markers :: [BoxMarker]
  }

-- | A page's Markdown, read ('PageRead').
readPage :: Text -> PageRead
readPage raw = PageRead {source, blocks = fst <$> parsedPage, markers = either (const []) snd parsedPage}
  where
    source = normalLines raw
    parsedPage = parseWithMarkers source

-- | A text with every line ended by @\\n@: CommonMark ends a line at
-- @\\r\\n@, at @\\r@ and at @\\n@ alike, so the lines of the result are
-- those the wiki's parser counts ('BoxMarker').
normalLines :: Text -> Text
normalLines = T.replace "\r" "\n" . T.replace "\r\n" "\n"

-- | The page as pandoc reads it, with its boxes where the wiki's parser
-- finds them ('withBoxes', 'boxesOf'). A marker pandoc does not read as
-- the start of a quotation (where the two parsers differ, as with a tab
-- that makes pandoc read code) is not replaced, and the page is read
-- again without it, so the document shows the marker as written, and no
-- placeholder.
withBoxesRead :: [BoxKind] -> PageRead -> Either PandocError [P.Block]
withBoxesRead defined page = go page.markers
  where
    go markers = do
      let (marked, boxes) = withBoxes page.source markers
      P.Pandoc _ read' <- runPure (readMarkdown def {readerExtensions = wikiExtensions} marked)
      let boxed = walk (boxesOf defined boxes) read'
          stray = Set.fromList (concatMap (\t -> [m | (placeholder, (m, _)) <- Map.toList boxes, placeholder `T.isInfixOf` t]) (texts boxed))
      if Set.null stray then pure boxed else go (filter (`Set.notMember` stray) markers)
    -- Every text a document holds where a placeholder could end up.
    texts :: [P.Block] -> [Text]
    texts bs =
      query (\case P.Str t -> [t]; P.Code _ t -> [t]; P.Math _ t -> [t]; P.RawInline _ t -> [t]; _ -> []) bs
        <> query (\case P.CodeBlock _ t -> [t]; P.RawBlock _ t -> [t]; _ -> []) bs

-- | 'Boxes' are the boxes of a page, each by the placeholder its marker
-- was replaced with ('withBoxes'): its marker as the wiki's parser read
-- it, and the text the placeholder replaced.
type Boxes = Map Text (BoxMarker, Text)

-- | A page's source with the marker of each of these boxes (@[!KIND]@ and
-- the title after it) replaced by a placeholder, and the boxes by their
-- placeholders. Pandoc reads each such box as a quotation that starts with
-- its placeholder, which 'boxesOf' makes the box. So pandoc never decides
-- what is a box: a marker the wiki reads as text (escaped, in code, with
-- no space before a title) is text in the document too, and a title is the
-- text the page shows.
--
-- The placeholder line is followed by a line of the quotation marks of
-- its prefix and nothing else, a blank line inside the quotation, so that what follows
-- (a table, a fenced div, HTML) starts a block of its own, as it does
-- after the marker on the page; the lines are rewritten by the numbers
-- the parser gave them, so the added lines move nothing.
--
-- A placeholder is @wikibox@, eight hexadecimal digits of the SHA-256 of
-- the source, a number and @z@, so that no placeholder is the start of
-- another. Pandoc decodes entities, so a page could spell a placeholder
-- (@wiki&#98;ox@…) and take a box's title, if it could know the digits:
-- they depend on the whole page, the spelling included, so it cannot. If
-- the source holds the family's start already (it may quote this
-- documentation), more of the digest is taken, and with all 64 digits
-- there the boxes are left as pandoc reads them.
withBoxes :: Text -> [BoxMarker] -> (Text, Boxes)
withBoxes source markers = case family of
  Nothing -> (source, mempty)
  Just prefix ->
    let placed =
          Map.fromList
            [ (m.markerLine, (prefix <> show n <> "z", m, start, T.drop start text))
            | (n, m) <- zip [1 :: Int ..] markers
            , Just text <- [atMay lines' (m.markerLine - 1)]
            , Just start <- [markerStart m text]
            ]
        rewrite n text = case Map.lookup n placed of
          Just (placeholder, _, start, _) -> [T.take start text <> placeholder, quoteOnly (T.take start text)]
          Nothing -> [text]
     in ( T.intercalate "\n" (concat (zipWith rewrite [1 ..] lines'))
        , Map.fromList [(placeholder, (m, original)) | (placeholder, m, _, original) <- Map.elems placed]
        )
  where
    lines' = T.splitOn "\n" source
    digest = decodeUtf8 (BSL.toStrict (toLazyByteString (byteStringHex (SHA256.hash (encodeUtf8 source)))))
    family = find (not . (`T.isInfixOf` source)) [prefix | n <- [8, 16, 64], let prefix = "wikibox" <> T.take n digest]
    -- The prefix of the marker's line with everything but the quotation
    -- marks (a list item's marker, its number) made spaces, so that the
    -- line continues the same list item and quotation instead of starting
    -- another item.
    quoteOnly = T.stripEnd . T.map (\c -> if c == '>' || c == '\t' then c else ' ')
    -- The marker starts at its column and runs to the end of the line. A
    -- tab before it counts to a tab stop, so the column is checked, and
    -- the line searched where it does not hold the marker.
    markerStart m text
      | "[!" `T.isPrefixOf` T.drop (m.markerColumn - 1) text = Just (m.markerColumn - 1)
      | otherwise = case T.breakOn "[!" text of
          (_, "") -> Nothing
          (before, _) -> Just (T.length before)

-- | A quotation that starts with a box's placeholder ('withBoxes') as the
-- box: GitHub's five kinds as pandoc's alerts are made (a div with the
-- kind's class and @alert@), any other kind as a div with the class
-- @alert-@ and its name, each starting with a @title@ div that holds the
-- box's title (the one written after the marker, else the kind's label).
-- Any other block is left as it is.
boxesOf :: [BoxKind] -> Boxes -> P.Block -> P.Block
boxesOf defined boxes = \case
  P.BlockQuote (P.Para (P.Str placeholder : after) : rest)
    | Just (m, _) <- Map.lookup placeholder boxes ->
        let label = fromMaybe (boxLabel (definedKind defined m.boxKind) m.boxKind) m.boxTitle
            classes = case m.boxKind of
              Custom name -> ["alert-" <> name]
              builtIn -> [alertKindName builtIn, "alert"]
            firstPara = case after of
              b : more | lineBreak b -> more
              more -> more
         in P.Div ("", classes, []) (P.Div ("", ["title"], []) [P.Para (B.toList (B.text label))] : [P.Para firstPara | not (null firstPara)] <> rest)
  b -> b
  where
    lineBreak = \case
      P.SoftBreak -> True
      P.LineBreak -> True
      _ -> False

----------------------------------------------------------------------
-- Raw HTML, through the allowlist

-- | A raw HTML block, as the part the allowlist keeps, read by pandoc's
-- HTML reader.
htmlBlock :: P.Block -> [P.Block]
htmlBlock = \case
  P.RawBlock f raw | isHtml f -> htmlBlocks raw
  b -> [b]

-- | Raw HTML, reduced to what the allowlist keeps, as pandoc's blocks.
htmlBlocks :: Text -> [P.Block]
htmlBlocks raw = case Html.parseHtml raw of
  [] -> []
  nodes -> either (const [P.Para (B.toList (B.text (Html.htmlText nodes)))]) (\(P.Pandoc _ bs) -> bs) (runPure (readHtml def (writeHtmlNodes nodes)))

-- | Inlines with tags among them, read together with the text between the
-- tags, as the page's renderer reads them: the tags the allowlist keeps,
-- as pandoc's inlines, containing the text.
htmlInlines :: [P.Inline] -> [P.Inline]
htmlInlines xs
  | any isRawHtml xs = concatMap inlineOf (Html.parseFragments Html.Phrasing (map fragment xs))
  | otherwise = xs
  where
    isRawHtml = \case
      P.RawInline f _ -> isHtml f
      _ -> False
    fragment = \case
      P.RawInline f raw | isHtml f -> Html.Markup raw
      x -> Html.Markdown x
    inlineOf :: Html.Node P.Inline -> [P.Inline]
    inlineOf = \case
      Html.Content x -> [x]
      Html.TextNode t -> B.toList (B.text t)
      Html.Element name attrs children ->
        let inner = concatMap inlineOf children
            attr = (fromMaybe "" (lookup "id" attrs), T.words (fromMaybe "" (lookup "class" attrs)), [])
         in case name of
              _ | name `elem` ["strong", "b"] -> [P.Strong inner]
              _ | name `elem` ["em", "i"] -> [P.Emph inner]
              _ | name `elem` ["s", "del", "strike"] -> [P.Strikeout inner]
              "u" -> [P.Underline inner]
              "sub" -> [P.Subscript inner]
              "sup" -> [P.Superscript inner]
              _ | name `elem` ["code", "kbd"] -> [P.Code attr (plain inner)]
              "br" -> [P.LineBreak]
              "a" -> case lookup "href" attrs of
                Just href -> [P.Link attr inner (href, fromMaybe "" (lookup "title" attrs))]
                Nothing -> [P.Span attr inner]
              "img" -> case lookup "src" attrs of
                Just src ->
                  [ P.Image
                      (fst3 attr, snd3 attr, [(k, v) | (k, v) <- attrs, k `elem` ["width", "height"]])
                      (B.toList (B.text (fromMaybe "" (lookup "alt" attrs))))
                      (src, fromMaybe "" (lookup "title" attrs))
                  ]
                Nothing -> []
              _ -> [P.Span (fst3 attr, snd3 attr <> [name | name /= "span"], []) inner]
    fst3 (a, _, _) = a
    snd3 (_, b, _) = b

-- | The text of some inlines, without their markup.
plain :: [P.Inline] -> Text
plain = query $ \case
  P.Str t -> t
  P.Space -> " "
  P.SoftBreak -> " "
  P.LineBreak -> " "
  P.Code _ t -> t
  P.Math _ t -> t
  _ -> ""

isHtml :: P.Format -> Bool
isHtml f = f == P.Format "html"

-- | What the allowlist kept, written out as HTML again, with its text and
-- attribute values escaped, so that pandoc reads exactly that tree.
writeHtmlNodes :: [Html.Node Void] -> Text
writeHtmlNodes = foldMap node
  where
    node = \case
      Html.Element name attrs children
        | name `elem` voidElements -> open name attrs
        | otherwise -> open name attrs <> foldMap node children <> "</" <> name <> ">"
      Html.TextNode t -> escape t
    open name attrs = "<" <> name <> foldMap (\(k, v) -> " " <> k <> "=\"" <> escape v <> "\"") attrs <> ">"
    escape = T.concatMap $ \case
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      '"' -> "&quot;"
      c -> T.singleton c
    voidElements = ["br", "hr", "img", "source", "wbr"]

----------------------------------------------------------------------
-- What the wiki adds

-- | Remove the @slides@ div, which only says how a deck looks and shows
-- nothing.
dropOptions :: P.Block -> [P.Block]
dropOptions = \case
  P.Div (_, cls, _) _ | "slides" `elem` cls -> []
  b -> [b]

-- | Prefix every identifier of the page, and every link to one, so that
-- the pages of one document do not share identifiers.
prefixIds :: Text -> [P.Block] -> [P.Block]
prefixIds "" = identity
prefixIds prefix = walk inline . walk block
  where
    block = \case
      P.Header l (i, c, kv) xs -> P.Header l (prefixed i, c, kv) xs
      P.Div (i, c, kv) bs -> P.Div (prefixed i, c, kv) bs
      b -> b
    inline = \case
      P.Link attr xs (url, title) | Just fragment <- T.stripPrefix "#" url -> P.Link attr xs ("#" <> prefixed fragment, title)
      P.Span (i, c, kv) xs -> P.Span (prefixed i, c, kv) xs
      x -> x
    prefixed i = if T.null i then i else prefix <> i

-- | The islands, as a document shows them.
islands :: Output -> P.Block -> [P.Block]
islands output = \case
  P.CodeBlock (_, cls, _) code
    | "math" `elem` cls -> [P.Para [P.Math P.DisplayMath code]]
    | "mermaid" `elem` cls -> islandNote "A Mermaid diagram is drawn here in the wiki; a document cannot draw it. Its source:" code
    | "tikz" `elem` cls ->
        if output `elem` [ToTeX, ToBeamer]
          then -- A picture LaTeX draws, inserted as it is, centred, in a
          -- div that carries what it loads for the preamble
          -- ('tikzPreamble').
            let picture = tikzDocument code
             in [P.Div ("", ["tikz"], [("preamble", picture.preamble)]) [P.RawBlock (P.Format "latex") ("\\begin{center}\n" <> picture.picture <> "\n\\end{center}")]]
          else islandNote "A TikZ picture is drawn here in the wiki, and in a PDF; this document cannot draw it. Its source:" code
  b -> [b]
  where
    islandNote text code = [P.Div ("", ["island-note"], []) [P.Para [P.Emph (B.toList (B.text text))], P.CodeBlock ("", [], []) code]]

-- | Links and embeds, resolved for a document.
resolveInlines :: Place -> P.Inline -> P.Inline
resolveInlines place = \case
  P.Link attr xs (dest, title) -> case linkTarget place dest of
    Just url -> P.Link attr xs (url, title)
    Nothing -> P.Span attr xs
  P.Image attr xs (dest, title) -> case embedOf place dest of
    Embedded file -> P.Image attr xs (file, title)
    Linked url -> P.Link attr (if null xs then B.toList (B.text dest) else xs) (url, title)
    Unlinked -> P.Span attr (if null xs then B.toList (B.text dest) else xs)
  x -> x

-- | What an embed becomes in a document.
data Embed
  = -- | An image, from the media bag.
    Embedded Text
  | -- | A link to something the document cannot hold.
    Linked Text
  | -- | Its caption: all that is left of something the document can
    -- neither contain nor link to.
    Unlinked

embedOf :: Place -> Text -> Embed
embedOf place dest = case classifyDestination dest of
  ToAttachment name -> attachment name
  -- A path names an attachment first, as a source in raw HTML does, and
  -- otherwise a page.
  ToPath path | Just _ <- findAttachment path place.attachments -> attachment path
  ToUrl url -> Linked url
  _ -> maybe Unlinked Linked (linkTarget place dest)
  where
    attachment name = case findAttachment name place.attachments of
      Just a
        | attachmentKind a == MediaImage && place.stored a.id -> Embedded (toS (mediaPath a))
        | otherwise -> maybe Unlinked Linked (absolute place (place.attachmentAddress a))
      Nothing -> Unlinked

-- | Where a link leads from a document, if anywhere.
linkTarget :: Place -> Text -> Maybe Text
linkTarget place dest = case classifyDestination dest of
  ToUrl url -> Just url
  -- Already prefixed, like the identifiers ('prefixIds').
  ToAnchor fragment -> Just ("#" <> fragment)
  ToAttachment name -> absolute place . place.attachmentAddress =<< findAttachment name place.attachments
  ToPath _ -> do
    PageLink r fragment <- resolvePageLink place.spaces place.spacePath place.pages place.pagePath dest
    case r of
      Page s p | Just anchor <- place.inDocument s p -> Just ("#" <> anchor)
      _ -> absolute place (Duplex.print route r <> fragment)

-- | An address in the wiki, under its public address.
absolute :: Place -> Text -> Maybe Text
absolute place path = place.publicUrl <&> \base -> T.dropWhileEnd (== '/') base.text <> "/" <> T.dropWhile (== '/') path

-- | Expand into each formula the macros it uses in the wiki: the space's,
-- then those of the formulas before it, the nearest definition winning. A
-- formula that only defines macros is removed.
expandMacros :: Macros -> [P.Block] -> [P.Block]
expandMacros (Macros spaceBlocks) bs = dropEmpty (evalState (walkM expand bs) initial)
  where
    initial = foldl' (\ms block -> fst (parseMacroDefinitions block) <> ms) [] spaceBlocks
    expand :: P.Inline -> State [Macro] P.Inline
    expand = \case
      P.Math kind tex -> do
        known <- get
        let (defined, rest) = parseMacroDefinitions tex
            now = defined <> known
        put now
        pure (P.Math kind (applyMacros now rest))
      x -> pure x
    dropEmpty = walk (filter (not . emptyMath)) . walk (filter (not . emptyPara))
    emptyMath = \case
      P.Math _ tex -> T.null (T.strip tex)
      _ -> False
    emptyPara = \case
      P.Para xs -> not (null xs) && all emptyMath xs
      _ -> False

----------------------------------------------------------------------
-- Slides

-- | A deck's blocks as pandoc's slide writers read them at slide level 2:
-- cut at the top-level thematic breaks as "Wiki.Core.Slides" cuts them,
-- each slide's first heading as its title (a level-one heading as a
-- section's title slide, anything else as a level-two heading), an
-- untitled slide given an empty title, and the other headings below the
-- slide level.
slideBlocks :: [P.Block] -> [P.Block]
slideBlocks = concatMap slide . filter (not . null) . splitAtRules
  where
    splitAtRules bs = case break (== P.HorizontalRule) bs of
      (before, []) -> [before]
      (before, _ : after) -> before : splitAtRules after
    slide bs =
      let (before, rest) = break isHeader bs
       in case rest of
            P.Header 1 attr xs : after ->
              P.Header 1 attr xs : (if null (before <> after) then [] else P.Header 2 nullAttr' [] : below (before <> after))
            P.Header _ attr xs : after -> P.Header 2 attr xs : below (before <> after)
            _ -> P.Header 2 nullAttr' [] : below bs
    isHeader = \case
      P.Header {} -> True
      _ -> False
    below = walk $ \case
      P.Header l attr xs -> P.Header (max 3 l) attr xs
      b -> b
    nullAttr' = ("", [], [])

-- | Whether a block is a pause, as pandoc reads @. . .@ alone in a
-- paragraph and its slide writers recognise it.
isPause :: P.Block -> Bool
isPause = (== P.Para [P.Str ".", P.Space, P.Str ".", P.Space, P.Str "."])

-- | A page's blocks without the pauses the wiki reads ('Wiki.Core.Markdown.Ast.Pause'):
-- at the top level, in boxes and alerts, and in list items. A document
-- that is not a presentation shows its content once, and would otherwise
-- print the three dots.
withoutPauses :: [P.Block] -> [P.Block]
withoutPauses = concatMap $ \case
  b | isPause b -> []
  P.Div attr bs -> [P.Div attr (withoutPauses bs)]
  P.BulletList items -> [P.BulletList (map withoutPauses items)]
  P.OrderedList attrs items -> [P.OrderedList attrs (map withoutPauses items)]
  b -> [b]

-- | A deck's steps as a slide writer reads them, Beamer's when the flag
-- says so, PowerPoint's otherwise. The pauses the wiki reads are kept for
-- Beamer and left out for PowerPoint, which has none, and those in the
-- speaker's notes are left out for both. Three dots anywhere else (a
-- quotation, a footnote) are made text that no writer reads as a pause,
-- and a quotation's lists are made not incremental, which pandoc would
-- otherwise make them, so that both writers show a quotation as the wiki
-- does: whole.
--
-- Beamer counts a pause after the items of an incremental list from after
-- the last item, and then one more: @\\pause@ would add a page that shows
-- nothing new. Such a pause is written @\\pause[\\value{beamerpauses}]@,
-- which starts the step right after the last item, as the wiki does. The
-- count starts again at each slide, at each top-level break.
slideSteps :: Bool -> [P.Block] -> [P.Block]
slideSteps beamer = walk inNotes . concat . (`evalState` False) . traverse topLevel
  where
    topLevel :: P.Block -> State Bool [P.Block]
    topLevel = \case
      P.HorizontalRule -> [P.HorizontalRule] <$ put False
      b -> block False b
    blocks :: Bool -> [P.Block] -> State Bool [P.Block]
    blocks incremental = fmap concat . traverse (block incremental)
    -- The state says whether an incremental list's item has come since
    -- the last pause.
    block :: Bool -> P.Block -> State Bool [P.Block]
    block incremental = \case
      b | isPause b -> do
        afterItems <- get
        put False
        pure $ case () of
          _
            | not beamer -> []
            | afterItems -> [P.RawBlock (P.Format "latex") "\\pause[\\value{beamerpauses}]"]
            | otherwise -> [b]
      P.Div attr@(_, cls, _) bs
        | "notes" `elem` cls -> pure [P.Div attr (walk (filter (not . isPause)) bs)]
        | otherwise -> pure . P.Div attr <$> blocks (incrementalIn cls incremental) bs
      P.BulletList items -> pure . P.BulletList <$> traverse (item incremental) items
      P.OrderedList attrs items -> pure . P.OrderedList attrs <$> traverse (item incremental) items
      P.BlockQuote bs -> pure [P.BlockQuote [P.Div ("", ["nonincremental"], []) (walk asText bs)]]
      b -> pure [b]
    item incremental bs = do
      when incremental (put True)
      blocks incremental bs
    incrementalIn cls incremental
      | "incremental" `elem` cls = True
      | "nonincremental" `elem` cls = False
      | otherwise = incremental
    asText b = if isPause b then P.Para [P.Str ". . ."] else b
    -- A footnote's pause is text too.
    inNotes = \case
      P.Note bs -> P.Note (walk asText bs)
      x -> x

-- | What the preamble needs for the TikZ pictures among some blocks: TikZ
-- itself and the libraries each picture loads, once each; nothing when
-- there is no picture.
tikzPreamble :: [P.Block] -> [Text]
tikzPreamble bs = case query pictures bs of
  [] -> []
  loaded -> ordNub ("\\usepackage{tikz}" : filter (not . T.null) loaded)
  where
    pictures = \case
      P.Div (_, cls, kv) _ | "tikz" `elem` cls -> [fromMaybe "" (lookup "preamble" kv)]
      _ -> []
