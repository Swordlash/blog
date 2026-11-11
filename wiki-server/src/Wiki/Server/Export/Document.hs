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
-- @$…$@ and @\\(…\\)@ math, GitHub's task lists, strikethrough, bare
-- links, emoji and wiki links, and attributes in braces. The wiki's own
-- blocks, @[[!name]]@ … @[[/name]]@, are found by the wiki's own parser,
-- and pandoc reads placeholders in their place ('withBoxes'); it reads no
-- fenced div (@:::@) and no pause (@. . .@) of its own, which the wiki
-- does not read either. Boxes, @> [!KIND]@, are found by the wiki's own parser, not by
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
--   box with its title whatever its kind: its kind's label and its number,
--   as the page numbers it (@Tip 2.3@), then the one written after the
--   marker, read as Markdown, so its math is math. A box in a footnote
--   has no number in a document: pandoc keeps a note inside the text that
--   refers to it, where the page shows it at the end.
-- * __Spoilers__ ("Wiki.Core.Markdown.Ast"): a document cannot hide
--   anything, so a block spoiler is a box with the class @alert-spoiler@,
--   titled with its description, its content shown; the wiki's parser
--   finds its marker lines, and they are rewritten as placeholders before
--   pandoc reads the page ('withBoxes', 'markedBlocks'). A spoiler the
--   page shows in red (not closed, or cutting a section) is its blocks as
--   they are, after its marker line and the reason as text, and so is a
--   broken marker line. A heading spoiler (@## [[!spoiler]] Question@) is its heading
--   and its section as they are: its marker is taken out of the
--   heading's line in the same pass, so pandoc reads an ordinary heading.
--   An inline spoiler, @||text||@, is its text in a @spoiler@ span
--   ('hiddenSpans').
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
--   note with its source. A code block whose fence has the class
--   @numbered@ (@codeNumbered@ in "Wiki.Core.Markdown.Ast") has pandoc's
--   class @numberLines@ in its place, which pandoc's writers number.
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
--   slide level. The @notes@ divs (@[[!notes]]@) are what pandoc writes
--   as the speaker's notes (@\\note{}@ in Beamer). The deck's look,
--   @[[!slides]]{…}@, is read from the wiki's parse ("Wiki.Server.Export").
-- * __Steps__ ("Wiki.Core.Slides"): a pause, @[[!pause]]@, becomes
--   pandoc's own, a paragraph of three dots, and a box with the class
--   @incremental@ is pandoc's own marker too, so its Beamer writer makes
--   overlays of them (@\\pause@, and @[\<+->]@ on the lists), one PDF page
--   for each step the wiki shows ('slideSteps'). Its PowerPoint writer
--   animates an incremental list, but has no pauses. A pause is made only
--   where the wiki reads one; three dots an author wrote stay text
--   ('dotsAsText'), and a quotation's lists are never incremental, since
--   the wiki shows a quotation whole. In any other document a pause is
--   left out ('withoutPauses'), and an incremental box is an ordinary one.
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
import Text.Pandoc.Extensions (Extension (..), Extensions, disableExtension, extensionsFromList)
import Text.Pandoc.Walk (query, walk, walkM)
import Text.TeXMath.Readers.TeX.Macros (Macro, applyMacros, parseMacroDefinitions)
import Wiki.App.Route (PageLink (..), Route (..), resolvePageLink, route)
import Wiki.App.Route qualified as R
import Wiki.Core.Attachment (Attachment (..), FileName (..), MediaKind (..), attachmentKind, findAttachment)
import Wiki.Core.Id (AttachmentId (..), PageId)
import Wiki.Core.Markdown.Ast (Attributes, Block (..), BoxMarker (..), Footnote (..), ListItem (..), MarkerLine (..), MarkerName (..), MarkerRole (..), MarkerStart (..), ParseError, SpoilerHead (..), WrittenIds (..), languageOfClasses, listingLanguage, markerAt, norenderClass, parseWithAllMarkers, spoilerProblemText)
import Wiki.Core.Markdown.Box (AlertKind (..), BoxCounter, BoxKind, Numbering, alertKindName, boxCaption, countBox, countSection, definedKind, startCounting)
import Wiki.Core.Markdown.Html qualified as Html
import Wiki.Core.Markdown.Link (Destination (..), classifyDestination)
import Wiki.Core.Markdown.Tikz (TikzDocument (..), tikzDocument)
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Page (Page (title))
import Wiki.Core.Slug (Slug, freshName, headingSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))

