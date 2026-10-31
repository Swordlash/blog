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
-- * boxes, @> [!KIND]@: GitHub's alerts (@> [!NOTE]@ and its four
--   others), and any other kind (@> [!EXERCISE]@), with an optional title
--   after the marker (@> [!TIP] Before you start@), read by the wiki's own
--   block syntax ('alertSpec');
-- * heading identifiers made from the heading's text ('headingSlug'),
--   unique in the document: a heading with an @id@ of its own keeps it,
--   and the others get theirs in document order (the second @Intro@ gets
--   @intro-2@, the third @intro-3@), none taking an id written in braces
--   anywhere in the page;
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
  , MathKind (..)
  , Attributes

    -- * Parsing
  , ParseError (..)
  , parseMarkdown
  , BoxMarker (..)
  , boxMarkers
  , parseWithMarkers
  , parseWithLines

    -- * Reading the tree
  , plainText
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
import Commonmark.TokParsers qualified as CM
import Data.Dynamic (fromDynamic, toDyn)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Tree (Tree (..))
import Protolude hiding (try)
import Text.Parsec (getPosition, many1, option, try)
import Text.Parsec qualified as Parsec
import Wiki.Core.Markdown.Box (AlertKind (..), readAlertKind)
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
  | -- | A box, @> [!KIND]@: its kind, the title written after the marker
    -- if there is one, and its blocks. GitHub's five kinds are its alerts
    -- (@> [!NOTE]@ and friends); "Wiki.Core.Markdown.Box" says what any
    -- other kind is.
    Alert AlertKind (Maybe Text) [Block]
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
  | SoftBreak
  | LineBreak
  | Emph [Inline]
  | Strong [Inline]
  | Strikeout [Inline]
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
parseWithMarkers source =
  (\(Blocks bs ms) -> (finished (map snd (toList bs)), sortOn (\m -> (m.markerLine, m.markerColumn)) (ordNub ms)))
    <$> parsed source

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
finished = withHeadingIds . map (withPauses . contentsMarker . withMentions)

-- | 'BoxMarker' is where a box's marker, @[!KIND]@, is in a page's source:
-- its line and column (from 1; a tab counts to the next multiple of four
-- columns, as CommonMark counts it), with the box's kind and its title as
-- the parser read them. The export rewrites the source at these places
-- before pandoc reads it ("Wiki.Server.Export.Document"), so that a
-- document has a box exactly where the page has one.
data BoxMarker = BoxMarker
  { markerLine :: Int
  , markerColumn :: Int
  , boxKind :: AlertKind
  , boxTitle :: Maybe Text
  }
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
    <> CME.autolinkSpec
    <> CME.taskListSpec
    <> CME.footnoteSpec
    <> alertSpec
    <> CME.mathSpec
    <> texMathSpec
    <> CME.wikilinksSpec CME.TitleAfterPipe
    <> CME.fencedDivSpec
    <> CME.attributesSpec
    <> CM.defaultSyntaxSpec
    <> CME.pipeTableSpec

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
      Alert _ _ bs -> mentions bs
      Footnotes notes -> foldMap (\(Footnote _ _ bs) -> mentions bs) notes
      _ -> mempty
    inlines' = foldMap $ \case
      Mention login -> Set.singleton login
      Emph xs -> inlines' xs
      Strong xs -> inlines' xs
      Strikeout xs -> inlines' xs
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
-- This replaces commonmark-extensions' @autoIdentifiersSpec@, which gave
-- the second @Intro@ the id @intro-1@ and did not avoid the ids written
-- out.
withHeadingIds :: [Block] -> [Block]
withHeadingIds doc = evalState (traverse assign doc) written
  where
    written = Set.fromList (concatMap explicit doc)
    explicit = \case
      Heading _ attrs _ -> ownId attrs
      Div attrs bs -> ownId attrs <> concatMap explicit bs
      CodeBlock attrs _ _ -> ownId attrs
      BlockQuote bs -> concatMap explicit bs
      List _ items -> concat [concatMap explicit bs | ListItem _ bs <- items]
      Alert _ _ bs -> concatMap explicit bs
      Footnotes notes -> concat [concatMap explicit bs | Footnote _ _ bs <- notes]
      _ -> []
    ownId attrs = [i | Just i <- [attribute "id" attrs], not (T.null i)]
    assign :: Block -> State (Set Text) Block
    assign = \case
      Heading level attrs xs
        | null (ownId attrs) -> do
            taken <- get
            let ident = freshName (`Set.member` taken) (headingSlug (plainText xs))
            put (Set.insert ident taken)
            pure (Heading level (("id", ident) : filter ((/= "id") . fst) attrs) xs)
      BlockQuote bs -> BlockQuote <$> traverse assign bs
      List kind items -> List kind <$> traverse (\(ListItem task bs) -> ListItem task <$> traverse assign bs) items
      Div attrs bs -> Div attrs <$> traverse assign bs
      Alert kind title bs -> Alert kind title <$> traverse assign bs
      Footnotes notes -> Footnotes <$> traverse (\(Footnote n label bs) -> Footnote n label <$> traverse assign bs) notes
      other -> pure other

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
  Alert kind title bs -> Alert kind title (map withMentions bs)
  Footnotes notes -> Footnotes [Footnote n label (map withMentions bs) | Footnote n label bs <- notes]
  other -> other
  where
    mentioning = concatMap $ \case
      Str t -> map (either Str Mention) (splitMentions t)
      Emph xs -> [Emph (mentioning xs)]
      Strong xs -> [Strong (mentioning xs)]
      Strikeout xs -> [Strikeout (mentioning xs)]
      other -> [other]

