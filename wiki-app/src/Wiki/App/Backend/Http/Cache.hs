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
-- writes, or the page is loaded again: the cache lives as long as the page;
-- but for a save of a page the live channel tells of ('afterEvent'), which
-- lets go of the pages read, and of what a save changes with them.
--
-- A refusal is an answer too, and is kept as one: that a space is not
-- there ('NotFound') or that the reader may not see it ('Forbidden') is
-- what the view shows, and a page the server rendered with that refusal in
-- it ("Wiki.App.Backend.Http.Preload") is rendered the same by the
-- program only if the program knows it at once. Those two are decided by
-- the wiki's content and rules, so they go stale as any answer does, and
-- are let go with the rest. 'Unreachable' is not an answer and is never
-- kept: trying again may well work.
--
-- A page's comments ("Wiki.Core.Comment") are kept by page, and their own
-- writes are the other exception: a comment changes its page's threads
-- and nothing else, so its result is folded into them
-- ('Wiki.Api.Events.applyEvent') rather than everything let go, which
-- would make the page itself load again. What happens to them elsewhere
-- comes over the live channel ("Wiki.App.Live"), which lets a page's
-- threads go when it hears of them, and when it stops listening for them
-- ('forgetThreads').
--
-- So is how many pages each space has, which the directory of spaces
-- shows. So are searches, by their query: the server renders the page of a
-- search's results with its hits, which the program then shows at once.
-- And so is the administration's directory of the wiki's people, which the
-- server renders the administration with, and its settings and invitations;
-- and an invitation as its link shows it to the person invited, by the
-- link's secret; and the server's own settings, without their secrets.
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
  , withThreads
  , afterComment
  , afterEvent
  , forgetThreads
  , afterWrite
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Protolude
import Wiki.Api.Account (InvitationInfo, InvitationToken)
import Wiki.Api.Admin (Directory, Invitations, WikiSettings)
import Wiki.Api.Backups (Backups)
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.Api.ServerSettings (ServerSettings)
import Wiki.App.Backend (Session, WikiError (..))
import Wiki.Core.Comment (Thread)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Page (Page)
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Search (SearchHit, SearchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.Version (Version, VersionInfo)

-- | Each read's answer, as it came back: what it gave, or the refusal it
-- was (see 'kept').
data Cache = Cache
  { session :: Maybe Session
  , spaces :: Maybe [Space]
  -- ^ 'Wiki.App.Backend.listSpaces'.
  , pageCounts :: Maybe (Map SpaceId Int)
  -- ^ 'Wiki.App.Backend.pageCounts'.
  , spaceAt :: Map [Slug] (Either WikiError Space)
  -- ^ 'Wiki.App.Backend.getSpace', by path.
  , pages :: Map SpaceId (Either WikiError [Page])
  -- ^ 'Wiki.App.Backend.listPages', by space.
  , pageAt :: Map (SpaceId, [Slug]) (Either WikiError Page)
  -- ^ 'Wiki.App.Backend.getPage', by space and path.
  , drafts :: Map PageId (Either WikiError (Maybe Draft))
  -- ^ 'Wiki.App.Backend.getDraft', by page: the signed-in user's draft, or
  -- that they have none.
  , searches :: [(SearchQuery, [SearchHit])]
  -- ^ 'Wiki.App.Backend.searchPages', by query, the latest first: a few
  -- at most, since a write lets them go.
  , versionLists :: Map PageId (Either WikiError [VersionInfo])
  -- ^ 'Wiki.App.Backend.listVersions', by page.
  , versions :: Map (PageId, UTCTime) (Either WikiError Version)
  -- ^ 'Wiki.App.Backend.getVersion', by page and time. A version never
  -- changes, but it goes with its page, so these are let go with the rest.
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
  , threads :: Map PageId (Either WikiError [Thread])
  -- ^ 'Wiki.App.Backend.Comments.listThreads', by page.
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
    , threads = mempty
    }

-- | Whether a read's answer is kept: what it gave, and a refusal the
-- wiki's content or rules decided ('NotFound', 'Forbidden'); not that the
-- server could not be asked, nor a refusal of how it was asked.
kept :: Either WikiError a -> Bool
kept = \case
  Right _ -> True
  Left NotFound -> True
  Left Forbidden -> True
  Left _ -> False

-- | The page at a path in a space, if it has been read: by itself, or with
-- every page of its space ('withPages'), which is how the space's view
-- has them, so that a page opened from there needs no fetch.
cachedPage :: SpaceId -> [Slug] -> Cache -> Maybe (Either WikiError Page)
cachedPage sid path c =
  Map.lookup (sid, path) c.pageAt
    <|> (Map.lookup sid c.pages >>= rightToMaybe >>= \ps -> rightToMaybe (resolvePath (findChild ps) path) >>= fmap Right . lastMay)

-- | The hits of a query searched for already.
cachedSearch :: SearchQuery -> Cache -> Maybe [SearchHit]
cachedSearch q c = snd <$> find ((== q) . fst) c.searches

-- | The cache with what a read gave, one function per read.
withSession :: Session -> Cache -> Cache
withSession s c = c {session = Just s}

withSpaces :: [Space] -> Cache -> Cache
withSpaces ss c = c {spaces = Just ss}

withPageCounts :: Map SpaceId Int -> Cache -> Cache
withPageCounts n c = c {pageCounts = Just n}

withSpaceAt :: [Slug] -> Either WikiError Space -> Cache -> Cache
withSpaceAt path s c = c {spaceAt = Map.insert path s c.spaceAt}

withPages :: SpaceId -> Either WikiError [Page] -> Cache -> Cache
withPages sid ps c = c {pages = Map.insert sid ps c.pages}

withPageAt :: SpaceId -> [Slug] -> Either WikiError Page -> Cache -> Cache
withPageAt sid path p c = c {pageAt = Map.insert (sid, path) p c.pageAt}

-- | The signed-in user's draft of a page as it now is ('Nothing' for
-- none), or why it cannot be read; or, given 'Nothing' at all, not known.
withDraft :: PageId -> Maybe (Either WikiError (Maybe Draft)) -> Cache -> Cache
withDraft pid d c = c {drafts = Map.alter (const d) pid c.drafts}

