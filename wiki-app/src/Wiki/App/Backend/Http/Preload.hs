-- | What a page the server rendered carries for the program: the answers
-- the server's render read, as the backend over HTTP keeps them
-- ("Wiki.App.Backend.Http.Cache"), written into the page as JSON
-- ('Halogen.Static.embed', by 'preloadId') beside the application's HTML.
--
-- The server renders a route's page with the application itself, over
-- 'Wiki.App.Backend.Http.HttpWiki' and the API in its own process
-- ("Wiki.App.Static.renderServed"), so what it read is exactly what the
-- views ask for at that route, and those are the API's answers to the
-- principal of the request. The program starts its backend with them
-- ('Wiki.App.Backend.Http.newHttpEnvWith', from 'embeddedCache'), so that
-- its first render, which loads through 'Wiki.App.Backend.atOnce', is the
-- page the server sent: 'Halogen.VDom.Driver.hydrateUI' adopts it with
-- nothing to repair and nothing is fetched again. (Decision 18 of the
-- plan.)
--
-- The encoding is the API's own: each answer is the JSON the API gives
-- for that read ("Wiki.Api.Types", @wiki-core@'s records), under the
-- read's arguments, with named fields; a refusal is the API's error body
-- ("Wiki.Api.Error"). A page of a space a view reads by itself is left out
-- when the space's list of pages, which holds it, is there, since the
-- backend finds it in the list ('cachedPage'): a page is not carried twice.
--
-- The cache is written and read here directly, field by field, rather
-- than through a record that mirrors it (WP5.9 of docs/PLAN.md). The
-- mirror, a record of twenty-three fields with derived instances, a record
-- for each kind of answer and the two functions between them and the
-- cache, was two thirds of what GHC spent on the module: 4.9 GB of
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
import Wiki.App.Backend.Http.Cache (Cache (..), cachedPage, emptyCache, kept)
import Wiki.App.Backend.Http.Request (fromApiError, fromSessionInfo, sessionInfo)
import Wiki.Core.Notification (WatchTarget (..))

-- | The id of the page's script that holds the payload.
preloadId :: Text
preloadId = "wiki-preload"

-- | What the backend kept, as the page carries it: every answer it would
-- give at once, and no page twice.
--
-- An object with a field per read: the session as the API gives it
-- (@session@, or @null@); the reads without arguments as their answers
-- (@spaces@, @pageCounts@, or @null@ for one not made); the reads by
-- arguments as lists of objects, each with the read's arguments and its
-- answer or @error@ (@spacesAt@, @pages@, @pagesAt@, @drafts@, @searches@,
-- @versionLists@, @versions@ always, and @invitationsAt@, @postDetails@,
-- @threads@, @watches@ as @null@ when empty, since they came later); the
-- administration's reads as an object with their answer or @error@, or
-- @null@; and @people@, by login, or @null@ when empty. A payload written
-- before a field there was reads as without it.
preloadJSON :: Cache -> Value
preloadJSON c =
  object
    [ "session" .= (sessionInfo <$> c.session)
    , "spaces" .= c.spaces
    , "pageCounts" .= c.pageCounts
    , "spacesAt" .= answers "space" (\path -> ["path" .= path]) c.spaceAt
    , "pages" .= answers "pages" (\space -> ["space" .= space]) c.pages
    , "pagesAt" .= answers "page" (\(space, path) -> ["space" .= space, "path" .= path]) (Map.filterWithKey apart c.pageAt)
    , "drafts" .= answers "draft" (\page -> ["page" .= page]) c.drafts
    , "searches" .= [object ["query" .= query, "hits" .= hits] | (query, hits) <- c.searches]
    , "versionLists" .= answers "versions" (\page -> ["page" .= page]) c.versionLists
    , "versions" .= answers "version" (\(page, updatedAt) -> ["page" .= page, "updatedAt" .= updatedAt]) c.versions
    , "directory" .= answer "directory" c.directory
    , "settings" .= answer "settings" c.settings
    , "invitations" .= answer "invitations" c.invitations
    , "invitationsAt" .= orNull (answers "invitation" (\token -> ["token" .= token]) c.invitationAt)
    , "server" .= answer "server" c.server
    , "backups" .= answer "backups" c.backups
    , "activity" .= answer "activity" c.activity
    , "status" .= answer "status" c.status
    , "postDetails" .= orNull (answers "details" (\space -> ["space" .= space]) c.postDetails)
    , "threads" .= orNull (answers "threads" (\page -> ["page" .= page]) c.threads)
    , "people" .= if Map.null c.people then Nothing else Just c.people
    , "notices" .= answer "notifications" c.notices
    , "watches" .= orNull (answers "watch" watchTarget c.watches)
    ]
  where
    -- A page its space's list holds as it is is found there.
    apart (space, path) p = cachedPage space path c {pageAt = mempty} /= Just p
    orNull = \case
      [] -> Nothing
      found -> Just found
    watchTarget = \case
      WatchPage p -> ["page" .= p]
      WatchSpace s -> ["space" .= s]

-- | Each answer kept, as an object of its read's arguments and the answer.
answers :: (ToJSON a) => Key -> (k -> [Pair]) -> Map k (Either WikiError a) -> [Value]
answers field arguments m = [object (arguments k <> answerFields field a) | (k, a) <- Map.toList m, kept a]

-- | A read without arguments, as an object of its answer, if it is kept.
answer :: (ToJSON a) => Key -> Maybe (Either WikiError a) -> Maybe Value
answer field = fmap (object . answerFields field) . mfilter kept

-- | An answer as its read's own field, or a refusal as @error@, the API's
-- error body.
answerFields :: (ToJSON a) => Key -> Either WikiError a -> [Pair]
answerFields field = \case
  Right a -> [field .= a]
  Left e -> ["error" .= refusal e]

-- | Only what 'kept' keeps is ever written, which is an answer or a
-- refusal of the API's.
refusal :: WikiError -> ApiError
refusal = \case
  NotFound -> ApiError.NotFound
  Forbidden -> ApiError.Forbidden
  Conflict t -> ApiError.Conflict t
  Invalid t -> ApiError.Invalid t
  -- Never kept, so never here; said as the nearest refusal rather than
  -- not at all.
  Unreachable t -> ApiError.Invalid t

-- | The backend's cache as the page's payload says ('preloadJSON').
parsePreload :: Value -> Parser Cache
parsePreload = withObject "the page's payload" $ \o -> do
  session <- fmap fromSessionInfo <$> o .:? "session"
  spaces <- o .:? "spaces"
  pageCounts <- o .:? "pageCounts"
  spaceAt <- byArguments "space" (.: "path") =<< o .: "spacesAt"
  pages <- byArguments "pages" (.: "space") =<< o .: "pages"
  pageAt <- byArguments "page" (\e -> (,) <$> e .: "space" <*> e .: "path") =<< o .: "pagesAt"
  drafts <- byArguments "draft" (.: "page") =<< o .: "drafts"
  searches <- traverse (withObject "a search" (\e -> (,) <$> e .: "query" <*> e .: "hits")) =<< o .: "searches"
  versionLists <- byArguments "versions" (.: "page") =<< o .: "versionLists"
  versions <- byArguments "version" (\e -> (,) <$> e .: "page" <*> e .: "updatedAt") =<< o .: "versions"
  directory <- traverse (withObject "an answer" (answerIn "directory")) =<< o .:? "directory"
  settings <- traverse (withObject "an answer" (answerIn "settings")) =<< o .:? "settings"
  invitations <- traverse (withObject "an answer" (answerIn "invitations")) =<< o .:? "invitations"
  invitationAt <- byArguments "invitation" (.: "token") . fold =<< o .:? "invitationsAt"
  server <- traverse (withObject "an answer" (answerIn "server")) =<< o .:? "server"
  backups <- traverse (withObject "an answer" (answerIn "backups")) =<< o .:? "backups"
  activity <- traverse (withObject "an answer" (answerIn "activity")) =<< o .:? "activity"
  status <- traverse (withObject "an answer" (answerIn "status")) =<< o .:? "status"
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

-- | Answers by their read's arguments, from the objects 'answers' writes.
byArguments :: (Ord k, FromJSON a) => Key -> (Object -> Parser k) -> [Value] -> Parser (Map k (Either WikiError a))
byArguments field arguments = fmap Map.fromList . traverse (withObject "an answer" (\e -> (,) <$> arguments e <*> answerIn field e))

-- | An answer in its read's own field, or the refusal in @error@.
answerIn :: (FromJSON a) => Key -> Object -> Parser (Either WikiError a)
answerIn field o =
  o .:? "error" >>= \case
    Just e -> pure (Left (fromApiError e))
    Nothing -> Right <$> o .: field

-- | The payload as the JSON text the page carries.
encodePreload :: Cache -> Text
encodePreload = decodeUtf8 . toS . encode . preloadJSON

-- | The cache a payload holds, or why it cannot be read.
decodePreload :: Text -> Either Text Cache
decodePreload = first toS . (parseEither parsePreload <=< eitherDecodeStrict') . encodeUtf8

-- | What the page the program runs in carries: the cache to start the
-- backend with ('Wiki.App.Backend.Http.newHttpEnvWith'). A page without a
-- payload (the server's build page, which the server sends when it cannot
-- render one) starts with nothing read, and so does a payload that cannot
-- be read, which says why: it costs a fetch, not the page.
embeddedCache :: (MonadBrowserDOM m) => m (Either Text Cache)
embeddedCache =
  readEmbedded preloadId <&> \case
    Nothing -> Right emptyCache
    Just json -> first (\why -> "the page's " <> preloadId <> " cannot be read: " <> why) (decodePreload json)
