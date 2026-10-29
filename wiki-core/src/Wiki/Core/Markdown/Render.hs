-- | The Markdown renderer: it turns a page's Markdown tree
-- ("Wiki.Core.Markdown.Ast") into Halogen HTML.
--
-- The HTML is built element by element, never from an HTML string: the
-- author's text is always text. Raw HTML in the source is parsed in
-- Haskell, and the parts an allowlist accepts are built as elements too
-- ("Wiki.Core.Markdown.Html"; 'renderRawHtml'). An HTML tag in the text
-- contains the Markdown up to its end tag. Links and embeds, including the
-- links and sources in raw HTML, are resolved through the 'Options' the
-- caller passes. A URL is written only if its scheme is harmless
-- ("Wiki.Core.Markdown.Link"), and an external link gets
-- @rel=\"noopener\"@.
--
-- __Islands.__ Code, math, Mermaid diagrams and TikZ pictures are drawn by
-- JavaScript libraries into elements Halogen does not look inside. The
-- renderer leaves them to 'Options' callbacks, which by default write the
-- source as text in the elements those libraries look for:
-- @\<pre>\<code class=\"language-x\">@, @\<span class=\"math inline\">@,
-- @\<div class=\"math display\">@, @\<pre class=\"mermaid\">@ and
-- @\<pre class=\"tikz\">@. A caller that renders them as child
-- components gets an 'IslandKey' with each, unique in the document, to use as
-- the slot's index: Halogen tells two children apart by their slot address,
-- and a document can hold the same formula twice.
--
-- __Macros.__ Each formula receives the earlier formulas in the document
-- that define macros ("Wiki.Core.Math"), in order. So a page's macro
-- definitions apply to every formula after them, as in a LaTeX document,
-- and how a formula is typeset depends on the page alone, not on the
-- order in which the islands are drawn.
--
-- __Embeds.__ @![caption](destination)@ shows what the destination resolves
-- to, according to its media type: for an attachment, the type the wiki
-- has for it, or else its name's extension; for a URL, its extension.
-- Images become @\<img>@, videos @\<video controls>@, audio
-- @\<audio controls>@, and an attachment of any other type a download
-- link. A URL of an unknown type is an image, as in plain Markdown. An
-- embedded page is a link to it.
--
-- __Layout.__ Headings carry their @id@, and end with an empty link to
-- it, @\<a class=\"heading-anchor\">@, which the stylesheet shows as a @#@
-- on hover. @[[toc]]@ is the document's table of contents
-- ("Wiki.Core.Markdown.Toc"), a @\<nav class=\"toc\">@. Task list items start with a
-- disabled checkbox. Footnote references are @\<sup class=\"footnote-ref\">@
-- links to @#fn-N@, and the notes are a @\<section class=\"footnotes\">@ at
-- the end, each ending with a link back to its first reference. Table cells
-- are aligned with a @text-align@ style. A box, @> [!KIND]@, is
-- @\<div class=\"alert alert-note\">@ (its kind's name after @alert-@)
-- with a @\<p class=\"alert-title\">@ that holds its title: the one
-- written after the marker, or else its kind's label
-- ("Wiki.Core.Markdown.Box"). A box of a kind the administrator defined
-- ('boxes') carries the kind's colour and icon as CSS custom properties in
-- its @style@, and its title starts with an empty
-- @\<span class=\"alert-icon\">@ when the kind has an icon, which the
-- stylesheet draws.
-- Only @id@ and @class@ attributes from braces reach the HTML (and @width@
-- and @height@ in pixels on an embed): any other could be an event handler.
--
-- __Mentions.__ @\@login@ is a link, @\<a class=\"mention\">@, to wherever
-- 'resolveMention' says the user is, titled with their name; a login it
-- does not know, and a mention in a link's text, are the text as written.
module Wiki.Core.Markdown.Render
  ( Options (..)
  , MentionTarget (..)
  , IslandKey (..)
  , defaultOptions
  , defaultResolveLink
  , renderBlocks
  , renderSections
  , renderRawHtml
  , boxOf
  )
where

