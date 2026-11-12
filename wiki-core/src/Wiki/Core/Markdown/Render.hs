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
-- __HTML blocks.__ An @html@ fence is an island too ('htmlBlock'): the
-- application shows it in a frame of its own ("Wiki.Core.Markdown.Frame"),
-- whose document the renderer makes from the block. Its HTML goes through
-- the allowlist widened by styles ("Wiki.Core.Markdown.Html.FrameHtml"),
-- its links and sources are resolved as raw HTML's are in the page
-- ('resolvedAttributes'), and a link opens in a new tab, with
-- @target=\"_blank\"@ and @rel=\"noopener noreferrer\"@, since a frame
-- cannot show another document. A link to a place in the page (@#intro@)
-- leads nowhere from the frame, and keeps its text without its @href@. By
-- default the block's source is written as an HTML listing, as a feed
-- shows it, since a feed reader has no sandbox to show a frame in.
--
-- __Macros.__ Each formula receives the earlier formulas in the document
-- that define macros ("Wiki.Core.Math"), in order. So a page's macro
-- definitions apply to every formula after them, as in a LaTeX document,
-- and how a formula is typeset depends on the page alone, not on the
-- order in which the islands are drawn. A display formula that does
-- nothing but define macros shows nothing.
--
-- __Embeds.__ @![caption](destination)@ shows what the destination resolves
-- to, according to its media type: for an attachment, the type the wiki
-- has for it, or else its name's extension; for a URL, its extension.
-- Images become @\<img>@, videos @\<video controls>@, audio
-- @\<audio controls>@, and an attachment of any other type a download
-- link. A URL of an unknown type is an image, as in plain Markdown. An
-- embedded page is a link to it.
--
-- An SVG attachment with the class @interactive@
-- (@![flame](attachment:flame.svg){.interactive}@) is shown in a frame
-- that runs its scripts, cut off from the wiki ("Wiki.Core.Markdown.Frame"
-- says how), when the attachment has an interactive form
-- ('Wiki.Core.Markdown.Link.frameUrl') and the caller draws frames
-- ('svgFrame'): a @\<span class=\"svg-frame\">@ that holds the frame,
-- an island, and after it an empty
-- @\<a class=\"svg-frame-download\" download>@ to the attachment's plain
-- form, which downloads the file, whose label ("Download flame.svg") the
-- stylesheet draws from its @download@ attribute, as a code block's copy
-- button's, so that the page's text gains no words.
-- Otherwise it is the image, as without the class; so is an interactive
-- embed in a link's text, where a frame and its link cannot go.
--
-- An embedded page with the class @presentation@
-- (@![Talk](/s/docs/p/talk/){.presentation}@) is what the caller draws
-- for it ('deckEmbed'), an island: the application's page draws a viewer
-- of the presentation (WP5.97 of docs/PLAN.md), which starts as the link
-- and stays it for a document or a page the reader may not read. With no
-- 'deckEmbed' (a feed, an export, the slides, a viewer itself), in a
-- link's text, or for anything but a page, it is what it is without the
-- class.
--
-- __Layout.__ Headings carry their @id@, and end with an empty link to
-- it, @\<a class=\"heading-anchor\">@, which the stylesheet shows as a @#@
-- on hover. @[[!toc]]@ is the document's table of contents
-- ("Wiki.Core.Markdown.Toc"), a @\<nav class=\"toc\">@. Footnote references are @\<sup class=\"footnote-ref\">@
-- links to @#fn-N@, titled with the note's text, which the browser shows
-- as a tooltip when the pointer rests on the number ('noteText'). The notes
-- are a @\<section class=\"footnotes\">@ at the end, each ending with a
-- link back to its first reference. Table cells
-- are aligned with a @text-align@ style. A box, @> [!KIND]@, is
-- @\<div class=\"alert alert-note\">@ (its kind's name after @alert-@),
-- with its @id@ if it has one ("Wiki.Core.Markdown.Ast"),
-- with a @\<p class=\"alert-title\">@ that holds its title: its kind's
-- label and its number ('numbering'; @Tip 3@), then the title written
-- after the marker, if there is one, with its math (@Tip 3: Title@), then
-- a heading's empty link to the box's @id@. A box
-- without a number shows the title written after the marker, or else its
-- kind's label ("Wiki.Core.Markdown.Box"). A box of a kind the administrator defined
-- ('boxes') carries the kind's colour and icon as CSS custom properties in
-- its @style@, and its title starts with an empty
-- @\<span class=\"alert-icon\">@ when the kind has an icon, which the
-- stylesheet draws.
-- Only @id@ and @class@ attributes from braces reach the HTML (and @width@
-- and @height@ in pixels on an embed): any other could be an event handler.
-- A fence's @rows=N@ is read by the renderer instead ('codeRows'): the
-- code block gets the class @code-scroll@ and a @style@ of
-- @max-height: Nlh; overflow: auto@, so it shows N lines of code and
-- scrolls inside. The @lh@ unit is the block's own line height, and an
-- inline style works in a page prerendered on the server before any
-- script runs; the stylesheet's @code-scroll@ makes the box's lines and
-- its @lh@ the same height (web/style.css). A fence with the class
-- @numbered@ ('codeNumbered') shows a number before each line: its
-- @\<pre>@ gets the class @numbered@ and starts with a gutter, a
-- @\<span class=\"code-lines\" aria-hidden=\"true\">@ that holds an empty
-- @\<span>@ for each line ('lineNumbers'), whose numbers the stylesheet
-- draws with a counter. The gutter has no text, so the code's text, what
-- a reader selects and what the copy button copies are the code alone.
--
-- __Copy buttons.__ With 'copyButtons' on, a code block is a
-- @\<div class=\"code-block\">@ that holds what 'codeBlock' made and,
-- after it, an empty @\<button class=\"code-copy\">@ with an
-- @aria-label@ ('copyButton'). The islands' script copies the text of the
-- block's @\<code>@ when the button is clicked (web/src/islands.js), and
-- the stylesheet draws the button's label, so that the page's text (what
-- a comment quotes, "Wiki.Core.Anchor", and what the reader selects) has
-- no "Copy" after every listing. The button is beside the @\<pre>@, not in
-- it: the island's library replaces what the @\<pre>@ holds, and a
-- listing that scrolls inside its @\<pre>@ keeps the button in place.
--
-- __Spoilers.__ An inline spoiler, @||text||@, is a
-- @\<span class=\"spoiler\" tabindex=\"0\" role=\"button\">@ whose text
-- the stylesheet blurs until the islands' script gives it the class
-- @shown@, on a click or on Enter or Space (web/src/islands.js). A block
-- spoiler is @\<details class=\"spoiler\" data-spoiler=\"name\">@, closed,
-- its @\<summary>@ the description; the islands' script opens again the
-- ones a reader left open, by their name and page. A spoiler the parser
-- found wrong ('SpoilerProblem'), and a marker line of any of the wiki's
-- blocks that the parser cannot read ('MarkerError'), show a
-- @\<p class=\"spoiler-error\">@ with the line as written and the reason;
-- the wrong spoiler's blocks follow, as they are, in a
-- @\<div class=\"spoiler-unclosed\">@, which the stylesheet draws in red.
-- The parser puts the blocks of any other unclosed block in such a div
-- itself. So the editor's preview shows the mistake as it is typed. A
-- heading spoiler (@## [[!spoiler]] Question@) is
-- @\<details class=\"spoiler spoiler-section\" data-spoiler=\"name\">@
-- whose @\<summary>@ holds the heading itself, rendered as any heading
-- is (its @id@, its link to itself), and whose other blocks are the
-- heading's section; its name is the one written, or else the heading's
-- @id@. With 'hiddenSections' off (a feed) it is the heading and its
-- section as they are.
--
-- __Line breaks.__ A line break in the source is a line break on the page,
-- a @\<br>@, wherever text is: in paragraphs, list items, quotations,
-- boxes and footnotes (the owner, issue #120: a line broken on purpose is
-- meant). Markdown would join the lines into one (a soft break) and break
-- only after two spaces or a backslash; here both kinds of break are the
-- same. The tree keeps them apart ("Wiki.Core.Markdown.Ast"), since it
-- records what was written.
--
-- __Mentions.__ @\@login@ is a link, @\<a class=\"mention\">@, to wherever
-- 'resolveMention' says the user is, titled with their name; a login it
-- does not know, and a mention in a link's text, are the text as written.
--
-- __Tasks.__ A task's item, @- [ ] text@, is a
-- @\<li class=\"task-list-item\">@ that starts with a checkbox labelled
-- with the item's text ('taskLabel'), and its list has the class
-- @task-list@. The checkbox is disabled, unless 'taskBoxes' says what a
-- change of it does: then it is enabled and carries the task's index
-- ("Wiki.Core.Markdown.Tasks") in @data-task@. The item's own text, its
-- first paragraph's, is in a @\<span class=\"task-text\">@, and a done
-- task's item has the class @task-done@ too, which the stylesheet strikes
-- through: its text and its other paragraphs, not the lists in it. A list
-- in a 'Div' of the class @sorted@ (@{.sorted}@ on the line before it),
-- and every list inside it, shows its done tasks after its other items,
-- each part in the order of the source. The items are rendered in the
-- order of the source and only shown in the other, so a task's index,
-- the islands' keys and the footnotes' numbers are those of the source.
--
-- A list that has tasks is keyed: each task's item by its index (and by
-- 'taskDrawn'), each other item by its place. When a sorted list moves an
-- item, its element moves with it, and its checkbox, whose state the
-- browser set on a click, stays the box of its own task. A checkbox's
-- state is written only when the rendered state changes, so a click the
-- page view does not take leaves the box as the browser set it: the view
-- then counts the box as drawn once more, its item gets a new key, and the
-- new element shows the state the view has.
module Wiki.Core.Markdown.Render
  ( Options (..)
  , MentionTarget (..)
  , IslandKey (..)
  , defaultOptions
  , defaultResolveLink
  , presentationClass
  , renderBlocks
  , renderLines
  , renderSections
  , renderSectionsWithIds
  , renderRawHtml
  , linkDestinations
  , boxOf
  , scrollingCode
  , lineNumbers
  )
where

import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as M
import Data.Row (Empty, HasType)
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Box (BoxCounter, BoxIcon (..), BoxKind (..), Numbering, alertKindName, boxCaption, boxStyle, countBox, countSection, definedKind, noNumbers, startCounting)
import Wiki.Core.Markdown.Frame (FrameScheme (..), SvgFrame (..), frameDocument, interactiveClass, svgFrameHeight)
import Wiki.Core.Markdown.Html qualified as Html
import Wiki.Core.Markdown.Link
import Wiki.Core.Markdown.LocalIds (localAttribute, prefixLocalIds)
import Wiki.Core.Markdown.Tasks (taskLabel)
import Wiki.Core.Markdown.Toc (contentsNav, tableOfContents)
import Wiki.Core.Math (Macros (..), definesMacros, onlyDefinitions)

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
  { codeBlock :: IslandKey -> Maybe Text -> Maybe Int -> Bool -> Text -> HH.HTML w i
  -- ^ A code block: its language, if it has one, the number of lines it
  -- shows before it scrolls, if its fence says ('codeRows'; see
  -- 'scrollingCode'), whether its lines are numbered ('codeNumbered'; see
  -- 'lineNumbers'), and its code.
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
  , htmlBlock :: IslandKey -> Text -> Maybe Int -> Text -> HH.HTML w i
  -- ^ An @html@ fence: its source, as written, the height its fence gives
  -- its frame, if it gives one ('frameHeight'; otherwise the frame is as
  -- high as its content), and the document its frame shows
  -- ('Wiki.Core.Markdown.Frame.frameDocument'), for the frame's @srcdoc@.
  , svgFrame :: Maybe (IslandKey -> SvgFrame -> HH.HTML w i)
  -- ^ How an interactive SVG's frame is drawn
  -- ("Wiki.Core.Markdown.Frame"), as an island: the application's page
  -- draws it. 'Nothing' by default: the embed is then an image, as a feed
  -- or an export shows it, since neither has the wiki's server behind it
  -- to answer the frame.
  , deckEmbed :: Maybe (IslandKey -> page -> Text -> HH.HTML w i)
  -- ^ How a page embedded with the class @presentation@ is drawn, given
  -- the page and the caption (or else the destination), as an island:
  -- the application's page draws a viewer. 'Nothing' by default: the
  -- embed is then the link to the page, as without the class.
  , frameScheme :: FrameScheme
  -- ^ The colours an @html@ fence's frame is drawn in: the system's on a
  -- page, by default, and a slide's theme's on a slide ("Wiki.Core.Slides").
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
  , hiddenSections :: Bool
  -- ^ Whether a heading spoiler hides its section in a @\<details>@, as
  -- on a page. Off, its heading and section are shown as they are, as a
  -- document exported from the page shows them: a feed, read apart from
  -- the wiki, gets the section, not a closed box with a heading on it.
  , copyButtons :: Bool
  -- ^ Whether a code block has a button that copies its code
  -- ('copyButton'): in the application, whose page loads the islands'
  -- script that makes the button work. Off by default, since a button
  -- does nothing where that script does not run (a feed).
  , boxes :: [BoxKind]
  -- ^ The kinds of box the administrator defined, with their labels,
  -- colours and icons ("Wiki.Core.Markdown.Box").
  , numbering :: Numbering
  -- ^ How the document's boxes are numbered: its space's way, and the
  -- page's number. None by default: a page's view sets it, and nothing
  -- else that renders Markdown (a comment, the front page) numbers boxes.
  , taskBoxes :: Maybe (Int -> Bool -> i)
  -- ^ What a change of a task's checkbox does, given the task's index
  -- ("Wiki.Core.Markdown.Tasks") and whether it is now ticked. 'Nothing'
  -- by default, and the checkboxes are disabled: only the page view, for
  -- a reader who may edit the page, ticks tasks.
  , taskDrawn :: Int -> Int
  -- ^ How many times the box of the task with this index was drawn anew,
  -- part of its item's key (the module's Haddock says why). None by
  -- default.
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
    { codeBlock = \_ lang rows numbered code ->
        HH.pre
          (scrollingCode rows ["numbered" | numbered])
          ([lineNumbers code | numbered] <> [HH.code (foldMap (\l -> [HP.class_ (HH.ClassName ("language-" <> l))]) lang) [HH.text code]])
    , mathInline = \_ _ tex -> HH.span [HP.class_ (HH.ClassName "math inline")] [HH.text tex]
    , mathDisplay = \_ _ tex -> HH.div [HP.class_ (HH.ClassName "math display")] [HH.text tex]
    , mermaid = \_ src -> HH.pre [HP.class_ (HH.ClassName "mermaid")] [HH.text src]
    , tikz = \_ src -> HH.pre [HP.class_ (HH.ClassName "tikz")] [HH.text src]
    , htmlBlock = \_ src _ _ -> HH.pre_ [HH.code [HP.class_ (HH.ClassName "language-html")] [HH.text src]]
    , svgFrame = Nothing
    , deckEmbed = Nothing
    , frameScheme = SystemScheme
    , resolveLink = defaultResolveLink
    , pageHref = identity
    , resolveMention = const Nothing
    , headingAnchors = True
    , hiddenSections = True
    , copyButtons = False
    , boxes = []
    , numbering = noNumbers
    , taskBoxes = Nothing
    , taskDrawn = const 0
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

-- | The document's blocks as HTML, in order, each block of the page (not
-- those inside another) after an empty marker of the source line it starts
-- on (@\<span class="source-line" data-line="12">@, from
-- 'Wiki.Core.Markdown.Ast.parseWithLines'). The editor's preview renders
-- with it, to scroll to the block being written; a page as read has no
-- markers. The blocks are one document, as for 'renderBlocks'.
renderLines :: Options page w i -> [(Maybe Int, Block)] -> [HH.HTML w i]
renderLines opts located =
  concat (zipWith (\line html -> marker line <> html) (map fst located) (renderSections opts (map (single . snd) located)))
  where
    marker = \case
      Just n -> [HH.span [classesProp ["source-line"], HP.attr (HH.AttrName "data-line") (show n), HP.attr (HH.AttrName "aria-hidden") "true"] []]
      Nothing -> []

-- | A document cut into sections, each section's blocks as HTML of its own,
-- in order: what a page shown as slides ("Wiki.Core.Slides") is rendered
-- with, each slide's title, body and notes a section, so that each can be
-- put where its slide shows it. The sections are one document all the same:
-- an island's key is unique among all of them, a formula is set with the
-- macros defined in the sections before it, and a footnote's references
-- are numbered across them, as they would be if the sections were one
-- page.
renderSections :: forall page w i. Options page w i -> [[Block]] -> [[HH.HTML w i]]
renderSections opts = renderSectionsWithIds opts . map ("",)

-- | 'renderSections', with a prefix for the ids of each section: every id
-- the section's HTML has (a heading's, a box's, a footnote's and its
-- references', one written in braces), every spoiler's name, and every
-- link to a place in the document (@#intro@) start with it. Sections that
-- were written apart, such as the changelog's entries on the page "What's
-- new?", then do not share ids even when they have the same headings or
-- footnotes, and a link in one leads to its own heading. A section with
-- the prefix @""@ is rendered as 'renderSections' renders it.
--
-- Raw HTML's ids and links, and the links @[[!toc]]@ writes, take the
-- prefix too ("Wiki.Core.Markdown.LocalIds").
renderSectionsWithIds :: forall page w i. Options page w i -> [(Text, [Block])] -> [[HH.HTML w i]]
renderSectionsWithIds opts prefixed = evalState (traverse section prefixed) (Counts M.empty M.empty [] M.empty (startCounting opts.numbering) "" 0 False)
  where
    sections = map snd prefixed

    -- A section's own notes are read first, the others' after: comments
    -- shown together are sections each numbering its notes from 1, and a
    -- slide's notes come in a section after its references.
    section (prefix, bs) = modify (\c -> c {sectionNotes = noteTexts [bs], idPrefix = prefix}) >> renderBlocks' bs

    -- An id the document writes, with the section's prefix.
    ownId :: Text -> R Text
    ownId ident = gets (\c -> if T.null ident then ident else c.idPrefix <> ident)

    -- Attributes, their id with the section's prefix.
    ownAttrs :: Attributes -> R Attributes
    ownAttrs = traverse (\(key, v) -> if key == "id" then (key,) <$> ownId v else pure (key, v))

    -- A link's destination: one to a place in the document (@#intro@)
    -- with the section's prefix, any other as written.
    ownDestination :: Text -> R Text
    ownDestination dest = case T.stripPrefix "#" dest of
      Just fragment | not (T.null fragment) -> ("#" <>) <$> ownId fragment
      _ -> pure dest

    -- Each footnote's text, by its number, for the title of its
    -- references: the notes come last, after the references.
    allNotes :: Map Int Text
    allNotes = noteTexts sections

    renderBlock :: Block -> R [HH.HTML w i]
    renderBlock = \case
      Para xs -> single . HH.p_ <$> renderInlines xs
      Plain xs -> renderInlines xs
      Heading level written xs -> do
        -- A level-two heading starts a section, which a box's number may
        -- count ("Wiki.Core.Markdown.Box").
        when (level == 2) $ modify (\c -> c {boxCounter = countSection c.boxCounter})
        attrs <- ownAttrs written
        inner <- renderInlines xs
        pure [headingOf level (idAndClasses attrs []) (inner <> (if opts.headingAnchors then headingAnchor attrs else []))]
      ThematicBreak -> pure [HH.hr_]
      -- A pause matters only on a slide ("Wiki.Core.Slides"), which has
      -- taken it out by now. A page shows nothing for it.
      Pause -> pure []
      BlockQuote bs -> single . HH.blockquote_ <$> renderBlocks' bs
      CodeBlock attrs lang code ->
        island code <&> \k ->
          let listing = opts.codeBlock k lang (codeRows attrs) (codeNumbered attrs) code
           in [if opts.copyButtons then HH.div [classesProp ["code-block"]] [listing, copyButton] else listing]
      Mermaid src -> island src <&> \k -> [opts.mermaid k src]
      Tikz src -> island src <&> \k -> [opts.tikz k src]
      HtmlBlock attrs src -> island src <&> \k -> [opts.htmlBlock k src (frameHeight attrs) (frameDocument opts.frameScheme (frameContent opts src))]
      -- A block of nothing but definitions (a page's macros, WP5.41) shows
      -- nothing; its macros hold for the formulas after it all the same.
      MathBlock tex
        | onlyDefinitions tex -> [] <$ formula tex
        | otherwise -> formula tex <&> \(k, ms) -> [opts.mathDisplay k ms tex]
      List kind items -> do
        rendered <- zipWithM (renderItem kind) [0 ..] items
        sorting <- gets (.sorting)
        let done (_, _, d) = d
            shown = if sorting then filter (not . done) rendered <> filter done rendered else rendered
        pure
          [ if any isTask items
              then keyedListOf kind [(key, html) | (key, html, _) <- shown]
              else listOf kind [html | (_, html, _) <- shown]
          ]
      Table aligns header rows -> single <$> renderTable aligns header rows
      Div written bs -> do
        attrs <- ownAttrs written
        before <- gets (.sorting)
        when (sortedClass `elem` classes written) $ modify (\c -> c {sorting = True})
        inner <- renderBlocks' bs
        modify (\c -> c {sorting = before})
        pure [HH.div (idAndClasses attrs []) inner]
      Alert kind box bs -> do
        number <- if box.numbered then state (\c -> second (\b -> c {boxCounter = b}) (countBox kind c.boxCounter)) else pure Nothing
        let defined = definedKind opts.boxes kind
        title <- withPieces [PText (boxCaption defined kind number (isJust box.title))] (maybe [] (map displayInline) box.title) []
        inner <- renderBlocks' bs
        ident <- traverse ownId box.id
        let anchor = if opts.headingAnchors then concatMap (\i -> headingAnchor [("id", i)]) ident else []
        pure [boxWith defined kind ident (title <> anchor) inner]
      -- A heading spoiler's summary is its heading, rendered as any
      -- heading is: its id, its link to itself, the section it starts
      -- for the boxes' numbers.
      Spoiler h (heading@Heading {} : rest)
        | h.kind == OnHeading ->
            if opts.hiddenSections
              then do
                summary <- renderBlock heading
                inner <- renderBlocks' rest
                name <- ownId h.name
                pure [HH.details [classesProp ["spoiler", "spoiler-section"], HP.attr (HH.AttrName "data-spoiler") name] (HH.summary_ summary : inner)]
              else renderBlocks' (heading : rest)
      Spoiler h bs -> case h.problem of
        Nothing -> do
          summary <- renderInlines (map displayInline h.description)
          inner <- renderBlocks' bs
          name <- ownId h.name
          pure [HH.details [classesProp ["spoiler"], HP.attr (HH.AttrName "data-spoiler") name] (HH.summary_ summary : inner)]
        Just problem -> do
          inner <- renderBlocks' bs
          pure [spoilerError h.marker (spoilerProblemText h problem), HH.div [classesProp ["spoiler-unclosed"]] inner]
      MarkerError written why -> pure [spoilerError written why]
      -- A slide shows the notes it refers to, which need not start at the
      -- first ("Wiki.Core.Slides").
      Footnotes notes ->
        single . HH.section [classesProp ["footnotes"]] . single . listOf (OrderedList (firstNote notes)) <$> traverse renderNote notes
      -- Raw HTML and the contents write ids and links the renderer does
      -- not make itself: they take the section's prefix by the same rule
      -- ("Wiki.Core.Markdown.LocalIds").
      RawHtmlBlock raw -> gets (\c -> c.idPrefix) <&> \p -> renderParsedHtml opts (map (localNode p) (Html.parseHtml raw))
      TableOfContents -> gets (\c -> c.idPrefix) <&> \p -> map (prefixLocalIds p) (contentsNav contents)

    -- The table of contents a @[[!toc]]@ shows: of the whole document, every
    -- section of it.
    contents = tableOfContents (concat sections)

    renderBlocks' :: [Block] -> R [HH.HTML w i]
    renderBlocks' bs = concat <$> traverse renderBlock bs

    -- An item of a list. A task's checkbox goes before its first
    -- paragraph's text. An item of a bulleted list whose text starts with
    -- an emoji shows the emoji in the bullet's place (WP5.86 of
    -- docs/PLAN.md): the item gets the class @emoji-item@, which hides the
    -- bullet, and the emoji the class @emoji-bullet@, which moves it to
    -- where the bullet was. The emoji stays in the item's text, so the
    -- text a search, a comment's quote or a slide's steps read is the same.
    -- A task's item is as the module's Haddock says. With the item, its key
    -- (a task's by its index, another item's by its place in the list) and
    -- whether it is a done task, which a sorted list shows last.
    renderItem :: ListKind -> Int -> ListItem -> R (Text, HH.HTML w i, Bool)
    renderItem kind place item@(ListItem task _) = do
      -- The next task's index: the item's own, if it is a task.
      index <- gets (.tasks)
      html <- renderItem' kind item
      let key = case task of
            Just _ -> "task-" <> show index <> "-" <> show (opts.taskDrawn index)
            Nothing -> "item-" <> show place
      pure (key, html, fromMaybe False task)

    renderItem' :: ListKind -> ListItem -> R (HH.HTML w i)
    renderItem' kind (ListItem task bs) = case task of
      Nothing | Just (keyword, emoji) <- emojiBullet kind bs -> do
        let bullet = [PNode (emojiSpan ["emoji", "emoji-bullet"] keyword emoji)]
        inner <- case bs of
          Para (_ : xs) : rest -> (:) . HH.p_ <$> withPieces bullet xs [] <*> renderBlocks' rest
          Plain (_ : xs) : rest -> (<>) <$> withPieces bullet xs [] <*> renderBlocks' rest
          _ -> renderBlocks' bs
        pure (HH.li [classesProp ["emoji-item"]] inner)
      Nothing -> HH.li_ <$> renderBlocks' bs
      Just done -> do
        -- Counted before the tasks in it, as the tree orders them.
        index <- state (\c -> (c.tasks, c {tasks = c.tasks + 1}))
        let label = nonEmptyOr "Task" (taskLabel bs)
            enabled = case opts.taskBoxes of
              Nothing -> [HP.disabled True]
              Just onTick -> [HP.attr (HH.AttrName "data-task") (show index), HE.onChecked (onTick index)]
            checkbox = fromPieces [PNode (HH.input ([HP.type_ I.InputCheckbox, HP.checked done, HP.attr (HH.AttrName "aria-label") label] <> enabled)), PText " "]
            own xs = (\inner -> checkbox <> [HH.span [classesProp ["task-text"]] inner]) <$> renderInlines xs
        inner <- case bs of
          Para xs : rest -> (:) . HH.p_ <$> own xs <*> renderBlocks' rest
          Plain xs : rest -> (<>) <$> own xs <*> renderBlocks' rest
          _ -> (checkbox <>) <$> renderBlocks' bs
        pure (HH.li [classesProp (["task-list-item"] <> ["task-done" | done])] inner)

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
      reference <- ownId ("fnref-" <> show n)
      noteId <- ownId ("fn-" <> show n)
      let back = [PText " ", PNode (HH.a [HP.href ("#" <> reference), classesProp ["footnote-back"]] [HH.text "↩"])]
      inner <- case unsnoc bs of
        Just (start, Para xs) -> (<>) <$> renderBlocks' start <*> (single . HH.p_ <$> withPieces [] xs back)
        _ -> (<> fromPieces (drop 1 back)) <$> renderBlocks' bs
      pure (HH.li [HP.id noteId] inner)

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
      | any isRawHtml xs = gets (\c -> c.idPrefix) >>= \p -> htmlPieces inLink (map (localNode p) (Html.parseFragments context (map fragment xs)))
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
      SoftBreak -> pure [PNode HH.br_, PText "\n"]
      -- A line ended with a backslash goes on in the next (WP5.55 of
      -- docs/PLAN.md): the two lines are one, a space between them, since
      -- a plain line break is a break already. CommonMark's two trailing
      -- spaces are the same node, and join the lines too.
      LineBreak -> pure [PText " "]
      Emph xs -> node HH.em_ . fromPieces <$> inlinePieces inLink xs
      Strong xs -> node HH.strong_ . fromPieces <$> inlinePieces inLink xs
      Strikeout xs -> node HH.del_ . fromPieces <$> inlinePieces inLink xs
      Hidden xs ->
        node (HH.span [classesProp ["spoiler"], HP.tabIndex 0, HP.attr (HH.AttrName "role") "button", HP.attr (HH.AttrName "aria-label") "Spoiler: click to reveal"])
          . fromPieces
          <$> inlinePieces inLink xs
      Code written code -> do
        attrs <- ownAttrs written
        pure [PNode (HH.code (idAndClasses attrs []) [HH.text code])]
      Link _ _ _ xs | inLink -> inlinePieces True xs
      Link written dest title xs -> do
        attrs <- ownAttrs written
        dest' <- ownDestination dest
        renderLink attrs dest' title xs
      Image written dest title xs -> do
        attrs <- ownAttrs written
        renderEmbed inLink attrs dest title (plainText xs)
      Math InlineMath tex -> formula tex <&> \(k, ms) -> [PNode (opts.mathInline k ms tex)]
      Math DisplayMath tex -> formula tex <&> \(k, ms) -> [PNode (opts.mathDisplay k ms tex)]
      FootnoteRef n _ -> do
        ident <- footnoteRefId n
        noteId <- ownId ("fn-" <> show n)
        own <- gets (.sectionNotes)
        let noteTitle = fromMaybe "" (M.lookup n own <|> M.lookup n allNotes)
        pure [PNode (HH.sup [classesProp ["footnote-ref"]] [HH.a ([HP.href ("#" <> noteId), HP.id ident] <> titleProp noteTitle) [HH.text (show n)]])]
      Emoji keyword emoji -> pure [PNode (emojiSpan ["emoji"] keyword emoji)]
      -- Raw HTML is read with its neighbours, by 'inlinePieces', and does
      -- not get here; on its own it would be read the same way.
      RawHtml raw -> gets (\c -> c.idPrefix) >>= \p -> htmlPieces inLink (map (localNode p) (Html.parseFragments (if inLink then Html.PhrasingInLink else Html.Phrasing) [Html.Markup raw]))
      Mention login -> pure $ case opts.resolveMention login of
        Just target
          | not inLink ->
              [PNode (HH.a [HP.href target.href, classesProp ["mention"], HP.title target.name] [HH.text ("@" <> login)])]
        _ -> [PText ("@" <> login)]
      -- A pause matters only on a slide ("Wiki.Core.Slides"), which has
      -- marked what follows it; a page shows nothing for it.
      InlinePause _ _ -> pure []
      -- One where none is read: in red, with the reason, as a marker
      -- line that is wrong.
      MisplacedPause _ _ why ->
        pure [PNode (HH.span [classesProp ["spoiler-error"], HP.title why] [HH.text (openingMarker PauseName), HH.span [classesProp ["spoiler-error-reason"]] [HH.text why]])]
      Marked written xs -> do
        attrs <- ownAttrs written
        node (HH.span (idAndClasses attrs [])) . fromPieces <$> inlinePieces inLink xs

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
          | safeHref ref.downloadUrl -> anchor [HP.href ref.downloadUrl, HP.download ref.name]
          | otherwise -> asText
        Unresolved -> [PNode (HH.span [classesProp ["link-unresolved"], HP.title dest] inner)]

    -- An embed in a link's text ('inLink') is never a frame: the frame's
    -- download link would be an anchor inside the link, which a browser
    -- parsing the prerendered page moves out of it, and a click in a frame
    -- never reaches the link around it.
    renderEmbed :: Bool -> Attributes -> Text -> Text -> Text -> R [Piece w i]
    renderEmbed inLink attrs dest title caption = case opts.resolveLink dest of
      External url
        | safeSrc url -> pure [PNode (media (mediaKindOfPath url) url url Nothing)]
        | otherwise -> pure [PText caption]
      Attachment ref
        | not inLink
        , interactiveClass `elem` classes attrs
        , Just frame <- ref.frameUrl
        , safeSrc frame
        , Just draw <- opts.svgFrame -> do
            k <- island frame
            let shown = SvgFrame {url = frame, title = nonEmptyOr ref.name caption, height = fromMaybe svgFrameHeight (frameHeight attrs)}
            pure
              [ PNode
                  ( HH.span
                      (idAndClasses attrs ["svg-frame"])
                      [ draw k shown
                      , HH.a [HP.href ref.downloadUrl, HP.download ref.name, classesProp ["svg-frame-download"], HP.attr (HH.AttrName "aria-label") ("Download " <> ref.name)] []
                      ]
                  )
              ]
        | safeSrc ref.url -> pure [PNode (media (maybe (mediaKindOfPath ref.name) mediaKindOfType ref.mediaType) ref.url ref.downloadUrl (Just ref.name))]
        | otherwise -> pure [PText caption]
      Page page
        | not inLink
        , presentationClass `elem` classes attrs
        , Just draw <- opts.deckEmbed -> do
            k <- island ("presentation " <> dest)
            pure [PNode (draw k page (nonEmptyOr dest caption))]
        | otherwise -> pure [PNode (HH.a [HP.href (opts.pageHref page)] [HH.text (nonEmptyOr dest caption)])]
      Unresolved -> pure [PNode (HH.span [classesProp ["embed-unresolved"], HP.title dest] [HH.text (nonEmptyOr dest caption)])]
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
        -- What is shown is fetched from the first URL; a link leads to the
        -- second ('AttachmentRef''s downloadUrl).
        media kind url linkTo name = case (kind, name) of
          (VideoMedia, _) -> HH.video ([HP.src url, HP.controls True] <> label <> common) []
          (AudioMedia, _) -> HH.audio ([HP.src url, HP.controls True] <> label <> common) []
          (OtherMedia, Just file) -> HH.a ([HP.href linkTo, HP.download file] <> idAndClasses attrs []) [HH.text (nonEmptyOr file caption)]
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
      let seen = M.findWithDefault 0 (c.idPrefix, n) c.footnoteRefs
          ident = c.idPrefix <> "fnref-" <> show n <> (if seen == 0 then "" else "-" <> show (seen + 1))
       in (ident, c {footnoteRefs = M.insert (c.idPrefix, n) (seen + 1) c.footnoteRefs})

-- | The counters rendering keeps as it goes: islands by source (for their
-- keys), references to each footnote (for their ids), the formulas so
-- far that define macros, the latest first, and the boxes so far, for
-- their numbers.
data Counts = Counts
  { islands :: Map Text Int
  , footnoteRefs :: Map (Text, Int) Int
  -- ^ By the section's id prefix and the note's number.
  , definitions :: [Text]
  , sectionNotes :: Map Int Text
  -- ^ The footnotes of the section being rendered, by number, as titles.
  , boxCounter :: BoxCounter
  , idPrefix :: Text
  -- ^ What the section being rendered puts before its ids
  -- ('renderSectionsWithIds').
  , tasks :: Int
  -- ^ How many tasks came before: the next task's index.
  , sorting :: Bool
  -- ^ Whether the lists being rendered are in a 'Div' of the class
  -- @sorted@, and show their done tasks last.
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

-- | Each footnote's text in these sections, by its number, wherever its
-- notes are: at the end, or wrapped in a div (a slide's step) or a quote.
noteTexts :: [[Block]] -> Map Int Text
noteTexts sections = M.fromList [(n, noteText bs) | Footnote n _ bs <- concatMap notesIn (concat sections)]
  where
    notesIn = \case
      Footnotes ns -> ns
      Div _ bs -> concatMap notesIn bs
      BlockQuote bs -> concatMap notesIn bs
      Alert _ _ bs -> concatMap notesIn bs
      Spoiler _ bs -> concatMap notesIn bs
      _ -> []

-- | A footnote's text, as the title of a reference to it shows it: the
-- words of its blocks without their markup, formulas and code as written,
-- on one line. A title is plain text, so this is the note as far as plain
-- text can show it.
noteText :: [Block] -> Text
noteText = T.unwords . T.words . T.unwords . map blockText
  where
    blockText = \case
      Para xs -> plainText xs
      Plain xs -> plainText xs
      Heading _ _ xs -> plainText xs
      BlockQuote bs -> noteText bs
      CodeBlock _ _ code -> code
      MathBlock tex -> tex
      List _ items -> T.unwords [noteText bs | ListItem _ bs <- items]
      Table _ header rows -> T.unwords (map plainText (header <> concat rows))
      Div _ bs -> noteText bs
      Alert _ box bs -> T.unwords (maybe [] (pure . plainText) box.title <> [noteText bs])
      Spoiler h bs -> T.unwords [plainText h.description, noteText bs]
      MarkerError written _ -> written
      RawHtmlBlock raw -> Html.htmlText (Html.parseHtml raw)
      HtmlBlock _ raw -> Html.htmlText (Html.parseFrameHtml raw)
      _ -> ""

firstNote :: [Footnote] -> Int
firstNote = \case
  Footnote n _ _ : _ -> n
  [] -> 1

-- | The link to a heading that its heading ends with, shown on hover (see
-- @web/style.css@): an empty @\<a class="heading-anchor">@ whose @#@ the
-- stylesheet draws, so that the page's text (what a comment quotes,
-- "Wiki.Core.Anchor", and what a search finds) has no @#@ after every
-- heading. A box's title ends with one too, to the box's @id@. In the
-- application a click on it copies the section's address
-- ("Wiki.App.Browser"); its @href@ is the section's all the same, for the
-- browser's own "Copy link" and a click with the middle button.
headingAnchor :: Attributes -> [HH.HTML w i]
headingAnchor attrs =
  [ HH.a [HP.href ("#" <> ident), classesProp ["heading-anchor"], HP.attr (HH.AttrName "aria-label") "Link to this section"] []
  | Just ident <- [attribute "id" attrs]
  , not (T.null ident)
  ]

isTask :: ListItem -> Bool
isTask (ListItem task _) = isJust task

-- | The class of a 'Div' whose lists show their done tasks last.
sortedClass :: Text
sortedClass = "sorted"

-- | The emoji an item of a list shows as its bullet: its first inline, when
-- the list is bulleted and the item's text starts with an emoji. A task's
-- checkbox is its own mark, and a numbered list keeps its numbers, so the
-- caller asks only for an item that is not a task.
emojiBullet :: ListKind -> [Block] -> Maybe (Text, Text)
emojiBullet BulletList (Para (Emoji keyword emoji : _) : _) = Just (keyword, emoji)
emojiBullet BulletList (Plain (Emoji keyword emoji : _) : _) = Just (keyword, emoji)
emojiBullet _ _ = Nothing

-- | An emoji, with its shortcode as its title, which a pointer shows.
emojiSpan :: [Text] -> Text -> Text -> HH.HTML w i
emojiSpan names keyword emoji = HH.span [classesProp names, HP.title (":" <> keyword <> ":")] [HH.text emoji]

headingOf :: Int -> [HP.IProp I.HTMLh1 i] -> [HH.HTML w i] -> HH.HTML w i
headingOf level = case level of
  1 -> HH.h1
  2 -> HH.h2
  3 -> HH.h3
  4 -> HH.h4
  5 -> HH.h5
  _ -> HH.h6

-- | A list of tasks, its items keyed ('renderItem').
keyedListOf :: ListKind -> [(Text, HH.HTML w i)] -> HH.HTML w i
keyedListOf kind = case kind of
  BulletList -> HH.keyed (HH.ElemName "ul") [taskList :: HP.IProp I.HTMLul i]
  OrderedList start -> HH.keyed (HH.ElemName "ol") ([taskList] <> [HP.prop (HH.PropName "start") start | start /= 1] :: [HP.IProp I.HTMLol i])
  where
    taskList :: (HasType "class" Text r) => HP.IProp r i
    taskList = classesProp ["task-list"]

-- | A list without tasks.
listOf :: ListKind -> [HH.HTML w i] -> HH.HTML w i
listOf kind = case kind of
  BulletList -> HH.ul []
  OrderedList start -> HH.ol [HP.prop (HH.PropName "start") start | start /= 1]

alignment :: (HasType "style" Text r) => Alignment -> [HP.IProp r i]
alignment = \case
  AlignDefault -> []
  AlignLeft -> [HP.styleText "text-align: left"]
  AlignCenter -> [HP.styleText "text-align: center"]
  AlignRight -> [HP.styleText "text-align: right"]

classesProp :: (HasType "class" Text r) => [Text] -> HP.IProp r i
classesProp = HP.class_ . HH.ClassName . T.unwords

-- | A box, @> [!KIND]@, without a number: its kind's definition among the
-- administrator's ('definedKind'), its kind, the title written after its
-- marker if there is one, as text, and what it holds. The
-- administration's preview of a kind is drawn by this ("Wiki.App.View.Server").
boxOf :: Maybe BoxKind -> AlertKind -> Maybe Text -> [HH.HTML w i] -> HH.HTML w i
boxOf defined kind title = boxWith defined kind Nothing [HH.text (fromMaybe (boxCaption defined kind Nothing False) title)]

-- | A box: its kind's definition, its kind, its @id@ if it has one, what
-- its title holds (after the icon), and what it holds.
boxWith :: Maybe BoxKind -> AlertKind -> Maybe Text -> [HH.HTML w i] -> [HH.HTML w i] -> HH.HTML w i
boxWith defined kind ident title inner =
  HH.div
    (classesProp ["alert", "alert-" <> alertKindName kind] : [HP.id i | Just i <- [ident]] <> [HP.styleText (boxStyle k) | Just k <- [defined]])
    (HH.p [classesProp ["alert-title"]] (icon <> title) : inner)
  where
    icon = [HH.span [classesProp ["alert-icon"], HP.attr (HH.AttrName "aria-hidden") "true"] [] | Just k <- [defined], k.icon /= NoIcon]

-- | The properties of a code block's @\<pre>@ that make it show this many
-- lines and scroll inside, if a number is given ('codeRows'), with the
-- element's own classes before: the class @code-scroll@, and the height
-- and the scrolling in its @style@ (the module's comment says why). The
-- default code block and the application's highlighted one
-- ("Wiki.App.Islands") both use it.
scrollingCode :: (HasType "class" Text r, HasType "style" Text r) => Maybe Int -> [Text] -> [HP.IProp r i]
scrollingCode rows own = case rows of
  Nothing -> [classesProp own | not (null own)]
  Just n -> [classesProp (own <> ["code-scroll"]), HP.styleText ("max-height: " <> show n <> "lh; overflow: auto")]

-- | The gutter of a numbered code block ('codeNumbered'), the first child
-- of its @\<pre>@, before the @\<code>@: an empty @\<span>@ for each line
-- of the code, the last one counted whether a newline ends it or not. The
-- stylesheet shows the spans as lines of the code's height and numbers
-- them with a counter, so the numbers are no text of the page: they are
-- not selected with the code, copied or searched. The gutter is
-- @aria-hidden@, since a screen reader reading numbers between the lines
-- would only get in the way. It is beside the @\<code>@, not in it,
-- because the highlighter replaces what the @\<code>@ holds; in the
-- @\<pre>@, it scrolls with the code in a listing that scrolls. The
-- default code block and the application's highlighted one
-- ("Wiki.App.Islands") both use it.
lineNumbers :: Text -> HH.HTML w i
lineNumbers code =
  HH.span
    [classesProp ["code-lines"], HP.attr (HH.AttrName "aria-hidden") "true"]
    (replicate (length (T.lines code)) (HH.span_ []))

-- | The button a code block ends with when 'copyButtons' is on. It is
-- empty: the stylesheet draws its label, "Copy", and the islands' script
-- changes the label for a moment after a click by setting @data-copy@
-- (web/src/islands.js). The @aria-label@ names it for a screen reader,
-- and @type=\"button\"@ keeps it from submitting a form it may be in.
copyButton :: HH.HTML w i
copyButton =
  HH.button
    [ HP.type_ I.ButtonButton
    , classesProp ["code-copy"]
    , HP.attr (HH.AttrName "aria-label") "Copy the code"
    ]
    []

-- | A line the page shows in red: a spoiler's marker as written, and what
-- is wrong with it, also as the line's title.
spoilerError :: Text -> Text -> HH.HTML w i
spoilerError written why =
  HH.p [classesProp ["spoiler-error"], HP.title why] [HH.text written, HH.span [classesProp ["spoiler-error-reason"]] [HH.text why]]

-- | Display math in a box's title, @$$…$$@, set on the title's line in
-- display style: a title is one line, and a block of display math in it
-- would break the line. Math inside emphasis or a link's text is set the
-- same way, since a block there would also sit inside the title's
-- paragraph.
displayInline :: Inline -> Inline
displayInline = \case
  Math DisplayMath tex -> Math InlineMath ("\\displaystyle " <> tex)
  Emph xs -> Emph (map displayInline xs)
  Strong xs -> Strong (map displayInline xs)
  Strikeout xs -> Strikeout (map displayInline xs)
  Hidden xs -> Hidden (map displayInline xs)
  Link attrs dest title xs -> Link attrs dest title (map displayInline xs)
  Image attrs dest title xs -> Image attrs dest title (map displayInline xs)
  other -> other

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
renderRawHtml opts raw = renderParsedHtml opts (Html.parseHtml raw)

-- | 'renderRawHtml' of HTML parsed already.
renderParsedHtml :: forall page w i. Options page w i -> [Html.Node Void] -> [HH.HTML w i]
renderParsedHtml opts parsed = fromPieces (concatMap pieces parsed)
  where
    pieces :: Html.Node Void -> [Piece w i]
    pieces = \case
      Html.Element name attrs children -> [PNode (htmlElement opts name attrs (fromPieces (concatMap pieces children)))]
      Html.TextNode t -> [PText t]

-- | 'linkDestinations' is the destination of every link the renderer
-- makes of some blocks, as written and in the order of the document,
-- whatever it resolves to: a Markdown link's and a wiki link's, an
-- embed's (an embed that resolves to a page is shown as a link to it), and
-- the @href@ of each @a@ in raw HTML that the allowlist keeps. It walks
-- the blocks as 'renderBlocks' does, so it finds what a reader can click:
-- a link inside a link's text is shown as text and is not one, an embed's
-- caption is plain text, a block spoiler that is written wrong shows its
-- blocks but not its description, and code, a formula or a diagram holds
-- no link. Nor does an @html@ fence: its links are in its frame, which
-- opens them in a new tab, not on the page. An image's or a video's @src@ in raw HTML is never a page, and
-- is left out. A page's backlinks ("Wiki.App.Backlinks") are counted
-- from what this finds, so that the list and the links on the page agree.
linkDestinations :: [Block] -> [Text]
linkDestinations = concatMap block
  where
    block = \case
      Para xs -> inlines False xs
      Plain xs -> inlines False xs
      Heading _ _ xs -> inlines False xs
      BlockQuote bs -> linkDestinations bs
      List _ items -> concat [linkDestinations bs | ListItem _ bs <- items]
      Table _ header rows -> concatMap (inlines False) (header <> concat rows)
      Div _ bs -> linkDestinations bs
      Alert _ box bs -> foldMap (inlines False) box.title <> linkDestinations bs
      Spoiler h bs
        | isJust h.problem -> linkDestinations bs
        | otherwise -> inlines False h.description <> linkDestinations bs
      Footnotes notes -> concat [linkDestinations bs | Footnote _ _ bs <- notes]
      RawHtmlBlock raw -> html (const absurd) False (Html.parseHtml raw)
      -- Every other block, named, so that a block added later is a
      -- decision of its own here.
      ThematicBreak -> []
      Pause -> []
      CodeBlock {} -> []
      Mermaid _ -> []
      Tikz _ -> []
      MathBlock _ -> []
      -- A link in an html fence is in its frame, a document of its own,
      -- and is not one of the page's (WP5.89 of docs/PLAN.md).
      HtmlBlock _ _ -> []
      MarkerError _ _ -> []
      TableOfContents -> []
    -- As 'renderBlocks' reads them: raw HTML among the inlines is parsed
    -- with the Markdown around it, in a link's text with no @a@ allowed.
    inlines :: Bool -> [Inline] -> [Text]
    inlines inLink xs
      | any isRawHtml xs = html inline inLink (Html.parseFragments (htmlContext inLink) (map fragment xs))
      | otherwise = concatMap (inline inLink) xs
      where
        fragment = \case
          RawHtml raw -> Html.Markup raw
          x -> Html.Markdown x
        isRawHtml = \case
          RawHtml _ -> True
          _ -> False
    inline :: Bool -> Inline -> [Text]
    inline inLink = \case
      Emph xs -> inlines inLink xs
      Strong xs -> inlines inLink xs
      Strikeout xs -> inlines inLink xs
      Hidden xs -> inlines inLink xs
      Link _ _ _ xs | inLink -> inlines True xs
      Link _ dest _ xs -> dest : inlines True xs
      Image _ dest _ _ -> [dest]
      RawHtml raw -> html inline inLink (Html.parseFragments (htmlContext inLink) [Html.Markup raw])
      Str _ -> []
      SoftBreak -> []
      LineBreak -> []
      Code _ _ -> []
      Math _ _ -> []
      FootnoteRef _ _ -> []
      Emoji _ _ -> []
      Mention _ -> []
      InlinePause _ _ -> []
      MisplacedPause {} -> []
      Marked _ xs -> inlines inLink xs
    htmlContext inLink = if inLink then Html.PhrasingInLink else Html.Phrasing
    -- Every @a@ with an @href@ ('htmlElement' makes each a link), and the
    -- Markdown among the elements, which inside an @a@ is a link's text.
    html :: (Bool -> a -> [Text]) -> Bool -> [Html.Node a] -> [Text]
    html content inLink = concatMap $ \case
      Html.Element name attrs children ->
        [dest | name == "a", Just dest <- [attribute "href" attrs]] <> html content (inLink || name == "a") children
      Html.TextNode _ -> []
      Html.Content x -> content inLink x

-- | Render an element the allowlist kept, with its attributes resolved
-- ('resolvedAttributes').
htmlElement :: forall page w i. Options page w i -> Text -> [Html.Attribute] -> [HH.HTML w i] -> HH.HTML w i
htmlElement opts name attrs = HH.element (HH.ElemName name) (map attr (resolvedAttributes opts attrs))
  where
    -- The element is made by name, so its properties are typed by no
    -- element's row.
    attr :: (Text, Text) -> HP.IProp Empty i
    attr (key, value) = HP.attr (HH.AttrName key) value

-- | The attributes of an element the allowlist kept, as the page writes
-- them. A URL is resolved as a Markdown link's or embed's is
-- ('resolveLink'), except that a relative address may also name an
-- attachment. A source is looked up as an attachment first, since a page
-- cannot be shown in an @img@. A link is looked up as an attachment only
-- if it names no page. The resolved URL is written only if its scheme is
-- harmless; otherwise the attribute is dropped, and an @a@ that leads
-- nowhere gets the class @link-unresolved@, as a Markdown link would show
-- it. A link to an attachment downloads it, and one that leaves the wiki
-- gets @rel=\"noopener\"@, as in Markdown.
resolvedAttributes :: forall page w i. Options page w i -> [Html.Attribute] -> [(Text, Text)]
resolvedAttributes opts attrs = concatMap prop attrs <> unresolvedClass
  where
    href :: Maybe [(Text, Text)]
    href = linkProps <$> attribute "href" attrs
    broken = maybe False null href
    unresolvedClass = [("class", "link-unresolved") | broken, isNothing (attribute "class" attrs)]
    prop (key, value) = case key of
      "href" -> fromMaybe [] href
      "src" -> sourceProp key value
      "poster" -> sourceProp key value
      "class" | broken -> [(key, value <> " link-unresolved")]
      _ -> [(key, value)]
    linkProps dest = case relativeFirst False dest of
      External url
        | safeHref url -> ("href", url) : [("rel", "noopener") | isExternal url]
      Page page -> [("href", opts.pageHref page)]
      Attachment ref
        | safeHref ref.downloadUrl -> [("href", ref.downloadUrl), ("download", ref.name)]
      _ -> []
    sourceProp key dest = case relativeFirst True dest of
      External url | safeSrc url -> [(key, url)]
      Attachment ref | safeSrc ref.url -> [(key, ref.url)]
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

-- | An @html@ fence's HTML as its frame shows it: through the allowlist
-- widened by styles ("Wiki.Core.Markdown.Html.parseFrameHtml"), its URLs
-- resolved as raw HTML's are in the page ('resolvedAttributes'), and
-- written out as HTML again. The addresses stay as the page writes them,
-- relative to the page's base address, which the frame's document
-- inherits. A link opens in a new tab: a frame cannot show the document it
-- leads to (the page's policy lets no other document into a frame), and
-- an attachment it leads to is opened there rather than downloaded, which
-- the frame's sandbox forbids. A link to a place in the page (@#intro@)
-- has nowhere to lead from the frame, and keeps its text alone.
frameContent :: Options page w i -> Text -> Text
frameContent opts = Html.renderHtml . map resolve . Html.parseFrameHtml
  where
    resolve :: Html.Node Void -> Html.Node Void
    resolve = \case
      Html.Element name attrs children -> Html.Element name (inFrame name attrs) (map resolve children)
      Html.TextNode t -> Html.TextNode t
    -- A link to a place in the page is known by its address as written:
    -- a resolved address may start with @#@ too, where the application's
    -- router keeps its routes in the fragment.
    inFrame name written
      | name == "a" =
          let inPage = maybe False ("#" `T.isPrefixOf`) (attribute "href" written)
              kept = [(k, v) | (k, v) <- resolvedAttributes opts written, k `notElem` ["rel", "download"], not (k == "href" && inPage)]
           in kept <> (if any ((== "href") . fst) kept then [("target", "_blank"), ("rel", "noopener noreferrer")] else [])
      | otherwise = resolvedAttributes opts written

-- | The class that makes an embedded page a viewer of the presentation
-- ('deckEmbed'): @![Talk](/s/docs/p/talk/){.presentation}@.
presentationClass :: Text
presentationClass = "presentation"

-- | Raw HTML's element with a section's prefix on its ids and its links to
-- a place in the document ('localAttribute').
localNode :: Text -> Html.Node a -> Html.Node a
localNode p = \case
  Html.Element name attrs children -> Html.Element name [(k, localAttribute p name k v) | (k, v) <- attrs] (map (localNode p) children)
  other -> other
