{-# LANGUAGE DeriveAnyClass #-}

-- | Pages: Markdown in a tree within a space.
module Wiki.Core.Page
  ( Page (..)
  , PageSummary (..)
  , summaryOf
  , treePages
  , templatePages
  , childPages
  , positionPage
  , placedPage
  , pageTreeOrder
  , pageNumber
  , savedAs

    -- * The title line
  , titleLine
  , withTitleLine
  , retitled
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.List (findIndex)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Data.Type.Equality (type (~))
import Protolude
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder, Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.PageKind (PageKind)
import Wiki.Core.Path (TreeNode (..), findChild, resolveUnder)
import Wiki.Core.Slug
import Wiki.Core.Version (Author)

-- | 'Page': a page. Pages form a tree within one space, so a page's parent,
-- and the lookups "Wiki.Core.Path" is given for pages, are among the pages
-- of its own space only.
data Page = Page
  { id :: PageId
  , space :: SpaceId
  -- ^ The space the page is in.
  , parent :: Maybe PageId
  -- ^ The page it is a child of, in the same space, or 'Nothing' for a
  -- top-level page of the space.
  , title :: Text
  , slug :: Slug
  -- ^ Its address segment, unique among its siblings.
  , body :: Text
  -- ^ The Markdown source, which is what is stored; the page is rendered
  -- from it wherever it is shown.
  , attachments :: [Attachment]
  , createdAt :: UTCTime
  -- ^ Set by the backend when the page is created.
  , updatedAt :: UTCTime
  -- ^ Set by the backend on every save.
  , position :: Int
  -- ^ Its position among its siblings, set by hand, for a space that
  -- orders its pages 'Wiki.Core.Order.ByHand'.
  , template :: Bool
  -- ^ Whether it is one of its space's templates ("Wiki.Core.Template").
  -- A template is a page like any other (it has a history, comments and
  -- the space's permissions), but it is listed under the space's
  -- "Templates" rather than in its tree, left out of a search that does
  -- not ask for templates, and offered as the start of a new page.
  , kind :: PageKind
  -- ^ What the page is, a document or a presentation
  -- ("Wiki.Core.PageKind"). A property of the page, not of a version.
  -- In JSON the field may be absent, which means a document.
  , createdBy :: Maybe Author
  -- ^ Who wrote the page's first version, as the page view's byline says
  -- (WP5.55 of docs/PLAN.md): read by the backend from the history, as
  -- the blog's author of a post is ('Wiki.Core.Blog.PostDetails'), and
  -- never stored with the page. 'Nothing' for a page without such a
  -- version (an imported page, the guide's) or one nobody is known to
  -- have saved. In JSON the field may be absent, which means 'Nothing'.
  , updatedBy :: Maybe Author
  -- ^ Who saved the page's latest version, read the same way.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Page where
  type NodeId Page = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

instance Sibling Page where
  siblingName p = p.title
  siblingCreatedAt p = p.createdAt
  siblingPosition p = p.position

-- | 'PageSummary' is a page without its Markdown body and its
-- attachments. A list of a space's pages holds summaries
-- ('Wiki.App.Backend.listPages'). The sidebar's tree, the space's view,
-- the blog's list of posts and the editor's choice of a parent need only
-- these fields. The body is fetched with the page alone
-- ('Wiki.App.Backend.getPage'), so a list stays small however long the
-- pages are.
data PageSummary = PageSummary
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , title :: Text
  , slug :: Slug
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  , position :: Int
  , template :: Bool
  , kind :: PageKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode PageSummary where
  type NodeId PageSummary = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

instance Sibling PageSummary where
  siblingName p = p.title
  siblingCreatedAt p = p.createdAt
  siblingPosition p = p.position

-- | The summary of a page: the page without its body and attachments.
summaryOf :: Page -> PageSummary
summaryOf p =
  PageSummary
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title = p.title
    , slug = p.slug
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position = p.position
    , template = p.template
    , kind = p.kind
    }

-- | The pages a space's tree shows: all except its templates, which are
-- listed separately ('templatePages'). A page under a template belongs to
-- the template and is left out with it.
treePages :: [PageSummary] -> [PageSummary]
treePages pages = [p | p <- pages, not (underTemplate p)]
  where
    byId = Map.fromList [(p.id, p) | p <- pages]
    underTemplate p = p.template || maybe False underTemplate (p.parent >>= (`Map.lookup` byId))

-- | A space's templates, among its pages, by title.
templatePages :: [PageSummary] -> [PageSummary]
templatePages pages = sortOn (\p -> p.title) [p | p <- pages, p.template]

-- | The pages under a page ('Nothing' for the space's top level), among the
-- pages of its space, in the space's page order
-- ('Wiki.Core.Space.pageOrder'). Every list of pages uses it.
childPages :: (Sibling p, NodeId p ~ PageId) => ChildOrder -> [p] -> Maybe PageId -> [p]
childPages = childrenInOrder

-- | All the pages of a space as one list, each followed by the pages under
-- it, in the space's page order.
pageTreeOrder :: (Sibling p, NodeId p ~ PageId) => ChildOrder -> [p] -> [p]
pageTreeOrder order = treeOrder (const order)

-- | 'pageNumber' is a page's number, by its path among the pages of its
-- space, given the space's root page ('Wiki.Core.Space.rootPage'): its
-- position under its parent, from 1, in the space's page order, whether
-- that order is by hand or not. A box's number may start with it
-- ("Wiki.Core.Markdown.Box"). Templates are numbered among the templates
-- under the same parent, and the other pages without them. The root, the
-- space's home page, is not one of the numbered pages: it is 0, as the
-- boxes before a page's first section are in section 0. 'Nothing' when no
-- page has the path.
pageNumber :: Maybe PageId -> ChildOrder -> [PageSummary] -> [Slug] -> Maybe Int
pageNumber root order pages path = do
  p <- lastMay =<< rightToMaybe (resolveUnder (root >>= \r -> find (\x -> x.id == r) pages) (findChild pages) path)
  if Just p.id == root
    then Just 0
    else (+ 1) <$> findIndex (\s -> s.id == p.id) [s | s <- childPages order pages p.parent, s.template == p.template]

-- | The page at another position among its siblings. (A function, since a
-- record update of @position@ cannot tell a page's field from a space's
-- or a summary's where they are in scope. The page is built field by field
-- for the same reason.)
positionPage :: Int -> Page -> Page
positionPage position p =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title = p.title
    , slug = p.slug
    , body = p.body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position
    , template = p.template
    , kind = p.kind
    , createdBy = p.createdBy
    , updatedBy = p.updatedBy
    }

-- | The page at another place in its space: under this parent ('Nothing'
-- for none), with this slug and this position among its new siblings. (A
-- function for the reason 'positionPage' is one.)
placedPage :: Maybe PageId -> Slug -> Int -> Page -> Page
placedPage parent slug position p =
  Page
    { id = p.id
    , space = p.space
    , parent
    , title = p.title
    , slug
    , body = p.body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position
    , template = p.template
    , kind = p.kind
    , createdBy = p.createdBy
    , updatedBy = p.updatedBy
    }

-- | A page saved with a new title and text at a time: its new version. The
-- version is later than the one it replaces even if the clock says
-- otherwise, so that no two versions of a page have the same time and an
-- editor open on the page sees that it has changed. A save, an import
-- that takes the imported page, and the guide's update all make a new
-- version this way. Who saved it is not known here: 'updatedBy' stays as it
-- was, for the backend to read again from the version it keeps.
savedAs :: UTCTime -> Text -> Text -> Page -> Page
savedAs time title body p =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title
    , slug = p.slug
    , body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = if time > p.updatedAt then time else addUTCTime 0.000001 p.updatedAt
    , position = p.position
    , template = p.template
    , kind = p.kind
    , createdBy = p.createdBy
    , updatedBy = p.updatedBy
    }

-- | 'titleLine' is the title a page's Markdown gives on its first line, a
-- level-one heading (@# Title@): the text after the @#@, without a closing
-- run of @#@ and without the spaces around it. 'Nothing' when the first
-- line is not a level-one heading. A page's text starts with its title
-- line (WP5.39 of docs/PLAN.md): the editor keeps the line there, and the
-- title it saves is this line's text.
titleLine :: Text -> Maybe Text
titleLine body = case T.uncons firstLine of
  Just ('#', rest)
    | T.null rest -> Just ""
    | Just (c, _) <- T.uncons rest, c == ' ' || c == '\t' -> Just (unclosed (T.stripEnd (fst (withoutAttributes (T.strip rest)))))
  _ -> Nothing
  where
    firstLine = T.dropWhileEnd (== '\r') (T.takeWhile (/= '\n') body)
    -- A heading may end with a run of @#@ after a space (@# Title ##@),
    -- which is not part of its text (CommonMark's closing sequence).
    unclosed t
      | T.null run = t
      | T.null before = ""
      | isSpace (T.last before) = T.stripEnd before
      | otherwise = t
      where
        run = T.takeWhileEnd (== '#') t
        before = T.dropEnd (T.length run) t

-- | A page's Markdown with a new title: its title line says the new title,
-- and a text without one gets one ('withTitleLine'). What renaming a page
-- writes, so that the title and the first line stay the same.
retitled :: Text -> Text -> Text
retitled title body = case titleLine trimmed of
  Just _ -> headingOf title <> attributes <> T.dropWhile (/= '\n') trimmed
  Nothing -> withTitleLine title body
  where
    trimmed = withTitleLine title body
    -- The heading's attributes (@{#id .class}@), kept: links to its id
    -- go on working.
    attributes = snd (withoutAttributes (T.strip (T.takeWhile (/= '\n') trimmed)))

-- | A heading's text without the attributes at its end (@Old {#stable
-- .lead}@), and those attributes with the space before them, or nothing.
withoutAttributes :: Text -> (Text, Text)
withoutAttributes t
  | Just inner <- T.stripSuffix "}" t
  , (before, block) <- T.breakOnEnd " {" inner
  , not (T.null before)
  , not (T.any (`elem` ['{', '}']) block) =
      (T.dropEnd 2 before, " {" <> block <> "}")
  | otherwise = (t, "")

-- | The title line for a title: @# Title@, and a closing @#@ after a title
-- that ends in a space and @#@ (@Release #@, or @#@ alone), which
-- 'titleLine' would otherwise read as a closing run, not as the title's.
headingOf :: Text -> Text
headingOf title
  | titleLine plain == Just title = plain
  | otherwise = plain <> " #"
  where
    plain = "# " <> title

-- | A page's Markdown with its title line first: unchanged when it starts
-- with one (after blank lines, which are dropped), and otherwise with
-- @# title@ and a blank line put before it. The editor opens a page this
-- way, so that a page written before titles were lines gets one.
withTitleLine :: Text -> Text -> Text
withTitleLine title body
  | isJust (titleLine trimmed) = trimmed
  | T.null (T.strip body) = headingOf title <> "\n\n"
  | otherwise = headingOf title <> "\n\n" <> trimmed
  where
    trimmed = dropBlankLines body
    dropBlankLines t =
      let (line, rest) = T.breakOn "\n" t
       in if not (T.null rest) && T.all isSpace line then dropBlankLines (T.drop 1 rest) else t
