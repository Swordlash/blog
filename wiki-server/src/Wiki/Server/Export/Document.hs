-- | A page, or a space's pages, as a pandoc document (WP4.16 of
-- docs/PLAN.md): what "Wiki.Server.Export" hands pandoc's writers. Pure,
-- so that what a page becomes is tested without writing a file.
--
-- = Reading
--
-- The input is the page's own Markdown, read by pandoc's Markdown reader
-- with the extensions that match the syntax the wiki reads
-- ("Wiki.Core.Markdown.Ast", 'wikiExtensions'): pipe tables, footnotes,
-- fenced divs, @$…$@ and @\\(…\\)@ math, GitHub's task lists,
-- strikethrough, bare links, emoji, alerts and wiki links, attributes in
-- braces. Raw HTML is read raw, and goes through the wiki's allowlist
-- ("Wiki.Core.Markdown.Html") before pandoc sees it: a raw block is cut
-- down to what the allowlist keeps, written out again and read by pandoc's
-- HTML reader; tags among the text are read with the text between them,
-- as the page's renderer reads them, and made into pandoc's inlines. Raw
-- TeX is not read: a page is not a LaTeX document, and nothing an author
-- writes reaches the TeX engine but the math and TikZ the page shows too.
--
-- = What the wiki adds
--
-- * __Math macros__ ("Wiki.Core.Math"): pandoc's writers set each formula
--   alone, so the macros it is set with in the wiki (its space's, and those
--   the formulas before it on the page define) are expanded into it here,
--   with texmath's own macro reader; a formula that only defines macros
--   goes. Only @\\newcommand@, @\\renewcommand@ and
--   @\\DeclareMathOperator@ are read, which is what a space's block and
--   nearly every page use.
-- * __Islands__: a @math@ fence is display math. A Mermaid diagram needs a
--   browser to be drawn, which the server has not got, so it is a note with
--   its source. A TikZ picture is LaTeX already: in a document LaTeX makes
--   (a PDF, a Beamer deck) it is put in as it is, with the packages it
--   loads in the preamble; elsewhere it is a note with its source.
-- * __Links and embeds__ ("Wiki.Core.Markdown.Link"): an attachment's image
--   is put into the document (its bytes, from the blob store, go into
--   pandoc's media bag under 'mediaPath'); an attachment that is not an
--   image, and a page of the wiki, are links to their addresses under the
--   wiki's public address, or plain text where it has none. In a space's
--   document a link to one of its pages goes to that page's section. An
--   image on the web is a link to it: the server fetches nothing while it
--   writes a document.
-- * __Slides__ ("Wiki.Core.Slides"): a deck is cut where the wiki cuts it,
--   at the top level's thematic breaks, and each slide is titled with its
--   first heading, as pandoc's slide writers want it: a level-one heading
--   becomes a section's title slide, any other a slide's title (a level-two
--   heading at pandoc's slide level 2), and a slide with none gets an
--   untitled one; the other headings on a slide are kept below the slide
--   level. The @notes@ divs are what pandoc writes as the speaker's notes
--   (@\\note{}@ in Beamer).
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
  , mediaPath
  , tikzPreamble
  , slideBlocks
  , htmlBlocks
  , htmlInlines
  , writeHtmlNodes
  )
where

import Data.List (lookup)
import Data.Map.Strict qualified as Map
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
import Wiki.Core.Attachment (Attachment (..), MediaKind (..), attachmentKind, findAttachment)
import Wiki.Core.Id (AttachmentId (..))
import Wiki.Core.Markdown.Html qualified as Html
import Wiki.Core.Markdown.Link (Destination (..), classifyDestination)
import Wiki.Core.Markdown.Tikz (TikzDocument (..), tikzDocument)
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Page (Page (title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))

-- | Where a page is, which its links and embeds are resolved against.
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
  -- shows, relative to the wiki's.
  , publicUrl :: Maybe Text
  -- ^ The wiki's public address, which a link out of the document starts
  -- with; without one, such a link is its text.
  , inDocument :: [Slug] -> [Slug] -> Maybe Text
  -- ^ The identifier of a page's section in this document, by its space's
  -- path and its own, if the document holds it: a space's does.
  , idPrefix :: Text
  -- ^ What this page's identifiers start with, so that two pages of one
  -- document cannot have one.
  , macros :: Macros
  -- ^ The math macros of the page's space and its ancestors.
  }

