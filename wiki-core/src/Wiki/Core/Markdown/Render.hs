-- | A page's Markdown tree ("Wiki.Core.Markdown.Ast") as Halogen HTML.
--
-- The HTML is built element by element, never from an HTML string: the
-- author's text is always text, and raw HTML in the source is shown as text
-- too (HTML comments are dropped). Links and embeds are resolved through the
-- 'Options' the caller passes, and only a URL whose scheme is harmless is
-- written ("Wiki.Core.Markdown.Link"); an external link gets
-- @rel=\"noopener\"@.
--
-- __Islands.__ Code, math and Mermaid diagrams are drawn by JavaScript
-- libraries into elements Halogen does not look inside. The renderer leaves
-- them to 'Options' callbacks, which by default write the source as text in
-- the elements those libraries look for: @\<pre>\<code class=\"language-x\">@,
-- @\<span class=\"math inline\">@, @\<div class=\"math display\">@ and
-- @\<pre class=\"mermaid\">@. A caller that renders them as child
-- components gets an 'IslandKey' with each, unique in the document, to use as
-- the slot's index: Halogen tells two children apart by their slot address,
-- and a document can hold the same formula twice.
--
-- __Embeds.__ @![caption](destination)@ shows what the destination resolves
-- to by its media type: an attachment by the type the wiki knows for it, or
-- failing that its name's extension; a URL by its extension. Images become
-- @\<img>@, videos @\<video controls>@, audio @\<audio controls>@, and an
-- attachment of any other type a download link. A URL of an unknown type is
-- an image, as in plain Markdown. An embedded page is a link to it.
--
-- __Layout.__ Headings carry their @id@. Task list items start with a
-- disabled checkbox. Footnote references are @\<sup class=\"footnote-ref\">@
-- links to @#fn-N@, and the notes are a @\<section class=\"footnotes\">@ at
-- the end, each ending with a link back to its first reference. Table cells
-- are aligned with a @text-align@ style. Alerts are
-- @\<div class=\"alert alert-note\">@ with a @\<p class=\"alert-title\">@.
-- Only @id@ and @class@ attributes from braces reach the HTML (and @width@
-- and @height@ in pixels on an embed): any other could be an event handler.
module Wiki.Core.Markdown.Render
  ( Options (..)
  , IslandKey (..)
  , defaultOptions
  , defaultResolveLink
  , renderBlocks
  )
where

import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as M
import Data.Row (HasType)
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Link

-- | What the renderer leaves to its caller.
--
-- @w@ and @i@ are those of the 'HH.HTML' it makes, so a caller that renders
-- islands as child components instantiates them with its component's slots
-- and actions (@HH.ComponentHTML action slots m@ is
-- @HH.HTML (ComponentSlot slots m action) action@). @page@ is the wiki's name
-- for a page, which 'resolveLink' finds and 'pageHref' makes a link to.
data Options page w i = Options
  { codeBlock :: IslandKey -> Maybe Text -> Text -> HH.HTML w i
  -- ^ A code block: its language, if it has one, and its code.
  , mathInline :: IslandKey -> Text -> HH.HTML w i
  -- ^ Inline math, @$…$@: its TeX.
  , mathDisplay :: IslandKey -> Text -> HH.HTML w i
  -- ^ Display math, @$$…$$@ or a @math@ fence: its TeX. Rendered as a block
  -- except in a heading or a table cell.
  , mermaid :: IslandKey -> Text -> HH.HTML w i
  -- ^ A Mermaid diagram: its source.
  , resolveLink :: Text -> LinkTarget page
  -- ^ What a link's or an embed's destination, as written, points at.
  , pageHref :: page -> Text
  -- ^ The @href@ of a link to a page.
  }

-- | Which island this is: its source, and how many islands with the same
-- source, of any kind, come before it in the document. No two islands of a document have
-- the same key, and an island keeps its key when the document changes
-- anywhere but in an island with the same source before it, so a child
-- component in a slot indexed by it survives edits elsewhere.
data IslandKey = IslandKey
  { source :: Text
  , occurrence :: Int
  }
  deriving stock (Eq, Ord, Show)

-- | Islands as the libraries that fill them expect their elements, filled
-- with the source as text, so that the page reads without them; links as
-- written ('defaultResolveLink'). @page@ is 'Text' only to have a type:
-- nothing resolves to a page until a caller's 'resolveLink' does, and a
-- record update that sets both 'resolveLink' and 'pageHref' picks the
-- caller's own type.
defaultOptions :: Options Text w i
defaultOptions =
  Options
    { codeBlock = \_ lang code ->
        HH.pre_ [HH.code (foldMap (\l -> [HP.class_ (HH.ClassName ("language-" <> l))]) lang) [HH.text code]]
    , mathInline = \_ tex -> HH.span [HP.class_ (HH.ClassName "math inline")] [HH.text tex]
    , mathDisplay = \_ tex -> HH.div [HP.class_ (HH.ClassName "math display")] [HH.text tex]
    , mermaid = \_ src -> HH.pre [HP.class_ (HH.ClassName "mermaid")] [HH.text src]
    , resolveLink = defaultResolveLink
    , pageHref = identity
    }

-- | What a destination is when nothing is known about the wiki: a URL, used
-- as it is (paths and fragments too), except an attachment, which is
-- unresolved.
defaultResolveLink :: Text -> LinkTarget page
defaultResolveLink dest = case classifyDestination dest of
  ToAttachment _ -> Unresolved
  _ -> External dest

