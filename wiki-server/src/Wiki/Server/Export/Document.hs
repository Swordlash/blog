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
--   box with its title whatever its kind: its kind's label and its number,
--   as the page numbers it (@Tip 2.3@), then the one written after the
--   marker, read as Markdown, so its math is math. A box in a footnote
--   has no number in a document: pandoc keeps a note inside the text that
--   refers to it, where the page shows it at the end.
-- * __Spoilers__ ("Wiki.Core.Markdown.Ast"): a document cannot hide
--   anything, so a block spoiler is a box with the class @alert-spoiler@,
--   titled with its description, its content shown; the wiki's parser
--   finds its marker lines, and they are rewritten as a fenced div before
--   pandoc reads the page ('withBoxes'). A spoiler the page shows in red
--   (not closed, or cutting a section) is its blocks as they are, after
--   its marker line and the reason as text, and so is a broken marker
--   line. An inline spoiler, @||text||@, is its text in a @spoiler@ span
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
import Wiki.Core.Markdown.Ast (Block (..), BoxMarker (..), Footnote (..), ListItem (..), ParseError, SpoilerHead (..), SpoilerMarker (..), SpoilerRole (..), parseWithAllMarkers, spoilerProblemText)
import Wiki.Core.Markdown.Box (AlertKind (..), BoxCounter, BoxKind, Numbering, alertKindName, boxCaption, countBox, countSection, definedKind, startCounting)
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
    , Ext_fenced_divs
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
  , spoilers :: Map Int (Int, SpoilerEdit)
  , bars :: [((Int, Int), (Int, Int))]
  -- ^ Where the bars of each inline spoiler are, the opening pair's line
  -- and column and the closing pair's ('InlineBars').
  -- ^ What becomes of each of the page's spoiler marker lines, by its
  -- line, with the column its marker starts at ('spoilerEdits').
  }

-- | A page's Markdown, read ('PageRead').
readPage :: Text -> PageRead
readPage raw =
  PageRead
    { source
    , blocks = (\(bs, _, _) -> bs) <$> parsedPage
    , markers = either (const []) (\(_, ms, _) -> ms) parsedPage
    , spoilers = either (const mempty) (\(bs, _, ss) -> spoilerEdits bs ss) parsedPage
    , bars = either (const []) (\(_, _, ss) -> [((s.spoilerLine, s.spoilerColumn), (l, c)) | s <- ss, InlineBars l c <- [s.role]]) parsedPage
    }
  where
    source = normalLines raw
    parsedPage = parseWithAllMarkers source

-- | 'SpoilerEdit' is what the export writes in place of a spoiler's
-- marker line ('withBoxes').
data SpoilerEdit
  = -- | The start of a box with this description as its title.
    OpenBox Text
  | -- | The end of the box that starts on this line.
    CloseBox Int
  | -- | A line of text, as the page shows it in red.
    ShowLine Text
  | -- | Nothing: the end marker of a spoiler shown as its blocks.
    DropLine
  deriving stock (Eq, Show)

