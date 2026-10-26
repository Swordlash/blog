-- | A page's Markdown as a tree of our own, parsed by @commonmark@.
--
-- The tree is what the rest of the wiki works with: the renderer
-- ("Wiki.Core.Markdown.Render") turns it into Halogen HTML, and later
-- features (search, a table of contents, export) walk it. It says what the
-- author wrote and nothing about how it is shown: a link keeps its
-- destination as written, to be resolved when it is rendered; an embed
-- (@![caption](…)@) does not yet know whether it is an image, a video or a
-- download; a code block in a @mermaid@, @tikz@ or @math@ fence is already told apart
-- from other code, because what it is does not depend on the wiki.
--
-- 'parseMarkdown' reads CommonMark with these extensions:
--
-- * GitHub's: pipe tables, task lists, footnotes, strikethrough, autolinks
--   (bare @https://…@ and @www.…@), emoji shortcodes (@:tada:@), alerts
--   (@> [!NOTE]@);
-- * heading identifiers made from the heading's text ('headingSlug'),
--   unique in the document: a heading with an @id@ of its own keeps it,
--   and the others get theirs in document order, the second @Intro@
--   @intro-2@, the third @intro-3@, none taking an id written out in
--   braces anywhere in the page;
-- * math, @$…$@ and @\\(…\\)@ inline, @$$…$$@ and @\\[…\\]@ display
--   ("Wiki.Core.Markdown.TexMath"), and a @math@ fence;
-- * attributes in braces after a heading, a fence's info string, a link,
--   an image or inline code (@# Intro {#start}@, @![](a.png){width=300}@);
-- * fenced divs (@::: warning@ … @:::@), for boxes styled by class;
-- * wiki links, @[[page]]@ and @[[page|label]]@, read as ordinary links to
--   @page@, but for @[[toc]]@ as a paragraph of its own, which is where
--   the page's table of contents goes ('TableOfContents');
-- * mentions, @\@login@, in text outside code, links and embeds
--   ("Wiki.Core.Markdown.Mention" says what counts as one).
--
-- Raw HTML in the source is kept as written, as 'RawHtml' (one tag or
-- comment each, with the Markdown between them as ordinary inlines) and
-- 'RawHtmlBlock'. What of it reaches the page is decided by the allowlist
-- in "Wiki.Core.Markdown.Html", when it is rendered.
--
-- Source positions are not kept: nothing needs them yet. Adding them means
-- giving 'Rangeable' a real instance and a field to the constructors.
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

    -- * Reading the tree
  , plainText
  , attribute
  , classes
  , mentions
  )
where

import Commonmark qualified as CM
import Commonmark.Entity qualified as CM
import Commonmark.Extensions qualified as CME
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Core.Markdown.Mention (splitMentions)
import Wiki.Core.Markdown.TexMath (texMathSpec)
import Wiki.Core.Slug (freshName, headingSlug)

-- | Attributes from braces, @{#id .class key=value}@, in the order written.
-- Heading identifiers are among them, as @id@. Which of them reach the HTML
-- is the renderer's decision.
type Attributes = [(Text, Text)]

-- | A block of a page.
data Block
  = -- | A paragraph. It never holds display math: a paragraph with some is
    -- split around it into paragraphs and 'MathBlock's, because a @p@
    -- cannot hold the block a formula is shown in.
    Para [Inline]
  | -- | Text not in a paragraph: an item of a tight list. Split around
    -- display math as 'Para' is.
    Plain [Inline]
  | -- | A heading: its level (1 to 6), its attributes (with its @id@), its
    -- text.
    Heading Int Attributes [Inline]
  | ThematicBreak
  | BlockQuote [Block]
  | -- | Fenced or indented code: attributes, the language (the first word of
    -- the info string, or failing that the first class), the code.
    CodeBlock Attributes (Maybe Text) Text
  | -- | A @mermaid@ fence: the diagram's source.
    Mermaid Text
  | -- | A @tikz@ fence: the picture's TeX, as written ("Wiki.Core.Markdown.Tikz"
    -- reads it).
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
  | -- | A GitHub alert, @> [!NOTE]@ and friends.
    Alert AlertKind [Block]
  | -- | The footnotes, in the order they were defined. Comes last in the
    -- document, once, when it has any.
    Footnotes [Footnote]
  | -- | A block of raw HTML, as written: rendered through the allowlist of
    -- "Wiki.Core.Markdown.Html", read as one document.
    RawHtmlBlock Text
  | -- | @[[toc]]@ (or @[[TOC]]@) as a paragraph of its own: the page's table
    -- of contents goes there ("Wiki.Core.Markdown.Toc").
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
  | -- | Raw HTML among the text, as written: a tag (opening or closing) or
    -- a comment. Rendered through the allowlist of
    -- "Wiki.Core.Markdown.Html", read with the inlines around it.
    RawHtml Text
  | -- | A mention, @\@login@: the login, without the @\@@. Whether it is a
    -- user's is the renderer's to ask; one that is not, and one in a link,
    -- shows as it is written.
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

data AlertKind = Note | Tip | Important | Warning | Caution
  deriving stock (Eq, Show)

-- | Why a text is not Markdown. CommonMark gives every text a meaning, so
-- this is rare; it is kept rather than thrown away so that a failure shows.
newtype ParseError = ParseError Text
  deriving stock (Eq, Show)

-- | Parse a page's Markdown.
parseMarkdown :: Text -> Either ParseError [Block]
parseMarkdown source =
  bimap (ParseError . show) (\(Blocks bs) -> withHeadingIds (map (contentsMarker . withMentions) (toList bs)))
    $ runIdentity
    $ CM.commonmarkWith syntax "markdown" terminated
  where
    -- The pipe table extension does not take a last row that the end of the
    -- text ends rather than a newline (commonmark-extensions 0.2.7.3), and
    -- a text area's value usually has no newline at the end.
    terminated
      | "\n" `T.isSuffixOf` source = source
      | otherwise = source <> "\n"

-- | GitHub's extensions (those of @gfmExtensions@) and ours, then the core
-- syntax, then pipe tables. An extension that changes what a core construct
-- means (a list item that is a task, a block quote that is an alert) has to
-- be tried before it; pipe tables, which take a paragraph's line as their
-- header, come after the core's blocks, as commonmark-extensions asks, so
-- that a line with a pipe in it that is something else stays that.
syntax :: CM.SyntaxSpec Identity Inlines Blocks
syntax =
  CME.emojiSpec
    <> CME.strikethroughSpec
    <> CME.autolinkSpec
    <> CME.taskListSpec
    <> CME.footnoteSpec
    <> CME.alertSpec
    <> CME.mathSpec
    <> texMathSpec
    <> CME.wikilinksSpec CME.TitleAfterPipe
    <> CME.fencedDivSpec
    <> CME.attributesSpec
    <> CM.defaultSyntaxSpec
    <> CME.pipeTableSpec

-- | The text of some inlines, without their markup: what a heading's
-- identifier is made from, and what an image's @alt@ is.
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

-- | The logins a document mentions, outside links (where a mention is
-- shown as text, since a link cannot hold one): whom it would notify.
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
      Alert _ bs -> mentions bs
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
-- otherwise one made from its text ('headingSlug'), in document order, free
-- of every id written in braces in the page and of the ids given to the
-- headings before it ('freshName'). One pass over the parsed tree, so that
-- whatever renders the tree, and whatever lists its headings, sees the same
-- ids.
--
-- This replaces commonmark-extensions' @autoIdentifiersSpec@, which made the
-- second @Intro@ @intro-1@ and did not stay clear of the ids written out.
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
      Alert _ bs -> concatMap explicit bs
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
      Alert kind bs -> Alert kind <$> traverse assign bs
      Footnotes notes -> Footnotes <$> traverse (\(Footnote n label bs) -> Footnote n label <$> traverse assign bs) notes
      other -> pure other

-- | A paragraph that is nothing but the wiki link @[[toc]]@ is where the
-- table of contents goes. Any other link to @toc@ stays a link, to a page
-- of that name.
contentsMarker :: Block -> Block
contentsMarker = \case
  Para [Link attrs dest _ [Str label]]
    | "wikilink" `elem` classes attrs
    , T.toLower dest == "toc"
    , T.toLower label == "toc" ->
        TableOfContents
  other -> other

----------------------------------------------------------------------
-- Mentions

-- | A block with the mentions in its text made 'Mention's: in every text
-- but code's, a link's and an embed's (whose caption is an image's
-- description, not text of the page's).
withMentions :: Block -> Block
withMentions = \case
  Para xs -> Para (mentioning xs)
  Plain xs -> Plain (mentioning xs)
  Heading l attrs xs -> Heading l attrs (mentioning xs)
  BlockQuote bs -> BlockQuote (map withMentions bs)
  List kind items -> List kind [ListItem task (map withMentions bs) | ListItem task bs <- items]
  Table aligns header rows -> Table aligns (map mentioning header) (map (map mentioning) rows)
  Div attrs bs -> Div attrs (map withMentions bs)
  Alert kind bs -> Alert kind (map withMentions bs)
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

newtype Blocks = Blocks (Seq Block)
  deriving stock (Show)
  deriving newtype (Semigroup, Monoid)

inline :: Inline -> Inlines
inline = Inlines . Seq.singleton

block :: Block -> Blocks
block = Blocks . Seq.singleton

inlines :: Inlines -> [Inline]
inlines (Inlines xs) = toList xs

blocks :: Blocks -> [Block]
blocks (Blocks xs) = toList xs

instance CM.Rangeable Inlines where
  ranged _ = identity

instance CM.Rangeable Blocks where
  ranged _ = identity

instance CM.HasAttributes Inlines where
  addAttributes new (Inlines xs) = Inlines (add <$> xs)
    where
      add = \case
        Code attrs t -> Code (attrs <> new) t
        Link attrs d t xs' -> Link (attrs <> new) d t xs'
        Image attrs d t xs' -> Image (attrs <> new) d t xs'
        other -> other

instance CM.HasAttributes Blocks where
  addAttributes new (Blocks xs) = Blocks (add <$> xs)
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

  -- The core syntax makes raw inlines of HTML only; the extensions that
  -- make other formats are not enabled.
  rawInline _ = inline . RawHtml

instance CM.IsBlock Inlines Blocks where
  paragraph = splitDisplayMath Para . inlines
  plain = splitDisplayMath Plain . inlines
  thematicBreak = block ThematicBreak
  blockQuote = block . BlockQuote . blocks
  codeBlock info = block . codeBlockWith [] (head (T.words info))
  heading level = block . Heading level [] . inlines
  rawBlock _ = block . RawHtmlBlock

  -- A definition has done its work once the links that use it are parsed.
  referenceLinkDefinition _ _ = mempty
  list kind _ = block . List (listKind kind) . map (ListItem Nothing . blocks)

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
  taskList kind _ = block . List (listKind kind) . map (\(done, b) -> ListItem (Just done) (blocks b))

instance CME.HasFootnote Inlines Blocks where
  footnote number label = block . Footnotes . pure . Footnote number label . blocks
  footnoteList notes = block (Footnotes (concat [ns | Footnotes ns <- blocks (mconcat notes)]))

  -- The note's contents come along for formats that show a note where it
  -- is referenced; here they are shown once, in 'Footnotes'.
  footnoteRef number label _ = inline (FootnoteRef (fromMaybe 0 (readMaybe number)) label)

instance CME.HasAlerts Inlines Blocks where
  alert kind = block . Alert (alertKind kind) . blocks
    where
      alertKind = \case
        CME.NoteAlert -> Note
        CME.TipAlert -> Tip
        CME.ImportantAlert -> Important
        CME.WarningAlert -> Warning
        CME.CautionAlert -> Caution

instance CME.HasDiv Blocks where
  div_ = block . Div [] . blocks

listKind :: CM.ListType -> ListKind
listKind = \case
  CM.BulletList _ -> BulletList
  CM.OrderedList start _ _ -> OrderedList start

-- | A code block, or a Mermaid diagram, a TikZ picture or display math when
-- its language says so. The language is the first word of the info string; a fence
-- written with attributes alone (@```{.mermaid}@) gives it as a class.
codeBlockWith :: Attributes -> Maybe Text -> Text -> Block
codeBlockWith attrs info code = case info <|> head (classes attrs) of
  Just "mermaid" -> Mermaid code
  Just "tikz" -> Tikz code
  Just "math" -> MathBlock code
  lang -> CodeBlock attrs lang code

-- | A paragraph's inlines as blocks: the paragraph itself, or, when it holds
-- display math, the paragraphs around each formula and the formulas as
-- 'MathBlock's. The text next to a formula loses the white space that
-- separated it from the formula.
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