----------------------------------------------------------------------
-- What commonmark builds

-- | Inlines as the parser builds them: a sequence, so that appending is
-- cheap, which merges adjacent text as it goes.
newtype Inlines = Inlines (Seq Inline)
  deriving stock (Show)

instance Semigroup Inlines where
  Inlines xs <> Inlines ys = case (Seq.viewr xs, Seq.viewl ys) of
    (xs' Seq.:> Str a, Str b Seq.:< ys') -> Inlines ((xs' Seq.|> Str (a <> b)) <> ys')
    _ -> Inlines (xs <> ys)

instance Monoid Inlines where
  mempty = Inlines Seq.empty

-- | Blocks as the parser builds them, each with the line of the source it
-- starts on once the parser has said ('parseWithLines'), and with the
-- markers of the boxes among them, nested ones too ('boxMarkers'). Every
-- block made of other blocks keeps their markers.
data Blocks = Blocks (Seq (Maybe Int, Block)) [BoxMarker]
  deriving stock (Show)

instance Semigroup Blocks where
  Blocks xs ms <> Blocks ys ns = Blocks (xs <> ys) (ms <> ns)

instance Monoid Blocks where
  mempty = Blocks Seq.empty []

inline :: Inline -> Inlines
inline = Inlines . Seq.singleton

block :: Block -> Blocks
block b = Blocks (Seq.singleton (Nothing, b)) []

-- | One block made of others, with their markers.
around :: ([Block] -> Block) -> Blocks -> Blocks
around make bs = Blocks (Seq.singleton (Nothing, make (blocks bs))) (markersOf bs)

markersOf :: Blocks -> [BoxMarker]
markersOf (Blocks _ ms) = ms

inlines :: Inlines -> [Inline]
inlines (Inlines xs) = toList xs

blocks :: Blocks -> [Block]
blocks (Blocks xs _) = map snd (toList xs)

instance CM.Rangeable Inlines where
  ranged _ = identity

-- | The parser says where each block is once it has made it, innermost
-- first: a block without a line yet starts where this range does. A block
-- the parser made several of (a paragraph split around display math) has
-- them all start there.
instance CM.Rangeable Blocks where
  ranged (CM.SourceRange ranges) (Blocks xs ms) = case ranges of
    (start, _) : _ -> Blocks (first (<|> Just (CM.sourceLine start)) <$> xs) ms
    [] -> Blocks xs ms

instance CM.HasAttributes Inlines where
  addAttributes new (Inlines xs) = Inlines (add <$> xs)
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
  emph = inline . Emph . inlines
  strong = inline . Strong . inlines
  link destination title = inline . Link [] destination title . inlines
  image source title = inline . Image [] source title . inlines
  code = inline . Code []

  -- The core syntax makes raw inlines only of HTML; the extensions that
  -- make other formats are not enabled.
  rawInline _ = inline . RawHtml

instance CM.IsBlock Inlines Blocks where
  paragraph = splitDisplayMath Para . inlines
  plain = splitDisplayMath Plain . inlines
  thematicBreak = block ThematicBreak
  blockQuote = around BlockQuote
  codeBlock info = block . codeBlockWith [] (head (T.words info))
  heading level = block . Heading level [] . inlines
  rawBlock _ = block . RawHtmlBlock

  -- A definition has done its job once the links that use it are parsed.
  referenceLinkDefinition _ _ = mempty
  list kind _ items = Blocks (Seq.singleton . (Nothing,) $ (List (listKind kind) (map (ListItem Nothing . blocks) items))) (concatMap markersOf items)

instance CME.HasMath Inlines where
  inlineMath = inline . Math InlineMath
  displayMath = inline . Math DisplayMath

instance CME.HasStrikethrough Inlines where
  strikethrough = inline . Strikeout . inlines

instance CME.HasEmoji Inlines where
  emoji keyword = inline . Emoji keyword

instance CME.HasWikilinks Inlines where
  wikilink destination = inline . Link [("class", "wikilink")] destination "" . inlines

instance CME.HasPipeTable Inlines Blocks where
  pipeTable aligns header rows =
    block $ Table (map alignment aligns) (map inlines header) (map (map inlines) rows)
    where
      alignment = \case
        CME.LeftAlignedCol -> AlignLeft
        CME.CenterAlignedCol -> AlignCenter
        CME.RightAlignedCol -> AlignRight
        CME.DefaultAlignedCol -> AlignDefault

instance CME.HasTaskList Inlines Blocks where
  taskList kind _ items = Blocks (Seq.singleton . (Nothing,) $ (List (listKind kind) [ListItem (Just done) (blocks b) | (done, b) <- items])) (concatMap (markersOf . snd) items)

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
-- syntax, the library's with those two differences. The marker is @[!@,
-- a name of letters and dashes in any case, and @]@ ('readAlertKind'); a
-- marker with any other name leaves the block an ordinary quotation. What
-- follows it on the line, after a space, is the box's title, as written:
-- plain text, in which Markdown is not read (@> [!TIP] *Read* this@ is
-- titled with the asterisks).
alertSpec :: CM.SyntaxSpec Identity Inlines Blocks
alertSpec = mempty {CM.syntaxBlockSpecs = [alertBlockSpec]}

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
        _ <- CM.symbol ']'
        rest <- many (CM.satisfyTok (not . CM.hasType CM.LineEnd))
        -- A title is set off from the marker by a space: @[!NOTE]s@ is
        -- not a box.
        guard (maybe True (CM.hasType CM.Spaces) (head rest))
        let title = mfilter (not . T.null) (Just (T.strip (CM.untokenize rest)))
        CM.addNodeToStack $
          Node (CM.defBlockData alertBlockSpec) {CM.blockData = toDyn BoxMarker {markerLine = Parsec.sourceLine at, markerColumn = Parsec.sourceColumn at, boxKind = kind, boxTitle = title}, CM.blockStartPos = [pos]} []
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
        let marker = fromMaybe BoxMarker {markerLine = 0, markerColumn = 0, boxKind = Note, boxTitle = Nothing} (fromDynamic (CM.blockData (rootLabel node)))
        inside <- mconcat <$> CM.renderChildren node
        pure (Blocks (Seq.singleton . (Nothing,) $ (Alert marker.boxKind marker.boxTitle (blocks inside))) (marker : markersOf inside))
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