-- | What a document is written as, as far as reading a page cares.
data Output
  = -- | Something LaTeX makes (a PDF, a Beamer deck): a TikZ picture can be
    -- put in as it is.
    ToTeX
  | -- | Anything else.
    ToOther
  deriving stock (Eq, Show)

-- | The extensions of pandoc's Markdown reader that read what the wiki's
-- own reader reads ("Wiki.Core.Markdown.Ast"), and no others: in
-- particular no raw TeX, no Markdown inside HTML, and no divs or spans
-- made of HTML, so that every piece of HTML stays raw for the allowlist.
wikiExtensions :: Extensions
wikiExtensions =
  extensionsFromList
    [ Ext_all_symbols_escapable
    , Ext_alerts
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
-- so that two pages' attachments of one name are two files, with its name
-- last, whose extension pandoc reads a type from where it needs one.
mediaPath :: Attachment -> FilePath
mediaPath a = toS ("attachments/" <> a.id.text <> "/" <> T.map safe a.name)
  where
    safe c = if c == '/' || c == '\\' then '_' else c

-- | A page's Markdown as blocks, with everything the wiki adds done.
pageBlocks :: Output -> Place -> Text -> Either PandocError [P.Block]
pageBlocks output place source = do
  P.Pandoc _ read' <- runPure (readMarkdown def {readerExtensions = wikiExtensions} source)
  pure
    . expandMacros place.macros
    . walk (resolveInlines place)
    . walk (concatMap (islands output))
    . prefixIds place.idPrefix
    . walk (concatMap dropOptions)
    . walk htmlInlines
    . walk (concatMap htmlBlock)
    $ read'

-- | A page, as a document of its own, titled as the page shows it
-- ('titled').
pageDocument :: Text -> [P.Block] -> P.Pandoc
pageDocument title blocks = P.Pandoc (P.Meta (Map.fromList [("title", P.MetaInlines heading)])) body
  where
    (heading, body) = titled title blocks

-- | A page's title and the rest of it, as the page shows them
-- ("Wiki.App.View.Body"): a page whose Markdown starts with a level-one
-- heading is titled with it, and another with its title.
titled :: Text -> [P.Block] -> ([P.Inline], [P.Block])
titled title = \case
  P.Header 1 _ xs : rest -> (xs, rest)
  bs -> (B.toList (B.text title), bs)

-- | A deck, as a document pandoc's slide writers write: its title, the
-- metadata given (the theme's and the aspect's), and its slides. A deck
-- that starts with a title slide (a level-one heading) is titled with it,
-- since pandoc makes the title slide of the title; another is titled as
-- its page is.
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
  -- ^ How deep it is in the space's tree, its top level 0.
  , anchor :: Text
  -- ^ Its section's identifier.
  , blocks :: [P.Block]
  -- ^ Its content ('pageBlocks').
  }

-- | A space's pages as one document, in the order given (the space's): each
-- page a section under its title ('titled'), as deep as the page is in the
-- tree, its own headings below that. The title page and the table of contents are
-- the writer's ("Wiki.Server.Export"), from the metadata.
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

-- | Every heading so many levels further down, as far as level 6.
shiftHeadings :: Int -> [P.Block] -> [P.Block]
shiftHeadings by = walk $ \case
  P.Header l attr xs -> P.Header (min 6 (l + by)) attr xs
  b -> b

----------------------------------------------------------------------
-- Raw HTML, through the allowlist

-- | A raw block of HTML as what the allowlist keeps of it, read by
-- pandoc's HTML reader.
htmlBlock :: P.Block -> [P.Block]
htmlBlock = \case
  P.RawBlock f raw | isHtml f -> htmlBlocks raw
  b -> [b]

