-- | What the backend over HTTP keeps of what it has read, so that a view
-- whose data has been seen already shows it at once rather than after a
-- fetch (decision 18 of the plan): kept per entity, as the reads return
-- them, and let go when the wiki changes.
--
-- The rule for letting go is the simplest that is right: any write the
-- client makes empties the cache, since a write can change much more than
-- what it names (a moved space moves every path under it; a new space
-- grants its creator a permission, which changes the session; a save
-- discards the saver's draft). A draft's own writes are the exception:
-- they change that draft and nothing else, and they are made every few
-- seconds while someone types, so they put the draft in its place instead.
--
-- What someone else changes on the server is not seen until this client
-- writes, or the page is loaded again: the cache lives as long as the page.
module Wiki.App.Backend.Http.Cache
  ( Cache (..)
  , emptyCache
  , cachedPage
  , withSession
  , withSpaces
  , withSpaceAt
  , withPages
  , withPageAt
  , withDraft
  , afterWrite
  )
where

import Data.Map.Strict qualified as Map
import Protolude
import Wiki.App.Backend (Session)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Page (Page)
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)

-- | Each read's answer, as it came back.
data Cache = Cache
  { session :: Maybe Session
  , spaces :: Maybe [Space]
  -- ^ 'Wiki.App.Backend.listSpaces'.
  , spaceAt :: Map [Slug] Space
  -- ^ 'Wiki.App.Backend.getSpace', by path.
  , pages :: Map SpaceId [Page]
  -- ^ 'Wiki.App.Backend.listPages', by space.
  , pageAt :: Map (SpaceId, [Slug]) Page
  -- ^ 'Wiki.App.Backend.getPage', by space and path.
  , drafts :: Map PageId (Maybe Draft)
  -- ^ 'Wiki.App.Backend.getDraft', by page: the signed-in user's draft, or
  -- that they have none.
  }
  deriving stock (Eq, Show)

emptyCache :: Cache
emptyCache = Cache {session = Nothing, spaces = Nothing, spaceAt = mempty, pages = mempty, pageAt = mempty, drafts = mempty}

-- | The page at a path in a space, if it has been read: by itself, or with
-- every page of its space ('withPages'), which is how the space's view
-- has them, so that a page opened from there needs no fetch.
cachedPage :: SpaceId -> [Slug] -> Cache -> Maybe Page
cachedPage sid path c =
  Map.lookup (sid, path) c.pageAt
    <|> (Map.lookup sid c.pages >>= \ps -> rightToMaybe (resolvePath (findChild ps) path) >>= lastMay)

-- | The cache with what a read gave, one function per read.
withSession :: Session -> Cache -> Cache
withSession s c = c {session = Just s}

withSpaces :: [Space] -> Cache -> Cache
withSpaces ss c = c {spaces = Just ss}

withSpaceAt :: [Slug] -> Space -> Cache -> Cache
withSpaceAt path s c = c {spaceAt = Map.insert path s c.spaceAt}

withPages :: SpaceId -> [Page] -> Cache -> Cache
withPages sid ps c = c {pages = Map.insert sid ps c.pages}

withPageAt :: SpaceId -> [Slug] -> Page -> Cache -> Cache
withPageAt sid path p c = c {pageAt = Map.insert (sid, path) p c.pageAt}

-- | The signed-in user's draft of a page as it now is ('Nothing' for
-- none); or, given 'Nothing' at all, not known.
withDraft :: PageId -> Maybe (Maybe Draft) -> Cache -> Cache
withDraft pid d c = c {drafts = Map.alter (const d) pid c.drafts}

-- | The cache after a write that changed the wiki: nothing in it can be
-- trusted any more.
afterWrite :: Cache -> Cache
afterWrite = const emptyCache