import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as M
import Data.Row (Empty, HasType)
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Box (BoxIcon (..), BoxKind (..), alertKindName, boxLabel, boxStyle, definedKind)
import Wiki.Core.Markdown.Html qualified as Html
import Wiki.Core.Markdown.Link
import Wiki.Core.Markdown.Toc (contentsNav, tableOfContents)
import Wiki.Core.Math (Macros (..), definesMacros)

-- | 'Options' are the parts of rendering that the caller decides: how
-- islands are drawn, and how links and mentions are resolved.
--
-- @w@ and @i@ are those of the 'HH.HTML' it makes, so a caller that renders
-- islands as child components instantiates them with its component's slots
-- and actions (@HH.ComponentHTML action slots m@ is
-- @HH.HTML (ComponentSlot slots m action) action@). @page@ is the caller's
-- type for a page: 'resolveLink' returns it, and 'pageHref' makes a link
-- to it.
data Options page w i = Options
  { codeBlock :: IslandKey -> Maybe Text -> Text -> HH.HTML w i
  -- ^ A code block: its language, if it has one, and its code.
  , mathInline :: IslandKey -> Macros -> Text -> HH.HTML w i
  -- ^ Inline math, @$…$@: the formulas before it that define macros, and
  -- its TeX.
  , mathDisplay :: IslandKey -> Macros -> Text -> HH.HTML w i
  -- ^ Display math, @$$…$$@ or a @math@ fence: the formulas before it that
  -- define macros, and its TeX. Rendered as a block except in a heading or
  -- a table cell.
  , mermaid :: IslandKey -> Text -> HH.HTML w i
  -- ^ A Mermaid diagram: its source.
  , tikz :: IslandKey -> Text -> HH.HTML w i
  -- ^ A TikZ picture: its source, as written in the fence
  -- ("Wiki.Core.Markdown.Tikz" makes it TeX).
  , resolveLink :: Text -> LinkTarget page
  -- ^ What a link's or an embed's destination, as written, points at.
  , pageHref :: page -> Text
  -- ^ The @href@ of a link to a page.
  , resolveMention :: Text -> Maybe MentionTarget
  -- ^ Where a mention of a login leads, if it is a user's that the reader
  -- may be shown.
  , headingAnchors :: Bool
  -- ^ Whether a heading ends with its link to itself: in a page, but not
  -- where nothing shows it (a feed, read without the stylesheet).
  , boxes :: [BoxKind]
  -- ^ The kinds of box the administrator defined, with their labels,
  -- colours and icons ("Wiki.Core.Markdown.Box").
  }

-- | The user a mention names, as its link shows them.
data MentionTarget = MentionTarget
  { href :: Text
  , name :: Text
  -- ^ Their display name, the link's title.
  }
  deriving stock (Eq, Show)

-- | 'IslandKey' identifies an island in a document: its source, and how
-- many islands with the same source, of any kind, come before it. No two
-- islands of a document have the same key. An island keeps its key when
-- the document changes anywhere but in an island with the same source
-- before it, so a child component in a slot indexed by the key survives
-- edits elsewhere.
data IslandKey = IslandKey
  { source :: Text
  , occurrence :: Int
  }
  deriving stock (Eq, Ord, Show)

-- | The default 'Options'. Each island is the element its library
-- expects, holding the source as text, so that the page is readable
-- without the library. Links are used as written ('defaultResolveLink'),
-- and mentions are plain text. @page@ is 'Text' only so that it has a
-- type: nothing resolves to a page until a caller's 'resolveLink' does,
-- and a record update that sets both 'resolveLink' and 'pageHref' gives
-- @page@ the caller's own type.
defaultOptions :: Options Text w i
defaultOptions =
  Options
    { codeBlock = \_ lang code ->
        HH.pre_ [HH.code (foldMap (\l -> [HP.class_ (HH.ClassName ("language-" <> l))]) lang) [HH.text code]]
    , mathInline = \_ _ tex -> HH.span [HP.class_ (HH.ClassName "math inline")] [HH.text tex]
    , mathDisplay = \_ _ tex -> HH.div [HP.class_ (HH.ClassName "math display")] [HH.text tex]
    , mermaid = \_ src -> HH.pre [HP.class_ (HH.ClassName "mermaid")] [HH.text src]
    , tikz = \_ src -> HH.pre [HP.class_ (HH.ClassName "tikz")] [HH.text src]
    , resolveLink = defaultResolveLink
    , pageHref = identity
    , resolveMention = const Nothing
    , headingAnchors = True
    , boxes = []
    }

