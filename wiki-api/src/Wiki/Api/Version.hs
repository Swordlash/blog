-- | Page versions over HTTP: the version of a page, as HTTP's conditional
-- requests carry it.
--
-- A page's version is its @updatedAt@: every save makes it later, and
-- @MonadWiki@'s @savePage@ already takes the @updatedAt@ the edit started
-- from to detect a conflict. Over HTTP that time is sent in headers rather
-- than in the body: a response with a page carries it as its @ETag@, and a
-- save sends it back as @If-Match@, which is what that header is for. The
-- server responds to a save whose @If-Match@ is not the page's current
-- version with 409 'Wiki.Api.Error.Conflict' (rather than HTTP's 412, so
-- that a conflict is one error however it is detected), and to a save
-- without the header with 400.
--
-- The tag is the time itself, in ISO 8601 with every digit of its
-- fraction (@\"2026-10-24T09:30:12.345678Z\"@, quotes included, as an
-- entity tag is written). So a client can build the tag from the page it
-- holds without having stored the header, and parse the time back from
-- it. It is a strong tag: a weak one (@W\/\"…\"@) is refused, since a save
-- compares versions exactly.
--
-- A version of a page in its history ("Wiki.Core.Version") is identified
-- by the same time, in the path of the endpoints that read and restore it
-- ('VersionTime'): written as in an entity tag, but without the quotes.
module Wiki.Api.Version
  ( PageVersion (..)
  , pageVersion
  , VersionTime (..)
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Protolude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))
import Wiki.Core.Page (Page (..))

-- | 'PageVersion': a page's version, the @updatedAt@ it had when the client read it.
newtype PageVersion = PageVersion {time :: UTCTime}
  deriving stock (Eq, Ord, Show)

-- | The current version of a page.
pageVersion :: Page -> PageVersion
pageVersion p = PageVersion p.updatedAt

-- | The entity tag, quoted.
instance ToHttpApiData PageVersion where
  toUrlPiece (PageVersion t) = "\"" <> toS (iso8601Show t) <> "\""

-- | Parses an entity tag that 'toUrlPiece' wrote: quoted, strong, and a time.
instance FromHttpApiData PageVersion where
  parseUrlPiece raw = do
    inner <-
      maybe
        (Left ("not a strong entity tag in quotes: " <> raw))
        Right
        (T.stripPrefix "\"" raw >>= T.stripSuffix "\"")
    maybe
      (Left ("not a page's version: " <> raw))
      (Right . PageVersion)
      (iso8601ParseM (toS inner))

-- | 'VersionTime': a version of a page in its history, by its @updatedAt@,
-- as a path segment. It is written in ISO 8601 with every digit of the
-- fraction, so that the parsed time is exactly the version's time, which
-- is looked up by equality. (http-api-data's own instance for 'UTCTime' is
-- not used, so that the path does not depend on how that instance writes a
-- fraction.)
newtype VersionTime = VersionTime {time :: UTCTime}
  deriving stock (Eq, Ord, Show)

instance ToHttpApiData VersionTime where
  toUrlPiece (VersionTime t) = toS (iso8601Show t)

instance FromHttpApiData VersionTime where
  parseUrlPiece raw = maybe (Left ("not a version's time: " <> raw)) (Right . VersionTime) (iso8601ParseM (toS raw))
