-- | Raw HTML in a page, read the way a browser would read it and cut down to
-- what an allowlist admits.
--
-- CommonMark lets an author write HTML in a page, as a block of its own or
-- as tags among the text, and hands it over as it is written ('RawHtml',
-- 'RawHtmlBlock'). A page is read by other people than its author, and the
-- renderer is shared with the server, so that HTML is never given to the
-- browser as markup: it is tokenised here (by @tagsoup@, which is pure
-- Haskell and builds for wasm), built into a tree the way the HTML parser
-- would build it, and everything the allowlist does not name is dropped.
-- What is left is a tree of plain data ('Node'), which
-- "Wiki.Core.Markdown.Render" turns into Halogen elements; so a script, an
-- event handler or a @javascript:@ URL in a page never reaches the page.
--
-- __Elements__ ('allowedElements'): formatting (@b@, @i@, @em@, @strong@,
-- @u@, @s@, @sub@, @sup@, @mark@, @small@, @abbr@, @kbd@, @code@, @span@,
-- @br@), links (@a@), structure (@h1@ to @h6@, @div@, @p@, @details@,
-- @summary@, @blockquote@, @pre@, @hr@, @ul@, @ol@, @li@, @dl@, @dt@, @dd@, @table@,
-- @caption@, @thead@, @tbody@, @tfoot@, @tr@, @th@, @td@, @figure@,
-- @figcaption@) and media (@img@, @video@, @audio@, @source@). An element
-- that is not among them is dropped and its content kept, as for a @font@
-- whose text should still show, except the ones whose content is code or
-- something other than text ('droppedElements': @script@, @style@,
-- @iframe@, @svg@ and the like), which go with everything in them.
--
-- __Attributes__ ('allowedAttributes'): @class@, @id@ and @title@ on every
-- element, and on the elements they mean something on: @href@ (@a@), @src@
-- (@img@, @video@, @audio@, @source@), @alt@ (@img@), @width@ and @height@
-- (@img@, @video@; @width@ also on @table@, @th@, @td@), @colspan@ and
-- @rowspan@ (@th@, @td@), @open@ (@details@), @controls@ (@video@,
-- @audio@), @poster@ (@video@) and @start@ (@ol@). Numbers must be numbers,
-- and a URL must be relative or have one of the schemes 'urlAllowed'
-- admits. Names are read without regard to case, and of two attributes with
-- one name the first counts, as in a browser.
--
-- __Where HTML is read.__ A raw block is read as one document
-- ('parseHtml'), in which an element left open ends where the block ends.
-- Tags among the text of a paragraph (or a heading, a cell, a link's text)
-- are read together with the Markdown between them ('parseFragments'), so
-- that @\<kbd>Ctrl\<\/kbd>@ or @\<mark>a *b*\<\/mark>@ hold what is between
-- their tags: the Markdown is kept as it is, as content of the elements
-- around it. There only elements that may be in a paragraph count
-- ('phrasingElements'): a @div@ among the text is dropped and its content
-- kept, since a paragraph cannot hold one.
--
-- __As a browser would.__ The tree is built with the HTML parser's rules
-- that decide where an element ends when its end tag is missing: a block
-- ends an open @p@, an @li@ ends the @li@ before it, a @dt@ or @dd@ the one
-- before, an @a@ an open @a@, a row or a cell the one before it; a row
-- straight in a @table@ gets the @tbody@ the parser would give it, and a
-- cell the row; text or an element straight in a table, a section or a row
-- (where the parser would move it out in front of the table) is dropped; an
-- end tag closes the elements opened after its own, and one with nothing to
-- close is ignored; the newline that starts a @pre@ is dropped. So the tree
-- written out as markup (as the prerender does) reads back as the same
-- tree. What is simplified: formatting closed by a misnested end tag is not
-- reopened afterwards (the parser's \"adoption agency\"), and a @table@
-- inside a table but outside a cell is dropped rather than ending the first.
module Wiki.Core.Markdown.Html
  ( -- * The tree
    Node (..)
  , Attribute

    -- * Reading HTML
  , Fragment (..)
  , Context (..)
  , parseHtml
  , parseFragments
  , htmlText

    -- * The allowlist
  , allowedElements
  , phrasingElements
  , droppedElements
  , allowedAttributes
  , UrlUse (..)
  , urlAllowed
  )
where

import Data.Text qualified as T
import Protolude
import Text.HTML.TagSoup (Tag (..), parseTags)
import Wiki.Core.Markdown.Link (urlScheme)

-- | An attribute the allowlist admits: its name, lowercase, and its value.
-- A URL is kept as written, for the renderer to resolve as it resolves the
-- Markdown's links.
type Attribute = (Text, Text)

-- | HTML that the allowlist admits, with @a@ for whatever is between the
-- tags that is not HTML (the Markdown among them).
data Node a
  = -- | An allowed element: its name, lowercase, its allowed attributes in
    -- the order written, and its children.
    Element Text [Attribute] [Node a]
  | -- | Text, with its character references decoded. Never empty.
    TextNode Text
  | -- | Something that was not HTML, kept where it was.
    Content a
  deriving stock (Eq, Show, Functor)

-- | What 'parseFragments' reads: HTML, or something else between it.
data Fragment a
  = -- | Markup as written: a tag, a comment, or several.
    Markup Text
  | -- | Something that is not HTML (a piece of Markdown), which becomes a
    -- 'Content' where it falls.
    Markdown a
  deriving stock (Eq, Show)

-- | Where the HTML is.
data Context
  = -- | Where blocks go: a raw block, a list item, the page.
    Flow
  | -- | Among the text of a paragraph, a heading or a cell: elements that
    -- may be inside a paragraph only.
    Phrasing
  | -- | Among the text of a link: as 'Phrasing', and no @a@, since a link
    -- cannot be inside a link.
    PhrasingInLink
  deriving stock (Eq, Show)

-- | A raw block of HTML, read as one document. Blank text before its first
-- element and after its last (the newline CommonMark leaves at the end of
-- a block) is left out, as it shows nothing between blocks.
parseHtml :: Text -> [Node Void]
parseHtml raw = trim (parseFragments Flow [Markup raw])
  where
    trim = reverse . dropWhile blank . reverse . dropWhile blank
    blank = \case
      TextNode t -> T.all isSpace t
      _ -> False

-- | Markup and what is between it, read as one document: an element opened
-- in one piece of markup holds what follows until a later piece closes it,
-- or until the end.
parseFragments :: Context -> [Fragment a] -> [Node a]
parseFragments context fragments = build context (concatMap tokens fragments)
  where
    tokens = \case
      Markup t -> map Tag (parseTags t)
      Markdown a -> [Other a]

-- | The text of some nodes, as a reader sees it, with blocks on lines of
-- their own; what is not HTML gives nothing. For search, which reads a
-- page's text.
htmlText :: [Node a] -> Text
htmlText = foldMap $ \case
  Element name _ children
    | name `elem` ["br", "hr"] -> "\n"
    | name `elem` phrasingElements -> htmlText children
    | otherwise -> "\n" <> htmlText children <> "\n"
  TextNode t -> t
  Content _ -> ""

----------------------------------------------------------------------
-- The allowlist

-- | Every element that is kept.
allowedElements :: [Text]
allowedElements = phrasingElements <> structure <> tableElements
  where
    structure =
      headings <> ["div", "p", "details", "summary", "blockquote", "pre", "hr", "ul", "ol", "li", "dl", "dt", "dd", "figure", "figcaption"]

-- | The elements kept among the text of a paragraph: formatting, links,
-- line breaks and media.
phrasingElements :: [Text]
phrasingElements =
  [ "b"
  , "i"
  , "em"
  , "strong"
  , "u"
  , "s"
  , "sub"
  , "sup"
  , "mark"
  , "small"
  , "abbr"
  , "kbd"
  , "code"
  , "span"
  , "br"
  , "a"
  , "img"
  , "video"
  , "audio"
  , "source"
  ]

tableElements :: [Text]
tableElements = ["table", "caption", "thead", "tbody", "tfoot", "tr", "th", "td"]

-- | The elements dropped with everything in them, rather than with their
-- content kept: code (@script@, @style@, @template@, @noscript@), other
-- documents and plugins (@iframe@, @object@, @embed@, @applet@,
-- @frameset@), drawings and formulas (@svg@, @math@), form fields whose
-- content is not text to read (@textarea@, @select@), and the elements the
-- parser reads as raw text (@title@, @xmp@, @noembed@, @noframes@,
-- @plaintext@). An end tag of the same name, if any, ends what is dropped;
-- an @embed@, which has neither end tag nor content, goes alone.
droppedElements :: [Text]
droppedElements =
  [ "script"
  , "style"
  , "iframe"
  , "object"
  , "embed"
  , "template"
  , "noscript"
  , "applet"
  , "frameset"
  , "svg"
  , "math"
  , "textarea"
  , "select"
  , "title"
  , "xmp"
  , "noembed"
  , "noframes"
  , "plaintext"
  ]

-- | The attributes an element keeps.
allowedAttributes :: Text -> [Text]
allowedAttributes element = ["class", "id", "title"] <> own
  where
    own = case element of
      "a" -> ["href"]
      "img" -> ["src", "alt", "width", "height"]
      "video" -> ["src", "poster", "controls", "width", "height"]
      "audio" -> ["src", "controls"]
      "source" -> ["src"]
      "details" -> ["open"]
      "ol" -> ["start"]
      "table" -> ["width"]
      "th" -> ["width", "colspan", "rowspan"]
      "td" -> ["width", "colspan", "rowspan"]
      _ -> []

-- | What a URL is for.
data UrlUse
  = -- | A link's @href@.
    Href
  | -- | What an image, a video or audio shows: @src@ and @poster@.
    Src
  deriving stock (Eq, Show)

-- | Whether a URL as written may be used: a relative one (a path, which the
-- wiki reads as a page or an attachment, or a fragment), or one with the
-- scheme @http@, @https@ or @attachment@ (the wiki's own, as in Markdown),
-- and for a link @mailto@ too. Never @javascript:@, @data:@ or anything
-- else. A URL that is used is resolved and checked again by the renderer.
urlAllowed :: UrlUse -> Text -> Bool
urlAllowed use url = case urlScheme url of
  Nothing -> True
  Just scheme -> scheme `elem` ["http", "https", "attachment"] || (use == Href && scheme == "mailto")

-- | An attribute's value, if the attribute is one 'allowedAttributes'
-- admits with a value it admits, as it is kept.
attributeValue :: Text -> Text -> Maybe Text
attributeValue name value = case name of
  "class" -> nonBlank
  "id" -> nonBlank
  "title" -> Just value
  "alt" -> Just value
  "width" -> number
  "height" -> number
  "colspan" -> number
  "rowspan" -> number
  "start" -> case T.stripPrefix "-" stripped of
    Just digits | isNumber' digits -> Just stripped
    _ -> number
  -- Boolean attributes: being there is what counts.
  "open" -> Just ""
  "controls" -> Just ""
  "href" -> url Href
  "src" -> url Src
  "poster" -> url Src
  _ -> Nothing
  where
    stripped = T.strip value
    nonBlank = if T.null stripped then Nothing else Just value
    number = if isNumber' stripped then Just stripped else Nothing
    isNumber' t = not (T.null t) && T.length t <= 6 && T.all isDigit t
    url use = if urlAllowed use value then Just (T.strip value) else Nothing

-- | An element's attributes as kept: names lowercased, the first of each
-- name, then those the allowlist admits.
keptAttributes :: Text -> [(Text, Text)] -> [Attribute]
keptAttributes element attrs =
  [ (name, v)
  | (name, value) <- firstOfEach [(T.toLower k, v) | (k, v) <- attrs]
  , name `elem` allowedAttributes element
  , Just v <- [attributeValue name value]
  ]
  where
    firstOfEach = go []
    go seen = \case
      [] -> []
      (k, v) : rest
        | k `elem` seen -> go seen rest
        | otherwise -> (k, v) : go (k : seen) rest

----------------------------------------------------------------------
-- Building the tree

data Token a = Tag (Tag Text) | Other a

-- | An element being built: its name, attributes and children so far, the
-- last first. The bottom of the stack is the document, named @""@.
data Open a = Open Text [Attribute] [Node a]

data Builder a = Builder
  { stack :: [Open a]
  -- ^ The open elements, the innermost first; never empty.
  , skipping :: Maybe (Text, Int)
  -- ^ Inside a dropped element: its name and how many elements of that
  -- name inside it are open.
  }

build :: forall a. Context -> [Token a] -> [Node a]
build context = finish . foldl' step (Builder [Open "" [] []] Nothing)
  where
    step :: Builder a -> Token a -> Builder a
    step b token = case b.skipping of
      Just (name, depth) -> case token of
        Tag (TagOpen n _) | T.toLower n == name -> b {skipping = Just (name, depth + 1)}
        Tag (TagClose n)
          | T.toLower n == name -> b {skipping = if depth == 0 then Nothing else Just (name, depth - 1)}
        _ -> b
      Nothing -> case token of
        Other a -> b {stack = appendContent (Content a) b.stack}
        Tag (TagText t) -> b {stack = appendContent (TextNode t) b.stack}
        Tag (TagOpen n attrs) -> start (T.toLower n) attrs b
        Tag (TagClose n) -> b {stack = end (T.toLower n) b.stack}
        Tag _ -> b

    start :: Text -> [(Text, Text)] -> Builder a -> Builder a
    start name attrs b
      -- An embed has no end tag, nor content: it goes alone.
      | name == "embed" = b
      | name `elem` droppedElements = b {skipping = Just (name, 0)}
      | not (allowedHere name) = b
      | inTableStructure b.stack && name `notElem` tableElements = b
      | otherwise = case prepare name b.stack of
          Nothing -> b
          Just s
            | name `elem` voidElements -> b {stack = append (Element name kept []) s}
            | otherwise -> b {stack = Open name kept [] : s}
      where
        kept = keptAttributes name attrs

    allowedHere name = case context of
      Flow -> name `elem` allowedElements
      Phrasing -> name `elem` phrasingElements
      PhrasingInLink -> name `elem` phrasingElements && name /= "a"

-- | Text or content, where it may go: not empty, and not straight inside a
-- table, its sections or its rows.
appendContent :: Node a -> [Open a] -> [Open a]
appendContent node s = case node of
  TextNode "" -> s
  _ | inTableStructure s -> s
  _ -> append node s

-- | Add a child to the innermost element, as one text with the text
-- before it if both are text (a comment or a dropped element between them
-- leaves nothing to separate them).
append :: Node a -> [Open a] -> [Open a]
append node = \case
  Open n as cs : rest -> Open n as (merged cs) : rest
  [] -> []
  where
    merged cs = case (node, cs) of
      (TextNode new, TextNode old : older) -> TextNode (old <> new) : older
      _ -> node : cs

inTableStructure :: [Open a] -> Bool
inTableStructure = \case
  Open n _ _ : _ -> n `elem` ["table", "thead", "tbody", "tfoot", "tr"]
  [] -> False

-- | Close the innermost element, adding it to its parent's children. The
-- document is never closed.
closeOne :: [Open a] -> [Open a]
closeOne = \case
  Open name attrs children : rest@(_ : _) -> append (Element name attrs (finishChildren name (reverse children))) rest
  s -> s

closeN :: Int -> [Open a] -> [Open a]
closeN n s = foldl' (\acc _ -> closeOne acc) s [1 .. n]

finish :: Builder a -> [Node a]
finish b = case closeN (length b.stack - 1) b.stack of
  Open _ _ children : _ -> reverse children
  [] -> []

-- | A @pre@'s first newline is not part of its text: the parser drops it.
finishChildren :: Text -> [Node a] -> [Node a]
finishChildren name children = case (name, children) of
  ("pre", TextNode t : rest) -> case T.stripPrefix "\n" t of
    Just "" -> rest
    Just t' -> TextNode t' : rest
    Nothing -> children
  _ -> children

names :: [Open a] -> [Text]
names s = [n | Open n _ _ <- s]

-- | How many elements, from the innermost, to close to close the first one
-- that @wanted@ picks, without going past one that @stop@ picks or the
-- document; 'Nothing' if there is none.
depthOf :: (Text -> Bool) -> (Text -> Bool) -> [Open a] -> Maybe Int
depthOf wanted stop = go 0 . names
  where
    go i = \case
      [] -> Nothing
      [_] -> Nothing
      n : rest
        | wanted n -> Just i
        | stop n -> Nothing
        | otherwise -> go (i + 1) rest

-- | Close the element @wanted@ picks, and those inside it, if it is open.
closeIf :: (Text -> Bool) -> (Text -> Bool) -> [Open a] -> [Open a]
closeIf wanted stop s = maybe s (\i -> closeN (i + 1) s) (depthOf wanted stop s)

-- | Close the elements inside the one @wanted@ picks, leaving it innermost.
closeInside :: (Text -> Bool) -> (Text -> Bool) -> [Open a] -> Maybe [Open a]
closeInside wanted stop s = (`closeN` s) <$> depthOf wanted stop s

-- | The stack an element starts on: the elements its start ends closed, and
-- the ones the parser would put around it opened; 'Nothing' when the parser
-- ignores it there.
prepare :: Text -> [Open a] -> Maybe [Open a]
prepare name s0
  | name `elem` ["caption", "thead", "tbody", "tfoot"] = closeInside (== "table") never s0
  | name == "tr" = do
      s <- closeInside (`elem` ["thead", "tbody", "tfoot", "table"]) never s0
      pure (if top s == Just "table" then opened "tbody" s else s)
  | name `elem` ["td", "th"] = do
      s <- closeInside (`elem` ["tr", "thead", "tbody", "tfoot", "table"]) never s0
      pure $ case top s of
        Just "table" -> opened "tr" (opened "tbody" s)
        Just "tr" -> s
        _ -> opened "tr" s
  | otherwise = Just (closeHeading (closeA (closeP (closeItems s0))))
  where
    never = const False
    opened n s = Open n [] [] : s
    top s = head (names s)
    -- An li ends the li it is in, and a dt or dd the dt or dd, unless a
    -- block other than a div or a p is in between.
    closeItems s
      | name == "li" = closeIf (== "li") listStop s
      | name `elem` ["dt", "dd"] = closeIf (`elem` ["dt", "dd"]) listStop s
      | otherwise = s
    listStop n = n `elem` specialElements && n `notElem` ["div", "p"]
    -- A block ends the paragraph it starts in.
    closeP s
      | name `elem` closesParagraph = closeIf (== "p") (`elem` scopeBoundaries) s
      | otherwise = s
    closeA s
      | name == "a" = closeIf (== "a") (`elem` scopeBoundaries) s
      | otherwise = s
    -- A heading started straight inside a heading ends it.
    closeHeading s
      | name `elem` headings, Just h <- top s, h `elem` headings = closeOne s
      | otherwise = s

-- | The stack after an end tag: the element it names closed with those
-- inside it, if it is open in reach; otherwise as it was.
end :: Text -> [Open a] -> [Open a]
end name s
  | name `elem` voidElements || name `notElem` allowedElements = s
  | name == "table" = closeIf (== name) (const False) s
  | name `elem` tableElements = closeIf (== name) (== "table") s
  -- Any heading's end tag ends the open heading, whatever its level.
  | name `elem` headings = closeIf (`elem` headings) (`elem` scopeBoundaries) s
  | otherwise = closeIf (== name) (`elem` scopeBoundaries) s

voidElements :: [Text]
voidElements = ["br", "hr", "img", "source"]

-- | The elements an end tag or a paragraph's end does not look past.
scopeBoundaries :: [Text]
scopeBoundaries = ["table", "caption", "td", "th"]

-- | The block elements whose start ends an open @p@.
closesParagraph :: [Text]
closesParagraph =
  headings
    <> ["blockquote", "details", "div", "dl", "dd", "dt", "figcaption", "figure", "hr", "li", "ol", "p", "pre", "summary", "table", "ul"]

-- | Of the allowed elements, those the parser counts as special: an @li@,
-- @dt@ or @dd@ does not end one of its kind past them (except a @div@ or a
-- @p@).
specialElements :: [Text]
specialElements =
  [ "blockquote"
  , "details"
  , "summary"
  , "div"
  , "p"
  , "pre"
  , "ul"
  , "ol"
  , "li"
  , "dl"
  , "dt"
  , "dd"
  , "figure"
  , "figcaption"
  ]
    <> headings
    <> tableElements

headings :: [Text]
headings = ["h1", "h2", "h3", "h4", "h5", "h6"]