-- | What a destination is when nothing is known about the wiki: a URL, used
-- as it is (paths and fragments too), except an attachment, which is
-- unresolved.
defaultResolveLink :: Text -> LinkTarget page
defaultResolveLink dest = case classifyDestination dest of
  ToAttachment _ -> Unresolved
  _ -> External dest

-- | The document's blocks as HTML, in order.
renderBlocks :: Options page w i -> [Block] -> [HH.HTML w i]
renderBlocks opts doc = concat (renderSections opts [doc])

-- | A document cut into sections, each section's blocks as HTML of its own,
-- in order: what a page shown as slides ("Wiki.Core.Slides") is rendered
-- with, each slide's title, body and notes a section, so that each can be
-- put where its slide shows it. The sections are one document all the same:
-- an island's key is unique among all of them, a formula is set with the
-- macros defined in the sections before it, and a footnote's references
-- are numbered across them, as they would be if the sections were one
-- page.
renderSections :: forall page w i. Options page w i -> [[Block]] -> [[HH.HTML w i]]
renderSections opts sections = evalState (traverse renderBlocks' sections) (Counts M.empty M.empty [])
  where
    renderBlock :: Block -> R [HH.HTML w i]
    renderBlock = \case
      Para xs -> single . HH.p_ <$> renderInlines xs
      Plain xs -> renderInlines xs
      Heading level attrs xs -> do
        inner <- renderInlines xs
        pure [headingOf level (idAndClasses attrs []) (inner <> (if opts.headingAnchors then headingAnchor attrs else []))]
      ThematicBreak -> pure [HH.hr_]
      -- A pause matters only on a slide ("Wiki.Core.Slides"), which has
      -- taken it out by now. A page shows nothing for it.
      Pause -> pure []
      BlockQuote bs -> single . HH.blockquote_ <$> renderBlocks' bs
      CodeBlock _ lang code -> island code <&> \k -> [opts.codeBlock k lang code]
      Mermaid src -> island src <&> \k -> [opts.mermaid k src]
      Tikz src -> island src <&> \k -> [opts.tikz k src]
      MathBlock tex -> formula tex <&> \(k, ms) -> [opts.mathDisplay k ms tex]
      List kind items -> single . listOf kind (any isTask items) <$> traverse renderItem items
      Table aligns header rows -> single <$> renderTable aligns header rows
      Div attrs bs -> single . HH.div (idAndClasses attrs []) <$> renderBlocks' bs
      Alert kind title bs -> do
        inner <- renderBlocks' bs
        pure [boxOf (definedKind opts.boxes kind) kind title inner]
      -- A slide shows the notes it refers to, which need not start at the
      -- first ("Wiki.Core.Slides").
      Footnotes notes ->
        single . HH.section [classesProp ["footnotes"]] . single . listOf (OrderedList (firstNote notes)) False <$> traverse renderNote notes
      RawHtmlBlock raw -> pure (renderRawHtml opts raw)
      TableOfContents -> pure (contentsNav contents)

    -- The table of contents a @[[toc]]@ shows: of the whole document, every
    -- section of it.
    contents = tableOfContents (concat sections)

    renderBlocks' :: [Block] -> R [HH.HTML w i]
    renderBlocks' bs = concat <$> traverse renderBlock bs

    renderItem :: ListItem -> R (HH.HTML w i)
    renderItem (ListItem task bs) = case task of
      Nothing -> HH.li_ <$> renderBlocks' bs
      Just done -> do
        let checkbox = [PNode (HH.input [HP.type_ I.InputCheckbox, HP.checked done, HP.disabled True]), PText " "]
        inner <- case bs of
          Para xs : rest -> (:) . HH.p_ <$> withPieces checkbox xs [] <*> renderBlocks' rest
          Plain xs : rest -> (<>) <$> withPieces checkbox xs [] <*> renderBlocks' rest
          _ -> (fromPieces checkbox <>) <$> renderBlocks' bs
        pure (HH.li [classesProp ["task-list-item"]] inner)

    renderTable :: [Alignment] -> [[Inline]] -> [[[Inline]]] -> R (HH.HTML w i)
    renderTable aligns header rows = do
      let cell isHeader n xs = do
            let align = fromMaybe AlignDefault (atMay aligns n)
            inner <- renderInlines xs
            pure (if isHeader then HH.th (alignment align) inner else HH.td (alignment align) inner)
          row isHeader cells = HH.tr_ <$> zipWithM (cell isHeader) [0 ..] cells
      thead <- if null header then pure [] else single . HH.thead_ . single <$> row True header
      tbody <- if null rows then pure [] else single . HH.tbody_ <$> traverse (row False) rows
      pure (HH.table_ (thead <> tbody))

    renderNote :: Footnote -> R (HH.HTML w i)
    renderNote (Footnote n _ bs) = do
      let back = [PText " ", PNode (HH.a [HP.href ("#fnref-" <> show n), classesProp ["footnote-back"]] [HH.text "↩"])]
      inner <- case unsnoc bs of
        Just (start, Para xs) -> (<>) <$> renderBlocks' start <*> (single . HH.p_ <$> withPieces [] xs back)
        _ -> (<> fromPieces (drop 1 back)) <$> renderBlocks' bs
      pure (HH.li [HP.id ("fn-" <> show n)] inner)

    renderInlines :: [Inline] -> R [HH.HTML w i]
    renderInlines xs = withPieces [] xs []

    -- Inlines between extra pieces, with adjacent text as one text node.
    withPieces :: [Piece w i] -> [Inline] -> [Piece w i] -> R [HH.HTML w i]
    withPieces before xs after = do
      middle <- inlinePieces False xs
      pure (fromPieces (before <> middle <> after))

    -- Render a sequence of inlines. The flag says whether they are a
    -- link's text; there a nested link is shown as its text, since a link
    -- cannot contain a link. Raw HTML among them is parsed together with
    -- the Markdown around it, so that a tag contains what is written up to
    -- its end tag ("Wiki.Core.Markdown.Html").
    inlinePieces :: Bool -> [Inline] -> R [Piece w i]
    inlinePieces inLink xs
      | any isRawHtml xs = htmlPieces inLink (Html.parseFragments context (map fragment xs))
      | otherwise = concat <$> traverse (renderInline inLink) xs
      where
        context = if inLink then Html.PhrasingInLink else Html.Phrasing
        fragment = \case
          RawHtml raw -> Html.Markup raw
          x -> Html.Markdown x
        isRawHtml = \case
          RawHtml _ -> True
          _ -> False

    htmlPieces :: Bool -> [Html.Node Inline] -> R [Piece w i]
    htmlPieces inLink =
      fmap concat
        . traverse
          ( \case
              Html.Element name attrs children -> do
                inner <- htmlPieces (inLink || name == "a") children
                pure [PNode (htmlElement opts name attrs (fromPieces inner))]
              Html.TextNode t -> pure [PText t]
              Html.Content x -> renderInline inLink x
          )

    renderInline :: Bool -> Inline -> R [Piece w i]
    renderInline inLink = \case
      Str t -> pure [PText t]
      SoftBreak -> pure [PText "\n"]
      LineBreak -> pure [PNode HH.br_, PText "\n"]
      Emph xs -> node HH.em_ . fromPieces <$> inlinePieces inLink xs
      Strong xs -> node HH.strong_ . fromPieces <$> inlinePieces inLink xs
      Strikeout xs -> node HH.del_ . fromPieces <$> inlinePieces inLink xs
      Code attrs code -> pure [PNode (HH.code (idAndClasses attrs []) [HH.text code])]
      Link _ _ _ xs | inLink -> inlinePieces True xs
      Link attrs dest title xs -> renderLink attrs dest title xs
      Image attrs dest title xs -> pure (renderEmbed attrs dest title (plainText xs))
      Math InlineMath tex -> formula tex <&> \(k, ms) -> [PNode (opts.mathInline k ms tex)]
      Math DisplayMath tex -> formula tex <&> \(k, ms) -> [PNode (opts.mathDisplay k ms tex)]
      FootnoteRef n _ -> do
        ident <- footnoteRefId n
        pure [PNode (HH.sup [classesProp ["footnote-ref"]] [HH.a [HP.href ("#fn-" <> show n), HP.id ident] [HH.text (show n)]])]
      Emoji keyword emoji -> pure [PNode (HH.span [classesProp ["emoji"], HP.title (":" <> keyword <> ":")] [HH.text emoji])]
      -- Raw HTML is read with its neighbours, by 'inlinePieces', and does
      -- not get here; on its own it would be read the same way.
      RawHtml raw -> htmlPieces inLink (Html.parseFragments (if inLink then Html.PhrasingInLink else Html.Phrasing) [Html.Markup raw])
      Mention login -> pure $ case opts.resolveMention login of
        Just target
          | not inLink ->
              [PNode (HH.a [HP.href target.href, classesProp ["mention"], HP.title target.name] [HH.text ("@" <> login)])]
        _ -> [PText ("@" <> login)]

    renderLink :: Attributes -> Text -> Text -> [Inline] -> R [Piece w i]
    renderLink attrs dest title xs = do
      pieces <- inlinePieces True xs
      let inner = fromPieces pieces
          anchor props = [PNode (HH.a (props <> titleProp title <> idAndClasses attrs []) inner)]
          -- What a link that may not be followed is shown as: its text.
          asText = pieces
      pure $ case opts.resolveLink dest of
        External url
          | safeHref url -> anchor (HP.href url : [HP.rel "noopener" | isExternal url])
          | otherwise -> asText
        Page page -> anchor [HP.href (opts.pageHref page)]
        Attachment ref
          | safeHref ref.url -> anchor [HP.href ref.url, HP.download ref.name]
          | otherwise -> asText
        Unresolved -> [PNode (HH.span [classesProp ["link-unresolved"], HP.title dest] inner)]

    renderEmbed :: Attributes -> Text -> Text -> Text -> [Piece w i]
    renderEmbed attrs dest title caption = case opts.resolveLink dest of
      External url
        | safeSrc url -> [PNode (media (mediaKindOfPath url) url Nothing)]
        | otherwise -> [PText caption]
      Attachment ref
        | safeSrc ref.url -> [PNode (media (maybe (mediaKindOfPath ref.name) mediaKindOfType ref.mediaType) ref.url (Just ref.name))]
        | otherwise -> [PText caption]
      Page page -> [PNode (HH.a [HP.href (opts.pageHref page)] [HH.text (nonEmptyOr dest caption)])]
      Unresolved -> [PNode (HH.span [classesProp ["embed-unresolved"], HP.title dest] [HH.text (nonEmptyOr dest caption)])]
      where
        common :: (HasType "title" Text r, HasType "id" Text r, HasType "class" Text r) => [HP.IProp r i]
        common = titleProp title <> idAndClasses attrs [] <> sizes
        sizes :: [HP.IProp r i]
        sizes =
          [ HP.attr (HH.AttrName key) v
          | (key, v) <- attrs
          , key `elem` ["width", "height"]
          , not (T.null v)
          , T.all isDigit v
          ]
        label :: [HP.IProp r i]
        label = [HP.attr (HH.AttrName "aria-label") caption | not (T.null caption)]
        media kind url name = case (kind, name) of
          (VideoMedia, _) -> HH.video ([HP.src url, HP.controls True] <> label <> common) []
          (AudioMedia, _) -> HH.audio ([HP.src url, HP.controls True] <> label <> common) []
          (OtherMedia, Just file) -> HH.a ([HP.href url, HP.download file] <> idAndClasses attrs []) [HH.text (nonEmptyOr file caption)]
          _ -> HH.img ([HP.src url, HP.alt caption] <> common)

    island :: Text -> R IslandKey
    island src = state $ \c ->
      let n = M.findWithDefault 0 src c.islands
       in (IslandKey src n, c {islands = M.insert src (n + 1) c.islands})

    -- A formula's key, and the earlier formulas that define macros.
    -- Afterwards the formula is added to those, if it defines any.
    formula :: Text -> R (IslandKey, Macros)
    formula tex = do
      k <- island tex
      state $ \c ->
        ( (k, Macros (reverse c.definitions))
        , if definesMacros tex then c {definitions = tex : c.definitions} else c
        )

    footnoteRefId :: Int -> R Text
    footnoteRefId n = state $ \c ->
      let seen = M.findWithDefault 0 n c.footnoteRefs
          ident = "fnref-" <> show n <> (if seen == 0 then "" else "-" <> show (seen + 1))
       in (ident, c {footnoteRefs = M.insert n (seen + 1) c.footnoteRefs})

-- | The counters rendering keeps as it goes: islands by source (for their
-- keys), references to each footnote (for their ids), and the formulas so
-- far that define macros, the latest first.
data Counts = Counts
  { islands :: Map Text Int
  , footnoteRefs :: Map Int Int
  , definitions :: [Text]
  }

type R = State Counts

-- | A piece of inline content: text, which is merged with the text next to
-- it into one node (two text nodes in a row would be written with an
-- @\<!---->@ between them), or an element.
data Piece w i = PText Text | PNode (HH.HTML w i)

fromPieces :: [Piece w i] -> [HH.HTML w i]
fromPieces = \case
  [] -> []
  PText a : PText b : rest -> fromPieces (PText (a <> b) : rest)
  PText a : rest
    | T.null a -> fromPieces rest
    | otherwise -> HH.text a : fromPieces rest
  PNode h : rest -> h : fromPieces rest

node :: ([HH.HTML w i] -> HH.HTML w i) -> [HH.HTML w i] -> [Piece w i]
node make inner = [PNode (make inner)]

single :: a -> [a]
single = pure

nonEmptyOr :: Text -> Text -> Text
nonEmptyOr fallback t = if T.null t then fallback else t

firstNote :: [Footnote] -> Int
firstNote = \case
  Footnote n _ _ : _ -> n
  [] -> 1

-- | The link to a heading that its heading ends with, shown on hover (see
-- @web/style.css@): an empty @\<a class="heading-anchor">@ whose @#@ the
-- stylesheet draws, so that the page's text (what a comment quotes,
-- "Wiki.Core.Anchor", and what a search finds) has no @#@ after every
-- heading. Following it puts the heading's address in the address bar.
headingAnchor :: Attributes -> [HH.HTML w i]
headingAnchor attrs =
  [ HH.a [HP.href ("#" <> ident), classesProp ["heading-anchor"], HP.attr (HH.AttrName "aria-label") "Link to this section"] []
  | Just ident <- [attribute "id" attrs]
  , not (T.null ident)
  ]

