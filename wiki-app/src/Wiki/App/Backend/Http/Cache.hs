-- | 'Cache' is the cache of API responses kept by the HTTP backend, the
-- one that talks to @wiki-server@ over its API.
--
-- The application talks to the wiki through 'Wiki.App.Backend.MonadWiki'
-- ("Wiki.App.Backend"), which has several implementations. The HTTP
-- backend ("Wiki.App.Backend.Http") talks to @wiki-server@ over its API.
-- The in-memory backend ("Wiki.App.Backend.Mem") keeps the wiki in the
-- browser, for the demo, and saves it in IndexedDB. The tests have their
-- own. Only the HTTP backend waits for the network, so only it has a
-- cache.
--
-- 'Cache' holds the responses (the JSON bodies the API returns to a read)
-- that the program has already fetched: pages, spaces, the
-- administration's directory of users, and so on, one entry per record,
-- in the shape the server sent them. A view whose data was fetched already
-- renders from the cache at once, instead of rendering a loading state and
-- fetching the same data again. This is decision 18 of the plan: a view
-- renders from the cache when it can, and otherwise renders "Loading" and
-- fetches in its initializer. Entries are dropped when the wiki changes,
-- so that nothing stale is shown.
--
-- There is one cache per browser tab. It belongs to one wiki (the server
-- the page was loaded from) and to one signed-in user: signing in or out
-- empties it. It lives as long as the page. It holds at most what this tab
-- has read since this client's last write, because a write empties it
-- (the exceptions, drafts and comments, are below).
--
-- Page content is cached only until the reader first goes to another
-- route (WP5.14 of docs/PLAN.md). Page content is the pages, the lists of
-- a space's pages, the details of a blog's posts, the version lists, the
-- searches and the directory's page counts ('forgetPageContent'). Until
-- then, the cache holds what the server prerendered the page with, and
-- the program's first render matches that page. When the route changes,
-- the backend drops the page content ('Wiki.App.Backend.endPreload') and
-- fetches it on every read from then on. So a page shown again is fetched
-- again, and shows someone else's edit made meanwhile. This also keeps
-- the cache small: what stays cached after the first route is the
-- session, the spaces, this user's drafts, the versions (a saved version
-- never changes), the comment threads and notifications the live channel
-- keeps up to date, the watches, and the administration's data.
--
-- Any write this client makes empties the whole cache ('afterWrite'). The
-- rule is coarse on purpose, because a write can change much more than the
-- record it names. Moving a space changes the path of everything under it.
-- Creating a space grants its creator a permission, which changes the
-- session. Saving a page discards the saver's draft. This does not defeat
-- the cache's purpose. The cache is for moving between views that only
-- read, which is most of what a tab does. Writes are rare by comparison,
-- and after one, the next views fetch their data once and are cached
-- again.
--
-- Saving a draft is the first exception: it changes that draft and nothing
-- else, and it happens every few seconds while someone types, so the new
-- draft replaces the cached one instead.
--
-- A change someone else makes to what stays cached (a space renamed, a
-- user's rights changed) is not seen until this client writes, or the
-- page is reloaded. Page content is fetched again after the first route,
-- as said above. Before that, a page save reported by the live channel
-- ("Wiki.App.Live") drops the cached pages, and the other entries a save
-- changes ('afterEvent').
--
-- Refusals are cached too. 'NotFound' (the space is not there) and
-- 'Forbidden' (the reader may not see it) are what the view shows. The
-- server may prerender an error page for such a refusal
-- ("Wiki.App.Backend.Http.Preload"). The program renders the same error
-- page only if that error is already in the cache (the prerender put it
-- there); otherwise it would render a loading state and fetch. Both
-- refusals depend on the wiki's content and permissions, so they can go
-- stale like any response, and are dropped with the rest. 'Unreachable'
-- is never cached: a retry may well work.
--
-- A page's comment threads ("Wiki.Core.Comment") are cached by page, and
-- writing a comment is the second exception to emptying the cache. A
-- comment changes its page's threads and nothing else, so the write's
-- result is applied to the cached threads ('Wiki.Api.Events.applyEvent').
-- Emptying the cache would make the page itself load again. Comment
-- changes made elsewhere arrive over the live channel ("Wiki.App.Live"),
-- which updates the cached threads, and removes a page's threads
-- ('forgetThreads') when it stops listening to that page.
--
-- The cache also holds:
--
-- * the number of pages in each space, which the directory of spaces
--   shows;
-- * the details a blog lists its posts with: each post's first author and
--   its number of comments (a comment write drops them);
-- * search results, by query: the server prerenders the search results
--   page with its hits, and the program then shows them at once;
-- * for the administration, which the server prerenders: the directory of
--   the wiki's users and groups, the wiki's settings and invitations, and
--   the server's own settings (without their secrets);
-- * an invitation as its link shows it to the invited person, by the
--   secret in the link;
-- * the user's notifications, which the bell shows (WP4.13 of
--   docs/PLAN.md), whether the user watches a page or a space, and which
--   of the mentioned logins belong to users: the server prerenders the
--   header and the page with them.
--
-- A notification received over the live channel is added at the front of
-- the cached ones ('withNotice'). Marking notifications read, or choosing
-- a watch, puts the server's response in the cache and changes nothing
-- else.
module Wiki.App.Backend.Http.Cache
  ( Cache (..)
  , emptyCache
  , kept
  , cachedPage
  , cachedSearch
  , withSession
  , withSpaces
  , withPageCounts
  , withSpaceAt
  , withPages
  , withPostDetails
  , withPageAt
  , withDraft
  , withSearch
  , withVersions
  , withVersion
  , withDirectory
  , withSettings
  , withInvitations
  , withInvitationAt
  , withServerSettings
  , withBackups
  , withActivity
  , withStatus
  , forgetActivity
  , forgetStatus
  , withThreads
  , withPeople
  , withNotices
  , withNotice
  , forgetNotices
  , withWatch
  , cachedPeople
  , afterComment
  , afterEvent
  , forgetThreads
  , forgetPageContent
  , afterWrite
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Protolude
import Wiki.Api.Account (InvitationInfo, InvitationToken)
import Wiki.Api.Activity (Activity)
import Wiki.Api.Admin (Directory, Invitations, ServerStatus, WikiSettings)
import Wiki.Api.Backups (Backups)
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.ServerSettings (ServerSettings)
import Wiki.App.Backend (Session, WikiError (..))
import Wiki.Core.Blog (PostDetails)
import Wiki.Core.Comment (Thread)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Notification (Notification, Watch, WatchTarget)
import Wiki.Core.Page (Page, PageSummary)
import Wiki.Core.Search (SearchHit, SearchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.Version (Author, Version, VersionInfo)

-- | The cached responses, one field for each of 'Wiki.App.Backend.MonadWiki''s
-- read methods ('Wiki.App.Backend.getPage', 'Wiki.App.Backend.listPages',
-- …) and of the other backend classes' reads. A field holds what the read
-- returned, or the refusal it returned (see 'kept').
data Cache = Cache
  { session :: Maybe Session
  , spaces :: Maybe [Space]
  -- ^ 'Wiki.App.Backend.listSpaces'.
  , pageCounts :: Maybe (Map SpaceId Int)
  -- ^ 'Wiki.App.Backend.pageCounts'.
  , spaceAt :: Map [Slug] (Either WikiError Space)
  -- ^ 'Wiki.App.Backend.getSpace', by path.
  , pages :: Map SpaceId (Either WikiError [PageSummary])
  -- ^ 'Wiki.App.Backend.listPages', by space.
  , postDetails :: Map SpaceId (Either WikiError (Map PageId PostDetails))
  -- ^ 'Wiki.App.Backend.postDetails', by space.
  , pageAt :: Map (SpaceId, [Slug]) (Either WikiError Page)
  -- ^ 'Wiki.App.Backend.getPage', by space and path.
  , drafts :: Map PageId (Either WikiError (Maybe Draft))
  -- ^ 'Wiki.App.Backend.getDraft', by page: the signed-in user's draft,
  -- or 'Nothing' when they have none.
  , searches :: [(SearchQuery, [SearchHit])]
  -- ^ 'Wiki.App.Backend.searchPages', by query, the latest first. The
  -- list stays short because every write empties it, and searches are
  -- cached only until the first route change ('forgetPageContent').
  , versionLists :: Map PageId (Either WikiError [VersionInfo])
  -- ^ 'Wiki.App.Backend.listVersions', by page.
  , versions :: Map (PageId, UTCTime) (Either WikiError Version)
  -- ^ 'Wiki.App.Backend.getVersion', by page and time. Only the versions
  -- this tab has opened are cached; the server keeps every saved version
  -- of every page ("Wiki.Core.Version"). A version never changes, but it
  -- is deleted with its page, so these entries are dropped with the rest.
  , directory :: Maybe (Either WikiError Directory)
  -- ^ 'Wiki.App.Backend.Admin.directory'.
  , settings :: Maybe (Either WikiError WikiSettings)
  -- ^ 'Wiki.App.Backend.Admin.wikiSettings'.
  , invitations :: Maybe (Either WikiError Invitations)
  -- ^ 'Wiki.App.Backend.Admin.invitations'.
  , invitationAt :: Map InvitationToken (Either WikiError InvitationInfo)
  -- ^ 'Wiki.App.Account.invitationFor', by the link's secret.
  , server :: Maybe (Either WikiError ServerSettings)
  -- ^ 'Wiki.App.Backend.Admin.serverSettings'.
  , backups :: Maybe (Either WikiError Backups)
  -- ^ 'Wiki.App.Backend.Admin.backups'.
  , activity :: Maybe (Either WikiError Activity)
  -- ^ 'Wiki.App.Backend.Admin.activity': the first page of the audit log,
  -- as the server put it into the prerendered administration page. It is
  -- used for one read only (the backend's 'once') and then removed, so
  -- that the next read fetches the log as it is now.
  , status :: Maybe (Either WikiError ServerStatus)
  -- ^ 'Wiki.App.Backend.Admin.serverStatus', cached and removed in the
  -- same way as 'activity'.
  , threads :: Map PageId (Either WikiError [Thread])
  -- ^ 'Wiki.App.Backend.Comments.listThreads', by page.
  , people :: Map Text (Maybe Author)
  -- ^ 'Wiki.App.Backend.Notifications.mentionable', by login: the user
  -- with that login, or 'Nothing' when no user has it.
  , notices :: Maybe (Either WikiError Notifications)
  -- ^ 'Wiki.App.Backend.Notifications.notifications'.
  , watches :: Map WatchTarget (Either WikiError Watch)
  -- ^ 'Wiki.App.Backend.Notifications.watching', by page or space.
  }
  deriving stock (Eq, Show)

emptyCache :: Cache
emptyCache =
  Cache
    { session = Nothing
    , spaces = Nothing
    , pageCounts = Nothing
    , spaceAt = mempty
    , pages = mempty
    , postDetails = mempty
    , pageAt = mempty
    , drafts = mempty
    , searches = []
    , versionLists = mempty
    , versions = mempty
    , directory = Nothing
    , settings = Nothing
    , invitations = Nothing
    , invitationAt = mempty
    , server = Nothing
    , backups = Nothing
    , activity = Nothing
    , status = Nothing
    , threads = mempty
    , people = mempty
    , notices = Nothing
    , watches = mempty
    }

-- | Whether a response is cached. A successful one is, and so are the
-- refusals that the wiki's content or permissions decide ('NotFound',
-- 'Forbidden'). 'Unreachable' is not cached, and neither is a refusal of
-- the request itself.
kept :: Either WikiError a -> Bool
kept = \case
  Right _ -> True
  Left NotFound -> True
  Left Forbidden -> True
  Left _ -> False

-- | The cached page at a path in a space, if there is one. It comes from
-- an earlier 'Wiki.App.Backend.getPage'.
cachedPage :: SpaceId -> [Slug] -> Cache -> Maybe (Either WikiError Page)
cachedPage sid path c = Map.lookup (sid, path) c.pageAt

-- | The hits of a query searched for already.
cachedSearch :: SearchQuery -> Cache -> Maybe [SearchHit]
cachedSearch q c = snd <$> find ((== q) . fst) c.searches

-- | The cache with a read's response added. There is one such function
-- per read.
withSession :: Session -> Cache -> Cache
withSession s c = c {session = Just s}

withSpaces :: [Space] -> Cache -> Cache
withSpaces ss c = c {spaces = Just ss}

withPageCounts :: Map SpaceId Int -> Cache -> Cache
withPageCounts n c = c {pageCounts = Just n}

withSpaceAt :: [Slug] -> Either WikiError Space -> Cache -> Cache
withSpaceAt path s c = c {spaceAt = Map.insert path s c.spaceAt}

withPages :: SpaceId -> Either WikiError [PageSummary] -> Cache -> Cache
withPages sid ps c = c {pages = Map.insert sid ps c.pages}

withPostDetails :: SpaceId -> Either WikiError (Map PageId PostDetails) -> Cache -> Cache
withPostDetails sid d c = c {postDetails = Map.insert sid d c.postDetails}

withPageAt :: SpaceId -> [Slug] -> Either WikiError Page -> Cache -> Cache
withPageAt sid path p c = c {pageAt = Map.insert (sid, path) p c.pageAt}

-- | Set what the cache knows of the signed-in user's draft of a page. The
-- value says one of four things: the user has this draft; the user has no
-- draft; the read was refused (with the error); or the draft is not
-- known, which removes the entry so that the next read fetches it.
withDraft :: PageId -> Maybe (Either WikiError (Maybe Draft)) -> Cache -> Cache
withDraft pid d c = c {drafts = Map.alter (const d) pid c.drafts}

-- | Cache the hits of a query, replacing any hits cached for the same
-- query.
withSearch :: SearchQuery -> [SearchHit] -> Cache -> Cache
withSearch q hits c = c {searches = (q, hits) : filter ((/= q) . fst) c.searches}

withVersions :: PageId -> Either WikiError [VersionInfo] -> Cache -> Cache
withVersions pid vs c = c {versionLists = Map.insert pid vs c.versionLists}

withVersion :: PageId -> UTCTime -> Either WikiError Version -> Cache -> Cache
withVersion pid at v c = c {versions = Map.insert (pid, at) v c.versions}

withDirectory :: Either WikiError Directory -> Cache -> Cache
withDirectory d c = c {directory = Just d}

withSettings :: Either WikiError WikiSettings -> Cache -> Cache
withSettings s c = c {settings = Just s}

withInvitations :: Either WikiError Invitations -> Cache -> Cache
withInvitations i c = c {invitations = Just i}

withInvitationAt :: InvitationToken -> Either WikiError InvitationInfo -> Cache -> Cache
withInvitationAt t i c = c {invitationAt = Map.insert t i c.invitationAt}

withServerSettings :: Either WikiError ServerSettings -> Cache -> Cache
withServerSettings s c = c {server = Just s}

withBackups :: Either WikiError Backups -> Cache -> Cache
withBackups b c = c {backups = Just b}

withActivity :: Either WikiError Activity -> Cache -> Cache
withActivity a c = c {activity = Just a}

withStatus :: Either WikiError ServerStatus -> Cache -> Cache
withStatus st c = c {status = Just st}

-- | Remove the cached first page of the audit log, once it has been used
-- for a read.
forgetActivity :: Cache -> Cache
forgetActivity c = c {activity = Nothing}

-- | Remove the cached server status, once it has been used for a read.
forgetStatus :: Cache -> Cache
forgetStatus c = c {status = Nothing}

withThreads :: PageId -> Either WikiError [Thread] -> Cache -> Cache
withThreads pid ts c = c {threads = Map.insert pid ts c.threads}

-- | Cache which of these logins belong to users. Every login asked about
-- gets an entry, also one that belongs to no user.
withPeople :: [Text] -> Map Text Author -> Cache -> Cache
withPeople asked found c = c {people = Map.fromList [(l, Map.lookup l found) | l <- asked] <> c.people}

-- | The users these logins belong to, if every login is cached. A login
-- that belongs to no user is left out of the map.
cachedPeople :: [Text] -> Cache -> Maybe (Map Text Author)
cachedPeople logins c = Map.fromList . catMaybes <$> traverse (\l -> fmap (l,) <$> Map.lookup l c.people) logins

withNotices :: Either WikiError Notifications -> Cache -> Cache
withNotices n c = c {notices = Just n}

-- | Add a notification received over the live channel at the front of the
-- cached notifications.
withNotice :: Notification -> Cache -> Cache
withNotice n c = c {notices = fmap (\ns -> Notifications {unread = ns.unread + 1, items = n : ns.items}) <$> c.notices}

-- | Remove the cached notifications, because some may have been missed.
forgetNotices :: Cache -> Cache
forgetNotices c = c {notices = Nothing}

withWatch :: WatchTarget -> Either WikiError Watch -> Cache -> Cache
withWatch t w c = c {watches = Map.insert t w c.watches}

-- | The cache after a write to a page's comments. If the write succeeded,
-- its event is applied to the page's cached threads, if any are cached.
-- If it failed or was refused, its outcome is not known, so the page's
-- threads are removed. The posts' details count comments, so they are
-- removed in both cases.
afterComment :: PageId -> Either WikiError PageEvent -> Cache -> Cache
afterComment pid outcome c = case outcome of
  Right event -> c {threads = Map.adjust (fmap (applyEvent event)) pid c.threads, postDetails = mempty}
  Left _ -> forgetThreads pid c {postDetails = mempty}

-- | The cache after the live channel reports an event on a page. A change
-- to the page's comments is applied to its threads ('afterComment'). A
-- save of the page, by anyone and in any tab, removes every cached page,
-- and the other entries a save changes: the lists of pages (they show
-- titles), the searches (they match the text) and the version lists. The
-- session, the spaces, the drafts (someone else's save does not change
-- this user's draft) and the threads stay.
afterEvent :: PageId -> PageEvent -> Cache -> Cache
afterEvent pid = \case
  PageChanged _ -> \c -> c {pageAt = mempty, pages = mempty, searches = [], versionLists = mempty}
  event -> afterComment pid (Right event)

-- | The cache without a page's threads: they have changed, or may have.
forgetThreads :: PageId -> Cache -> Cache
forgetThreads pid c = c {threads = Map.delete pid c.threads}

-- | The cache without page content: the pages, the lists of a space's
-- pages, the details of a blog's posts, the version lists, the searches
-- and the directory's page counts. These change whenever anyone saves,
-- creates, moves or deletes a page. The backend drops them when the
-- reader first goes to another route, and caches them no more after that
-- ('Wiki.App.Backend.endPreload').
forgetPageContent :: Cache -> Cache
forgetPageContent c =
  c
    { pageAt = mempty
    , pages = mempty
    , postDetails = mempty
    , versionLists = mempty
    , searches = []
    , pageCounts = Nothing
    }

-- | The cache after a write that changed the wiki: nothing in it can be
-- trusted any more.
afterWrite :: Cache -> Cache
afterWrite = const emptyCache