-- | The hits of a query, in place of any kept for it before.
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

withThreads :: PageId -> Either WikiError [Thread] -> Cache -> Cache
withThreads pid ts c = c {threads = Map.insert pid ts c.threads}

-- | The cache after a write to a page's comments: what it did folded into
-- the page's threads, if they are kept; or, for a write whose outcome is
-- not known (it failed, or was refused), the page's threads let go.
afterComment :: PageId -> Either WikiError PageEvent -> Cache -> Cache
afterComment pid outcome c = case outcome of
  Right event -> c {threads = Map.adjust (fmap (applyEvent event)) pid c.threads}
  Left _ -> forgetThreads pid c

-- | The cache after an event the live channel told of a page: a change to
-- its comments folded into its threads ('afterComment'), and a save of it
-- (by anyone, in any tab) letting go of every page read, with what a save
-- changes besides the page: its space's list of pages (titles), the
-- searches (its text) and its history. Who is asking, the spaces, the
-- drafts (another's save leaves this author's alone) and the threads stay.
afterEvent :: PageId -> PageEvent -> Cache -> Cache
afterEvent pid = \case
  PageChanged _ -> \c -> c {pageAt = mempty, pages = mempty, searches = [], versionLists = mempty}
  event -> afterComment pid (Right event)

-- | The cache without a page's threads: they have changed, or may have.
forgetThreads :: PageId -> Cache -> Cache
forgetThreads pid c = c {threads = Map.delete pid c.threads}

-- | The cache after a write that changed the wiki: nothing in it can be
-- trusted any more.
afterWrite :: Cache -> Cache
afterWrite = const emptyCache