-- | Raw HTML, cut down to what the allowlist keeps, as pandoc's blocks.
htmlBlocks :: Text -> [P.Block]
htmlBlocks raw = case Html.parseHtml raw of
  [] -> []
  nodes -> either (const [P.Para (B.toList (B.text (Html.htmlText nodes)))]) (\(P.Pandoc _ bs) -> bs) (runPure (readHtml def (writeHtmlNodes nodes)))

-- | Inlines with tags among them read as the page's renderer reads them,
-- with the text between them: what the allowlist keeps of the tags, as
-- pandoc's inlines, holding the text.
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

-- | What the allowlist kept, written as HTML again: its text and its
-- attributes' values escaped, so that what pandoc reads is the tree.
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

-- | The @slides@ div says how a deck looks and shows nothing.
dropOptions :: P.Block -> [P.Block]
dropOptions = \case
  P.Div (_, cls, _) _ | "slides" `elem` cls -> []
  b -> [b]

-- | Every identifier of the page, and every link to one, prefixed, so that
-- the pages of one document do not share one.
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

-- | The islands as a document shows them.
islands :: Output -> P.Block -> [P.Block]
islands output = \case
  P.CodeBlock (_, cls, _) code
    | "math" `elem` cls -> [P.Para [P.Math P.DisplayMath code]]
    | "mermaid" `elem` cls -> islandNote "A Mermaid diagram is drawn here in the wiki; a document cannot draw it. Its source:" code
    | "tikz" `elem` cls -> case output of
        -- A picture LaTeX draws, put in as it is, centred, in a div that
        -- carries what it loads for the preamble ('tikzPreamble').
        ToTeX ->
          let picture = tikzDocument code
           in [P.Div ("", ["tikz"], [("preamble", picture.preamble)]) [P.RawBlock (P.Format "latex") ("\\begin{center}\n" <> picture.picture <> "\n\\end{center}")]]
        ToOther -> islandNote "A TikZ picture is drawn here in the wiki, and in a PDF; this document cannot draw it. Its source:" code
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
  | -- | Its caption, which is all that is left of something the document
    -- can neither hold nor link to.
    Unlinked

embedOf :: Place -> Text -> Embed
embedOf place dest = case classifyDestination dest of
  ToAttachment name -> attachment name
  -- A path names an attachment first, as a source in raw HTML does, then a
  -- page.
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
  -- Prefixed already, with the identifiers ('prefixIds').
  ToAnchor fragment -> Just ("#" <> fragment)
  ToAttachment name -> absolute place . place.attachmentAddress =<< findAttachment name place.attachments
  ToPath _ -> do
    PageLink r fragment <- resolvePageLink place.spaces place.spacePath place.pages place.pagePath dest
    case r of
      Page s p | Just anchor <- place.inDocument s p -> Just ("#" <> anchor)
      _ -> absolute place (Duplex.print route r <> fragment)

-- | An address of the wiki's, under its public address.
absolute :: Place -> Text -> Maybe Text
absolute place path = place.publicUrl <&> \base -> T.dropWhileEnd (== '/') base <> "/" <> T.dropWhile (== '/') path

-- | Each formula with the macros it is set with in the wiki expanded in
-- it: the space's, then those of the formulas before it, the nearest
-- winning. A formula that does nothing but define macros goes.
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
-- cut at the top level's thematic breaks as "Wiki.Core.Slides" cuts it,
-- each slide's first heading its title (a level-one heading a section's
-- title slide, anything else a level-two heading), an untitled slide given
-- an empty one, and the other headings below the slide level.
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

-- | What the preamble needs for the TikZ pictures among some blocks:
-- TikZ itself and what each picture loads, once each; nothing when there
-- is no picture.
tikzPreamble :: [P.Block] -> [Text]
tikzPreamble bs = case query pictures bs of
  [] -> []
  loaded -> ordNub ("\\usepackage{tikz}" : filter (not . T.null) loaded)
  where
    pictures = \case
      P.Div (_, cls, kv) _ | "tikz" `elem` cls -> [fromMaybe "" (lookup "preamble" kv)]
      _ -> []