-- | The document's blocks as HTML, in order.
renderBlocks :: forall page w i. Options page w i -> [Block] -> [HH.HTML w i]
renderBlocks opts doc = evalState (concat <$> traverse renderBlock doc) (Counts M.empty M.empty)
  where
    renderBlock :: Block -> R [HH.HTML w i]
    renderBlock = \case
      Para xs -> single . HH.p_ <$> renderInlines xs
      Plain xs -> renderInlines xs
      Heading level attrs xs -> single . headingOf level (idAndClasses attrs []) <$> renderInlines xs
      ThematicBreak -> pure [HH.hr_]
      BlockQuote bs -> single . HH.blockquote_ <$> renderBlocks' bs
      CodeBlock _ lang code -> island code <&> \k -> [opts.codeBlock k lang code]
      Mermaid src -> island src <&> \k -> [opts.mermaid k src]
      MathBlock tex -> island tex <&> \k -> [opts.mathDisplay k tex]
      List kind items -> single . listOf kind (any isTask items) <$> traverse renderItem items
      Table aligns header rows -> single <$> renderTable aligns header rows
      Div attrs bs -> single . HH.div (idAndClasses attrs []) <$> renderBlocks' bs
      Alert kind bs -> do
        inner <- renderBlocks' bs
        let (cls, title) = alertName kind
        pure [HH.div [classesProp ["alert", "alert-" <> cls]] (HH.p [classesProp ["alert-title"]] [HH.text title] : inner)]
      Footnotes notes -> single . HH.section [classesProp ["footnotes"]] . single . HH.ol_ <$> traverse renderNote notes
      RawHtmlBlock raw
        | isComment raw -> pure []
        | otherwise -> pure [HH.pre [classesProp ["raw-html"]] [HH.text raw]]

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
      middle <- concat <$> traverse renderInline xs
      pure (fromPieces (before <> middle <> after))

    renderInline :: Inline -> R [Piece w i]
    renderInline = \case
      Str t -> pure [PText t]
      SoftBreak -> pure [PText "\n"]
      LineBreak -> pure [PNode HH.br_, PText "\n"]
      Emph xs -> node HH.em_ <$> renderInlines xs
      Strong xs -> node HH.strong_ <$> renderInlines xs
      Strikeout xs -> node HH.del_ <$> renderInlines xs
      Code attrs code -> pure [PNode (HH.code (idAndClasses attrs []) [HH.text code])]
      Link attrs dest title xs -> renderLink attrs dest title xs
      Image attrs dest title xs -> pure (renderEmbed attrs dest title (plainText xs))
      Math InlineMath tex -> island tex <&> \k -> [PNode (opts.mathInline k tex)]
      Math DisplayMath tex -> island tex <&> \k -> [PNode (opts.mathDisplay k tex)]
      FootnoteRef n _ -> do
        ident <- footnoteRefId n
        pure [PNode (HH.sup [classesProp ["footnote-ref"]] [HH.a [HP.href ("#fn-" <> show n), HP.id ident] [HH.text (show n)]])]
      Emoji keyword emoji -> pure [PNode (HH.span [classesProp ["emoji"], HP.title (":" <> keyword <> ":")] [HH.text emoji])]
      RawHtml raw
        | isComment raw -> pure []
        | otherwise -> pure [PText raw]

    renderLink :: Attributes -> Text -> Text -> [Inline] -> R [Piece w i]
    renderLink attrs dest title xs = do
      pieces <- concat <$> traverse renderInline xs
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

    footnoteRefId :: Int -> R Text
    footnoteRefId n = state $ \c ->
      let seen = M.findWithDefault 0 n c.footnoteRefs
          ident = "fnref-" <> show n <> (if seen == 0 then "" else "-" <> show (seen + 1))
       in (ident, c {footnoteRefs = M.insert n (seen + 1) c.footnoteRefs})

-- | What rendering keeps count of as it goes: islands by source, for their
-- keys, and references to each footnote, for their ids.
data Counts = Counts
  { islands :: Map Text Int
  , footnoteRefs :: Map Int Int
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

isTask :: ListItem -> Bool
isTask (ListItem task _) = isJust task

isComment :: Text -> Bool
isComment = T.isPrefixOf "<!--" . T.stripStart

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

alertName :: AlertKind -> (Text, Text)
alertName = \case
  Note -> ("note", "Note")
  Tip -> ("tip", "Tip")
  Important -> ("important", "Important")
  Warning -> ("warning", "Warning")
  Caution -> ("caution", "Caution")

classesProp :: (HasType "class" Text r) => [Text] -> HP.IProp r i
classesProp = HP.class_ . HH.ClassName . T.unwords

-- | The @id@ and the classes of some attributes, after classes of the
-- element's own.
idAndClasses :: (HasType "id" Text r, HasType "class" Text r) => Attributes -> [Text] -> [HP.IProp r i]
idAndClasses attrs own =
  [HP.id ident | Just ident <- [attribute "id" attrs], not (T.null ident)]
    <> [classesProp cls | let cls = own <> classes attrs, not (null cls)]

titleProp :: (HasType "title" Text r) => Text -> [HP.IProp r i]
titleProp title = [HP.title title | not (T.null title)]