isTask :: ListItem -> Bool
isTask (ListItem task _) = isJust task

headingOf :: Int -> [HP.IProp I.HTMLh1 i] -> [HH.HTML w i] -> HH.HTML w i
headingOf level = case level of
  1 -> HH.h1
  2 -> HH.h2
  3 -> HH.h3
  4 -> HH.h4
  5 -> HH.h5
  _ -> HH.h6

listOf :: ListKind -> Bool -> [HH.HTML w i] -> HH.HTML w i
listOf kind tasks = case kind of
  BulletList -> HH.ul cls
  OrderedList start -> HH.ol (cls <> [HP.prop (HH.PropName "start") start | start /= 1])
  where
    cls :: (HasType "class" Text r) => [HP.IProp r i]
    cls = [classesProp ["task-list"] | tasks]

alignment :: (HasType "style" Text r) => Alignment -> [HP.IProp r i]
alignment = \case
  AlignDefault -> []
  AlignLeft -> [HP.styleText "text-align: left"]
  AlignCenter -> [HP.styleText "text-align: center"]
  AlignRight -> [HP.styleText "text-align: right"]

classesProp :: (HasType "class" Text r) => [Text] -> HP.IProp r i
classesProp = HP.class_ . HH.ClassName . T.unwords

-- | A box, @> [!KIND]@: its kind's definition among the administrator's
-- ('definedKind'), its kind, the title written after its marker if there
-- is one, and what it holds. The administration's preview of a kind is
-- drawn by this too ("Wiki.App.View.Server").
boxOf :: Maybe BoxKind -> AlertKind -> Maybe Text -> [HH.HTML w i] -> HH.HTML w i
boxOf defined kind title inner =
  HH.div
    (classesProp ["alert", "alert-" <> alertKindName kind] : [HP.styleText (boxStyle k) | Just k <- [defined]])
    (HH.p [classesProp ["alert-title"]] (icon <> [HH.text (fromMaybe (boxLabel defined kind) title)]) : inner)
  where
    icon = [HH.span [classesProp ["alert-icon"], HP.attr (HH.AttrName "aria-hidden") "true"] [] | Just k <- [defined], k.icon /= NoIcon]

