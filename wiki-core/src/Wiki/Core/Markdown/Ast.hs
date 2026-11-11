-- | The Markdown tree: a page's Markdown as a tree of the wiki's own
-- types, parsed by @commonmark@.
--
-- The rest of the wiki works with this tree: the renderer
-- ("Wiki.Core.Markdown.Render") turns it into Halogen HTML, and other
-- features (search, a table of contents, export) walk it. It records what
-- the author wrote and nothing about how it is shown. A link keeps its
-- destination as written, to be resolved when it is rendered. An embed
-- (@![caption](…)@) does not yet know whether it is an image, a video or a
-- download. A code block in a @mermaid@, @tikz@, @math@, @latex@ or @html@
-- fence is already distinguished from other code, because what it is does
-- not depend on the wiki.
--
-- 'parseMarkdown' reads CommonMark with these extensions:
--
-- * GitHub's: pipe tables, task lists, footnotes, strikethrough, autolinks
--   (bare @https://…@ and @www.…@), emoji shortcodes (@:tada:@);
-- * the wiki's own blocks, each between two marker lines,
--   @[[!name]]{attributes}(Title)@ and @[[/name]]@, read by the wiki's own
--   block syntax ('markerSpec'): block spoilers,
--   @[[!spoiler]]{name}(Description)@ … @[[/spoiler]]@ ('Spoiler'); a
--   deck's speaker notes and its lists shown item by item, @[[!notes]]@
--   and @[[!incremental]]@; and a box styled by its classes,
--   @[[!div]]{.summary}@ (each a 'Div'). Three markers are one line with
--   no end marker: @[[!slides]]{theme=dark aspect=4:3}@, the deck's look
--   (an empty 'Div' of the class @slides@), @[[!pause]]@, which cuts a
--   slide into steps ('Pause'), and @[[!toc]]@, where the table of
--   contents goes ('TableOfContents');
-- * spoilers: @||hidden||@ inline, read as the strikethrough's @~~@ is
--   read ('Hidden'), and heading spoilers, @## [[!spoiler]] Question@ or
--   @## [[!spoiler]]{name} Question@, which hide the heading's section
--   ('spoilerHeadingSpec', 'withHeadingSections');
-- * a fence's @rows=N@ attribute, the number of lines its code shows
--   before it scrolls ('codeRows'), its class @numbered@, a number
--   before each line ('codeNumbered'), and its class @norender@, which
--   keeps a fence the wiki would render (@html@, @latex@, @math@,
--   @mermaid@, @tikz@) a listing of its language ('codeBlockWith');
-- * boxes, @> [!KIND]@: GitHub's alerts (@> [!NOTE]@ and its four
--   others), and any other kind (@> [!EXERCISE]@), with an optional title
--   after the marker (@> [!TIP] Before you start@), and a star for a box
--   without a number (@> [!TIP*]@), read by the wiki's own block syntax
--   ('alertSpec');
-- * heading identifiers made from the heading's text ('headingSlug'),
--   unique in the document: a heading with an @id@ of its own keeps it,
--   and the others get theirs in document order (the second @Intro@ gets
--   @intro-2@, the third @intro-3@), none taking an id written in braces
--   anywhere in the page; and box identifiers, made the same way from the
--   box's kind and its number or its title (@box-tip-3@,
--   @box-tip-before-you-start@; 'withHeadingIds');
-- * math, @$…$@ and @\\(…\\)@ inline, @$$…$$@ and @\\[…\\]@ display
--   ("Wiki.Core.Markdown.TexMath"), and a @math@ or @latex@ fence;
-- * an @html@ fence, HTML the page shows in a frame of its own
--   ('HtmlBlock');
-- * attributes in braces after a heading, a fence's info string, a link,
--   an image or inline code (@# Intro {#start}@, @![](a.png){width=300}@);
-- * wiki links, @[[page]]@ and @[[page|label]]@, read as ordinary links to
--   @page@;
-- * mentions, @\@login@, in text outside code, links and embeds
--   ("Wiki.Core.Markdown.Mention" says what counts as one).
--
-- Raw HTML in the source is kept as written, as 'RawHtml' (one tag or
-- comment each, with the Markdown between them as ordinary inlines) and
-- 'RawHtmlBlock'. The allowlist in "Wiki.Core.Markdown.Html" decides what
-- of it reaches the page, when it is rendered.
--
-- Source positions are not kept in the tree. The one place that needs
-- one is the export, which reads a page with pandoc's own reader and must
-- find the boxes this parser found: 'boxMarkers' gives where each box's
-- marker is in the source.
module Wiki.Core.Markdown.Ast
  ( -- * The tree
    Block (..)
  , Inline (..)
  , ListKind (..)
  , ListItem (..)
  , Footnote (..)
  , Alignment (..)
  , AlertKind (..)
  , BoxHead (..)
  , SpoilerHead (..)
  , SpoilerKind (..)
  , SpoilerProblem (..)
  , MathKind (..)
  , Attributes

    -- * Parsing
  , ParseError (..)
  , parseMarkdown
  , BoxMarker (..)
  , boxMarkers
  , MarkerLine (..)
  , MarkerRole (..)
  , WrittenIds (..)
  , TaskBox (..)
  , parseWithTasks

    -- * Markers
  , MarkerName (..)
  , MarkerStart (..)
  , markerNameText
  , openingMarker
  , closingMarker
  , markerAt
  , parseWithMarkers
  , parseWithAllMarkers
  , parseWithLines
  , parseWithLinesAndMarkers

    -- * Reading the tree
  , plainText
  , codeRows
  , codeNumbered
  , frameHeight
  , norenderClass
  , languageOfClasses
  , listingLanguage
  , spoilerProblemText
  , validSpoilerName
  , leadingHeading
  , formulasOf
  , attribute
  , classes
  , mentions
  , mentionsWhole
  )
where

import Commonmark qualified as CM
import Commonmark.Blocks qualified as CM
import Commonmark.Entity qualified as CM
import Commonmark.Extensions qualified as CME
import Commonmark.Inlines qualified as CMI
import Commonmark.TokParsers qualified as CM
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Dynamic (fromDyn, fromDynamic, toDyn)
import Data.List (span)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Tree (Tree (..))
import Protolude hiding (try)
import Text.Parsec (getPosition, getState, many1, option, optionMaybe, try)
import Text.Parsec qualified as Parsec
import Wiki.Core.Markdown.Box (AlertKind (..), alertKindName, readAlertKind)
import Wiki.Core.Markdown.Mention (splitMentions)
import Wiki.Core.Markdown.TexMath (texMathSpec)
import Wiki.Core.Slug (freshName, headingSlug)

-- | Attributes from braces, @{#id .class key=value}@, in the order
-- written. Heading identifiers are among them, as @id@. The renderer
-- decides which of them reach the HTML.
type Attributes = [(Text, Text)]

-- | A block of a page.
data Block
  = -- | A paragraph. It never contains display math: a paragraph with some
    -- is split around it into paragraphs and 'MathBlock's, because a @p@
    -- cannot contain the block a formula is shown in.
    Para [Inline]
  | -- | Text not in a paragraph: an item of a tight list. Split around
    -- display math like 'Para'.
    Plain [Inline]
  | -- | A heading: its level (1 to 6), its attributes (with its @id@), its
    -- text.
    Heading Int Attributes [Inline]
  | ThematicBreak
  | -- | A pause, @[[!pause]]@ on a line of its own. A deck
    -- ("Wiki.Core.Slides") shows a slide in steps, and a pause starts the
    -- next step; a page shows nothing for it. It is read at the top level
    -- of the page, in boxes, in alerts, in spoilers and in list items. In
    -- a quotation or a footnote the line is a 'MarkerError': a deck shows
    -- a quotation and a footnote whole.
    Pause
  | BlockQuote [Block]
  | -- | Fenced or indented code: attributes, the language (the first word
    -- of the info string, or else the first class), and the code.
    CodeBlock Attributes (Maybe Text) Text
  | -- | A @mermaid@ fence: the diagram's source.
    Mermaid Text
  | -- | A @tikz@ fence: the picture's TeX, as written (read by
    -- "Wiki.Core.Markdown.Tikz").
    Tikz Text
  | -- | Display math: a @math@ or @latex@ fence, or @$$…$$@ or @\\[…\\]@
    -- in a paragraph. The TeX source, as written between the delimiters.
    MathBlock Text
  | -- | An @html@ fence: its attributes (a height, 'frameHeight') and its
    -- HTML as written, which the page shows in a frame of its own, with
    -- the author's styles, through the allowlist of
    -- "Wiki.Core.Markdown.Html" widened by @style@
    -- ("Wiki.Core.Markdown.Frame"). Unlike 'RawHtmlBlock', which is
    -- HTML in the page itself.
    HtmlBlock Attributes Text
  | List ListKind [ListItem]
  | -- | A pipe table: each column's alignment, the header's cells (none
    -- when the table has no header), and the rows' cells.
    Table [Alignment] [[Inline]] [[[Inline]]]
  | -- | A box of blocks, with its attributes. @[[!div]]{.summary}@ …
    -- @[[/div]]@ gives the attributes in its braces; @[[!notes]]@ and
    -- @[[!incremental]]@ give their name as a class too (@notes@,
    -- @incremental@), which a deck reads ("Wiki.Core.Slides"). The one
    -- line @[[!slides]]{theme=dark}@ is an empty 'Div' of the class
    -- @slides@: the deck's look. A block of these three names that is not
    -- closed is a 'MarkerError' line, then a 'Div' of the class
    -- @spoiler-unclosed@ that holds its blocks, which the page shows in
    -- red as it shows an unclosed spoiler's.
    Div Attributes [Block]
  | -- | A box, @> [!KIND]@: its kind, its title and whether it has a
    -- number ('BoxHead'), and its blocks. GitHub's five kinds are its
    -- alerts (@> [!NOTE]@ and friends); "Wiki.Core.Markdown.Box" says what
    -- any other kind is.
    Alert AlertKind BoxHead [Block]
  | -- | A block spoiler: blocks a reader sees only once they open it,
    -- written between two lines of their own,
    -- @[[!spoiler]]{name}(Description)@ and @[[/spoiler]]@ (or
    -- @[[/spoiler]]{name}@). Its head says its name, its description and
    -- whether something is wrong with it ('SpoilerHead'). Spoilers nest:
    -- an end marker ends the innermost open block, and only when it is a
    -- spoiler and the end marker's name, if it has one, is the
    -- spoiler's.
    --
    -- A heading spoiler (@## [[!spoiler]] Question@) is a 'Spoiler' too,
    -- of the kind 'OnHeading': its first block is the heading, without
    -- the marker, and its other blocks are the heading's section. So
    -- everything that reads a spoiler's blocks (the contents, the
    -- headings' ids, search, the section rule) reads the heading as a
    -- heading, where it is.
    Spoiler SpoilerHead [Block]
  | -- | A marker line the page cannot read as one: a line that starts as
    -- a marker but is not a whole one (@[[!spoiler]]@ without its name or
    -- its description), an end marker that ends no open block, a pause
    -- where none is read, or the start of a @notes@, @incremental@ or
    -- @div@ block that is never closed. It holds the line as written, and
    -- what is wrong with it. The page shows it in red, so that the author
    -- sees the mistake as they type.
    MarkerError Text Text
  | -- | The footnotes, in the order they were defined. Comes once, last in
    -- the document, when it has any.
    Footnotes [Footnote]
  | -- | A block of raw HTML, as written: rendered through the allowlist of
    -- "Wiki.Core.Markdown.Html", parsed as one document.
    RawHtmlBlock Text
  | -- | @[[!toc]]@ on a line of its own: where the page's table of
    -- contents goes ("Wiki.Core.Markdown.Toc").
    TableOfContents
  deriving stock (Eq, Show)

-- | An inline element.
data Inline
  = -- | Text. Adjacent text is always one 'Str'.
    Str Text
  | -- | A line ended plainly, which the page shows as a line break.
    SoftBreak
  | -- | A line ended with a backslash (or two spaces): CommonMark's hard
    -- break, which the page shows as one line going on, a space in place of
    -- the break ("Wiki.Core.Markdown.Render").
    LineBreak
  | Emph [Inline]
  | Strong [Inline]
  | Strikeout [Inline]
  | -- | An inline spoiler, @||hidden||@: text the page shows blurred
    -- until the reader clicks it.
    Hidden [Inline]
  | -- | Inline code: attributes, code.
    Code Attributes Text
  | -- | A link: attributes, destination as written, title, description.
    -- A wiki link @[[page]]@ is a 'Link' to @page@ with the class
    -- @wikilink@.
    Link Attributes Text Text [Inline]
  | -- | An embed, @![caption](destination "title")@: attributes,
    -- destination as written, title, caption. Whether it shows as an image,
    -- a video, an audio player or a download link is decided when it is
    -- rendered, from the media type of what the destination resolves to.
    Image Attributes Text Text [Inline]
  | -- | Math: inline (@$…$@, @\\(…\\)@), or display (@$$…$$@,
    -- @\\[…\\]@) where it is not in a paragraph (in a heading, a table
    -- cell).
    Math MathKind Text
  | -- | A reference to a footnote: its number and its label.
    FootnoteRef Int Text
  | -- | An emoji shortcode: the keyword (@tada@) and the emoji.
    Emoji Text Text
  | -- | Raw HTML in the text, as written: a tag (opening or closing) or a
    -- comment. Rendered through the allowlist of
    -- "Wiki.Core.Markdown.Html", parsed together with the inlines around it.
    RawHtml Text
  | -- | A mention, @\@login@: the login, without the @\@@. The renderer
    -- asks whether it belongs to a user; one that does not, and one in a
    -- link, is shown as written.
    Mention Text
  deriving stock (Eq, Show)

data MathKind = InlineMath | DisplayMath
  deriving stock (Eq, Show)

-- | 'BoxHead' is what a box's marker line says besides its kind: the title
-- written after the marker, read as Markdown text (so @$x^2$@ in it is
-- math), if there is one; and whether the box is numbered, which it is
-- unless its kind has a star (@> [!TIP*]@). It also holds the box's @id@,
-- which the parser gives it ('withHeadingIds'), so that a link can point
-- at the box as it points at a heading.
data BoxHead = BoxHead
  { title :: Maybe [Inline]
  , numbered :: Bool
  , id :: Maybe Text
  -- ^ The box's @id@: @box-tip-3@ for the third numbered tip of the
  -- page, @box-tip-before-you-start@ for a tip without a number titled
  -- "Before you start", none for a box with neither.
  }
  deriving stock (Eq, Show)

-- | 'SpoilerHead' is what a block spoiler's start marker,
-- @[[!spoiler]]{name}(Description)@, says, and what the parser found
-- wrong with the spoiler, if anything.
data SpoilerHead = SpoilerHead
  { name :: Text
  -- ^ The name in braces, @{name}@ or @{#name}@ ('validSpoilerName'). The
  -- end marker may repeat it, and the reader's browser remembers whether
  -- a spoiler is open by its name and its page. It is no HTML @id@: two
  -- spoilers may share one.
  , description :: [Inline]
  -- ^ The text in parentheses, read as Markdown text: what the reader
  -- clicks to open the spoiler.
  , marker :: Text
  -- ^ The start marker's line as written, without the white space at
  -- either end: what the page shows in red when the spoiler is wrong.
  , line :: Int
  -- ^ The line of the source the start marker is on, from 1. The export
  -- finds the spoiler's markers in the source by it
  -- ('parseWithAllMarkers').
  , problem :: Maybe SpoilerProblem
  , kind :: SpoilerKind
  }
  deriving stock (Eq, Show)

-- | 'SpoilerKind' is how a block spoiler is written, and so what its
-- summary is.
data SpoilerKind
  = -- | Between two marker lines: the summary is the start marker's
    -- description.
    BetweenMarkers
  | -- | On a heading, @## [[!spoiler]] Question@ or
    -- @## [[!spoiler]]{name} Question@: the summary is the heading, the
    -- spoiler's first block, and the rest is the heading's section, up
    -- to the next heading of the same or a higher level, or the end of
    -- the document or of the block the heading is in
    -- ('withHeadingSections'). The description is empty. The name is the
    -- one written in braces, or else the heading's @id@
    -- ('withHeadingIds'), so the reader's browser remembers a spoiler
    -- without a name by its heading. The marker is @[[!spoiler]]@ or
    -- @[[!spoiler]]{name}@ as written, and the line the heading's. Such a
    -- spoiler has no problem: it is a whole section by how it is made.
    OnHeading
  deriving stock (Eq, Show)

-- | 'SpoilerProblem' is why a spoiler cannot be shown as one. The page
-- then shows its start marker in red with the reason
-- ('spoilerProblemText'), and its blocks, in red too, as they are, so the
-- author still sees them.
data SpoilerProblem
  = -- | No end marker of its name came before the end of the document,
    -- or of the quotation or list item the spoiler is in.
    NotClosed
  | -- | It holds a heading but is not a whole section, or ends in the
    -- middle of one: see 'withSpoilerSections'.
    CutsSection
  deriving stock (Eq, Show)

-- | What the page says about a spoiler with a problem, after its start
-- marker.
spoilerProblemText :: SpoilerHead -> SpoilerProblem -> Text
spoilerProblemText h = \case
  NotClosed -> "Spoiler “" <> h.name <> "” is not closed: add " <> closingMarker SpoilerName <> "{" <> h.name <> "}"
  CutsSection ->
    "Spoiler “"
      <> h.name
      <> "” cuts a section: a spoiler lies within one section, or wraps a whole one (its heading first, up to the next heading of the same or a higher level)"

-- | Whether a text is a spoiler's name: one word of ASCII letters, digits,
-- @-@ and @_@, as an identifier in code is.
validSpoilerName :: Text -> Bool
validSpoilerName name = not (T.null name) && T.all (\c -> isAsciiUpper c || isAsciiLower c || isDigit c || c == '-' || c == '_') name

-- | The number of lines a code block shows before it scrolls, from its
-- fence's attribute @rows=N@ (@```haskell {rows=20}@): a whole number
-- above zero. Anything else, and no @rows@, gives none, and the block is
-- as long as its code.
codeRows :: Attributes -> Maybe Int
codeRows attrs = do
  written <- attribute "rows" attrs
  guard (not (T.null written) && T.length written <= 6 && T.all isDigit written)
  n <- readMaybe (T.unpack written)
  guard (n > 0)
  pure n

-- | The height an @html@ fence's frame is given, in pixels, from its
-- fence's attribute @height=N@ (@```html {height=300}@, or @height=300px@):
-- a whole number above 0, held to at most 4000. Anything else (0, a
-- fraction, another unit), and no @height@, gives none, and the frame is
-- as high as its content. The page caps a frame at 80% of the window's
-- height either way. An interactive SVG's frame reads its embed's
-- @height@ the same way (@![flame](attachment:flame.svg){.interactive
-- height=600}@, "Wiki.Core.Markdown.Frame"), and without one is
-- 'Wiki.Core.Markdown.Frame.svgFrameHeight' high.
frameHeight :: Attributes -> Maybe Int
frameHeight attrs = do
  written <- attribute "height" attrs
  let digits = fromMaybe written (T.stripSuffix "px" written)
      significant = T.dropWhile (== '0') digits
  guard (not (T.null significant) && T.all isDigit digits)
  -- More than four digits is more than 4000, and is not read.
  n <- if T.length significant > 4 then Just maxFrameHeight else readMaybe (T.unpack significant)
  pure (min maxFrameHeight n)
  where
    maxFrameHeight = 4000

-- | Whether a code block shows a number before each line: its fence has
-- the class @numbered@ (@```haskell {.numbered}@, or
-- @```{.haskell .numbered}@). The class is never the block's language
-- ('codeBlockWith').
codeNumbered :: Attributes -> Bool
codeNumbered attrs = numberedClass `elem` classes attrs

-- | The class that numbers a code block's lines ('codeNumbered').
numberedClass :: Text
numberedClass = "numbered"

-- | A bulleted list, or a numbered one with the number it starts at.
data ListKind = BulletList | OrderedList Int
  deriving stock (Eq, Show)

-- | An item of a list: whether it is a task, and if so whether it is done
-- (@- [x]@), and its blocks.
data ListItem = ListItem (Maybe Bool) [Block]
  deriving stock (Eq, Show)

-- | A footnote: its number, its label (@[^label]@) and its blocks.
data Footnote = Footnote Int Text [Block]
  deriving stock (Eq, Show)

data Alignment = AlignDefault | AlignLeft | AlignCenter | AlignRight
  deriving stock (Eq, Show)

-- | Why a text is not Markdown. CommonMark gives every text a meaning, so
-- this is rare; it is kept rather than discarded so that a failure shows.
newtype ParseError = ParseError Text
  deriving stock (Eq, Show)

-- | Parse a page's Markdown.
parseMarkdown :: Text -> Either ParseError [Block]
parseMarkdown = fmap fst . parseWithMarkers

-- | Parse a page's Markdown, with the markers of its boxes in the order of
-- the source ('boxMarkers'): one parse, for a caller that needs both.
parseWithMarkers :: Text -> Either ParseError ([Block], [BoxMarker])
parseWithMarkers = fmap (\(bs, ms, _, _) -> (bs, ms)) . parseWithAllMarkers

-- | Parse a page's Markdown, with the markers of its boxes and its marker
-- lines (those of spoilers and of the wiki's other blocks, and the bars of
-- inline spoilers), each in the order of the source, and the identifiers
-- written in it ('WrittenIds'). The export rewrites the source at these
-- lines before pandoc reads it, and gives the document's headings the
-- identifiers the wiki gives them ("Wiki.Server.Export.Document").
parseWithAllMarkers :: Text -> Either ParseError ([Block], [BoxMarker], [MarkerLine], WrittenIds)
parseWithAllMarkers source =
  ( \(Blocks bs (Markers ms ss _) _) ->
      let read' = map snd (toList bs)
       in ( finished read'
          , sortOn (\m -> (m.markerLine, m.markerColumn)) (ordNub ms)
          , sortOn (\s -> (s.lineAt, s.columnAt)) (ordNub ss)
          , WrittenIds {headings = writtenHeadings read', taken = concatMap writtenIds read'}
          )
  )
    <$> parsed source

-- | 'WrittenIds' are the identifiers written in braces in a page's source
-- (@## Title {#custom}@). The wiki keeps a written identifier as it is,
-- and gives no other heading the same one ('withHeadingIds'). The export
-- needs both lists to give its headings the wiki's identifiers: pandoc's
-- reader does not say which identifiers were written.
data WrittenIds = WrittenIds
  { headings :: [Maybe Text]
  -- ^ One entry for every heading of the page, in the order
  -- 'withHeadingIds' visits them: the identifier written for the
  -- heading, or 'Nothing'. The headings in footnotes come last, because
  -- the wiki puts the footnotes at the end of the page.
  , taken :: [Text]
  -- ^ Every identifier written in the page: those of headings, divs
  -- and code blocks.
  }
  deriving stock (Eq, Show)

-- | The identifiers written in braces in a block and in the blocks inside
-- it: those of headings, divs and code blocks.
writtenIds :: Block -> [Text]
writtenIds = \case
  Heading _ attrs _ -> ownId attrs
  Div attrs bs -> ownId attrs <> concatMap writtenIds bs
  CodeBlock attrs _ _ -> ownId attrs
  BlockQuote bs -> concatMap writtenIds bs
  List _ items -> concat [concatMap writtenIds bs | ListItem _ bs <- items]
  Alert _ _ bs -> concatMap writtenIds bs
  Spoiler _ bs -> concatMap writtenIds bs
  Footnotes notes -> concat [concatMap writtenIds bs | Footnote _ _ bs <- notes]
  _ -> []

-- | Every heading of some blocks, in the order 'withHeadingIds' visits
-- them, with the identifier written for it, if any.
writtenHeadings :: [Block] -> [Maybe Text]
writtenHeadings = concatMap $ \case
  Heading _ attrs _ -> [head (ownId attrs)]
  BlockQuote bs -> writtenHeadings bs
  List _ items -> concat [writtenHeadings bs | ListItem _ bs <- items]
  Div _ bs -> writtenHeadings bs
  Alert _ _ bs -> writtenHeadings bs
  Spoiler _ bs -> writtenHeadings bs
  Footnotes notes -> concat [writtenHeadings bs | Footnote _ _ bs <- notes]
  _ -> []

-- | The identifier written in some attributes, if there is one.
ownId :: Attributes -> [Text]
ownId attrs = [i | Just i <- [attribute "id" attrs], not (T.null i)]

-- | Parse a page's Markdown, with the place of each of its tasks
-- ('TaskBox') in the order of the tree: the order a walk of the blocks
-- meets the tasks, each item before the items in it, the footnotes'
-- tasks last, as the footnotes are. "Wiki.Core.Markdown.Tasks" names a
-- task by its place in this order.
parseWithTasks :: Text -> Either ParseError ([Block], [TaskBox])
parseWithTasks source =
  (\(Blocks bs (Markers _ _ ts) _) -> (finished (map snd (toList bs)), ts)) <$> parsed source

-- | Parse a page's Markdown, each block of the page (not those inside
-- another) with the line of the source it starts on, from 1: what the
-- editor's preview is scrolled by, to show the block being written
-- ("Wiki.Core.Markdown.Render"'s 'Wiki.Core.Markdown.Render.renderLines').
parseWithLines :: Text -> Either ParseError [(Maybe Int, Block)]
parseWithLines source =
  (\(Blocks bs _ _) -> finishedWith (toList bs)) <$> parsed source

-- | Parse a page's Markdown into what 'parseWithLines' and
-- 'parseWithAllMarkers' give apart: each block of the page with the line
-- it starts on, and the marker lines. One parse, for a caller that needs
-- both (the editor's check of its text, "Wiki.Core.Markdown.Problems").
parseWithLinesAndMarkers :: Text -> Either ParseError ([(Maybe Int, Block)], [MarkerLine])
parseWithLinesAndMarkers source =
  (\(Blocks bs (Markers _ ss _) _) -> (finishedWith (toList bs), sortOn (\s -> (s.lineAt, s.columnAt)) (ordNub ss))) <$> parsed source

-- | What every block of a page goes through once parsed.
finished :: [Block] -> [Block]
finished = map snd . finishedWith . map ((),)

-- | 'finished' for blocks that each carry something of their own (the
-- line of the source they start on), kept with them. The blocks are one
-- for one with those given, except the blocks a heading spoiler's
-- section takes in ('withHeadingSections'), which go into the spoiler;
-- the spoiler keeps what its heading carried.
finishedWith :: [(a, Block)] -> [(a, Block)]
finishedWith located =
  let grouped = withHeadingSections (map (second withMentions) located)
   in zip (map fst grouped) (withHeadingIds (withSpoilerSections (map snd grouped)))

-- | 'BoxMarker' is where a box's marker, @[!KIND]@, is in a page's source:
-- its line and column (from 1; a tab counts to the next multiple of four
-- columns, as CommonMark counts it), with the box's kind, its title as
-- written and whether it is numbered (no star after the kind), as the
-- parser read them. The export rewrites the source at these places
-- before pandoc reads it ("Wiki.Server.Export.Document"), so that a
-- document has a box exactly where the page has one.
data BoxMarker = BoxMarker
  { markerLine :: Int
  , markerColumn :: Int
  , boxKind :: AlertKind
  , boxTitle :: Maybe Text
  , boxNumbered :: Bool
  }
  deriving stock (Eq, Ord, Show)

-- | 'TaskBox' is where a task's item starts in a page's source: the line
-- and the column of its bullet (from 1, a tab counted as 'BoxMarker''s
-- are). The task's box, @[ ]@ or @[x]@, follows the bullet on that line,
-- after spaces. "Wiki.Core.Markdown.Tasks" ticks a box there.
data TaskBox = TaskBox
  { taskLine :: Int
  , taskColumn :: Int
  }
  deriving stock (Eq, Ord, Show)

-- | 'MarkerLine' is a line of a page's source that is a marker of one of
-- the wiki's blocks, or starts as one, or a place the bars of an inline
-- spoiler are at: its line and the column its text starts at (from 1,
-- counted as 'BoxMarker''s are), and what is there.
data MarkerLine = MarkerLine
  { lineAt :: Int
  , columnAt :: Int
  , role :: MarkerRole
  }
  deriving stock (Eq, Ord, Show)

-- | What a marker line is, as the parser read it.
data MarkerRole
  = -- | The start of a spoiler: its name, and its description as
    -- written. The tree's 'Spoiler' with this line ('SpoilerHead''s
    -- @line@) says whether the spoiler is right.
    Starts Text Text
  | -- | The start of a @notes@, @incremental@ or @div@ block that is
    -- closed: the attributes of the 'Div' it makes.
    Opens Attributes
  | -- | The end of the block that starts on this line.
    Ends Int
  | -- | A pause, @[[!pause]]@, read as one ('Pause').
    Pauses
  | -- | The deck's look, @[[!slides]]{…}@.
    SetsSlides
  | -- | Where the table of contents goes, @[[!toc]]@.
    PlacesContents
  | -- | A line the page shows in red ('MarkerError'): the line as
    -- written, and what is wrong with it.
    Faulty Text Text
  | -- | A heading spoiler's marker, @[[!spoiler]]@ or
    -- @[[!spoiler]]{name}@, starts here, and the heading's own text at
    -- this column, after the marker and the spaces after it. The export
    -- removes what lies between, so a document shows the heading's text
    -- alone.
    HeadingMarker Int
  | -- | The two bars that open an inline spoiler, @||@, are here; the
    -- line and the column of the two that close it. Only the bars the
    -- parser read as a spoiler's are listed, so the export knows them
    -- apart from an escaped bar, a character reference and code.
    InlineBars Int Int
  | -- | A line of attributes in braces alone, @{.sorted}@, which the
    -- block after it takes (a list is put in a 'Div' with them). Pandoc's
    -- reader would read it as text, so the export leaves it out.
    SetsAttributes
  | -- | A fence starts here that took the attributes of the line of
    -- attributes alone before it ('SetsAttributes'): these. Pandoc's
    -- reader reads a fence's attributes only after its fence, where the
    -- export puts them. Only the parser knows which block a line of
    -- attributes went to (a quotation that starts with a fence takes them,
    -- not the fence), so the export asks it rather than read the text.
    TakesAttributes Attributes
  deriving stock (Eq, Ord, Show)

-- | Every box's marker in a page's source, in the order of the source;
-- none when the source cannot be parsed.
boxMarkers :: Text -> [BoxMarker]
boxMarkers = either (const []) snd . parseWithMarkers

-- | The source parsed, as the parser builds it.
parsed :: Text -> Either ParseError Blocks
parsed source =
  first (ParseError . show)
    $ runIdentity
    $ CM.commonmarkWith syntax "markdown" terminated
  where
    -- The pipe table extension does not accept a last row ended by the end
    -- of the text rather than a newline (commonmark-extensions 0.2.7.3),
    -- and a text area's value usually has no newline at the end.
    terminated
      | "\n" `T.isSuffixOf` source = source
      | otherwise = source <> "\n"

-- | GitHub's extensions (those of @gfmExtensions@) and the wiki's own,
-- then the core syntax, then pipe tables. An extension that changes what a
-- core construct means (a list item that is a task, a block quote that is
-- a box) must be tried before the core. Pipe tables, which take a
-- paragraph's line as their header, come after the core's blocks, as
-- commonmark-extensions requires, so that a line with a pipe in it that is
-- something else stays that.
syntax :: CM.SyntaxSpec Identity Inlines Blocks
syntax =
  CME.emojiSpec
    <> CME.strikethroughSpec
    <> hiddenSpec
    <> CME.autolinkSpec
    <> CME.taskListSpec
    <> CME.footnoteSpec
    <> alertSpec
    <> markerSpec
    <> spoilerHeadingSpec
    <> CME.mathSpec
    <> texMathSpec
    <> CME.wikilinksSpec CME.TitleAfterPipe
    <> CME.attributesSpec
    <> attributeLineSpec
    <> CM.defaultSyntaxSpec
    <> CME.pipeTableSpec

-- | The formulas of some blocks, inline and display alike, in the order
-- of the document: what KaTeX sets, and so where a page's own macro
-- definitions are and where its macros are used. Code, a TikZ picture and
-- raw HTML are not formulas, even when they show TeX.
formulasOf :: [Block] -> [Text]
formulasOf = concatMap ofBlock
  where
    ofBlock = \case
      Para xs -> ofInlines xs
      Plain xs -> ofInlines xs
      Heading _ _ xs -> ofInlines xs
      BlockQuote bs -> formulasOf bs
      MathBlock tex -> [tex]
      List _ items -> concat [formulasOf bs | ListItem _ bs <- items]
      Table _ header rows -> concatMap ofInlines (header <> concat rows)
      Div _ bs -> formulasOf bs
      Alert _ box bs -> foldMap ofInlines box.title <> formulasOf bs
      Spoiler h bs -> ofInlines h.description <> formulasOf bs
      Footnotes notes -> concat [formulasOf bs | Footnote _ _ bs <- notes]
      _ -> []
    ofInlines = concatMap $ \case
      Math _ tex -> [tex]
      Emph xs -> ofInlines xs
      Strong xs -> ofInlines xs
      Strikeout xs -> ofInlines xs
      Hidden xs -> ofInlines xs
      Link _ _ _ xs -> ofInlines xs
      Image _ _ _ xs -> ofInlines xs
      _ -> []

-- | The text of some inlines, without their markup: what a heading's
-- identifier is made from, and an image's @alt@ text.
plainText :: [Inline] -> Text
plainText = foldMap $ \case
  Str t -> t
  SoftBreak -> " "
  LineBreak -> " "
  Emph xs -> plainText xs
  Strong xs -> plainText xs
  Strikeout xs -> plainText xs
  Hidden xs -> plainText xs
  Code _ t -> t
  Link _ _ _ xs -> plainText xs
  Image _ _ _ xs -> plainText xs
  Math _ t -> t
  FootnoteRef _ _ -> ""
  Emoji _ t -> t
  RawHtml _ -> ""
  Mention login -> "@" <> login

-- | The value of the first attribute with this name.
attribute :: Text -> Attributes -> Maybe Text
attribute key attrs = head [v | (k, v) <- attrs, k == key]

-- | Every class the attributes give, in order: @{.a .b}@ and @class="a b"@
-- alike.
classes :: Attributes -> [Text]
classes attrs = concatMap T.words [v | ("class", v) <- attrs]

-- | Whether a page that says @\@login@ mentions this login and nothing
-- else: the text parsed as Markdown, as a page is, is one paragraph that
-- holds only a 'Mention' of the login. A login a mention reads less of
-- (one that ends in @.@ or @-@, or has a space, an @\@@ or other
-- punctuation in it) fails, and so does one that Markdown reads as
-- something else first, such as @_anna_@, which is emphasis around
-- @anna@. The editor offers to complete a mention only with logins for
-- which this holds ("Wiki.App.Backend.Notifications"' @mentionCandidates@),
-- so that the login it writes mentions the user chosen and tells them.
mentionsWhole :: Text -> Bool
mentionsWhole login = parseMarkdown ("@" <> login) == Right [Para [Mention login]]

-- | The logins a document mentions, outside links (where a mention is
-- shown as text, since a link cannot contain a link): who it would notify.
mentions :: [Block] -> Set Text
mentions = foldMap block'
  where
    block' = \case
      Para xs -> inlines' xs
      Plain xs -> inlines' xs
      Heading _ _ xs -> inlines' xs
      BlockQuote bs -> mentions bs
      List _ items -> foldMap (\(ListItem _ bs) -> mentions bs) items
      Table _ header rows -> foldMap inlines' header <> foldMap (foldMap inlines') rows
      Div _ bs -> mentions bs
      Alert _ box bs -> foldMap inlines' box.title <> mentions bs
      Spoiler h bs -> inlines' h.description <> mentions bs
      Footnotes notes -> foldMap (\(Footnote _ _ bs) -> mentions bs) notes
      _ -> mempty
    inlines' = foldMap $ \case
      Mention login -> Set.singleton login
      Emph xs -> inlines' xs
      Strong xs -> inlines' xs
      Strikeout xs -> inlines' xs
      Hidden xs -> inlines' xs
      _ -> mempty

----------------------------------------------------------------------
-- Headings and the table of contents

-- | The document with an @id@ on every heading: its own if it has one, and
-- otherwise one made from its text ('headingSlug'), in document order,
-- different from every id written in braces in the page and from the ids
-- given to the headings before it ('freshName'). It is one pass over the
-- parsed tree, so that whatever renders the tree, and whatever lists its
-- headings, sees the same ids.
--
-- Boxes get theirs in the same pass, so that a box's id and a heading's
-- are never the same. A numbered box's id is its kind and its number
-- among the numbered boxes of its kind in the whole page, in the order
-- the page shows them (@box-tip-3@): the number "Within the page" shows,
-- whatever the space's numbering, since the id must not change when an
-- administrator numbers the boxes another way. A box without a number
-- but with a title gets its kind and its title's slug
-- (@box-tip-before-you-start@). A box with neither has no id: nothing
-- names it that a link could keep to.
--
-- This replaces commonmark-extensions' @autoIdentifiersSpec@, which gave
-- the second @Intro@ the id @intro-1@ and did not avoid the ids written
-- out.
withHeadingIds :: [Block] -> [Block]
withHeadingIds doc = evalState (traverse assign doc) (written, mempty)
  where
    written = Set.fromList (concatMap writtenIds doc)
    -- The ids taken so far, and how many numbered boxes of each kind
    -- (by its name) came before.
    assign :: Block -> State (Set Text, Map Text Int) Block
    assign = \case
      Heading level attrs xs
        | null (ownId attrs) -> do
            ident <- fresh (headingSlug (plainText xs))
            pure (Heading level (("id", ident) : filter ((/= "id") . fst) attrs) xs)
      BlockQuote bs -> BlockQuote <$> traverse assign bs
      List kind items -> List kind <$> traverse (\(ListItem task bs) -> ListItem task <$> traverse assign bs) items
      Div attrs bs -> Div attrs <$> traverse assign bs
      -- The box's own id before those of the headings and boxes inside
      -- it, as the page shows them and counts the boxes.
      Alert kind box bs -> do
        let name = alertKindName kind
        base <-
          if box.numbered
            then do
              n <- gets (\(_, counts) -> Map.findWithDefault 0 name counts + 1)
              modify (second (Map.insert name n))
              pure (Just (show n))
            else pure (headingSlug . plainText <$> mfilter (T.any isAlphaNum . plainText) box.title)
        ident <- traverse (\b -> fresh ("box-" <> name <> "-" <> b)) base
        Alert kind box {id = ident} <$> traverse assign bs
      -- A heading spoiler without a name is known by its heading's id.
      Spoiler h bs -> do
        inner <- traverse assign bs
        let named = case inner of
              Heading _ attrs _ : _ | h.kind == OnHeading, T.null h.name -> h {name = fromMaybe "" (attribute "id" attrs)}
              _ -> h
        pure (Spoiler named inner)
      Footnotes notes -> Footnotes <$> traverse (\(Footnote n label bs) -> Footnote n label <$> traverse assign bs) notes
      other -> pure other
    -- The name, or the first of @name-2@, @name-3@, … that is free, taken
    -- from now on.
    fresh :: Text -> State (Set Text, Map Text Int) Text
    fresh base = do
      ident <- gets (\(taken, _) -> freshName (`Set.member` taken) base)
      modify (first (Set.insert ident))
      pure ident

----------------------------------------------------------------------
-- Mentions

-- | A block with the mentions in its text turned into 'Mention's: in all
-- text except code, links and embeds (whose caption is an image's
-- description, not text of the page).
withMentions :: Block -> Block
withMentions = \case
  Para xs -> Para (mentioning xs)
  Plain xs -> Plain (mentioning xs)
  Heading l attrs xs -> Heading l attrs (mentioning xs)
  BlockQuote bs -> BlockQuote (map withMentions bs)
  List kind items -> List kind [ListItem task (map withMentions bs) | ListItem task bs <- items]
  Table aligns header rows -> Table aligns (map mentioning header) (map (map mentioning) rows)
  Div attrs bs -> Div attrs (map withMentions bs)
  Alert kind box bs -> Alert kind box {title = mentioning <$> box.title} (map withMentions bs)
  Spoiler h bs -> Spoiler h {description = mentioning h.description} (map withMentions bs)
  Footnotes notes -> Footnotes [Footnote n label (map withMentions bs) | Footnote n label bs <- notes]
  other -> other
  where
    mentioning = concatMap $ \case
      Str t -> map (either Str Mention) (splitMentions t)
      Emph xs -> [Emph (mentioning xs)]
      Strong xs -> [Strong (mentioning xs)]
      Strikeout xs -> [Strikeout (mentioning xs)]
      Hidden xs -> [Hidden (mentioning xs)]
      other -> [other]

----------------------------------------------------------------------
-- Spoilers and sections

-- | The document with each spoiler checked against the page's sections
-- (the owner, issue #152): a spoiler must not cut across them, or the
-- page's table of contents would point into a section that is half
-- hidden. A spoiler is right when one of these holds:
--
-- * it lies within one section: none of its blocks is a heading;
-- * it wraps a whole section: its first block is a heading of level N,
--   every other heading in it is deeper than N (the section's own
--   subsections), and the block after it is a heading of level N or
--   less, or nothing (the end of the document, or of the quotation, list
--   item or spoiler it is in).
--
-- Any other spoiler gets the problem 'CutsSection'. The headings counted
-- are those of the page's sections: the blocks of the spoiler, and the
-- blocks of the spoilers inside it, as the table of contents counts them
-- ("Wiki.Core.Markdown.Toc"). A spoiler inside another is checked the
-- same way, within the blocks of the outer one. A spoiler already wrong
-- ('NotClosed') stays so.
--
-- A heading spoiler ('OnHeading') is not checked: it is its heading's
-- section by how it is made. For the marker pair around it, it is a
-- section that starts with a heading, as a pair that wraps a section is.
-- So a pair that holds a heading spoiler and the blocks after it, or
-- starts in a heading spoiler's section and ends after it, cuts a
-- section.
withSpoilerSections :: [Block] -> [Block]
withSpoilerSections = checked
  where
    checked bs = zipWith checkOne bs (map Just (drop 1 bs) <> [Nothing])
    checkOne b next = case b of
      Spoiler h bs ->
        let inner = checked bs
            problem = h.problem <|> (CutsSection <$ guard (h.kind == BetweenMarkers && not (fits inner next)))
         in Spoiler h {problem} inner
      BlockQuote bs -> BlockQuote (checked bs)
      List kind items -> List kind [ListItem task (checked bs) | ListItem task bs <- items]
      Div attrs bs -> Div attrs (checked bs)
      Alert kind box bs -> Alert kind box (checked bs)
      Footnotes notes -> Footnotes [Footnote n label (checked bs) | Footnote n label bs <- notes]
      other -> other
    fits inner next = case sectionLevels inner of
      [] -> True
      _ : deeper -> case leadingHeading =<< head inner of
        Just level -> all (> level) deeper && endsSection level next
        Nothing -> False
    -- The footnotes come last in a document; after them there is no text.
    endsSection level = \case
      Nothing -> True
      Just (Footnotes _) -> True
      Just b -> maybe False (<= level) (leadingHeading b)

-- | The blocks with each heading spoiler's section in it. The parser
-- makes a heading spoiler of its heading alone ('spoilerHeadingSpec');
-- here it takes in the blocks after it, up to the next block that
-- starts a section of the same or a higher level ('leadingHeading': a
-- heading, or a spoiler whose first block is one), the footnotes, or the
-- end of the blocks it is among. So a section never leaves the
-- quotation, list item, box or spoiler its heading is in. A deeper
-- heading spoiler in the section takes in its own subsection, and a
-- marker pair that holds a heading without starting with it is taken in
-- whole (the pair then cuts a section: 'withSpoilerSections').
withHeadingSections :: [(a, Block)] -> [(a, Block)]
withHeadingSections = \case
  [] -> []
  (at, Spoiler h (heading@(Heading level _ _) : own)) : rest
    | h.kind == OnHeading ->
        let (inside, after) = break (endsSection . snd) rest
            endsSection = \case
              Footnotes _ -> True
              b -> maybe False (<= level) (leadingHeading b)
         in (at, Spoiler h (heading : sectionsIn (own <> map snd inside))) : withHeadingSections after
  (at, b) : rest -> (at, within b) : withHeadingSections rest
  where
    within = \case
      BlockQuote bs -> BlockQuote (sectionsIn bs)
      List kind items -> List kind [ListItem task (sectionsIn bs) | ListItem task bs <- items]
      Div attrs bs -> Div attrs (sectionsIn bs)
      Alert kind box bs -> Alert kind box (sectionsIn bs)
      Spoiler h bs -> Spoiler h (sectionsIn bs)
      Footnotes notes -> Footnotes [Footnote n label (sectionsIn bs) | Footnote n label bs <- notes]
      other -> other
    sectionsIn = map snd . withHeadingSections . map ((),)

-- | The level of the heading a block starts a section with: a heading's,
-- or that of the first block of a spoiler that wraps a section.
leadingHeading :: Block -> Maybe Int
leadingHeading = \case
  Heading level _ _ -> Just level
  Spoiler _ (b : _) -> leadingHeading b
  _ -> Nothing

-- | The levels of the headings of some blocks that are sections of the
-- page, in order: the blocks' own headings, and those in their spoilers.
sectionLevels :: [Block] -> [Int]
sectionLevels = concatMap $ \case
  Heading level _ _ -> [level]
  Spoiler _ bs -> sectionLevels bs
  _ -> []

----------------------------------------------------------------------
-- What commonmark builds

-- | Inlines as the parser builds them: a sequence, so that appending is
-- cheap, which merges adjacent text as it goes. With them, where the bars
-- of the inline spoilers among them are in the source ('InlineBars'), for
-- the export, and whether they are an inline spoiler just made, whose
-- place the parser gives next ('CM.Rangeable').
data Inlines = Inlines (Seq Inline) [MarkerLine] Bool
  deriving stock (Show)

instance Semigroup Inlines where
  Inlines xs bs _ <> Inlines ys cs _ = case (Seq.viewr xs, Seq.viewl ys) of
    (xs' Seq.:> Str a, Str b Seq.:< ys') -> Inlines ((xs' Seq.|> Str (a <> b)) <> ys') (bs <> cs) False
    _ -> Inlines (xs <> ys) (bs <> cs) False

instance Monoid Inlines where
  mempty = Inlines Seq.empty [] False

-- | One inline made of others, with the bars of the inline spoilers in
-- them.
wrapping :: ([Inline] -> Inline) -> Inlines -> Inlines
wrapping make xs = Inlines (Seq.singleton (make (inlines xs))) (barsOf xs) False

-- | Where the bars of the inline spoilers among some inlines are.
barsOf :: Inlines -> [MarkerLine]
barsOf (Inlines _ bs _) = bs

-- | Blocks made of some inlines, with the bars of their inline spoilers.
withBars :: Inlines -> Blocks -> Blocks
withBars xs (Blocks bs ms at) = Blocks bs (ms <> Markers [] (barsOf xs) []) at

-- | Blocks as the parser builds them, each with the line of the source it
-- starts on once the parser has said ('parseWithLines'), and with the
-- markers of the boxes among them, nested ones too ('boxMarkers'). Every
-- block made of other blocks keeps their markers. The last field is where
-- the parser last said these blocks start, as a line and a column
-- ('CM.Rangeable'); blocks combined with others have none. The blocks of
-- a list item are given their item's place just before the list is made,
-- and a task list reads each task's place from there ('TaskBox').
data Blocks = Blocks (Seq (Maybe Int, Block)) Markers (Maybe (Int, Int))
  deriving stock (Show)

-- | The markers of boxes and of spoilers among some blocks, nested ones
-- too, and the places of their tasks, in the order of the tree.
data Markers = Markers [BoxMarker] [MarkerLine] [TaskBox]
  deriving stock (Show)

-- | Where some blocks start, if the parser has just said
-- ('CM.Rangeable').
startOf :: Blocks -> Maybe (Int, Int)
startOf (Blocks _ _ at) = at

instance Semigroup Markers where
  Markers bs ss ts <> Markers bs' ss' ts' = Markers (bs <> bs') (ss <> ss') (ts <> ts')

instance Monoid Markers where
  mempty = Markers [] [] []

instance Semigroup Blocks where
  Blocks xs ms _ <> Blocks ys ns _ = Blocks (xs <> ys) (ms <> ns) Nothing

instance Monoid Blocks where
  mempty = Blocks Seq.empty mempty Nothing

inline :: Inline -> Inlines
inline x = Inlines (Seq.singleton x) [] False

block :: Block -> Blocks
block b = Blocks (Seq.singleton (Nothing, b)) mempty Nothing

-- | One block made of others, with their markers.
around :: ([Block] -> Block) -> Blocks -> Blocks
around make bs = Blocks (Seq.singleton (Nothing, make (blocks bs))) (markersOf bs) Nothing

markersOf :: Blocks -> Markers
markersOf (Blocks _ ms _) = ms

inlines :: Inlines -> [Inline]
inlines (Inlines xs _ _) = toList xs

blocks :: Blocks -> [Block]
blocks (Blocks xs _ _) = map snd (toList xs)

-- | The parser gives the place of each inline it makes, the formatted ones
-- just after it makes them: an inline spoiler's place, from its first two
-- bars to the end of its last two, says where its bars are.
instance CM.Rangeable Inlines where
  ranged (CM.SourceRange ranges) = \case
    Inlines xs bs True
      | Just (start, _) <- head ranges
      , Just (_, end) <- lastMay ranges ->
          Inlines xs (bs <> [MarkerLine (Parsec.sourceLine start) (Parsec.sourceColumn start) (InlineBars (Parsec.sourceLine end) (Parsec.sourceColumn end - 2))]) False
    Inlines xs bs _ -> Inlines xs bs False

-- | The parser says where each block is once it has made it, innermost
-- first: a block without a line yet starts where this range does. A block
-- the parser made several of (a paragraph split around display math) has
-- them all start there. The range's start is kept as the blocks' place
-- ('startOf'), the outermost one said last.
instance CM.Rangeable Blocks where
  ranged (CM.SourceRange ranges) (Blocks xs ms at) = case ranges of
    (start, _) : _ -> Blocks (first (<|> Just (CM.sourceLine start)) <$> xs) ms (Just (CM.sourceLine start, CM.sourceColumn start))
    [] -> Blocks xs ms at

instance CM.HasAttributes Inlines where
  addAttributes new (Inlines xs bs fresh) = Inlines (add <$> xs) bs fresh
    where
      add = \case
        Code attrs t -> Code (attrs <> new) t
        Link attrs d t xs' -> Link (attrs <> new) d t xs'
        Image attrs d t xs' -> Image (attrs <> new) d t xs'
        other -> other

instance CM.HasAttributes Blocks where
  addAttributes new (Blocks xs ms at) = Blocks (fmap add <$> xs) (ms <> taken) at
    where
      -- Blocks the parser has placed ('startOf') take the attributes of a
      -- line before them; a fence's own, after its info word, come before
      -- it is placed. A fence that takes those of a line says so, at its
      -- start ('TakesAttributes').
      taken = case (at, toList xs) of
        (Just (line, column), [(_, b)]) | not (null new), fence b -> Markers [] [MarkerLine line column (TakesAttributes new)] []
        _ -> mempty
      fence = \case
        CodeBlock {} -> True
        HtmlBlock {} -> True
        Mermaid _ -> True
        Tikz _ -> True
        MathBlock _ -> True
        _ -> False
      add = \case
        Heading l attrs xs' -> Heading l (attrs <> new) xs'
        -- A heading spoiler's attributes are its heading's
        -- (@## [[!spoiler]] Question {#q}@).
        Spoiler h (Heading l attrs xs' : rest) | h.kind == OnHeading -> Spoiler h (Heading l (attrs <> new) xs' : rest)
        CodeBlock attrs lang t -> codeBlockWith (attrs <> new) lang t
        Div attrs xs' -> Div (attrs <> new) xs'
        -- An html fence keeps its attributes (its height), unless they
        -- make it a listing.
        HtmlBlock attrs t | norenderClass `notElem` classes new -> HtmlBlock (attrs <> new) t
        -- A list has no attributes of its own: it goes in a 'Div' that has
        -- them, as pandoc's CommonMark reader puts it. @{.sorted}@ on the
        -- line before a list is read so ("Wiki.Core.Markdown.Render").
        l@(List _ _) | not (null new) -> Div new [l]
        -- A fence the parser has rendered already, with @norender@ in the
        -- braces after its info word (@```mermaid {.norender}@).
        other
          | norenderClass `elem` classes new
          , Just (lang, t) <- listingOf other ->
              CodeBlock new (Just lang) t
          | otherwise -> other

instance CM.ToPlainText Inlines where
  toPlainText = plainText . inlines

instance CM.IsInline Inlines where
  lineBreak = inline LineBreak
  softBreak = inline SoftBreak
  str t
    | T.null t = mempty
    | otherwise = inline (Str t)
  entity t = CM.str (fromMaybe t (CM.lookupEntity (T.drop 1 t)))
  escapedChar c = CM.str (T.singleton c)
  emph = wrapping Emph
  strong = wrapping Strong
  link destination title = wrapping (Link [] destination title)
  image source title = wrapping (Image [] source title)
  code = inline . Code []

  -- The core syntax makes raw inlines only of HTML; the extensions that
  -- make other formats are not enabled.
  rawInline _ = inline . RawHtml

instance CM.IsBlock Inlines Blocks where
  paragraph xs = withBars xs (splitDisplayMath Para (inlines xs))
  plain xs = withBars xs (splitDisplayMath Plain (inlines xs))
  thematicBreak = block ThematicBreak
  blockQuote = around BlockQuote
  codeBlock info = block . codeBlockWith [] (head (T.words info))
  heading level xs = withBars xs (block (Heading level [] (inlines xs)))
  rawBlock _ = block . RawHtmlBlock

  -- A definition has done its job once the links that use it are parsed.
  referenceLinkDefinition _ _ = mempty
  list kind _ items = Blocks (Seq.singleton . (Nothing,) $ (List (listKind kind) (map (ListItem Nothing . blocks) items))) (foldMap markersOf items) Nothing

instance CME.HasMath Inlines where
  inlineMath = inline . Math InlineMath
  displayMath = inline . Math DisplayMath

instance CME.HasStrikethrough Inlines where
  strikethrough = wrapping Strikeout

instance CME.HasEmoji Inlines where
  emoji keyword = inline . Emoji keyword

instance CME.HasWikilinks Inlines where
  wikilink destination = wrapping (Link [("class", "wikilink")] destination "")

instance CME.HasPipeTable Inlines Blocks where
  pipeTable aligns header rows =
    withBars (mconcat (header <> concat rows)) . block $ Table (map alignment aligns) (map inlines header) (map (map inlines) rows)
    where
      alignment = \case
        CME.LeftAlignedCol -> AlignLeft
        CME.CenterAlignedCol -> AlignCenter
        CME.RightAlignedCol -> AlignRight
        CME.DefaultAlignedCol -> AlignDefault

instance CME.HasTaskList Inlines Blocks where
  -- Each item's box, before the boxes of the tasks under it: the order
  -- of the tree ('parseWithTasks').
  taskList kind _ items =
    Blocks
      (Seq.singleton . (Nothing,) $ (List (listKind kind) [ListItem (Just done) (blocks b) | (done, b) <- items]))
      (foldMap (\(_, b) -> Markers [] [] [TaskBox line column | Just (line, column) <- [startOf b]] <> markersOf b) items)
      Nothing

instance CME.HasFootnote Inlines Blocks where
  footnote number label = around (Footnotes . pure . Footnote number label)
  footnoteList notes =
    let all' = mconcat notes
     in Blocks (Seq.singleton . (Nothing,) $ (Footnotes (concat [ns | Footnotes ns <- blocks all']))) (markersOf all') Nothing

  -- The note's contents come along for formats that show a note where it
  -- is referenced; here they are shown once, in 'Footnotes'.
  footnoteRef number label _ = inline (FootnoteRef (fromMaybe 0 (readMaybe number)) label)

-- | Boxes, @> [!KIND]@ with an optional title after the marker: GitHub's
-- alerts and the wiki's own kinds ("Wiki.Core.Markdown.Box").
--
-- commonmark-extensions reads GitHub's alerts (@alertSpec@), but only its
-- five kinds, and only with nothing after the marker: its kinds are a
-- closed type, and so is pandoc's reader's. So the wiki has its own block
-- syntax, the library's with those differences. The marker is @[!@, a
-- name of letters and dashes in any case, an optional star, and @]@
-- ('readAlertKind'); a marker with any other name leaves the block an
-- ordinary quotation. The star (@[!TIP*]@) makes a box without a number.
-- What follows the marker on the line, after a space, is the box's title.
-- It is read as the text of a paragraph is (math, emphasis, code), with
-- the inline parser the rest of the page is read with, as a heading's
-- text is; so @> [!TIP] Use $x^2$@ has math in its title.
alertSpec :: CM.SyntaxSpec Identity Inlines Blocks
alertSpec = mempty {CM.syntaxBlockSpecs = [alertBlockSpec]}

-- | 'AlertLine' is what 'alertBlockSpec' keeps of a box's marker line until the box is
-- made: the marker, and the tokens of the title.
data AlertLine = AlertLine BoxMarker [CM.Tok]

alertBlockSpec :: CM.BlockSpec Identity Inlines Blocks
alertBlockSpec =
  CM.BlockSpec
    { CM.blockType = "Alert"
    , CM.blockStart = do
        CM.nonindentSpaces
        pos <- getPosition
        _ <- CM.symbol '>'
        _ <- option 0 (CM.gobbleSpaces 1)
        at <- getPosition
        _ <- CM.symbol '['
        _ <- CM.symbol '!'
        name <- many1 (CM.satisfyTok (\t -> CM.hasType CM.WordChars t || CM.hasType (CM.Symbol '-') t))
        kind <- maybe mzero pure (readAlertKind (CM.untokenize name))
        starred <- option False (True <$ CM.symbol '*')
        _ <- CM.symbol ']'
        rest <- many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
        -- A title is set off from the marker by a space: @[!NOTE]s@ is
        -- not a box.
        guard (maybe True (CM.hasType CM.Spaces) (head rest))
        let titleToks = reverse (dropWhile isSpaces (reverse (dropWhile isSpaces rest)))
            isSpaces = CM.hasType CM.Spaces
            title = mfilter (not . T.null) (Just (T.strip (CM.untokenize rest)))
            marker = BoxMarker {markerLine = Parsec.sourceLine at, markerColumn = Parsec.sourceColumn at, boxKind = kind, boxTitle = title, boxNumbered = not starred}
        CM.addNodeToStack $
          Node (CM.defBlockData alertBlockSpec) {CM.blockData = toDyn (AlertLine marker titleToks), CM.blockStartPos = [pos]} []
        pure CM.BlockStartMatch
    , CM.blockCanContain = const True
    , CM.blockContainsLines = False
    , CM.blockParagraph = False
    , CM.blockContinue = \n -> try $ do
        CM.nonindentSpaces
        pos <- getPosition
        _ <- CM.symbol '>'
        _ <- CM.gobbleUpToSpaces 1
        pure (pos, n)
    , CM.blockConstructor = \node -> do
        let AlertLine marker titleToks =
              fromMaybe
                (AlertLine BoxMarker {markerLine = 0, markerColumn = 0, boxKind = Note, boxTitle = Nothing, boxNumbered = True} [])
                (fromDynamic (CM.blockData (rootLabel node)))
        written <- if null titleToks then pure Nothing else Just <$> CM.runInlineParser titleToks
        inside <- mconcat <$> CM.renderChildren node
        let title = inlines <$> written
        pure (Blocks (Seq.singleton . (Nothing,) $ (Alert marker.boxKind BoxHead {title, numbered = marker.boxNumbered, id = Nothing} (blocks inside))) (Markers [marker] (foldMap barsOf written) [] <> markersOf inside) Nothing)
    , CM.blockFinalize = CM.defaultFinalizer
    }

-- | Inline spoilers, @||hidden||@: two bars on each side, read as the
-- strikethrough's two tildes are (commonmark-extensions'
-- @strikethroughSpec@), so they may hold emphasis, code and math, and
-- may be inside them. A single bar, or bars that pair with none, stay
-- text. A pipe table splits its rows into cells at the bars before any
-- cell's text is read, so a bar in a table is the table's, as before.
hiddenSpec :: CM.SyntaxSpec Identity Inlines Blocks
hiddenSpec = mempty {CM.syntaxFormattingSpecs = [CMI.FormattingSpec '|' True True Nothing (Just hidden) '|']}
  where
    -- Marked as just made, so that its place, which the parser gives
    -- next, is kept as its bars'.
    hidden xs = let Inlines made bs _ = wrapping Hidden xs in Inlines made bs True

-- | The wiki's own blocks, each written between two marker lines of its
-- own, @[[!name]]{attributes}(Title)@ and @[[/name]]@, indented by at most
-- three spaces, as other blocks may be. The names are those of
-- 'MarkerName':
--
-- * @[[!spoiler]]{name}(Description)@ starts a block spoiler
--   ('Spoiler'). Its braces hold its name alone, @{name}@ or @{#name}@.
--   It is the one marker that takes a description in parentheses.
-- * @[[!notes]]@, @[[!incremental]]@ and @[[!div]]@, with attributes in
--   braces or none, start a 'Div' with those attributes, the first two
--   with their name as a class too.
-- * @[[!slides]]@, with the deck's options in braces or none,
--   @[[!pause]]@ and @[[!toc]]@ are one line each, with no end marker.
--
-- The braces hold pandoc's attributes, @#id@, @.class@ and @key=value@,
-- read by commonmark-extensions' reader of a fence's and a heading's
-- attributes ('CME.pAttributes').
--
-- The exclamation mark keeps the blocks apart from wiki links: a page's
-- address cannot hold one. So a line that starts with @[[!@ and a name
-- in brackets is always a marker, and one with a name the wiki does not
-- have is a 'MarkerError' line. In the middle of a line, @[[!notes]]@ is
-- what the inline parser makes of it.
--
-- The blocks inside need no prefix: code, lists, tables and other marked
-- blocks go in as they are. An open block is a container on the block
-- parser's stack, so blocks nest, and the inline parser never sees a
-- marker.
--
-- An end marker has no exclamation mark. It ends the innermost open
-- block when the block has its name and, for a spoiler, when the name in
-- its braces, if it has one, is the spoiler's. When no block of its name
-- is open, the line is not a marker but the text it is (a wiki link to
-- @/name@). When one is open but the end marker cannot end it (another
-- block is open inside it, the names differ, something follows the
-- marker), the line is a 'MarkerError', which ends nothing. So is a line
-- that starts as a start marker and is not a whole one, and a pause in a
-- quotation or a footnote. A block whose container (the document, a
-- quotation, a list item) ends before its end marker is not closed: a
-- spoiler is 'NotClosed', and any other block is a 'MarkerError' line
-- followed by its blocks. An end marker in code, in a block of HTML or in
-- a paragraph's lazy line is not read as one.
markerSpec :: CM.SyntaxSpec Identity Inlines Blocks
markerSpec = mempty {CM.syntaxBlockSpecs = [markerBlockSpec]}

-- | 'MarkerName' is the name of one of the wiki's own blocks, as its
-- markers write it between their brackets, in lower case.
data MarkerName
  = -- | A block spoiler.
    SpoilerName
  | -- | A deck's speaker notes.
    NotesName
  | -- | Lists a deck shows item by item.
    IncrementalName
  | -- | A box styled by its classes.
    DivName
  | -- | The deck's look, one line.
    SlidesName
  | -- | The next step of a slide, one line.
    PauseName
  | -- | Where the page's table of contents goes, one line.
    TocName
  deriving stock (Eq, Show, Enum, Bounded)

-- | A marker's name as its markers write it.
markerNameText :: MarkerName -> Text
markerNameText = \case
  SpoilerName -> "spoiler"
  NotesName -> "notes"
  IncrementalName -> "incremental"
  DivName -> "div"
  SlidesName -> "slides"
  PauseName -> "pause"
  TocName -> "toc"

-- | The text a start marker begins with, @[[!notes]]@: what
-- 'markerOpening' reads, and what the toolbar and the messages write.
openingMarker :: MarkerName -> Text
openingMarker name = "[[!" <> markerNameText name <> "]]"

-- | An end marker without a name, @[[/notes]]@.
closingMarker :: MarkerName -> Text
closingMarker name = "[[/" <> markerNameText name <> "]]"

-- | 'MarkerStart' is what a line that starts as a marker starts with.
data MarkerStart
  = -- | A start marker of one of the wiki's names, @[[!notes]]@.
    Opening MarkerName
  | -- | An end marker of one of the names of a block that holds
    -- others, @[[/notes]]@.
    Closing MarkerName
  | -- | A start marker of a name the wiki does not have, as written
    -- between @[[!@ and @]]@.
    UnknownName Text
  deriving stock (Eq, Show)

-- | The marker at the start of some tokens, if they start with one, and
-- the tokens after it. This, with 'openingMarker' and 'closingMarker', is
-- the one place that says how a marker is spelled and so how it is told
-- from a wiki link.
markerOpening :: [CM.Tok] -> Maybe (MarkerStart, [CM.Tok])
markerOpening = either (const Nothing) Just . Parsec.parse (try opening <|> closing) "marker"
  where
    opening = do
      _ <- CM.symbol '['
      _ <- CM.symbol '['
      _ <- CM.symbol '!'
      written <- many (CM.satisfyTok (\t -> not (CM.hasType (CM.Symbol ']') t || CM.hasType CM.LineEnd t)))
      brackets
      let text = CM.untokenize written
      (maybe (UnknownName text) Opening (named text),) <$> Parsec.getInput
    closing = do
      _ <- CM.symbol '['
      _ <- CM.symbol '['
      _ <- CM.symbol '/'
      word <- CM.satisfyWord (const True)
      name <- maybe mzero pure (mfilter holdsBlocks (named (CM.tokContents word)))
      brackets
      (Closing name,) <$> Parsec.getInput
    brackets = CM.symbol ']' *> void (CM.symbol ']')
    named text = find (\n -> markerNameText n == text) [minBound .. maxBound]

-- | Whether a block of this name holds other blocks, and so has an end
-- marker.
holdsBlocks :: MarkerName -> Bool
holdsBlocks = (`elem` [SpoilerName, NotesName, IncrementalName, DivName])

-- | The marker a text starts with, if any ('markerOpening'), for a caller
-- that has a line as text.
markerAt :: Text -> Maybe MarkerStart
markerAt t = fst <$> markerOpening (CM.tokenize "marker" t)

-- | A marker line as 'readMarker' reads it.
data MarkerText
  = -- | @[[!spoiler]]{name}(Description)@: the name, the description,
    -- and the description's tokens.
    SpoilerText Text Text [CM.Tok]
  | -- | The start of a @notes@, @incremental@ or @div@ block, with the
    -- attributes in its braces.
    OpenText MarkerName Attributes
  | -- | A whole end marker, with the name in its braces if it has one.
    EndText MarkerName (Maybe Text)
  | -- | An end marker that is not a whole one: why.
    BrokenEnd MarkerName Text
  | -- | A marker of one line, and the block it makes: @[[!slides]]@ and
    -- its attributes, @[[!pause]]@ or @[[!toc]]@.
    LineText MarkerName Block
  | -- | A line that starts as a start marker and is not a whole one: why.
    BrokenText Text
  deriving stock (Show)

-- | What braces hold, as 'bracedAt' reads them.
data Braced
  = -- | Attributes, @{#id .class key=value}@.
    Attributed Attributes
  | -- | Anything else up to the first closing brace, as written.
    Bare Text
  | -- | An opening brace that no brace closes.
    Unclosed

-- | The braces at the start of some tokens, if they start with one: what
-- they hold, and the tokens after them. Attributes are read by
-- commonmark-extensions' own reader, as a fence's are.
bracedAt :: [CM.Tok] -> Maybe (Braced, [CM.Tok])
bracedAt toks = case toks of
  brace : rest
    | CM.hasType (CM.Symbol '{') brace -> Just $ case Parsec.parse ((,) <$> CME.pAttributes <*> Parsec.getInput) "attributes" toks of
        Right (attrs, after) -> (Attributed attrs, after)
        Left _ -> case break (CM.hasType (CM.Symbol '}')) rest of
          (inside, _ : after) -> (Bare (CM.untokenize inside), after)
          (_, []) -> (Unclosed, [])
  _ -> Nothing

-- | A spoiler's name from its braces: @{name}@, or @{#name}@, which is
-- the same name and no HTML @id@. Or why the braces hold no name.
spoilerNameIn :: Braced -> Either Text Text
spoilerNameIn = \case
  Bare name | validSpoilerName name -> Right name
  Attributed [("id", name)]
    | validSpoilerName name -> Right name
    | otherwise -> Left badSpoilerName
  Attributed _ -> Left ("a spoiler's braces hold its name alone, with no class or other attribute, as in " <> openingMarker SpoilerName <> "{name}(Description)")
  _ -> Left badSpoilerName

badSpoilerName :: Text
badSpoilerName = "a spoiler's name is one word of letters, digits, - and _"

-- | Whether some tokens are only white space.
blankToks :: [CM.Tok] -> Bool
blankToks = all spaceTok

spaceTok :: CM.Tok -> Bool
spaceTok t = CM.hasType CM.Spaces t || CM.hasType CM.UnicodeSpace t

-- | What a line is, if it starts as a marker: its tokens from the first
-- non-space.
readMarker :: [CM.Tok] -> Maybe MarkerText
readMarker toks = do
  (marker, rest) <- markerOpening toks
  pure $ case marker of
    Opening name -> start name (dropWhile spaceTok rest)
    Closing name -> end name (dropWhile spaceTok rest)
    UnknownName written ->
      BrokenText
        ( "“"
            <> written
            <> "” is not a name of the wiki's blocks, which are "
            <> T.intercalate ", " (map markerNameText [minBound .. maxBound])
            <> ", in lower case"
        )
  where
    start name rest = case name of
      SpoilerName -> spoiler rest
      SlidesName -> case bracedAt rest of
        Nothing | blankToks rest -> LineText SlidesName (Div [("class", "slides")] [])
        Just (Attributed attrs, after) | blankToks after -> LineText SlidesName (Div (("class", "slides") : attrs) [])
        Just (Attributed _, _) -> BrokenText (nothingAfter name)
        _ -> BrokenText ("the braces after " <> openingMarker SlidesName <> " hold the deck's options, as in " <> openingMarker SlidesName <> "{theme=dark aspect=4:3}")
      PauseName -> alone name Pause rest
      TocName -> alone name TableOfContents rest
      _ -> case bracedAt rest of
        Nothing -> box name [] rest
        Just (Attributed attrs, after) -> box name attrs (dropWhile spaceTok after)
        Just _ -> BrokenText ("the braces after " <> openingMarker name <> " hold attributes, #id, .class or key=value, as in " <> openingMarker DivName <> "{.summary}")
    alone name b rest
      | blankToks rest = LineText name b
      | otherwise = BrokenText ("nothing may follow " <> openingMarker name <> " on its line")
    box name attrs after
      | blankToks after = OpenText name attrs
      | (t : _) <- after, CM.hasType (CM.Symbol '(') t = BrokenText ("only a spoiler takes a description in parentheses, as in " <> openingMarker SpoilerName <> "{name}(Description)")
      | otherwise = BrokenText (nothingAfter name)
    nothingAfter name = "nothing may follow " <> openingMarker name <> " and its braces on its line"
    spoiler rest = case bracedAt rest of
      Just (braced, after) | not (isUnclosed braced) -> case spoilerNameIn braced of
        Left why -> BrokenText why
        Right name -> case dropWhile spaceTok after of
          -- From the parenthesis after the name to the last one.
          open : inside
            | CM.hasType (CM.Symbol '(') open
            , (trailing, _ : described) <- break (CM.hasType (CM.Symbol ')')) (reverse inside) ->
                described' name (trim (reverse described)) (reverse trailing)
          _ -> BrokenText ("a spoiler needs a description in parentheses after its name, as in " <> openingMarker SpoilerName <> "{name}(Description)")
      _ -> BrokenText ("a spoiler needs its name in braces after " <> openingMarker SpoilerName <> ", as in " <> openingMarker SpoilerName <> "{name}(Description)")
    isUnclosed = \case
      Unclosed -> True
      _ -> False
    described' name descriptionToks trailing
      | not (blankToks trailing) = BrokenText "nothing may follow the description's closing parenthesis"
      | T.null description = BrokenText ("a spoiler needs a description in its parentheses, as in " <> openingMarker SpoilerName <> "{name}(Description)")
      | otherwise = SpoilerText name description descriptionToks
      where
        description = T.strip (CM.untokenize descriptionToks)
    trim = reverse . dropWhile spaceTok . reverse . dropWhile spaceTok
    -- Only a spoiler's end marker may name it.
    end name rest = case bracedAt rest of
      Nothing
        | blankToks rest -> EndText name Nothing
        | otherwise -> BrokenEnd name ("nothing may follow " <> closingMarker name <> " on its line")
      Just (braced, after)
        | name /= SpoilerName -> BrokenEnd name ("nothing may follow " <> closingMarker name <> " on its line")
        | otherwise -> case spoilerNameIn braced of
            Left why -> BrokenEnd name why
            Right named
              | blankToks after -> EndText name (Just named)
              | otherwise -> BrokenEnd name "nothing may follow an end marker's name"

-- | What the parser keeps of an open block until it is made: its name,
-- what its start marker said, where the marker is, and where its end
-- marker was once one has ended it.
data OpenBlock = OpenBlock
  { openKind :: MarkerName
  , openName :: Maybe Text
  -- ^ A spoiler's name, which its end marker may repeat.
  , openAttributes :: Attributes
  -- ^ The attributes of the 'Div' a block other than a spoiler makes.
  , openDescription :: Text
  , openDescriptionToks :: [CM.Tok]
  -- ^ A spoiler's description, and its tokens, which are the source's,
  -- so that the places of the inline spoilers in it are the source's.
  , openMarker :: Text
  , openLine :: Int
  , openColumn :: Int
  , ended :: Maybe (Int, Int)
  }

-- | The attributes of the 'Div' a block makes: its braces', after the
-- block's name as a class for @notes@ and @incremental@.
divAttributes :: MarkerName -> Attributes -> Attributes
divAttributes name attrs = case name of
  NotesName -> ("class", "notes") : attrs
  IncrementalName -> ("class", "incremental") : attrs
  _ -> attrs

-- | Why a whole end marker ends no block, given the blocks open where it
-- is, the innermost first, by their names; one of them has the end
-- marker's name.
endProblem :: MarkerName -> Maybe Text -> [(MarkerName, Maybe Text)] -> Text
endProblem name named open = case open of
  innermost : outer
    | fits innermost -> "an end marker ends its block only outside the quotations and boxes inside the block"
    | any fits outer -> case innermost of
        (SpoilerName, n) -> "the innermost open spoiler is “" <> fromMaybe "" n <> "”: end it first"
        (other, _) -> "the innermost open block is " <> openingMarker other <> ": end it first with " <> closingMarker other
  _ -> "no open spoiler of this name"
  where
    fits (k, n) = k == name && maybe True (\w -> n == Just w) named

-- | Why a block other than a spoiler is not closed.
notClosed :: MarkerName -> Text
notClosed name = "the " <> openingMarker name <> " block is not closed: add " <> closingMarker name <> " after its last line"

markerBlockSpec :: CM.BlockSpec Identity Inlines Blocks
markerBlockSpec =
  CM.BlockSpec
    { CM.blockType = "Marker"
    , CM.blockStart = do
        CM.nonindentSpaces
        pos <- getPosition
        toks <- many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
        stack <- CM.nodeStack <$> getState
        let written = T.stripEnd (CM.untokenize toks)
            line = Parsec.sourceLine pos
            column = Parsec.sourceColumn pos
            oneLine b role = CM.addNodeToStack (Node (CM.defBlockData markerLineSpec) {CM.blockData = toDyn (b, MarkerLine line column role), CM.blockStartPos = [pos]} [])
            broken why = oneLine (MarkerError written why) (Faulty written why)
            opened o = CM.addNodeToStack (Node (CM.defBlockData markerBlockSpec) {CM.blockData = toDyn o, CM.blockStartPos = [pos]} [])
            block' kind name attributes description descriptionToks =
              OpenBlock {openKind = kind, openName = name, openAttributes = attributes, openDescription = description, openDescriptionToks = descriptionToks, openMarker = written, openLine = line, openColumn = column, ended = Nothing}
            specOf n = CM.blockType (CM.blockSpec (rootLabel n))
            open = [(o.openKind, o.openName) | n <- stack, Just o <- [openOf n]]
            -- An end marker is one only where a block of its name is open;
            -- elsewhere it is the text it is.
            ending kind why = do
              guard (any ((== kind) . fst) open)
              broken why
        case readMarker toks of
          Nothing -> mzero
          Just (SpoilerText name description descriptionToks) -> opened (block' SpoilerName (Just name) [] description descriptionToks)
          Just (OpenText kind attrs) -> opened (block' kind Nothing (divAttributes kind attrs) "" [])
          -- An end marker that ended its block was taken by the block's
          -- continuation ('closesBlock'), so this one ends none.
          Just (EndText kind named) -> ending kind (endProblem kind named open)
          Just (BrokenEnd kind why) -> ending kind why
          Just (LineText PauseName _)
            | any ((`elem` ["BlockQuote", "Footnote"]) . specOf) stack -> broken "a pause is not read in a quotation or a footnote, which a deck shows whole"
          Just (LineText name b) -> oneLine b (lineRole name)
          Just (BrokenText why) -> broken why
        pure CM.BlockStartMatch
    , CM.blockCanContain = const True
    , CM.blockContainsLines = False
    , CM.blockParagraph = False
    , CM.blockContinue = \node -> do
        ending <- optionMaybe (try (closesBlock node))
        pos <- getPosition
        case ending of
          Nothing -> pure (pos, node)
          Just at -> do
            CM.endOfBlock
            let ended = maybe (CM.blockData (rootLabel node)) (\o -> toDyn o {ended = Just at}) (openOf node)
            pure (pos, node {rootLabel = (rootLabel node) {CM.blockData = ended}})
    , CM.blockConstructor = \node -> do
        inside <- mconcat <$> CM.renderChildren node
        case openOf node of
          Nothing -> pure inside
          Just o | o.openKind == SpoilerName -> do
            parsedDescription <- CM.runInlineParser o.openDescriptionToks
            let name = fromMaybe "" o.openName
                h = SpoilerHead {name, description = inlines parsedDescription, marker = o.openMarker, line = o.openLine, problem = NotClosed <$ guard (isNothing o.ended), kind = BetweenMarkers}
                found = Markers [] ([MarkerLine o.openLine o.openColumn (Starts name o.openDescription)] <> [MarkerLine l c (Ends o.openLine) | Just (l, c) <- [o.ended]] <> barsOf parsedDescription) []
            pure (Blocks (Seq.singleton (Nothing, Spoiler h (blocks inside))) (found <> markersOf inside) Nothing)
          Just o -> pure $ case o.ended of
            Just (l, c) ->
              Blocks
                (Seq.singleton (Nothing, Div o.openAttributes (blocks inside)))
                (Markers [] [MarkerLine o.openLine o.openColumn (Opens o.openAttributes), MarkerLine l c (Ends o.openLine)] [] <> markersOf inside)
                Nothing
            -- Shown as an unclosed spoiler is: the marker and the reason
            -- in red, then the blocks in red.
            Nothing ->
              let why = notClosed o.openKind
               in Blocks
                    (Seq.fromList [(Nothing, MarkerError o.openMarker why), (Nothing, Div [("class", "spoiler-unclosed")] (blocks inside))])
                    (Markers [] [MarkerLine o.openLine o.openColumn (Faulty o.openMarker why)] [] <> markersOf inside)
                    Nothing
    , CM.blockFinalize = CM.defaultFinalizer
    }
  where
    lineRole = \case
      PauseName -> Pauses
      SlidesName -> SetsSlides
      _ -> PlacesContents
    -- The line is the end marker of this block: it has the block's name,
    -- the block is the innermost open one on this line, and the line is
    -- not a line of a block inside it that takes its lines as they are
    -- (code, HTML). Where the marker's text starts, if so.
    closesBlock node = do
      stack <- CM.nodeStack <$> getState
      let above = takeWhile (\n -> CM.blockStartPos (rootLabel n) /= CM.blockStartPos (rootLabel node) || isNothing (openOf n)) stack
      crossed <- Parsec.lookAhead (holdsLine (reverse above))
      guard (not crossed)
      CM.nonindentSpaces
      at <- getPosition
      toks <- many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
      own <- maybe mzero pure (openOf node)
      case readMarker toks of
        Just (EndText kind named) | kind == own.openKind, maybe True (\n -> own.openName == Just n) named -> pass
        _ -> mzero
      pure (Parsec.sourceLine at, Parsec.sourceColumn at)
    -- Whether the line belongs to a block inside this one that an end
    -- marker may not cross: another open block of the wiki's own, or a
    -- block that takes its lines as they are. The blocks are those above
    -- this one on the parser's stack, the outermost first. The stack is
    -- the one the previous line left: a block that does not continue on
    -- this line is still on it (indented code before a line that is not
    -- indented, a block in a list item that has ended). So each block's
    -- own continuation is run on the line, as commonmark runs them, until
    -- one does not continue. An open block of the wiki's own always
    -- continues, and its continuation is not run, since it would read an
    -- end marker as its own. The caller restores the input and the
    -- parser's state ('Parsec.lookAhead').
    holdsLine = \case
      nodes | not (any stops nodes) -> pure False
      n : _ | isJust (openOf n) -> pure True
      n : inner -> do
        continued <- optionMaybe (try (CM.blockContinue (CM.blockSpec (rootLabel n)) n))
        matched <- CM.blockMatched <$> getState
        case continued of
          Just _ | matched -> if verbatim n then pure True else holdsLine inner
          _ -> pure False
      [] -> pure False
    stops n = isJust (openOf n) || verbatim n
    verbatim n = let s = CM.blockSpec (rootLabel n) in CM.blockContainsLines s && not (CM.blockParagraph s)

-- | The open block a node of the parser's stack is, if it is one.
openOf :: CM.BlockNode Identity Inlines Blocks -> Maybe OpenBlock
openOf n
  | CM.blockType (CM.blockSpec (rootLabel n)) == "Marker" = fromDynamic (CM.blockData (rootLabel n))
  | otherwise = Nothing

-- | A marker that is one line and holds nothing: a 'MarkerError', the
-- deck's look, a pause or the table of contents. It is made at once, so
-- the next line is read afresh.
markerLineSpec :: CM.BlockSpec Identity Inlines Blocks
markerLineSpec =
  CM.BlockSpec
    { CM.blockType = "MarkerLine"
    , CM.blockStart = mzero
    , CM.blockCanContain = const False
    , CM.blockContainsLines = False
    , CM.blockParagraph = False
    , CM.blockContinue = const mzero
    , CM.blockConstructor = \node -> pure $ case fromDynamic (CM.blockData (rootLabel node)) of
        Just (b, m) -> Blocks (Seq.singleton (Nothing, b)) (Markers [] [m :: MarkerLine] []) Nothing
        Nothing -> mempty
    , CM.blockFinalize = CM.defaultFinalizer
    }

-- | Heading spoilers: an ATX heading whose text starts with
-- @[[!spoiler]]@, or @[[!spoiler]]{name}@, then a space and the heading's
-- own text (@## [[!spoiler]] Question@). The heading is read as
-- commonmark reads any ATX heading (its closing hashes and its
-- attributes in braces taken off); this spec takes the heading's node
-- only when its text starts with the marker, and makes a 'Spoiler' of the
-- kind 'OnHeading' holding the heading alone, with the marker taken out
-- of its text. 'withHeadingSections' then gives it its section.
--
-- The marker is read from the heading's tokens, so it counts only as
-- written, at the start of the text: escaped, spelled otherwise
-- (@[[! spoiler ]]@), with a name that is not one ('validSpoilerName'),
-- without a space and text after it, or anywhere later in the heading,
-- it is what the inline parser makes of it, a link. A setext heading has
-- no marker: its first line, starting with @[[!spoiler]]@, is a marker
-- line ('markerSpec').
spoilerHeadingSpec :: CM.SyntaxSpec Identity Inlines Blocks
spoilerHeadingSpec = mempty {CM.syntaxBlockSpecs = [spoilerHeadingBlockSpec]}

-- | A heading spoiler's marker as 'headingMarker' finds it.
data HeadingMarkerAt = HeadingMarkerAt
  { markerName :: Maybe Text
  , markerWritten :: Text
  , markerPos :: Parsec.SourcePos
  , textAt :: Parsec.SourcePos
  , textToks :: [CM.Tok]
  }

-- | The marker at the start of a heading's text, if there is one. It is
-- read as a marker line's start is ('markerOpening', 'bracedAt',
-- 'spoilerNameIn').
headingMarker :: [CM.Tok] -> Maybe HeadingMarkerAt
headingMarker toks = do
  open <- head toks
  (Opening SpoilerName, rest) <- markerOpening toks
  (name, afterName) <- case bracedAt rest of
    Just (braced, after) -> (\n -> (Just n, after)) <$> rightToMaybe (spoilerNameIn braced)
    Nothing -> pure (Nothing, rest)
  let (spaces, text) = span spaceTok afterName
  first' <- head text
  guard (not (null spaces))
  pure
    HeadingMarkerAt
      { markerName = name
      , markerWritten = CM.untokenize (take (length toks - length afterName) toks)
      , markerPos = CM.tokPos open
      , textAt = CM.tokPos first'
      , textToks = text
      }

spoilerHeadingBlockSpec :: CM.BlockSpec Identity Inlines Blocks
spoilerHeadingBlockSpec =
  CM.atxHeadingSpec
    { CM.blockType = "SpoilerHeading"
    , -- commonmark's own ATX heading, its node then made this spec's
      -- when its text starts with the marker.
      CM.blockStart = try $ do
        started <- CM.blockStart CM.atxHeadingSpec
        st <- getState
        case CM.nodeStack st of
          top : rest
            | CM.blockType (CM.blockSpec (rootLabel top)) == "ATXHeading"
            , isJust (headingMarker (CM.getBlockText top)) -> do
                Parsec.putState st {CM.nodeStack = top {rootLabel = (rootLabel top) {CM.blockSpec = spoilerHeadingBlockSpec}} : rest}
                pure started
          _ -> mzero
    , -- The heading's attributes are off its text by now. Without any
      -- text after the marker, it is an ordinary heading.
      CM.blockConstructor = \node -> do
        let level = fromDyn (CM.blockData (rootLabel node)) (1 :: Int)
            toks = CM.getBlockText node
        case headingMarker toks of
          Just m -> do
            text <- CM.runInlineParser m.textToks
            let line = Parsec.sourceLine m.markerPos
                h = SpoilerHead {name = fromMaybe "" m.markerName, description = [], marker = m.markerWritten, line, problem = Nothing, kind = OnHeading}
                found = MarkerLine line (Parsec.sourceColumn m.markerPos) (HeadingMarker (Parsec.sourceColumn m.textAt))
            pure (Blocks (Seq.singleton (Nothing, Spoiler h [Heading level [] (inlines text)])) (Markers [] (found : barsOf text) []) Nothing)
          Nothing -> CM.heading level <$> CM.runInlineParser toks
    }

-- | Lines of attributes in braces alone, @{.sorted}@, which the block
-- after them takes: commonmark's own reader of them (@attributeSpec@),
-- whose node is made this spec's once it has read a line, so that each
-- line it reads is listed as a 'MarkerLine' of the role 'SetsAttributes'.
-- The attributes reach the next block as before.
attributeLineSpec :: CM.SyntaxSpec Identity Inlines Blocks
attributeLineSpec = mempty {CM.syntaxBlockSpecs = [attributeLineBlockSpec]}

attributeLineBlockSpec :: CM.BlockSpec Identity Inlines Blocks
attributeLineBlockSpec =
  CM.attributeSpec
    { CM.blockStart = try $ do
        started <- CM.blockStart CM.attributeSpec
        st <- getState
        case CM.nodeStack st of
          top : rest
            | CM.blockType (CM.blockSpec (rootLabel top)) == "Attribute" -> do
                Parsec.putState st {CM.nodeStack = top {rootLabel = (rootLabel top) {CM.blockSpec = attributeLineBlockSpec}} : rest}
                pure started
          _ -> mzero
    , CM.blockConstructor = \node ->
        pure (Blocks Seq.empty (Markers [] [MarkerLine (Parsec.sourceLine p) (Parsec.sourceColumn p) SetsAttributes | p <- CM.blockStartPos (rootLabel node)] []) Nothing)
    }

listKind :: CM.ListType -> ListKind
listKind = \case
  CM.BulletList _ -> BulletList
  CM.OrderedList start _ _ -> OrderedList start

-- | A code block, or a block the wiki renders when its language says so
-- ('renderedBlock'). The language is the first word of the info string; a
-- fence written with attributes alone (@```{.mermaid}@) gives it as its
-- first class other than @numbered@ ('codeNumbered') and @norender@, which
-- say how the block is shown and are no language. With the class
-- @norender@ the block stays a listing of its language
-- ('listingLanguage').
codeBlockWith :: Attributes -> Maybe Text -> Text -> Block
codeBlockWith attrs info code
  | norenderClass `elem` classes attrs = CodeBlock attrs (listingLanguage <$> lang) code
  | otherwise = fromMaybe (CodeBlock attrs lang code) (lang >>= \l -> renderedBlock attrs l code)
  where
    lang = info <|> languageOfClasses (classes attrs)

-- | The language a fence written with classes alone gives
-- (@```{.numbered .mermaid}@): its first class other than @numbered@ and
-- @norender@. The export reads fences with pandoc's reader, which gives
-- the info word as the first class, and finds the language with this, so
-- that it agrees with 'codeBlockWith'.
languageOfClasses :: [Text] -> Maybe Text
languageOfClasses = head . filter (`notElem` [numberedClass, norenderClass])

-- | The block a fence of this language and these attributes is rendered
-- as, if the wiki renders
-- it: a Mermaid diagram (@mermaid@), a TikZ picture (@tikz@), display
-- math (@math@, and @latex@, which the owner asked to work as @$$@ does)
-- or HTML in a frame (@html@). Any other language is a listing; so are
-- @tex@, @xml@ and @svg@.
renderedBlock :: Attributes -> Text -> Text -> Maybe Block
renderedBlock attrs lang code = case lang of
  "mermaid" -> Just (Mermaid code)
  "tikz" -> Just (Tikz code)
  "math" -> Just (MathBlock code)
  "latex" -> Just (MathBlock code)
  "html" -> Just (HtmlBlock attrs code)
  _ -> Nothing

-- | A rendered block as the listing @norender@ makes of it, when the
-- class comes after its fence (@```mermaid {.norender}@) and the parser
-- has already made the block: its language and its source. Display math
-- is a @latex@ listing ('listingLanguage').
listingOf :: Block -> Maybe (Text, Text)
listingOf = \case
  Mermaid code -> Just ("mermaid", code)
  Tikz code -> Just ("tikz", code)
  MathBlock code -> Just ("latex", code)
  HtmlBlock _ code -> Just ("html", code)
  _ -> Nothing

-- | The language a listing made with @norender@ is highlighted as: its
-- own, except that a @math@ fence's TeX is highlighted as @latex@, a
-- language the highlighter knows. So a @math@ fence and a @latex@ fence
-- give the same listing however the class is written.
listingLanguage :: Text -> Text
listingLanguage = \case
  "math" -> "latex"
  lang -> lang

-- | The class that keeps a fence the wiki would render a listing of its
-- language ('codeBlockWith'). The page shows no class of a listing, so it
-- does not show this one either.
norenderClass :: Text
norenderClass = "norender"

-- | A paragraph's inlines as blocks: the paragraph itself, or, when it
-- contains display math, the paragraphs around each formula and the
-- formulas as 'MathBlock's. The text next to a formula loses the white
-- space that separated it from the formula.
splitDisplayMath :: ([Inline] -> Block) -> [Inline] -> Blocks
splitDisplayMath para xs = case break isDisplayMath xs of
  (before, []) -> paragraphOf before
  (before, Math _ tex : after) -> paragraphOf before <> block (MathBlock tex) <> splitDisplayMath para after
  (before, _ : after) -> paragraphOf before <> splitDisplayMath para after
  where
    isDisplayMath = \case
      Math DisplayMath _ -> True
      _ -> False
    paragraphOf ys = case trim ys of
      [] -> mempty
      ys' -> block (para ys')
    trim = reverse . stripFirst T.stripEnd . dropWhile blank . reverse . stripFirst T.stripStart . dropWhile blank
    blank = \case
      SoftBreak -> True
      LineBreak -> True
      Str t -> T.all isSpace t
      _ -> False
    -- The first inline is not blank, so stripping it leaves some text.
    stripFirst strip = \case
      Str t : rest -> Str (strip t) : rest
      ys -> ys