-- | Where a page is: what its links and embeds are resolved against.
data Place = Place
  { spaces :: [Space]
  -- ^ The spaces the reader may view, for links to them and their pages.
  , spacePath :: [Slug]
  -- ^ The path of the page's space.
  , root :: Maybe PageId
  -- ^ The root of its space's pages, the space's home page
  -- ('Wiki.Core.Space.rootPage'), which paths start under.
  , pages :: [Page]
  -- ^ The pages of its space.
  , pagePath :: [Slug]
  -- ^ The page's own path in its space ('Wiki.Core.Space.pagePath').
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
  , numbering :: Numbering
  -- ^ How the page's boxes are numbered: its space's way, and the page's
  -- number.
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
-- Nor @alerts@: the boxes are the wiki parser's ('withBoxes'). With
-- @hard_line_breaks@, since every line break of a page is one on the page
-- ("Wiki.Core.Markdown.Render").
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
    , Ext_footnotes
    , Ext_gfm_auto_identifiers
    , Ext_auto_identifiers
    , Ext_hard_line_breaks
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
  read' <- withBoxesRead place.boxes place.numbering page
  pure
    . expandMacros place.macros
    . walk (resolveInlines place)
    . walk (concatMap (islands output))
    . prefixIds place.idPrefix
    . walk (concatMap dropOptions)
    . walk htmlInlines
    . walk (concatMap htmlBlock)
    $ steps read'
  where
    steps = case output of
      ToBeamer -> slideSteps True
      ToPowerPoint -> slideSteps False
      _ -> withoutPauses

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
  , lineEdits :: Map Int (Int, MarkerEdit)
  -- ^ What becomes of each of the page's marker lines (those of its
  -- spoilers and of its other blocks of the wiki's own), by its line, with
  -- the column its marker starts at ('markerEdits').
  , written :: WrittenIds
  -- ^ The identifiers written in the page's source, and which of its
  -- headings have one written ('reidentified').
  , bars :: [((Int, Int), (Int, Int))]
  -- ^ Where the bars of each inline spoiler are, the opening pair's line
  -- and column and the closing pair's ('InlineBars').
  }

-- | A page's Markdown, read ('PageRead').
readPage :: Text -> PageRead
readPage raw =
  PageRead
    { source
    , blocks = (\(bs, _, _, _) -> bs) <$> parsedPage
    , markers = either (const []) (\(_, ms, _, _) -> ms) parsedPage
    , lineEdits = either (const mempty) (\(bs, _, ss, _) -> markerEdits bs ss) parsedPage
    , written = either (const (WrittenIds [] [])) (\(_, _, _, w) -> w) parsedPage
    , bars = either (const []) (\(_, _, ss, _) -> [((s.lineAt, s.columnAt), (l, c)) | s <- ss, InlineBars l c <- [s.role]]) parsedPage
    }
  where
    source = normalLines raw
    parsedPage = parseWithAllMarkers source