-- | The @id@ and the classes of some attributes, after classes of the
-- element's own.
idAndClasses :: (HasType "id" Text r, HasType "class" Text r) => Attributes -> [Text] -> [HP.IProp r i]
idAndClasses attrs own =
  [HP.id ident | Just ident <- [attribute "id" attrs], not (T.null ident)]
    <> [classesProp cls | let cls = own <> classes attrs, not (null cls)]

titleProp :: (HasType "title" Text r) => Text -> [HP.IProp r i]
titleProp title = [HP.title title | not (T.null title)]

-- | Render a raw block of HTML: the parts the allowlist keeps
-- ("Wiki.Core.Markdown.Html"), with links and sources resolved through
-- the options, as the Markdown's are. An HTML comment renders as nothing.
renderRawHtml :: forall page w i. Options page w i -> Text -> [HH.HTML w i]
renderRawHtml opts raw = fromPieces (concatMap pieces (Html.parseHtml raw))
  where
    pieces :: Html.Node Void -> [Piece w i]
    pieces = \case
      Html.Element name attrs children -> [PNode (htmlElement opts name attrs (fromPieces (concatMap pieces children)))]
      Html.TextNode t -> [PText t]

-- | Render an element the allowlist kept, with its attributes. A URL is
-- resolved as a Markdown link's or embed's is ('resolveLink'), except that
-- a relative address may also name an attachment. A source is looked up as
-- an attachment first, since a page cannot be shown in an @img@. A link is
-- looked up as an attachment only if it names no page. The resolved URL is
-- written only if its scheme is harmless; otherwise the attribute is
-- dropped, and an @a@ that leads nowhere gets the class
-- @link-unresolved@, as a Markdown link would show it. A link to an
-- attachment downloads it, and one that leaves the wiki gets
-- @rel=\"noopener\"@, as in Markdown.
htmlElement :: forall page w i. Options page w i -> Text -> [Html.Attribute] -> [HH.HTML w i] -> HH.HTML w i
htmlElement opts name attrs = HH.element (HH.ElemName name) (concatMap prop attrs <> unresolvedClass)
  where
    -- The element is made by name, so its properties are typed by no
    -- element's row.
    href :: Maybe [HP.IProp Empty i]
    href = linkProps <$> attribute "href" attrs
    broken = maybe False null href
    unresolvedClass = [attr "class" "link-unresolved" | broken, isNothing (attribute "class" attrs)]
    prop (key, value) = case key of
      "href" -> fromMaybe [] href
      "src" -> sourceProp key value
      "poster" -> sourceProp key value
      "class" | broken -> [attr key (value <> " link-unresolved")]
      _ -> [attr key value]
    linkProps dest = case relativeFirst False dest of
      External url
        | safeHref url -> attr "href" url : [attr "rel" "noopener" | isExternal url]
      Page page -> [attr "href" (opts.pageHref page)]
      Attachment ref
        | safeHref ref.url -> [attr "href" ref.url, attr "download" ref.name]
      _ -> []
    sourceProp key dest = case relativeFirst True dest of
      External url | safeSrc url -> [attr key url]
      Attachment ref | safeSrc ref.url -> [attr key ref.url]
      _ -> []
    -- Resolve a path as an attachment's name, and through 'resolveLink':
    -- the attachment first for a source, 'resolveLink' first for a link.
    relativeFirst asAttachment dest = case classifyDestination dest of
      ToPath path
        | asAttachment -> unlessResolved (opts.resolveLink ("attachment:" <> path)) (opts.resolveLink dest)
        | otherwise -> unlessResolved (opts.resolveLink dest) (opts.resolveLink ("attachment:" <> path))
      _ -> opts.resolveLink dest
    unlessResolved target fallback = case target of
      Unresolved -> fallback
      found -> found
    attr :: Text -> Text -> HP.IProp Empty i
    attr key = HP.attr (HH.AttrName key)
