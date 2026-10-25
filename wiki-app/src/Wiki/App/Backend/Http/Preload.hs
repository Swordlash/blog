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
module Wiki.App.Backend.Http.Preload
  ( -- * The payload
    Preload (..)
  , SpaceAt (..)
  , SpacePages (..)
  , PageAt (..)
  , DraftOf (..)
  , SearchOf (..)
  , VersionsOf (..)
  , VersionOf (..)
  , DirectoryOf (..)
  , Answer (..)
  , preloadId
  , toPreload
  , fromPreload

    -- * In the page
  , encodePreload
  , decodePreload
  , embeddedCache
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict', encode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Pair, Parser, Value)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Halogen.IO.Util (readEmbedded)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude
import Wiki.Api.Admin (Directory)
import Wiki.Api.Error (ApiError)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Http.Cache (Cache (..), cachedPage, emptyCache, kept)
import Wiki.App.Backend.Http.Request (fromApiError, fromSessionInfo, sessionInfo)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Page (Page)
import Wiki.Core.Search (SearchHit, SearchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.Version (Version, VersionInfo)

-- | The id of the page's script that holds the payload.
preloadId :: Text
preloadId = "wiki-preload"

-- | What the server's render read, read by read.
data Preload = Preload
  { session :: Maybe SessionInfo
  -- ^ Who is asking ('Wiki.App.Backend.session').
  , spaces :: Maybe [Space]
  -- ^ The tree of spaces ('Wiki.App.Backend.listSpaces').
  , spacesAt :: [SpaceAt]
  , pages :: [SpacePages]
  , pagesAt :: [PageAt]
  , drafts :: [DraftOf]
  , searches :: [SearchOf]
  , versionLists :: [VersionsOf]
  , versions :: [VersionOf]
  , directory :: Maybe DirectoryOf
  -- ^ The administration's people ('Wiki.App.Backend.Admin.directory'),
  -- for a page of the administration rendered for an administrator; a
  -- payload written before it had this field reads as without it.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Preload

instance FromJSON Preload

-- | A space by its path ('Wiki.App.Backend.getSpace').
data SpaceAt = SpaceAt {path :: [Slug], space :: Answer Space}
  deriving stock (Eq, Show)

-- | A space's pages ('Wiki.App.Backend.listPages').
data SpacePages = SpacePages {space :: SpaceId, pages :: Answer [Page]}
  deriving stock (Eq, Show)

-- | A page by its space and its path ('Wiki.App.Backend.getPage').
data PageAt = PageAt {space :: SpaceId, path :: [Slug], page :: Answer Page}
  deriving stock (Eq, Show)

-- | The signed-in user's draft of a page, or that they have none
-- ('Wiki.App.Backend.getDraft').
data DraftOf = DraftOf {page :: PageId, draft :: Answer (Maybe Draft)}
  deriving stock (Eq, Show)

-- | A search's hits ('Wiki.App.Backend.searchPages').
data SearchOf = SearchOf {query :: SearchQuery, hits :: [SearchHit]}
  deriving stock (Eq, Show, Generic)

instance ToJSON SearchOf

instance FromJSON SearchOf

-- | A page's history ('Wiki.App.Backend.listVersions').
data VersionsOf = VersionsOf {page :: PageId, versions :: Answer [VersionInfo]}
  deriving stock (Eq, Show)

-- | One version of a page ('Wiki.App.Backend.getVersion').
data VersionOf = VersionOf {page :: PageId, updatedAt :: UTCTime, version :: Answer Version}
  deriving stock (Eq, Show)

-- | The wiki's people, as the administration reads them
-- ('Wiki.App.Backend.Admin.directory').
newtype DirectoryOf = DirectoryOf {directory :: Answer Directory}
  deriving stock (Eq, Show)

-- | What a read gave, or the API's refusal: written as the read's own field
-- (@space@, @pages@, …) or as @error@, the API's error body.
data Answer a = Gave a | Refused ApiError
  deriving stock (Eq, Show)

answerFields :: (ToJSON a) => Key -> Answer a -> [Pair]
answerFields field = \case
  Gave a -> [field .= a]
  Refused e -> ["error" .= e]

parseAnswer :: (FromJSON a) => Key -> Value -> Parser (Answer a)
parseAnswer field = withObject "an answer" $ \o ->
  o .:? "error" >>= \case
    Just e -> pure (Refused e)
    Nothing -> Gave <$> o .: field

instance ToJSON SpaceAt where
  toJSON s = object (("path" .= s.path) : answerFields "space" s.space)

instance FromJSON SpaceAt where
  parseJSON v = withObject "SpaceAt" (\o -> SpaceAt <$> o .: "path" <*> parseAnswer "space" v) v

instance ToJSON SpacePages where
  toJSON s = object (("space" .= s.space) : answerFields "pages" s.pages)

instance FromJSON SpacePages where
  parseJSON v = withObject "SpacePages" (\o -> SpacePages <$> o .: "space" <*> parseAnswer "pages" v) v

instance ToJSON PageAt where
  toJSON p = object (["space" .= p.space, "path" .= p.path] <> answerFields "page" p.page)

instance FromJSON PageAt where
  parseJSON v = withObject "PageAt" (\o -> PageAt <$> o .: "space" <*> o .: "path" <*> parseAnswer "page" v) v

instance ToJSON DraftOf where
  toJSON d = object (("page" .= d.page) : answerFields "draft" d.draft)

instance FromJSON DraftOf where
  parseJSON v = withObject "DraftOf" (\o -> DraftOf <$> o .: "page" <*> parseAnswer "draft" v) v

instance ToJSON VersionsOf where
  toJSON v = object (("page" .= v.page) : answerFields "versions" v.versions)

instance FromJSON VersionsOf where
  parseJSON v = withObject "VersionsOf" (\o -> VersionsOf <$> o .: "page" <*> parseAnswer "versions" v) v

instance ToJSON VersionOf where
  toJSON v = object (["page" .= v.page, "updatedAt" .= v.updatedAt] <> answerFields "version" v.version)

instance FromJSON VersionOf where
  parseJSON v = withObject "VersionOf" (\o -> VersionOf <$> o .: "page" <*> o .: "updatedAt" <*> parseAnswer "version" v) v

instance ToJSON DirectoryOf where
  toJSON d = object (answerFields "directory" d.directory)

instance FromJSON DirectoryOf where
  parseJSON v = DirectoryOf <$> parseAnswer "directory" v

-- | What the backend kept, as the page carries it: every answer it would
-- give at once, and no page twice.
toPreload :: Cache -> Preload
toPreload c =
  Preload
    { session = sessionInfo <$> c.session
    , spaces = c.spaces
    , spacesAt = [SpaceAt {path, space = toAnswer s} | (path, s) <- Map.toList c.spaceAt, kept s]
    , pages = [SpacePages {space, pages = toAnswer ps} | (space, ps) <- Map.toList c.pages, kept ps]
    , pagesAt =
        [ PageAt {space, path, page = toAnswer p}
        | ((space, path), p) <- Map.toList c.pageAt
        , kept p
        , -- Found in its space's list as it is.
        cachedPage space path c {pageAt = mempty} /= Just p
        ]
    , drafts = [DraftOf {page, draft = toAnswer d} | (page, d) <- Map.toList c.drafts, kept d]
    , searches = [SearchOf {query, hits} | (query, hits) <- c.searches]
    , versionLists = [VersionsOf {page, versions = toAnswer vs} | (page, vs) <- Map.toList c.versionLists, kept vs]
    , versions = [VersionOf {page, updatedAt, version = toAnswer v} | ((page, updatedAt), v) <- Map.toList c.versions, kept v]
    , directory = DirectoryOf . toAnswer <$> mfilter kept c.directory
    }

-- | The backend's cache as the page's payload says.
fromPreload :: Preload -> Cache
fromPreload p =
  emptyCache
    { session = fromSessionInfo <$> p.session
    , spaces = p.spaces
    , spaceAt = Map.fromList [(s.path, fromAnswer s.space) | s <- p.spacesAt]
    , pages = Map.fromList [(s.space, fromAnswer s.pages) | s <- p.pages]
    , pageAt = Map.fromList [((x.space, x.path), fromAnswer x.page) | x <- p.pagesAt]
    , drafts = Map.fromList [(d.page, fromAnswer d.draft) | d <- p.drafts]
    , searches = [(s.query, s.hits) | s <- p.searches]
    , versionLists = Map.fromList [(v.page, fromAnswer v.versions) | v <- p.versionLists]
    , versions = Map.fromList [((v.page, v.updatedAt), fromAnswer v.version) | v <- p.versions]
    , directory = (\d -> fromAnswer d.directory) <$> p.directory
    }

-- | Only what 'kept' keeps is ever written, which is an answer or a
-- refusal of the API's.
toAnswer :: Either WikiError a -> Answer a
toAnswer = \case
  Right a -> Gave a
  Left NotFound -> Refused ApiError.NotFound
  Left Forbidden -> Refused ApiError.Forbidden
  Left (Conflict t) -> Refused (ApiError.Conflict t)
  Left (Invalid t) -> Refused (ApiError.Invalid t)
  -- Never kept, so never here; said as the nearest refusal rather than
  -- not at all.
  Left (Unreachable t) -> Refused (ApiError.Invalid t)

fromAnswer :: Answer a -> Either WikiError a
fromAnswer = \case
  Gave a -> Right a
  Refused e -> Left (fromApiError e)

-- | The payload as the JSON text the page carries.
encodePreload :: Cache -> Text
encodePreload = decodeUtf8 . toS . encode . toPreload

-- | The cache a payload holds, or why it cannot be read.
decodePreload :: Text -> Either Text Cache
decodePreload = bimap toS fromPreload . eitherDecodeStrict' . encodeUtf8

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
