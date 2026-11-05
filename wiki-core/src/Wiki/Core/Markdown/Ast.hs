-- | The Markdown tree: a page's Markdown as a tree of the wiki's own
-- types, parsed by @commonmark@.
--
-- The rest of the wiki works with this tree: the renderer
-- ("Wiki.Core.Markdown.Render") turns it into Halogen HTML, and other
-- features (search, a table of contents, export) walk it. It records what
-- the author wrote and nothing about how it is shown. A link keeps its
-- destination as written, to be resolved when it is rendered. An embed
-- (@![caption](…)@) does not yet know whether it is an image, a video or a
-- download. A code block in a @mermaid@, @tikz@ or @math@ fence is already
-- distinguished from other code, because what it is does not depend on
-- the wiki.
--
-- 'parseMarkdown' reads CommonMark with these extensions:
--
-- * GitHub's: pipe tables, task lists, footnotes, strikethrough, autolinks
--   (bare @https://…@ and @www.…@), emoji shortcodes (@:tada:@);
-- * spoilers: @||hidden||@ inline, read as the strikethrough's @~~@ is
--   read ('Hidden'), and block spoilers between two marker lines,
--   @[[spoiler]]{name}(Description)@ and @[[/spoiler]]{name}@, read by
--   the wiki's own block syntax ('spoilerSpec'; 'Spoiler');
-- * a fence's @rows=N@ attribute, the number of lines its code shows
--   before it scrolls ('codeRows');
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
--   ("Wiki.Core.Markdown.TexMath"), and a @math@ fence;
-- * attributes in braces after a heading, a fence's info string, a link,
--   an image or inline code (@# Intro {#start}@, @![](a.png){width=300}@);
-- * fenced divs (@::: warning@ … @:::@), for boxes styled by class;
-- * pandoc's pause, @. . .@ alone in a paragraph ('Pause'), which cuts a
--   slide into steps;
-- * wiki links, @[[page]]@ and @[[page|label]]@, read as ordinary links to
--   @page@, except @[[toc]]@ alone in a paragraph, which marks where the
--   page's table of contents goes ('TableOfContents');
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
  , SpoilerProblem (..)
  , MathKind (..)
  , Attributes

    -- * Parsing
  , ParseError (..)
  , parseMarkdown
  , BoxMarker (..)
  , boxMarkers
  , SpoilerMarker (..)
  , SpoilerRole (..)
  , WrittenIds (..)
  , parseWithMarkers
  , parseWithAllMarkers
  , parseWithLines

    -- * Reading the tree
  , plainText
  , codeRows
  , spoilerProblemText
  , validSpoilerName
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
import Data.Dynamic (fromDynamic, toDyn)
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
  | -- | A pause, @. . .@: a paragraph of three dots separated by spaces,
    -- alone. A deck ("Wiki.Core.Slides") shows a slide in steps, and a
    -- pause starts the next step; a page shows nothing for it. It is
    -- read at the top level of the page, in boxes, in alerts and in list
    -- items. In a quotation or a footnote the three dots stay text: there
    -- they are more likely an omission than a pause.
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
  | -- | Display math: a @math@ fence, or @$$…$$@ or @\\[…\\]@ in a
    -- paragraph. The TeX source, as written between the delimiters.
    MathBlock Text
  | List ListKind [ListItem]
  | -- | A pipe table: each column's alignment, the header's cells (none
    -- when the table has no header), and the rows' cells.
    Table [Alignment] [[Inline]] [[[Inline]]]
  | -- | A fenced div, with its attributes (@::: warning@ gives the class
    -- @warning@).
    Div Attributes [Block]
  | -- | A box, @> [!KIND]@: its kind, its title and whether it has a
    -- number ('BoxHead'), and its blocks. GitHub's five kinds are its
    -- alerts (@> [!NOTE]@ and friends); "Wiki.Core.Markdown.Box" says what
    -- any other kind is.
    Alert AlertKind BoxHead [Block]
  | -- | A block spoiler: blocks a reader sees only once they open it,
    -- written between two lines of their own,
    -- @[[spoiler]]{name}(Description)@ and @[[/spoiler]]{name}@. Its
    -- head says its name, its description and whether something is
    -- wrong with it ('SpoilerHead'). Spoilers nest: an end marker ends
    -- the innermost open spoiler, and only when the names agree.
    Spoiler SpoilerHead [Block]
  | -- | A line that starts as a spoiler's marker but is not a whole one
    -- (@[[spoiler]]@ without its name or its description), or an end
    -- marker that ends no open spoiler: the line as written, and what is
    -- wrong with it. The page shows it in red, so that the author sees
    -- the mistake as they type.
    SpoilerError Text Text
  | -- | The footnotes, in the order they were defined. Comes once, last in
    -- the document, when it has any.
    Footnotes [Footnote]
  | -- | A block of raw HTML, as written: rendered through the allowlist of
    -- "Wiki.Core.Markdown.Html", parsed as one document.
    RawHtmlBlock Text
  | -- | @[[toc]]@ (or @[[TOC]]@) alone in a paragraph: where the page's
    -- table of contents goes ("Wiki.Core.Markdown.Toc").
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
-- @[[spoiler]]{name}(Description)@, says, and what the parser found
-- wrong with the spoiler, if anything.
data SpoilerHead = SpoilerHead
  { name :: Text
  -- ^ The name in braces ('validSpoilerName'). The end marker repeats
  -- it, and the reader's browser remembers whether a spoiler is open by
  -- its name and its page.
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
  }
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
  NotClosed -> "Spoiler “" <> h.name <> "” is not closed: add [[/spoiler]]{" <> h.name <> "}"
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

-- | Parse a page's Markdown, with the markers of its boxes and the marker
-- lines of its spoilers, each in the order of the source, and the
-- identifiers written in it ('WrittenIds'). The export rewrites the
-- source at these lines before pandoc reads it, and gives the document's
-- headings the identifiers the wiki gives them
-- ("Wiki.Server.Export.Document").
parseWithAllMarkers :: Text -> Either ParseError ([Block], [BoxMarker], [SpoilerMarker], WrittenIds)
parseWithAllMarkers source =
  ( \(Blocks bs (Markers ms ss)) ->
      let read' = map snd (toList bs)
       in ( finished read'
          , sortOn (\m -> (m.markerLine, m.markerColumn)) (ordNub ms)
          , sortOn (\s -> (s.spoilerLine, s.spoilerColumn)) (ordNub ss)
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
  -- ^ Every identifier written in the page: those of headings, fenced
  -- divs and code blocks.
  }
  deriving stock (Eq, Show)

-- | The identifiers written in braces in a block and in the blocks inside
-- it: those of headings, fenced divs and code blocks.
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

-- | Parse a page's Markdown, each block of the page (not those inside
-- another) with the line of the source it starts on, from 1: what the
-- editor's preview is scrolled by, to show the block being written
-- ("Wiki.Core.Markdown.Render"'s 'Wiki.Core.Markdown.Render.renderLines').
parseWithLines :: Text -> Either ParseError [(Maybe Int, Block)]
parseWithLines source =
  (\(Blocks bs _) -> let located = toList bs in zip (map fst located) (finished (map snd located)))
    <$> parsed source

-- | What every block of a page goes through once parsed, one for one.
finished :: [Block] -> [Block]
finished = withHeadingIds . withSpoilerSections . map (withPauses . contentsMarker . withMentions)

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

-- | 'SpoilerMarker' is a line of a page's source that is a spoiler's
-- marker, or starts as one: its line and the column its text starts at
-- (from 1, counted as 'BoxMarker''s are), and what the line is.
data SpoilerMarker = SpoilerMarker
  { spoilerLine :: Int
  , spoilerColumn :: Int
  , role :: SpoilerRole
  }
  deriving stock (Eq, Ord, Show)

-- | What a spoiler's marker line is, as the parser read it.
data SpoilerRole
  = -- | The start of a spoiler: its name, and its description as
    -- written. The tree's 'Spoiler' with this line ('SpoilerHead''s
    -- @line@) says whether the spoiler is right.
    Starts Text Text
  | -- | The end of the spoiler that starts on this line.
    Ends Int
  | -- | A line the page shows in red ('SpoilerError'): the line as
    -- written, and what is wrong with it.
    Faulty Text Text
  | -- | The two bars that open an inline spoiler, @||@, are here; the
    -- line and the column of the two that close it. Only the bars the
    -- parser read as a spoiler's are listed, so the export knows them
    -- apart from an escaped bar, a character reference and code.
    InlineBars Int Int
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
    <> spoilerSpec
    <> CME.mathSpec
    <> texMathSpec
    <> CME.wikilinksSpec CME.TitleAfterPipe
    <> CME.fencedDivSpec
    <> CME.attributesSpec
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
      Spoiler h bs -> Spoiler h <$> traverse assign bs
      Footnotes notes -> Footnotes <$> traverse (\(Footnote n label bs) -> Footnote n label <$> traverse assign bs) notes
      other -> pure other
    -- The name, or the first of @name-2@, @name-3@, … that is free, taken
    -- from now on.
    fresh :: Text -> State (Set Text, Map Text Int) Text
    fresh base = do
      ident <- gets (\(taken, _) -> freshName (`Set.member` taken) base)
      modify (first (Set.insert ident))
      pure ident

-- | A paragraph that is nothing but the wiki link @[[toc]]@ marks where
-- the table of contents goes. Any other link to @toc@ stays a link, to a
-- page of that name.
contentsMarker :: Block -> Block
contentsMarker = \case
  Para [Link attrs dest _ [Str label]]
    | "wikilink" `elem` classes attrs
    , T.toLower dest == "toc"
    , T.toLower label == "toc" ->
        TableOfContents
  other -> other

-- | A block with its pauses ('Pause') read: each paragraph of three dots
-- separated by spaces, where a pause is read.
withPauses :: Block -> Block
withPauses = \case
  Para [Str t] | T.words t == [".", ".", "."] -> Pause
  Div attrs bs -> Div attrs (map withPauses bs)
  Alert kind title bs -> Alert kind title (map withPauses bs)
  Spoiler h bs -> Spoiler h (map withPauses bs)
  List kind items -> List kind [ListItem task (map withPauses bs) | ListItem task bs <- items]
  other -> other

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
withSpoilerSections :: [Block] -> [Block]
withSpoilerSections = checked
  where
    checked bs = zipWith checkOne bs (map Just (drop 1 bs) <> [Nothing])
    checkOne b next = case b of
      Spoiler h bs ->
        let inner = checked bs
            problem = h.problem <|> (CutsSection <$ guard (not (fits inner next)))
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
data Inlines = Inlines (Seq Inline) [SpoilerMarker] Bool
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
barsOf :: Inlines -> [SpoilerMarker]
barsOf (Inlines _ bs _) = bs

-- | Blocks made of some inlines, with the bars of their inline spoilers.
withBars :: Inlines -> Blocks -> Blocks
withBars xs (Blocks bs ms) = Blocks bs (ms <> Markers [] (barsOf xs))

-- | Blocks as the parser builds them, each with the line of the source it
-- starts on once the parser has said ('parseWithLines'), and with the
-- markers of the boxes among them, nested ones too ('boxMarkers'). Every
-- block made of other blocks keeps their markers.
data Blocks = Blocks (Seq (Maybe Int, Block)) Markers
  deriving stock (Show)

-- | The markers of boxes and of spoilers among some blocks, nested ones
-- too.
data Markers = Markers [BoxMarker] [SpoilerMarker]
  deriving stock (Show)

instance Semigroup Markers where
  Markers bs ss <> Markers bs' ss' = Markers (bs <> bs') (ss <> ss')

instance Monoid Markers where
  mempty = Markers [] []

instance Semigroup Blocks where
  Blocks xs ms <> Blocks ys ns = Blocks (xs <> ys) (ms <> ns)

instance Monoid Blocks where
  mempty = Blocks Seq.empty mempty

inline :: Inline -> Inlines
inline x = Inlines (Seq.singleton x) [] False

block :: Block -> Blocks
block b = Blocks (Seq.singleton (Nothing, b)) mempty

-- | One block made of others, with their markers.
around :: ([Block] -> Block) -> Blocks -> Blocks
around make bs = Blocks (Seq.singleton (Nothing, make (blocks bs))) (markersOf bs)

markersOf :: Blocks -> Markers
markersOf (Blocks _ ms) = ms

inlines :: Inlines -> [Inline]
inlines (Inlines xs _ _) = toList xs

blocks :: Blocks -> [Block]
blocks (Blocks xs _) = map snd (toList xs)

-- | The parser gives the place of each inline it makes, the formatted ones
-- just after it makes them: an inline spoiler's place, from its first two
-- bars to the end of its last two, says where its bars are.
instance CM.Rangeable Inlines where
  ranged (CM.SourceRange ranges) = \case
    Inlines xs bs True
      | Just (start, _) <- head ranges
      , Just (_, end) <- lastMay ranges ->
          Inlines xs (bs <> [SpoilerMarker (Parsec.sourceLine start) (Parsec.sourceColumn start) (InlineBars (Parsec.sourceLine end) (Parsec.sourceColumn end - 2))]) False
    Inlines xs bs _ -> Inlines xs bs False

-- | The parser says where each block is once it has made it, innermost
-- first: a block without a line yet starts where this range does. A block
-- the parser made several of (a paragraph split around display math) has
-- them all start there.
instance CM.Rangeable Blocks where
  ranged (CM.SourceRange ranges) (Blocks xs ms) = case ranges of
    (start, _) : _ -> Blocks (first (<|> Just (CM.sourceLine start)) <$> xs) ms
    [] -> Blocks xs ms

instance CM.HasAttributes Inlines where
  addAttributes new (Inlines xs bs fresh) = Inlines (add <$> xs) bs fresh
    where
      add = \case
        Code attrs t -> Code (attrs <> new) t
        Link attrs d t xs' -> Link (attrs <> new) d t xs'
        Image attrs d t xs' -> Image (attrs <> new) d t xs'
        other -> other

instance CM.HasAttributes Blocks where
  addAttributes new (Blocks xs ms) = Blocks (fmap add <$> xs) ms
    where
      add = \case
        Heading l attrs xs' -> Heading l (attrs <> new) xs'
        CodeBlock attrs lang t -> codeBlockWith (attrs <> new) lang t
        Div attrs xs' -> Div (attrs <> new) xs'
        other -> other

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
  list kind _ items = Blocks (Seq.singleton . (Nothing,) $ (List (listKind kind) (map (ListItem Nothing . blocks) items))) (foldMap markersOf items)

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
  taskList kind _ items = Blocks (Seq.singleton . (Nothing,) $ (List (listKind kind) [ListItem (Just done) (blocks b) | (done, b) <- items])) (foldMap (markersOf . snd) items)

instance CME.HasFootnote Inlines Blocks where
  footnote number label = around (Footnotes . pure . Footnote number label)
  footnoteList notes =
    let all' = mconcat notes
     in Blocks (Seq.singleton . (Nothing,) $ (Footnotes (concat [ns | Footnotes ns <- blocks all']))) (markersOf all')

  -- The note's contents come along for formats that show a note where it
  -- is referenced; here they are shown once, in 'Footnotes'.
  footnoteRef number label _ = inline (FootnoteRef (fromMaybe 0 (readMaybe number)) label)

instance CME.HasDiv Blocks where
  div_ = around (Div [])

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

-- | What 'alertBlockSpec' keeps of a box's marker line until the box is
-- made: the marker, and the tokens of the title.
data MarkerLine = MarkerLine BoxMarker [CM.Tok]

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
          Node (CM.defBlockData alertBlockSpec) {CM.blockData = toDyn (MarkerLine marker titleToks), CM.blockStartPos = [pos]} []
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
        let MarkerLine marker titleToks =
              fromMaybe
                (MarkerLine BoxMarker {markerLine = 0, markerColumn = 0, boxKind = Note, boxTitle = Nothing, boxNumbered = True} [])
                (fromDynamic (CM.blockData (rootLabel node)))
        written <- if null titleToks then pure Nothing else Just <$> CM.runInlineParser titleToks
        inside <- mconcat <$> CM.renderChildren node
        let title = inlines <$> written
        pure (Blocks (Seq.singleton . (Nothing,) $ (Alert marker.boxKind BoxHead {title, numbered = marker.boxNumbered, id = Nothing} (blocks inside))) (Markers [marker] (foldMap barsOf written) <> markersOf inside))
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

-- | Block spoilers: the blocks between @[[spoiler]]{name}(Description)@
-- and @[[/spoiler]]{name}@, each marker a line of its own (indented by at
-- most three spaces, as other blocks may be). The blocks inside need no
-- prefix: code, lists, tables and other spoilers go in as they are. The
-- spoiler is a container on the block parser's stack, as a fenced div is,
-- so spoilers nest, and the inline parser never sees a marker: a line
-- that starts with @[[spoiler]]@ is never a wiki link.
--
-- An end marker ends the innermost open spoiler, and only when its name is
-- that spoiler's. Any other end marker, and a start marker without its
-- name in braces or its description in parentheses, is a 'SpoilerError'
-- line, which opens and ends nothing. A spoiler whose container (the
-- document, a quotation, a list item) ends before its end marker is
-- 'NotClosed'. An end marker in code, in a block of HTML or in a
-- paragraph's lazy line is not read as one, as a fenced div's end is not.
spoilerSpec :: CM.SyntaxSpec Identity Inlines Blocks
spoilerSpec = mempty {CM.syntaxBlockSpecs = [spoilerBlockSpec]}

-- | A marker line as 'readSpoilerMarker' reads it.
data MarkerText
  = -- | @[[spoiler]]{name}(Description)@: the name and the description.
    StartText Text Text
  | -- | @[[/spoiler]]{name}@: the name.
    EndText Text
  | -- | A line that starts as a marker and is not a whole one: why.
    BrokenText Text
  deriving stock (Eq, Show)

-- | What a line is, if it starts as a spoiler's marker: its text from the
-- first non-space, without the white space at its end.
readSpoilerMarker :: Text -> Maybe MarkerText
readSpoilerMarker written
  | Just rest <- T.stripPrefix "[[spoiler]]" written = Just (start (T.stripStart rest))
  | Just rest <- T.stripPrefix "[[/spoiler]]" written = Just (end (T.stripStart rest))
  | otherwise = Nothing
  where
    start rest = case braced rest of
      Nothing -> BrokenText "a spoiler needs its name in braces after [[spoiler]], as in [[spoiler]]{name}(Description)"
      Just (name, after)
        | not (validSpoilerName name) -> BrokenText badName
        | otherwise -> case T.uncons (T.stripStart after) of
            -- From the parenthesis after the name to the last one.
            Just ('(', inside) | (described, trailing) <- T.breakOnEnd ")" inside, not (T.null described) -> described' name (T.strip (T.dropEnd 1 described)) trailing
            _ -> BrokenText "a spoiler needs a description in parentheses after its name, as in [[spoiler]]{name}(Description)"
    described' name description trailing
      | not (T.null (T.strip trailing)) = BrokenText "nothing may follow the description's closing parenthesis"
      | T.null description = BrokenText "a spoiler needs a description in its parentheses, as in [[spoiler]]{name}(Description)"
      | otherwise = StartText name description
    end rest = case braced rest of
      Nothing -> BrokenText "an end marker needs the spoiler's name in braces, as in [[/spoiler]]{name}"
      Just (name, after)
        | not (validSpoilerName name) -> BrokenText badName
        | not (T.null (T.strip after)) -> BrokenText "nothing may follow an end marker's name"
        | otherwise -> EndText name
    badName = "a spoiler's name is one word of letters, digits, - and _"
    braced t = case T.uncons t of
      Just ('{', rest) | (inside, close) <- T.breakOn "}" rest, not (T.null close) -> Just (inside, T.drop 1 close)
      _ -> Nothing

-- | What the parser keeps of an open spoiler until it is made: what its
-- start marker said, where the marker is, and where its end marker was
-- once one has ended it.
data OpenSpoiler = OpenSpoiler
  { openName :: Text
  , openDescription :: Text
  , openDescriptionToks :: [CM.Tok]
  -- ^ The description's tokens, where the source has them, so that the
  -- places of the inline spoilers in it are the source's.
  , openMarker :: Text
  , openLine :: Int
  , openColumn :: Int
  , ended :: Maybe (Int, Int)
  }

spoilerBlockSpec :: CM.BlockSpec Identity Inlines Blocks
spoilerBlockSpec =
  CM.BlockSpec
    { CM.blockType = "Spoiler"
    , CM.blockStart = do
        CM.nonindentSpaces
        pos <- getPosition
        toks <- many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
        let written = T.stripEnd (CM.untokenize toks)
            line = Parsec.sourceLine pos
            column = Parsec.sourceColumn pos
            broken why = CM.addNodeToStack (Node (CM.defBlockData spoilerErrorSpec) {CM.blockData = toDyn (SpoilerMarker line column (Faulty written why)), CM.blockStartPos = [pos]} [])
        case readSpoilerMarker written of
          Nothing -> mzero
          Just (StartText name description) ->
            CM.addNodeToStack $
              Node (CM.defBlockData spoilerBlockSpec) {CM.blockData = toDyn OpenSpoiler {openName = name, openDescription = description, openDescriptionToks = descriptionToks toks, openMarker = written, openLine = line, openColumn = column, ended = Nothing}, CM.blockStartPos = [pos]} []
          -- An end marker that ended its spoiler was taken by the
          -- spoiler's continuation ('closesSpoiler'), so this one ends
          -- none.
          Just (EndText name) -> do
            open <- openSpoilers
            broken $ case open of
              [] -> "no spoiler is open here"
              innermost : outer
                | name `elem` outer -> "the innermost open spoiler is “" <> innermost <> "”: end it first"
                | otherwise -> "no open spoiler of this name"
          Just (BrokenText why) -> broken why
        pure CM.BlockStartMatch
    , CM.blockCanContain = const True
    , CM.blockContainsLines = False
    , CM.blockParagraph = False
    , CM.blockContinue = \node -> do
        ending <- optionMaybe (try (closesSpoiler node))
        pos <- getPosition
        case ending of
          Nothing -> pure (pos, node)
          Just at -> do
            CM.endOfBlock
            let ended = maybe (CM.blockData (rootLabel node)) (\o -> toDyn o {ended = Just at}) (spoilerOf node)
            pure (pos, node {rootLabel = (rootLabel node) {CM.blockData = ended}})
    , CM.blockConstructor = \node -> do
        inside <- mconcat <$> CM.renderChildren node
        case spoilerOf node of
          Nothing -> pure inside
          Just o -> do
            -- The description's own tokens, or, should they not be the
            -- description as read, its text tokenized again.
            let toks
                  | T.strip (CM.untokenize o.openDescriptionToks) == o.openDescription = o.openDescriptionToks
                  | otherwise = CM.tokenize "spoiler" o.openDescription
            parsedDescription <- CM.runInlineParser toks
            let h = SpoilerHead {name = o.openName, description = inlines parsedDescription, marker = o.openMarker, line = o.openLine, problem = NotClosed <$ guard (isNothing o.ended)}
                found = Markers [] ([SpoilerMarker o.openLine o.openColumn (Starts o.openName o.openDescription)] <> [SpoilerMarker l c (Ends o.openLine) | Just (l, c) <- [o.ended]] <> barsOf parsedDescription)
            pure (Blocks (Seq.singleton (Nothing, Spoiler h (blocks inside))) (found <> markersOf inside))
    , CM.blockFinalize = CM.defaultFinalizer
    }
  where
    -- The names of the spoilers open where the parser is, the innermost
    -- first.
    openSpoilers = do
      stack <- CM.nodeStack <$> getState
      pure [o.openName | n <- stack, Just o <- [spoilerOf n]]
    spoilerOf :: CM.BlockNode Identity Inlines Blocks -> Maybe OpenSpoiler
    spoilerOf n
      | CM.blockType (CM.blockSpec (rootLabel n)) == "Spoiler" = fromDynamic (CM.blockData (rootLabel n))
      | otherwise = Nothing
    -- The line is the end marker of this spoiler: it names it, the
    -- spoiler is the innermost open one, and nothing above it on the
    -- stack takes its lines as they are (code, HTML). Where the marker's
    -- text starts, if so.
    closesSpoiler node = do
      CM.nonindentSpaces
      at <- getPosition
      written <- T.stripEnd . CM.untokenize <$> many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
      own <- maybe mzero pure (spoilerOf node)
      guard (readSpoilerMarker written == Just (EndText own.openName))
      stack <- CM.nodeStack <$> getState
      let above = takeWhile (\n -> CM.blockStartPos (rootLabel n) /= CM.blockStartPos (rootLabel node) || isNothing (spoilerOf n)) stack
          verbatim n = let s = CM.blockSpec (rootLabel n) in CM.blockContainsLines s && not (CM.blockParagraph s)
      guard (not (any (\n -> isJust (spoilerOf n) || verbatim n) above))
      pure (Parsec.sourceLine at, Parsec.sourceColumn at)

-- | The tokens of a start marker's description: after the name's closing
-- brace and the opening parenthesis, up to the last closing parenthesis,
-- without the spaces at either end.
descriptionToks :: [CM.Tok] -> [CM.Tok]
descriptionToks toks = case dropWhile spaces (drop 1 (dropWhile (not . CM.hasType (CM.Symbol '}')) toks)) of
  open : rest
    | CM.hasType (CM.Symbol '(') open ->
        trim (reverse (drop 1 (dropWhile (not . CM.hasType (CM.Symbol ')')) (reverse rest))))
  _ -> []
  where
    spaces = CM.hasType CM.Spaces
    trim = reverse . dropWhile spaces . reverse . dropWhile spaces

-- | A 'SpoilerError' line: made at once, and holding nothing, so the next
-- line is read afresh.
spoilerErrorSpec :: CM.BlockSpec Identity Inlines Blocks
spoilerErrorSpec =
  CM.BlockSpec
    { CM.blockType = "SpoilerError"
    , CM.blockStart = mzero
    , CM.blockCanContain = const False
    , CM.blockContainsLines = False
    , CM.blockParagraph = False
    , CM.blockContinue = const mzero
    , CM.blockConstructor = \node -> pure $ case fromDynamic (CM.blockData (rootLabel node)) of
        Just m@(SpoilerMarker _ _ (Faulty written why)) -> Blocks (Seq.singleton (Nothing, SpoilerError written why)) (Markers [] [m])
        _ -> mempty
    , CM.blockFinalize = CM.defaultFinalizer
    }

listKind :: CM.ListType -> ListKind
listKind = \case
  CM.BulletList _ -> BulletList
  CM.OrderedList start _ _ -> OrderedList start

-- | A code block, or a Mermaid diagram, a TikZ picture or display math
-- when its language says so. The language is the first word of the info
-- string; a fence written with attributes alone (@```{.mermaid}@) gives it
-- as a class.
codeBlockWith :: Attributes -> Maybe Text -> Text -> Block
codeBlockWith attrs info code = case info <|> head (classes attrs) of
  Just "mermaid" -> Mermaid code
  Just "tikz" -> Tikz code
  Just "math" -> MathBlock code
  lang -> CodeBlock attrs lang code

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