-- | 'MarkerEdit' is what the export writes in place of a marker line of
-- one of the wiki's own blocks ('withBoxes').
data MarkerEdit
  = -- | The start of a spoiler's box with this description as its title.
    OpenBox Text
  | -- | The start of a div with these attributes (a @notes@,
    -- @incremental@ or @div@ block).
    OpenDiv Attributes
  | -- | The end of the box or div that starts on this line.
    CloseBox Int
  | -- | A pause, which pandoc's slide writers read.
    PauseHere
  | -- | A line of text, as the page shows it in red.
    ShowLine Text
  | -- | Nothing: the end marker of a spoiler shown as its blocks, the
    -- deck's look and the table of contents' place, which a document
    -- gets from the writer.
    DropLine
  | -- | A line of attributes alone, @{.sorted}@, from its column to the
    -- end of the line. What comes before on the line stays: whatever opens
    -- the blocks the attributes are in (a quotation's @>@, a list item's
    -- marker, a footnote's label), so that pandoc reads the same blocks
    -- around what follows.
    DropAttributes
  | -- | A fence that took the attributes of a line before it, as the
    -- wiki's parser says ('TakesAttributes'): these, put after its fence,
    -- where pandoc reads them.
    TakeAttributes Attributes
  | -- | A heading spoiler's marker, from its column up to this one,
    -- where the heading's text starts, taken out of the line.
    DropMarker Int
  deriving stock (Eq, Show)

-- | What becomes of each marker line of a page, by its line: a spoiler
-- the page shows as one is a box; one the page shows in red
-- ('SpoilerHead''s @problem@) is its blocks, after its marker and the
-- reason as text; another block is a div, a pause a pause, and a broken
-- marker line is its text and the reason.
markerEdits :: [Block] -> [MarkerLine] -> Map Int (Int, MarkerEdit)
markerEdits doc markers = Map.fromList [(m.lineAt, (m.columnAt, e)) | m <- markers, Just e <- [edit m]]
  where
    -- The lines of the blocks other than spoilers that are closed.
    divs = Set.fromList [m.lineAt | m <- markers, Opens _ <- [m.role]]
    heads = Map.fromList [(h.line, h) | h <- concatMap headsOf doc]
    headsOf = \case
      Spoiler h bs -> h : concatMap headsOf bs
      BlockQuote bs -> concatMap headsOf bs
      List _ items -> concat [concatMap headsOf bs | ListItem _ bs <- items]
      Div _ bs -> concatMap headsOf bs
      Alert _ _ bs -> concatMap headsOf bs
      Footnotes notes -> concat [concatMap headsOf bs | Footnote _ _ bs <- notes]
      _ -> []
    edit m = case m.role of
      Starts _ description -> Just $ case Map.lookup m.lineAt heads of
        Just h | Just problem <- h.problem -> ShowLine (h.marker <> " — " <> spoilerProblemText h problem)
        _ -> OpenBox description
      Opens attrs -> Just (OpenDiv attrs)
      Ends start -> Just $ case Map.lookup start heads of
        Just h | isNothing h.problem -> CloseBox start
        _ | start `Set.member` divs -> CloseBox start
        _ -> DropLine
      Pauses -> Just PauseHere
      SetsSlides -> Just DropLine
      PlacesContents -> Just DropLine
      Faulty written why -> Just (ShowLine (written <> " — " <> why))
      HeadingMarker end -> Just (DropMarker end)
      -- An inline spoiler's bars are rewritten apart ('withBoxes').
      InlineBars _ _ -> Nothing
      -- A line of attributes alone, @{.sorted}@, which pandoc's reader
      -- would show as text.
      SetsAttributes -> Just DropAttributes
      TakesAttributes attrs -> Just (TakeAttributes attrs)

-- | Whether a fence opens at the start of a text: three backticks or
-- three tildes. The text starts where the wiki's parser says a fence that
-- took attributes starts ('TakesAttributes'), so an indented code block,
-- which takes them too and has no fence to carry them, is left as it is.
opensFence :: Text -> Bool
opensFence rest = any (`T.isPrefixOf` rest) ["```", "~~~"]

-- | A fence's opening line, from where the fence starts, with more
-- attributes, written as pandoc reads a fence's attributes: one pair of
-- braces after the fence, with the language as the first class
-- (@```{.mermaid .norender}@). The fence's own attributes come first, then
-- the others, in their order. What is before the fence on the line (the
-- blocks it is in) stays.
withFenceAttributes :: Attributes -> Text -> Text -> Text
withFenceAttributes added before rest =
  let (fence, info) = T.span (\c -> Just c == fmap fst (T.uncons rest)) rest
      (word, braces) = T.breakOn "{" (T.strip info)
      lang = T.strip word
      inside t = T.unwords [T.strip (T.dropWhile (== '{') g) | g <- T.splitOn "}" t, not (T.null (T.strip (T.dropWhile (== '{') g)))]
      written = \case
        ("id", v) -> "#" <> v
        ("class", v) -> T.unwords (map ("." <>) (T.words v))
        (k, v) -> k <> "=\"" <> T.replace "\"" "\\\"" v <> "\""
   in before <> fence <> "{" <> T.unwords (filter (not . T.null) (["." <> lang | not (T.null lang)] <> [inside braces] <> map written added)) <> "}"

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
withBoxesRead :: [BoxKind] -> Numbering -> PageRead -> Either PandocError [P.Block]
withBoxesRead defined numbering page = go page.markers page.lineEdits
  where
    go markers edits = do
      let (marked, boxes, markedLines, bars) = withBoxes page.source markers edits page.bars
      -- Without pandoc's automatic identifiers, so that a heading's
      -- identifier is one written in the source ('reidentified').
      P.Pandoc _ read' <- runPure (readMarkdown def {readerExtensions = disableExtension Ext_auto_identifiers wikiExtensions} marked)
      -- The three dots an author wrote are text before the pauses are
      -- made, so that only the wiki's pauses are pandoc's.
      let boxed = walk (markedBlocks markedLines) (walk (boxesOf defined boxes (numbersOf numbering boxes read')) (walk dotsAsText read'))
          found = texts boxed
          stray = Set.fromList (concatMap (\t -> [m | (placeholder, (m, _)) <- Map.toList boxes, placeholder `T.isInfixOf` t]) found)
          -- A block whose start or end pandoc did not read as a paragraph
          -- of its own, in the same list of blocks as the other, keeps
          -- both marker lines as written, and so does a line shown as
          -- text or a pause that pandoc did not read as a paragraph of
          -- its own.
          strayLines = [(line, e) | (placeholder, (line, e)) <- Map.toList markedLines, any (placeholder `T.isInfixOf`) found]
          strayMarked = Set.fromList (map fst strayLines <> [start | (_, CloseBox start) <- strayLines])
          unmarked = Map.filterWithKey (\line (_, e) -> line `Set.notMember` strayMarked && (case e of CloseBox start -> start `Set.notMember` strayMarked; _ -> True)) edits
      if Set.null stray && Set.null strayMarked
        then pure (reidentified page.written (maybe boxed (\b -> restoreBars b (walk (hiddenSpans b) boxed)) bars))
        else go (filter (`Set.notMember` stray) markers) unmarked
    -- Every text a document holds where a placeholder could end up.
    texts :: [P.Block] -> [Text]
    texts bs =
      query (\case P.Str t -> [t]; P.Code _ t -> [t]; P.Math _ t -> [t]; P.RawInline _ t -> [t]; _ -> []) bs
        <> query (\case P.CodeBlock _ t -> [t]; P.RawBlock _ t -> [t]; _ -> []) bs

-- | 'Boxes' are the boxes of a page, each by the placeholder its marker
-- was replaced with ('withBoxes'): its marker as the wiki's parser read
-- it, and the text the placeholder replaced.
type Boxes = Map Text (BoxMarker, Text)

-- | A page's source with the marker of each of these boxes (@[!KIND]@)
-- replaced by a placeholder, and the boxes by their placeholders. Pandoc
-- reads each such box as a quotation that starts with its placeholder,
-- which 'boxesOf' makes the box. So pandoc never decides what is a box: a
-- marker the wiki reads as text (escaped, in code, with no space before a
-- title) is text in the document too. The title stays after the
-- placeholder, on its line, so pandoc reads it as part of the page: a
-- reference link or a footnote in it finds its definition elsewhere in the
-- page, as on the page.
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
--
-- The marker lines of the wiki's own blocks are rewritten at the same
-- time ('MarkerEdit'). Each becomes a paragraph of a placeholder
-- (@wikibox@, the digits, @s@, a number and @z@), which 'markedBlocks'
-- makes what the line stands for once pandoc has read the page: the
-- start of a block and its end the two ends of a div (the start of a
-- spoiler's with its description after the placeholder, as the box's
-- title), a pause pandoc's pause, a line the page shows in red the line's
-- text, so that nothing in it is read as Markdown. So pandoc reads no
-- fenced div and no pause of its own: what an author wrote as @:::@ or
-- @. . .@ is text in a document, as on the page ('wikiExtensions',
-- 'dotsAsText'). Each placeholder is a paragraph of its own, so each of
-- these lines has an empty line (of the prefix's quotation marks)
-- before and after it. The deck's look, the table of contents' place and
-- the end marker of a spoiler shown in red become an empty line. A
-- heading spoiler's marker is taken out of its heading's line, with the
-- spaces after it, and nothing else of the line changes. The third
-- result is each marker line's placeholder, with its line and what it
-- becomes.
--
-- The bars of each inline spoiler the wiki's parser found are replaced
-- too, each pair by a placeholder ('Bars', the fourth result), which
-- 'hiddenSpans' pairs again once pandoc has read the page. So pandoc
-- never decides what is a spoiler either: bars it would read as text
-- once it has decoded them (@\\|@, @&#124;@) stay text.
withBoxes :: Text -> [BoxMarker] -> Map Int (Int, MarkerEdit) -> [((Int, Int), (Int, Int))] -> (Text, Boxes, Map Text (Int, MarkerEdit), Maybe Bars)
withBoxes source markers edits bars = case family of
  Nothing -> (source, mempty, mempty, Nothing)
  Just prefix ->
    let placed =
          Map.fromList
            [ (m.markerLine, (prefix <> show n <> "z", m, start, T.drop start text))
            | (n, m) <- zip [1 :: Int ..] markers
            , Just text <- [atMay lines' (m.markerLine - 1)]
            , Just start <- [markerStart m text]
            ]
        linePlaceholders = Map.fromList [(line, prefix <> "s" <> show n <> "z") | (n, line) <- zip [1 :: Int ..] (Map.keys edits)]
        -- Each pair of bars, by its line, with its column and its
        -- placeholder.
        barPlaceholders =
          Map.fromListWith
            (<>)
            ( concat
                [ [(ol, [(oc, "|" <> prefix <> "ho" <> show n <> "z|")]), (cl, [(cc, "|" <> prefix <> "hc" <> show n <> "z|")])]
                | (n, ((ol, oc), (cl, cc))) <- zip [1 :: Int ..] bars
                ]
            )
        -- A line with its bars replaced, from its end, so that each
        -- column is still the line's as written.
        withPlaceholders n text = foldl' place text (sortOn (Down . fst) (mapMaybe (\(c, p) -> (\i -> (i, p)) <$> barsAt text c) (Map.findWithDefault [] n barPlaceholders)))
        place text (i, placeholder) = T.take i text <> placeholder <> T.drop (i + 2) text
        rewrite n written =
          let text = withPlaceholders n written
           in case (Map.lookup n placed, Map.lookup n edits) of
                (Just (placeholder, m, start, _), _) -> [T.take start text <> placeholder <> maybe "" (const (" " <> titleIn (T.drop start text))) m.boxTitle, quoteOnly (T.take start text)]
                (Nothing, Just (column, e)) -> case indexAt text column of
                  -- No character at the marker's column, which the
                  -- wiki's parser never gives: the line stays as
                  -- written, and 'withBoxesRead' then reads the other
                  -- marker line of its block as written too.
                  Nothing -> [text]
                  Just i ->
                    let before = T.take i text
                        placeholder = fromMaybe "" (Map.lookup n linePlaceholders)
                        around ls = [quoteOnly before] <> ls <> [quoteOnly before]
                     in case e of
                          OpenBox _ -> around [before <> placeholder <> " " <> descriptionIn (T.drop i text)]
                          DropLine -> [quoteOnly before]
                          DropAttributes -> [before]
                          TakeAttributes attrs
                            | opensFence (T.drop i text) -> [withFenceAttributes attrs before (T.drop i text)]
                            | otherwise -> [text]
                          DropMarker end -> case indexAt text end of
                            Just j | markerAt (T.drop i text) == Just (Opening SpoilerName) -> [before <> T.drop j text]
                            _ -> [text]
                          _ -> around [before <> placeholder]
                (Nothing, Nothing) -> [text]
     in ( T.intercalate "\n" (concat (zipWith rewrite [1 ..] lines'))
        , Map.fromList [(placeholder, (m, original)) | (placeholder, m, _, original) <- Map.elems placed]
        , Map.fromList [(placeholder, (line, e)) | (line, placeholder) <- Map.toList linePlaceholders, Just (_, e) <- [Map.lookup line edits]]
        , Bars (prefix <> "h") <$ guard (not (null bars))
        )
  where
    -- The index in a line of the bars at a column, if they are there.
    barsAt text column = do
      i <- indexAt text column
      i <$ guard ("||" `T.isPrefixOf` T.drop i text)
    -- The index in a line of the character at a column, if one is
    -- there. The wiki's parser gives columns as CommonMark counts them:
    -- a tab counts to the next multiple of four columns. So a column is
    -- not an index into the line where a tab comes before it (a tab
    -- after a list item's marker, or before the lines of the item), and
    -- every column is turned into an index here.
    indexAt text column = go 0 1 (T.unpack text)
      where
        go i c rest
          | c == column = Just i
          | c > column = Nothing
          | otherwise = case rest of
              [] -> Nothing
              ch : more -> go (i + 1) (if ch == '\t' then c + 4 - (c - 1) `mod` 4 else c + 1) more
    -- A box's title, after its marker, as written.
    titleIn = T.strip . T.drop 1 . T.dropWhile (/= ']')
    -- A spoiler's description, in its start marker as written: from the
    -- parenthesis after the name to the last one.
    descriptionIn marker =
      let afterName = T.drop 1 (T.dropWhile (/= '}') marker)
          inside = T.drop 1 (T.dropWhile (/= '(') afterName)
       in T.strip (T.dropWhileEnd (/= ')') inside & T.dropEnd 1)
    lines' = T.splitOn "\n" source
    digest = decodeUtf8 (BSL.toStrict (toLazyByteString (byteStringHex (SHA256.hash (encodeUtf8 source)))))
    family = find (not . (`T.isInfixOf` source)) [prefix | n <- [8, 16, 64], let prefix = "wikibox" <> T.take n digest]
    -- The prefix of the marker's line with everything but the quotation
    -- marks (a list item's marker, its number) made spaces, so that the
    -- line continues the same list item and quotation instead of starting
    -- another item.
    quoteOnly = T.stripEnd . T.map (\c -> if c == '>' || c == '\t' then c else ' ')
    -- Where a box's marker starts in its line: at its column, as
    -- 'indexAt' counts it. It runs to the end of the line.
    markerStart m text = do
      i <- indexAt text m.markerColumn
      i <$ guard ("[!" `T.isPrefixOf` T.drop i text)

-- | Some blocks with the paragraphs of the placeholders 'withBoxes' wrote
-- for marker lines made what the lines stand for. The blocks between the
-- placeholders of a block's start and its end, in the same list of
-- blocks, become a div: a spoiler's a box with the class
-- @alert-spoiler@, titled with its description, as the other kinds'
-- boxes are ('boxesOf'), and any other the div of the attributes the
-- wiki's parser read. A pause's placeholder becomes pandoc's pause, and a
-- line shown in red its text. A start whose end is not in the same list
-- is left as it is; 'withBoxesRead' then reads the page again with both
-- lines as written.
markedBlocks :: Map Text (Int, MarkerEdit) -> [P.Block] -> [P.Block]
markedBlocks placeholders = go
  where
    go = \case
      [] -> []
      b : more
        | Just (placeholder, title) <- placed b
        , Just (line, e) <- Map.lookup placeholder placeholders
        , Just made <- opened e title
        , (inside, _ : after) <- break (closes line) more ->
            made (go inside) : go after
      b : more
        | Just (placeholder, []) <- placed b
        , Just (_, e) <- Map.lookup placeholder placeholders
        , Just made <- alone e ->
            made : go more
      b : more -> b : go more
    -- A placeholder and what follows it on its line: a paragraph, or the
    -- text of a tight list's item, which pandoc reads as plain text.
    placed = \case
      P.Para (P.Str placeholder : rest) -> Just (placeholder, rest)
      P.Plain (P.Str placeholder : rest) -> Just (placeholder, rest)
      _ -> Nothing
    opened e title = case e of
      OpenBox _ -> Just (P.Div ("", ["alert-spoiler"], []) . (P.Div ("", ["title"], []) [P.Para (dropWhile (== P.Space) title)] :))
      OpenDiv attrs | null title -> Just (P.Div (pandocAttributes attrs))
      _ -> Nothing
    alone = \case
      PauseHere -> Just (P.Para [P.Str ".", P.Space, P.Str ".", P.Space, P.Str "."])
      ShowLine shown -> Just (P.Para (B.toList (B.text shown)))
      _ -> Nothing
    closes line b = case placed b of
      Just (placeholder, []) | Just (_, CloseBox start) <- Map.lookup placeholder placeholders -> start == line
      _ -> False

-- | The wiki's attributes as pandoc's: the identifier, the classes and
-- the other attributes.
pandocAttributes :: Attributes -> P.Attr
pandocAttributes attrs =
  ( fromMaybe "" (lookup "id" attrs)
  , concatMap T.words [v | ("class", v) <- attrs]
  , [(k, v) | (k, v) <- attrs, k /= "id", k /= "class"]
  )

-- | A paragraph of three dots alone, which pandoc's slide writers read as
-- a pause, as the text it is on the page: one 'P.Str', which no writer
-- reads as a pause. The wiki's own pauses are made after this
-- ('markedBlocks').
dotsAsText :: P.Block -> P.Block
dotsAsText b = if isPause b then P.Para [P.Str ". . ."] else b

-- | 'Bars' are the placeholders 'withBoxes' put in place of the bars of
-- the page's inline spoilers: each starts with this text, then @o@ for an
-- opening pair or @c@ for a closing one, the spoiler's number and @z@,
-- between two single bars (so that pandoc reads emphasis next to it as it
-- reads it next to the bars).
newtype Bars = Bars Text

-- | A run of inlines with each inline spoiler as its text in a span of the
-- class @spoiler@. The wiki's parser found the spoilers' bars, and
-- 'withBoxes' put placeholders in their place, so a bar escaped or
-- written as a character reference, and bars in code, are what pandoc
-- read them as. An opening placeholder is paired with its own closing one
-- in the same run of inlines; one that pandoc put elsewhere (where it reads
-- emphasis differently) is its bars again.
hiddenSpans :: Bars -> [P.Inline] -> [P.Inline]
hiddenSpans (Bars family) xs
  | not (any hasPlaceholder xs) = xs
  | otherwise = B.toList (build pieces)
  where
    hasPlaceholder = \case
      P.Str t -> family `T.isInfixOf` t
      _ -> False
    -- The inlines, with each placeholder apart: whether it opens, and
    -- its spoiler's number.
    pieces :: [Either (Bool, Int) P.Inline]
    pieces = concatMap split xs
    split = \case
      P.Str t -> [either Left (Right . P.Str) p | p <- placeholdersIn (Bars family) t]
      x -> [Right x]
    build = \case
      [] -> mempty
      Left (True, n) : rest
        | (inside, _ : after) <- break (== Left (False, n)) rest -> B.spanWith ("", ["spoiler"], []) (build inside) <> build after
      Left _ : rest -> B.str "||" <> build rest
      Right x : rest -> B.singleton x <> build rest

-- | A text cut at the placeholders of inline spoilers' bars ('Bars'): its
-- text, and each placeholder as whether it opens and its spoiler's number.
placeholdersIn :: Bars -> Text -> [Either (Bool, Int) Text]
placeholdersIn (Bars family) t = case T.breakOn ("|" <> family) t of
  (before, "") -> [Right before | not (T.null before)]
  (before, rest) ->
    let after = T.drop (T.length family + 1) rest
        (digits, more) = T.span isDigit (T.drop 1 after)
        kind = T.take 1 after
     in case (kind, readMaybe (T.unpack digits), T.take 2 more) of
          (k, Just n, "z|") | k `elem` ["o", "c"] -> [Right before | not (T.null before)] <> [Left (k == "o", n)] <> placeholdersIn (Bars family) (T.drop 2 more)
          _ -> Right (before <> "|") : placeholdersIn (Bars family) (T.drop 1 rest)

-- | Any placeholder of an inline spoiler's bars left in code, math or raw
-- text (where pandoc read the source otherwise than the wiki) is its bars
-- again.
restoreBars :: Bars -> [P.Block] -> [P.Block]
restoreBars bars = walk inBlock . walk inInline
  where
    unplace t = T.concat [either (const "||") identity p | p <- placeholdersIn bars t]
    inInline = \case
      P.Code attrs t -> P.Code attrs (unplace t)
      P.Math kind t -> P.Math kind (unplace t)
      P.RawInline f t -> P.RawInline f (unplace t)
      x -> x
    inBlock = \case
      P.CodeBlock attrs t -> P.CodeBlock attrs (unplace t)
      P.RawBlock f t -> P.RawBlock f (unplace t)
      b -> b

-- | The document with the identifier of every heading that has none
-- written in the source made as the wiki makes it ("Wiki.Core.Markdown.Ast"'s
-- withHeadingIds), so that a link written on the page to a section lands
-- on it in the document too, and the writer's table of contents links to
-- the same identifiers. Pandoc makes them otherwise: a second @Answer@ is
-- @answer-1@ for it and @answer-2@ for the wiki.
--
-- An identifier written in the source (@## Title {#custom}@) is kept,
-- whatever it looks like. The written identifiers of headings, fenced divs
-- and code blocks are taken before any other, as the wiki takes them
-- ('WrittenIds'). Then, in the order of the document, every other heading
-- gets the slug of its text, or the first of @-2@, @-3@, … after it that
-- is free ('freshName').
--
-- Which headings have an identifier written is the wiki parser's answer
-- ('WrittenIds''s @headings@), matched to pandoc's headings by position
-- when both read the same number of headings and pandoc's identifier
-- agrees with each identifier the wiki read as written. The orders can
-- differ: pandoc keeps a footnote's blocks where the footnote is
-- referenced, and the wiki puts the footnotes at the end of the page, so
-- a heading inside a footnote has another position in each. Then pandoc's
-- own reading decides: the document is read without pandoc's automatic
-- identifiers ('withBoxesRead'), so a heading has an identifier exactly
-- when one is written for it.
reidentified :: WrittenIds -> [P.Block] -> [P.Block]
reidentified written blocks = evalState (walkM renamed blocks) (taken, keptOnes)
  where
    -- Pandoc's headings' identifiers, in the order 'renamed' visits them.
    pandocIds = reverse (execState (walkM (\b -> b <$ (case b of P.Header _ (ident, _, _) _ -> modify (ident :); _ -> pass)) blocks) [])
    aligned = length pandocIds == length written.headings && and (zipWith (\w ident -> maybe True (== ident) w) written.headings pandocIds)
    -- For each of pandoc's headings, in order, whether its identifier is
    -- one written in the source.
    keptOnes
      | aligned = map isJust written.headings
      | otherwise = map (not . T.null) pandocIds
    taken = Set.fromList (written.taken <> [ident | (True, ident) <- zip keptOnes pandocIds])
    renamed :: P.Block -> State (Set Text, [Bool]) P.Block
    renamed = \case
      P.Header level (ident, cls, kvs) xs -> do
        (taken', kept) <- get
        case kept of
          True : rest -> P.Header level (ident, cls, kvs) xs <$ put (taken', rest)
          _ -> do
            let fresh = freshName (`Set.member` taken') (headingSlug (headingText xs))
            put (Set.insert fresh taken', drop 1 kept)
            pure (P.Header level (fresh, cls, kvs) xs)
      b -> pure b

-- | A heading's text as the wiki reads it for its identifier
-- ("Wiki.Core.Markdown.Ast"'s plainText): the words without their markup,
-- code and formulas as written, a link's and an image's text, and nothing
-- of a footnote or of raw HTML.
headingText :: [P.Inline] -> Text
headingText = foldMap $ \case
  P.Str t -> t
  P.Space -> " "
  P.SoftBreak -> " "
  P.LineBreak -> " "
  P.Code _ t -> t
  P.Math _ t -> t
  P.Emph xs -> headingText xs
  P.Strong xs -> headingText xs
  P.Strikeout xs -> headingText xs
  P.Underline xs -> headingText xs
  P.Superscript xs -> headingText xs
  P.Subscript xs -> headingText xs
  P.SmallCaps xs -> headingText xs
  P.Quoted _ xs -> headingText xs
  P.Cite _ xs -> headingText xs
  P.Span _ xs -> headingText xs
  P.Link _ xs _ -> headingText xs
  P.Image _ xs _ -> headingText xs
  P.Note _ -> ""
  P.RawInline _ _ -> ""

-- | The number of each numbered box of a page ('withBoxes'), by its
-- placeholder, as the page's renderer numbers it ("Wiki.Core.Markdown.Box"):
-- in the order the boxes come in the document, each @##@ heading starting a
-- section. A box in a footnote is not reached, and has no number.
numbersOf :: Numbering -> Boxes -> [P.Block] -> Map Text Text
numbersOf numbering boxes read' = snd (execState (traverse_ go read') (startCounting numbering, mempty))
  where
    go :: P.Block -> State (BoxCounter, Map Text Text) ()
    go = \case
      P.Header 2 _ _ -> modify (first countSection)
      P.BlockQuote (P.Para (P.Str placeholder : _) : rest)
        | Just (m, _) <- Map.lookup placeholder boxes -> do
            when m.boxNumbered $ do
              (counter, numbers) <- get
              let (number, counter') = countBox m.boxKind counter
              put (counter', maybe numbers (\n -> Map.insert placeholder n numbers) number)
            traverse_ go rest
      P.BlockQuote bs -> traverse_ go bs
      P.Div _ bs -> traverse_ go bs
      P.BulletList items -> traverse_ (traverse_ go) items
      P.OrderedList _ items -> traverse_ (traverse_ go) items
      P.DefinitionList items -> traverse_ (traverse_ (traverse_ go) . snd) items
      _ -> pass

-- | A quotation that starts with a box's placeholder ('withBoxes') as the
-- box: GitHub's five kinds as pandoc's alerts are made (a div with the
-- kind's class and @alert@), any other kind as a div with the class
-- @alert-@ and its name, each starting with a @title@ div that holds the
-- box's title: the kind's label and the box's number ('numbersOf') if it
-- has one, then the title written after the marker, read as Markdown, as
-- the page shows them ('boxCaption'). Any other block is left as it is.
boxesOf :: [BoxKind] -> Boxes -> Map Text Text -> P.Block -> P.Block
boxesOf defined boxes numbers = \case
  P.BlockQuote (P.Para (P.Str placeholder : after) : rest)
    | Just (m, _) <- Map.lookup placeholder boxes ->
        let caption = boxCaption (definedKind defined m.boxKind) m.boxKind (Map.lookup placeholder numbers) (isJust m.boxTitle)
            -- The title is what pandoc read after the placeholder, up to
            -- the end of its line ('withBoxes').
            (onLine, more) = break lineBreak after
            title = map displayInline (dropWhile (== P.Space) onLine)
            label = B.toList (B.text caption) <> title
            classes = case m.boxKind of
              Custom name -> ["alert-" <> name]
              builtIn -> [alertKindName builtIn, "alert"]
            firstPara = drop 1 more
         in P.Div ("", classes, []) (P.Div ("", ["title"], []) [P.Para label] : [P.Para firstPara | not (null firstPara)] <> rest)
  b -> b
  where
    lineBreak = \case
      P.SoftBreak -> True
      P.LineBreak -> True
      _ -> False
    -- Display math in a title is set on the title's line, as the page sets
    -- it, wherever it is in the title's text: in emphasis and links too.
    -- A footnote's body is not the title's text, so its math stays as the
    -- page shows it.
    displayInline = \case
      P.Math P.DisplayMath tex -> P.Math P.InlineMath ("\\displaystyle " <> tex)
      P.Emph xs -> P.Emph (map displayInline xs)
      P.Strong xs -> P.Strong (map displayInline xs)
      P.Strikeout xs -> P.Strikeout (map displayInline xs)
      P.Underline xs -> P.Underline (map displayInline xs)
      P.Superscript xs -> P.Superscript (map displayInline xs)
      P.Subscript xs -> P.Subscript (map displayInline xs)
      P.SmallCaps xs -> P.SmallCaps (map displayInline xs)
      P.Quoted q xs -> P.Quoted q (map displayInline xs)
      P.Span attrs xs -> P.Span attrs (map displayInline xs)
      P.Link attrs xs target -> P.Link attrs (map displayInline xs) target
      other -> other

----------------------------------------------------------------------
-- Raw HTML, through the allowlist

-- | A raw HTML block, as the part the allowlist keeps, read by pandoc's
-- HTML reader. An @html@ fence, which the page shows in a frame with the
-- author's styles, is read the same way: through the page's allowlist,
-- without the styles, which a document has no frame to keep apart from
-- its own.
htmlBlock :: P.Block -> [P.Block]
htmlBlock = \case
  P.RawBlock f raw | isHtml f -> htmlBlocks raw
  P.CodeBlock (_, cls, _) code
    | norenderClass `notElem` cls
    , languageOfClasses cls == Just "html" ->
        htmlBlocks code
  b -> [b]

-- | Raw HTML, reduced to what the allowlist keeps, as pandoc's blocks. A
-- paragraph of three dots in it stays text ('dotsAsText').
htmlBlocks :: Text -> [P.Block]
htmlBlocks raw = case Html.parseHtml raw of
  [] -> []
  nodes -> either (const [P.Para (B.toList (B.text (Html.htmlText nodes)))]) (\(P.Pandoc _ bs) -> walk dotsAsText bs) (runPure (readHtml def (Html.renderHtml nodes)))

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

----------------------------------------------------------------------
-- What the wiki adds

-- | Remove a div of the class @slides@, which a deck reads as how it
-- looks and does not show ("Wiki.Core.Slides"). The line
-- @[[!slides]]{…}@ is taken out before pandoc reads the page
-- ('withBoxes'); this is for a @[[!div]]@ with that class.
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

-- | The islands, as a document shows them. A fence's language is found as
-- the page's parser finds it ('languageOfClasses'), and a fence with the
-- class @norender@ is a listing of its language, as on the page
-- ('listingLanguage').
islands :: Output -> P.Block -> [P.Block]
islands output = \case
  P.CodeBlock (ident, cls, kv) code
    | norenderClass `elem` cls ->
        let lang = languageOfClasses cls
         in listing (ident, map listingLanguage (maybeToList lang) <> filter (`notElem` (norenderClass : maybeToList lang)) cls, kv) code
    | Just lang <- languageOfClasses cls, lang `elem` ["math", "latex"] -> [P.Para [P.Math P.DisplayMath code]]
    | languageOfClasses cls == Just "mermaid" -> islandNote "A Mermaid diagram is drawn here in the wiki; a document cannot draw it. Its source:" code
    | languageOfClasses cls == Just "tikz" ->
        if output `elem` [ToTeX, ToBeamer]
          then -- A picture LaTeX draws, inserted as it is, centred, in a
          -- div that carries what it loads for the preamble
          -- ('tikzPreamble').
            let picture = tikzDocument code
             in [P.Div ("", ["tikz"], [("preamble", picture.preamble)]) [P.RawBlock (P.Format "latex") ("\\begin{center}\n" <> picture.picture <> "\n\\end{center}")]]
          else islandNote "A TikZ picture is drawn here in the wiki, and in a PDF; this document cannot draw it. Its source:" code
    | otherwise -> listing (ident, cls, kv) code
  b -> [b]
  where
    -- A listing; a numbered one with pandoc's class for numbered lines.
    listing (i, classes, kvs) source = [P.CodeBlock (i, map (\c -> if c == "numbered" then "numberLines" else c) classes, kvs) source]
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
  -- A path, or a page's permanent address, as a link in the wiki reads
  -- them: a page of the document is linked inside it, whichever way the
  -- link names it, and any other at the wiki's address.
  _ -> do
    PageLink r fragment <- resolvePageLink place.spaces place.spacePath place.root place.pages place.pagePath (if null place.spacePath then "/" <> T.dropWhile (== '/') dest else dest)
    case r of
      Page s p | Just anchor <- place.inDocument s p -> Just ("#" <> anchor)
      -- A space's own route is its home page's.
      R.Space s | Just anchor <- place.inDocument s [] -> Just ("#" <> anchor)
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

-- | Whether a block is a pause, as pandoc's slide writers recognise one:
-- a paragraph of three dots and the spaces between them. Only the wiki's
-- own pauses are such a paragraph in a page's blocks ('markedBlocks',
-- 'dotsAsText').
isPause :: P.Block -> Bool
isPause = (== P.Para [P.Str ".", P.Space, P.Str ".", P.Space, P.Str "."])

-- | A page's blocks without the pauses the wiki reads ('Wiki.Core.Markdown.Ast.Pause'):
-- at the top level, in boxes, alerts and spoilers, and in list items. A
-- document that is not a presentation shows its content once, and would
-- otherwise print the three dots.
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
-- speaker's notes are left out for both. A quotation's lists are made not
-- incremental, which pandoc would otherwise make them, so that both
-- writers show a quotation as the wiki does: whole. (The wiki reads no
-- pause in a quotation or a footnote, so none is there.)
--
-- Beamer counts a pause after the items of an incremental list from after
-- the last item, and then one more: @\\pause@ would add a page that shows
-- nothing new. Such a pause is written @\\pause[\\value{beamerpauses}]@,
-- which starts the step right after the last item, as the wiki does. The
-- count starts again at each slide, at each top-level break.
slideSteps :: Bool -> [P.Block] -> [P.Block]
slideSteps beamer = concat . (`evalState` False) . traverse topLevel
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
      P.BlockQuote bs -> pure [P.BlockQuote [P.Div ("", ["nonincremental"], []) bs]]
      b -> pure [b]
    item incremental bs = do
      when incremental (put True)
      blocks incremental bs
    incrementalIn cls incremental
      | "incremental" `elem` cls = True
      | "nonincremental" `elem` cls = False
      | otherwise = incremental

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
