-- | The preload: the cached API responses that a page prerendered by the
-- server carries for the program. They are the responses the server's
-- prerender read, in the form the HTTP backend caches them
-- ("Wiki.App.Backend.Http.Cache"), written into the page as JSON
-- ('Halogen.Static.embed', under 'preloadId') beside the application's
-- HTML.
--
-- The server prerenders a route's page with the application itself, over
-- 'Wiki.App.Backend.Http.HttpWiki' and the API in its own process
-- ("Wiki.App.Static.renderServed"). So the responses it read are exactly
-- what the views ask for at that route, as the API answers the user who
-- sent the request. The program starts its backend with them
-- ('Wiki.App.Backend.Http.newHttpEnvWith', from 'embeddedCache'). Its
-- first render loads through 'Wiki.App.Backend.atOnce', so it matches the
-- page the server sent: 'Halogen.VDom.Driver.hydrateUI' adopts that page
-- with nothing to repair, and nothing is fetched again (decision 18 of the
-- plan).
--
-- The encoding is the API's own. Each response is the JSON the API
-- returns for that read ("Wiki.Api.Types", @wiki-core@'s records), stored
-- with the read's arguments, with named fields. A refusal is the API's
-- error body ("Wiki.Api.Error"). A space's list of pages holds summaries
-- without bodies ('Wiki.Core.Page.PageSummary'), so the page shown is
-- carried once, under @pagesAt@.
--
-- The cache is written and read here directly, field by field, rather
-- than through a record that mirrors it (WP5.9 of docs/PLAN.md). That
-- mirror (a record of twenty-three fields with derived instances, a record
-- for each kind of response, and the two functions between them and the
-- cache) took two thirds of the work GHC spent on the module: 4.9 GB of
-- allocation natively and 5.6 GB on WebAssembly, against 1.5 GB for each
-- now, for the same bytes in the page.
module Wiki.App.Backend.Http.Preload
  ( -- * The payload
    preloadId
  , preloadJSON
  , parsePreload

    -- * In the page
  , encodePreload
  , decodePreload
  , embeddedCache
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeStrict', encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Object, Pair, Parser, parseEither)
import Data.Map.Strict qualified as Map
import Halogen.IO.Util (readEmbedded)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude
import Wiki.Api.Error (ApiError)
import Wiki.Api.Error qualified as ApiError
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Http.Cache (Cache (..), cachedDraft, draftAnswer, emptyCache, kept)
import Wiki.App.Backend.Http.Client (fromApiError, fromSessionInfo, sessionInfo)
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Version (VersionsQuery (..), versionsPageSize)

-- | The id of the page's script element that holds the preload.
preloadId :: Text
preloadId = "wiki-preload"

-- | The cache as the page carries it: every response it would answer at
-- once with.
--
-- An object with a field per read. The session is as the API returns it
-- (@session@, or @null@). The reads without arguments hold their response
-- (@spaces@, @pageCounts@, or @null@ for a read not made). The reads with
-- arguments are lists of objects, each with the read's arguments and its
-- response or @error@: @spacesAt@, @pages@, @pagesAt@, @drafts@,
-- @searches@, @versionLists@ and @versions@ always, and @invitationsAt@,
-- @postDetails@, @threads@ and @watches@ as @null@ when empty, since they
-- were added later. The administration's reads are an object with their
-- response or @error@, or @null@. @people@ is by login, or @null@ when
-- empty. A preload written before a field existed reads as without it.
preloadJSON :: Cache -> Value
preloadJSON c =
  object
    [ "session" .= (sessionInfo <$> c.session)
    , "homeDocument" .= answer "document" c.homeDocument
    , "spaces" .= c.spaces
    , "pageCounts" .= c.pageCounts
    , "spacesAt" .= answers "space" (\path -> ["path" .= path]) c.spaceAt
    , "pages" .= answers "pages" (\space -> ["space" .= space]) c.pages
    , "pagesAt" .= answers "page" (\(space, path) -> ["space" .= space, "path" .= path]) c.pageAt
    , "drafts" .= answers "draft" (\page -> ["page" .= page]) (draftAnswer <$> c.drafts)
    , "searches" .= [object ["query" .= query, "hits" .= hits] | (query, hits) <- c.searches]
    , "versionLists" .= answers "versions" (\(page, q) -> ["page" .= page, "before" .= q.before, "limit" .= q.limit]) c.versionLists
    , "versions" .= answers "version" (\(page, updatedAt) -> ["page" .= page, "updatedAt" .= updatedAt]) c.versions
    , "directory" .= answer "directory" c.directory
    , "settings" .= answer "settings" c.settings
    , "invitations" .= answer "invitations" c.invitations
    , "invitationsAt" .= orNull (answers "invitation" (\token -> ["token" .= token]) c.invitationAt)
    , "server" .= answer "server" c.server
    , "backups" .= answer "backups" c.backups
    , "activity" .= answer "activity" c.activity
    , "status" .= answer "status" c.status
    , "userPages" .= orNull (answers "users" (\q -> ["query" .= q]) c.userPages)
    , "postDetails" .= orNull (answers "details" (\space -> ["space" .= space]) c.postDetails)
    , "threads" .= orNull (answers "threads" (\page -> ["page" .= page]) c.threads)
    , "people" .= if Map.null c.people then Nothing else Just c.people
    , "notices" .= answer "notifications" c.notices
    , "watches" .= orNull (answers "watch" watchTarget c.watches)
    ]
  where
    orNull = \case
      [] -> Nothing
      found -> Just found
    watchTarget = \case
      WatchPage p -> ["page" .= p]
      WatchSpace s -> ["space" .= s]

-- | Each cached response, as an object of its read's arguments and the
-- response.
answers :: (ToJSON a) => Key -> (k -> [Pair]) -> Map k (Either WikiError a) -> [Value]
answers field arguments m = [object (arguments k <> answerFields field a) | (k, a) <- Map.toList m, kept a]

-- | A read without arguments, as an object of its response, if it is
-- cached.
answer :: (ToJSON a) => Key -> Maybe (Either WikiError a) -> Maybe Value
answer field = fmap (object . answerFields field) . mfilter kept

-- | A response in its read's own field, or a refusal in @error@, as the
-- API's error body.
answerFields :: (ToJSON a) => Key -> Either WikiError a -> [Pair]
answerFields field = \case
  Right a -> [field .= a]
  Left e -> ["error" .= refusal e]

-- | The API error for a cached refusal. Only what 'kept' accepts is ever
-- written, which is a response or one of the API's refusals.
refusal :: WikiError -> ApiError
refusal = \case
  NotFound -> ApiError.NotFound
  Forbidden -> ApiError.Forbidden
  Conflict t -> ApiError.Conflict t
  Invalid t -> ApiError.Invalid t
  -- Never cached, so never written; mapped to the nearest refusal rather
  -- than left out.
  Unreachable t -> ApiError.Invalid t

-- | Parse the preload into the backend's cache ('preloadJSON' writes it).
parsePreload :: Value -> Parser Cache
parsePreload = withObject "the page's payload" $ \o -> do
  session <- fmap fromSessionInfo <$> o .:? "session"
  homeDocument <- traverse (withObject "an answer" (answerIn "document")) =<< o .:? "homeDocument"
  spaces <- o .:? "spaces"
  pageCounts <- o .:? "pageCounts"
  spaceAt <- byArguments "space" (.: "path") =<< o .: "spacesAt"
  pages <- byArguments "pages" (.: "space") =<< o .: "pages"
  pageAt <- byArguments "page" (\e -> (,) <$> e .: "space" <*> e .: "path") =<< o .: "pagesAt"
  drafts <- fmap cachedDraft <$> (byArguments "draft" (.: "page") =<< o .: "drafts")
  searches <- traverse (withObject "a search" (\e -> (,) <$> e .: "query" <*> e .: "hits")) =<< o .: "searches"
  versionLists <- byArguments "versions" (\e -> (,) <$> e .: "page" <*> (VersionsQuery <$> e .:? "before" <*> (fromMaybe versionsPageSize <$> e .:? "limit"))) =<< o .: "versionLists"
  versions <- byArguments "version" (\e -> (,) <$> e .: "page" <*> e .: "updatedAt") =<< o .: "versions"
  directory <- traverse (withObject "an answer" (answerIn "directory")) =<< o .:? "directory"
  settings <- traverse (withObject "an answer" (answerIn "settings")) =<< o .:? "settings"
  invitations <- traverse (withObject "an answer" (answerIn "invitations")) =<< o .:? "invitations"
  invitationAt <- byArguments "invitation" (.: "token") . fold =<< o .:? "invitationsAt"
  server <- traverse (withObject "an answer" (answerIn "server")) =<< o .:? "server"
  backups <- traverse (withObject "an answer" (answerIn "backups")) =<< o .:? "backups"
  activity <- traverse (withObject "an answer" (answerIn "activity")) =<< o .:? "activity"
  status <- traverse (withObject "an answer" (answerIn "status")) =<< o .:? "status"
  userPages <- byArguments "users" (.: "query") . fold =<< o .:? "userPages"
  postDetails <- byArguments "details" (.: "space") . fold =<< o .:? "postDetails"
  threads <- byArguments "threads" (.: "page") . fold =<< o .:? "threads"
  people <- fold <$> o .:? "people"
  notices <- traverse (withObject "an answer" (answerIn "notifications")) =<< o .:? "notices"
  watches <- byArguments "watch" watchTarget . fold =<< o .:? "watches"
  pure Cache {..}
  where
    watchTarget e =
      e .:? "page" >>= \case
        Just p -> pure (WatchPage p)
        Nothing -> WatchSpace <$> e .: "space"

-- | Responses by their read's arguments, from the objects 'answers'
-- writes.
byArguments :: (Ord k, FromJSON a) => Key -> (Object -> Parser k) -> [Value] -> Parser (Map k (Either WikiError a))
byArguments field arguments = fmap Map.fromList . traverse (withObject "an answer" (\e -> (,) <$> arguments e <*> answerIn field e))

-- | A response in its read's own field, or the refusal in @error@.
answerIn :: (FromJSON a) => Key -> Object -> Parser (Either WikiError a)
answerIn field o =
  o .:? "error" >>= \case
    Just e -> pure (Left (fromApiError e))
    Nothing -> Right <$> o .: field

-- | The preload as the JSON text the page carries.
encodePreload :: Cache -> Text
encodePreload = decodeUtf8 . toS . encode . preloadJSON

-- | The cache a preload holds, or the reason it cannot be read.
decodePreload :: Text -> Either Text Cache
decodePreload = first toS . (parseEither parsePreload <=< eitherDecodeStrict') . encodeUtf8

-- | The preload of the page the program runs in: the cache to start the
-- backend with ('Wiki.App.Backend.Http.newHttpEnvWith'). A page without a
-- preload (the build page the server sends when it cannot prerender one)
-- starts with an empty cache. So does a preload that cannot be read, with
-- the reason: that costs a fetch, not the page.
embeddedCache :: (MonadBrowserDOM m) => m (Either Text Cache)
embeddedCache =
  readEmbedded preloadId <&> \case
    Nothing -> Right emptyCache
    Just json -> first (\why -> "the page's " <> preloadId <> " cannot be read: " <> why) (decodePreload json)