-- | What becomes of each spoiler marker line of a page, by its line: a
-- spoiler the page shows as one is a box; one the page shows in red
-- ('SpoilerHead''s @problem@) is its blocks, after its marker and the
-- reason as text; a broken marker line is its text and the reason.
spoilerEdits :: [Block] -> [SpoilerMarker] -> Map Int (Int, SpoilerEdit)
spoilerEdits doc markers = Map.fromList [(m.spoilerLine, (m.spoilerColumn, e)) | m <- markers, Just e <- [edit m]]
  where
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
      Starts _ description -> Just $ case Map.lookup m.spoilerLine heads of
        Just h | Just problem <- h.problem -> ShowLine (h.marker <> " — " <> spoilerProblemText h problem)
        _ -> OpenBox description
      Ends start -> Just $ case Map.lookup start heads of
        Just h | isNothing h.problem -> CloseBox start
        _ -> DropLine
      Faulty written why -> Just (ShowLine (written <> " — " <> why))
      -- An inline spoiler's bars are rewritten apart ('withBoxes').
      InlineBars _ _ -> Nothing

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
withBoxesRead defined numbering page = go page.markers page.spoilers
  where
    go markers spoilers = do
      let (marked, boxes, spoilerBoxes, bars) = withBoxes page.source markers spoilers page.bars
      P.Pandoc _ read' <- runPure (readMarkdown def {readerExtensions = wikiExtensions} marked)
      let boxed = walk (spoilersOf spoilerBoxes) (walk (boxesOf defined boxes (numbersOf numbering boxes read')) read')
          found = texts boxed
          stray = Set.fromList (concatMap (\t -> [m | (placeholder, (m, _)) <- Map.toList boxes, placeholder `T.isInfixOf` t]) found)
          -- A spoiler whose box pandoc did not read keeps its marker
          -- lines as written, and so does a line shown as text that
          -- pandoc did not read as a paragraph of its own.
          straySpoilers = Set.fromList [line | (placeholder, (line, _)) <- Map.toList spoilerBoxes, any (placeholder `T.isInfixOf`) found]
          unmarked = Map.filterWithKey (\line (_, e) -> line `Set.notMember` straySpoilers && (case e of CloseBox start -> start `Set.notMember` straySpoilers; _ -> True)) spoilers
      if Set.null stray && Set.null straySpoilers
        then pure (maybe boxed (\b -> restoreBars b (walk (hiddenSpans b) boxed)) bars)
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
-- A spoiler's marker lines are rewritten at the same time
-- ('SpoilerEdit'): the start of a spoiler shown as one becomes a fenced
-- div of the class @wikispoiler@ whose first paragraph is a placeholder
-- (@wikibox@, the digits, @s@, a number and @z@) and the description,
-- which 'spoilersOf' makes the box's title; its end marker ends the div.
-- A line the page shows in red becomes a paragraph of a placeholder
-- alone, which 'spoilersOf' replaces with the line's text, so that
-- nothing in the text is read as Markdown. Pandoc wants a fenced div
-- apart from the blocks around it, so each of these lines has an empty
-- line (of the prefix's quotation marks) before and after it. The third
-- result is each spoiler line's placeholder, with its line and what it
-- becomes.
--
-- The bars of each inline spoiler the wiki's parser found are replaced
-- too, each pair by a placeholder ('Bars', the fourth result), which
-- 'hiddenSpans' pairs again once pandoc has read the page. So pandoc
-- never decides what is a spoiler either: bars it would read as text
-- once it has decoded them (@\\|@, @&#124;@) stay text.
withBoxes :: Text -> [BoxMarker] -> Map Int (Int, SpoilerEdit) -> [((Int, Int), (Int, Int))] -> (Text, Boxes, Map Text (Int, SpoilerEdit), Maybe Bars)
withBoxes source markers spoilers bars = case family of
  Nothing -> (source, mempty, mempty, Nothing)
  Just prefix ->
    let placed =
          Map.fromList
            [ (m.markerLine, (prefix <> show n <> "z", m, start, T.drop start text))
            | (n, m) <- zip [1 :: Int ..] markers
            , Just text <- [atMay lines' (m.markerLine - 1)]
            , Just start <- [markerStart m text]
            ]
        spoilerPlaceholders = Map.fromList [(line, prefix <> "s" <> show n <> "z") | (n, line) <- zip [1 :: Int ..] (Map.keys spoilers)]
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
           in case (Map.lookup n placed, Map.lookup n spoilers) of
                (Just (placeholder, m, start, _), _) -> [T.take start text <> placeholder <> maybe "" (const (" " <> titleIn (T.drop start text))) m.boxTitle, quoteOnly (T.take start text)]
                (Nothing, Just (column, e)) ->
                  let before = T.take (column - 1) text
                      -- The prefix as the lines after the marker's continue it.
                      indent = T.map (\c -> if c == '>' || c == '\t' then c else ' ') before
                      placeholder = fromMaybe "" (Map.lookup n spoilerPlaceholders)
                      around ls = [quoteOnly before] <> ls <> [quoteOnly before]
                   in case e of
                        OpenBox _ -> around [before <> "::: wikispoiler", quoteOnly before, indent <> placeholder <> " " <> descriptionIn (T.drop (column - 1) text)]
                        CloseBox _ -> around [before <> ":::"]
                        ShowLine _ -> around [before <> placeholder]
                        DropLine -> [quoteOnly before]
                (Nothing, Nothing) -> [text]
     in ( T.intercalate "\n" (concat (zipWith rewrite [1 ..] lines'))
        , Map.fromList [(placeholder, (m, original)) | (placeholder, m, _, original) <- Map.elems placed]
        , Map.fromList [(placeholder, (line, e)) | (line, placeholder) <- Map.toList spoilerPlaceholders, Just (_, e) <- [Map.lookup line spoilers]]
        , Bars (prefix <> "h") <$ guard (not (null bars))
        )
  where
    -- The index in a line of the bars at a column, if they are there. A
    -- tab counts to the next multiple of four columns, as CommonMark
    -- counts it.
    barsAt text column = go 0 1 (T.unpack text)
      where
        go i c rest
          | c == column = i <$ guard ("||" `T.isPrefixOf` T.drop i text)
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
    -- The marker starts at its column and runs to the end of the line. A
    -- tab before it counts to a tab stop, so the column is checked, and
    -- the line searched where it does not hold the marker.
    markerStart m text
      | "[!" `T.isPrefixOf` T.drop (m.markerColumn - 1) text = Just (m.markerColumn - 1)
      | otherwise = case T.breakOn "[!" text of
          (_, "") -> Nothing
          (before, _) -> Just (T.length before)

-- | A fenced div that 'withBoxes' made of a spoiler as a box with the
-- class @alert-spoiler@, titled with the spoiler's description, as the
-- other kinds' boxes are ('boxesOf'); and a paragraph of a placeholder
-- alone as the text of the line it stands for. Any other block is left as
-- it is, a div of that class the page wrote itself too.
spoilersOf :: Map Text (Int, SpoilerEdit) -> P.Block -> P.Block
spoilersOf placeholders = \case
  P.Div (_, ["wikispoiler"], _) (P.Para (P.Str placeholder : title) : rest)
    | Just (_, OpenBox _) <- Map.lookup placeholder placeholders ->
        P.Div ("", ["alert-spoiler"], []) (P.Div ("", ["title"], []) [P.Para (dropWhile (== P.Space) title)] : rest)
  P.Para [P.Str placeholder]
    | Just (_, ShowLine shown) <- Map.lookup placeholder placeholders -> P.Para (B.toList (B.text shown))
  b -> b

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
-- again. A heading's identifier, which pandoc made from its text with the
-- placeholders in it, is made without them, as pandoc makes it without
-- the bars, which it leaves out.
restoreBars :: Bars -> [P.Block] -> [P.Block]
restoreBars bars@(Bars family) = walk inBlock . walk inInline
  where
    unplace t = T.concat [either (const "||") identity p | p <- placeholdersIn bars t]
    unplaceId ident = case T.breakOn family ident of
      (before, "") -> before
      (before, rest) ->
        let after = T.drop (T.length family) rest
            (digits, more) = T.span isDigit (T.drop 1 after)
         in if T.take 1 after `elem` ["o", "c"] && not (T.null digits) && "z" `T.isPrefixOf` more
              then before <> unplaceId (T.drop 1 more)
              else before <> T.take (T.length family) rest <> unplaceId after
    inInline = \case
      P.Code attrs t -> P.Code attrs (unplace t)
      P.Math kind t -> P.Math kind (unplace t)
      P.RawInline f t -> P.RawInline f (unplace t)
      x -> x
    inBlock = \case
      P.Header level (ident, cls, kvs) xs -> P.Header level (unplaceId ident, cls, kvs) xs
      P.CodeBlock attrs t -> P.CodeBlock attrs (unplace t)
      P.RawBlock f t -> P.RawBlock f (unplace t)
      b -> b

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
    PageLink r fragment <- resolvePageLink place.spaces place.spacePath place.pages place.pagePath (if null place.spacePath then "/" <> T.dropWhile (== '/') dest else dest)
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
