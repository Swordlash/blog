-- | 'Wiki.App.Backlinks' says which pages a page's links lead to, as the
-- page view follows them: what a page's backlinks, its list "Linked
-- from" (issue #189), are counted from. Every backend counts them with
-- these functions: the demo's in-memory backend resolves every page's
-- links each time a list is read ("Wiki.App.Backend.Mem.State"), and the
-- server keeps each link with the page it leads to, and resolves the link
-- again when a change to the tree may lead it elsewhere
-- ("Wiki.Server.Storage.Rows"). The contract tests run both, so the two
-- agree.
--
-- A link counts as the page shows it and a click follows it:
--
-- * the links are those 'Wiki.Core.Markdown.Render.linkDestinations'
--   finds, the ones the renderer makes ('pageLinks');
-- * a destination is read by 'Wiki.App.Route.resolvePageLink', the
--   function the page view resolves its links with
--   ("Wiki.App.View.Body"), into the route a click goes to;
-- * the route is read as the shell reads it when it shows that route
--   ('routeTarget'): a page's address, with an old address read as
--   'Wiki.Core.Space.pagesAt' reads it; a space's address, its home page;
--   a permanent address, the page with that id.
--
-- Two things differ from a click, on purpose. A link is followed among
-- every space, not only those the reader may see, so that a page's list
-- does not depend on who stored it: the list then leaves out the pages
-- the reader may not view. And the wiki's front page and the pages of an
-- encrypted space are neither listed nor given a list ('counted'): the
-- front page is no page of a space, and the server cannot read an
-- encrypted page's text.
module Wiki.App.Backlinks
  ( -- * A page's links
    pageLinks

    -- * Where a link leads
  , LinkedSpace (..)
  , linkedSpace
  , LinkWorld (..)
  , linkTarget
  , routeTarget
  , counted
  )
where

import Data.Map.Strict qualified as Map
import Data.Type.Equality (type (~))
import Protolude
import Wiki.App.Route (PageLink (..), Route, resolvePageLinkWith)
import Wiki.App.Route qualified as Route
import Wiki.Core.HomePage (HomePage, isHomeSpace)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Markdown (Destination (..), classifyDestination, linkDestinations, parseMarkdown)
import Wiki.Core.Path (TreeNode (..), findChild, resolvePath)
import Wiki.Core.Permission (spaceChain)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..), pagePath, pagesAtWith, rootPage)

-- | 'pageLinks' is the destinations of a page's links that may lead to a
-- page, each once, in the order they first appear: the paths and the
-- permanent addresses among the links the page shows. An attachment, a
-- URL and a place on the same page (@#section@) lead to no page. Markdown
-- that does not parse shows as text, with no links.
pageLinks :: Text -> [Text]
pageLinks body = ordNub (filter toPage (either (const []) linkDestinations (parseMarkdown body)))
  where
    toPage destination = case classifyDestination destination of
      ToPath _ -> True
      ToPageId {} -> True
      _ -> False

-- | 'LinkedSpace' is one space and its pages, looked up by id and by their
-- parent and slug: what following links in a space, or into it, reads.
data LinkedSpace node = LinkedSpace
  { space :: Space
  , byId :: Map PageId node
  , children :: Map (Maybe PageId, Slug) node
  }

-- | A space as 'LinkedSpace', with its pages.
linkedSpace :: (TreeNode node, NodeId node ~ PageId) => Space -> [node] -> LinkedSpace node
linkedSpace space nodes =
  LinkedSpace
    { space
    , byId = Map.fromList [(nodeId n, n) | n <- nodes]
    , children = Map.fromList [((nodeParent n, nodeSlug n), n) | n <- nodes]
    }

-- | 'LinkWorld' is what following a link reads besides the page the link
-- is on: every space, and the pages of each, read as the caller keeps
-- them, in a monad (the server reads a space's pages from its database
-- the first time it needs them).
data LinkWorld m node = LinkWorld
  { spaces :: [Space]
  -- ^ Every space but the wiki's front page's.
  , pagesIn :: SpaceId -> m (Maybe (LinkedSpace node))
  -- ^ A space's pages, or 'Nothing' for a space not among 'spaces'.
  , exists :: PageId -> m Bool
  -- ^ Whether a page with this id is in one of 'spaces'.
  }

-- | 'linkTarget' is the page a destination written on a page leads to, if
-- any: the page with the link (by its id, among its space's pages), and
-- the destination as written. 'Nothing' for a link that leads to no page
-- of 'LinkWorld''s spaces, and for a page that is not among its space's
-- pages.
linkTarget :: (Monad m, TreeNode node, NodeId node ~ PageId) => LinkWorld m node -> LinkedSpace node -> PageId -> Text -> m (Maybe PageId)
linkTarget world here pid destination = fromMaybe (pure Nothing) $ do
  path <- pagePath here.space (`Map.lookup` here.byId) pid
  PageLink r _ <-
    resolvePageLinkWith
      world.spaces
      (map (\s -> s.slug) (spaceChain world.spaces here.space.id))
      (rootPage here.space)
      (`Map.lookup` here.byId)
      (\parent slug -> Map.lookup (parent, slug) here.children)
      path
      destination
  pure (routeTarget world r)

-- | 'routeTarget' is the page a route shows, as the shell shows it: a
-- page's address ('Page', 'PageAtVersion') the page at that path in that
-- space, an old address too ('pagesAtWith'); a space's address ('Space')
-- its home page; a permanent address ('PermanentLink') the page with that
-- id. Any other route shows no one page.
routeTarget :: (Monad m, TreeNode node, NodeId node ~ PageId) => LinkWorld m node -> Route -> m (Maybe PageId)
routeTarget world = \case
  Route.Page sp path -> pageIn sp path
  Route.PageAtVersion sp path _ -> pageIn sp path
  Route.Space sp -> inSpace sp $ \pages -> pure (pages.space.homePage >>= \h -> nodeId <$> Map.lookup h pages.byId)
  Route.PermanentLink pid _ -> (\found -> guard found $> pid) <$> world.exists pid
  _ -> pure Nothing
  where
    inSpace sp found = case lastMay =<< rightToMaybe (resolvePath (findChild world.spaces) sp) of
      Nothing -> pure Nothing
      Just s -> world.pagesIn s.id >>= maybe (pure Nothing) found
    pageIn sp path = inSpace sp $ \pages ->
      pure (nodeId <$> (lastMay =<< rightToMaybe (pagesAtWith pages.space (`Map.lookup` pages.byId) (\parent slug -> Map.lookup (parent, slug) pages.children) path)))

-- | 'counted' is whether a space's pages have backlinks, and are counted
-- among other pages' backlinks: every space's but the wiki's front
-- page's, and an encrypted space's, whose text the server cannot read.
counted :: HomePage -> Space -> Bool
counted home s = not (isHomeSpace home s.id) && isNothing s.encryption
