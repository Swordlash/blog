-- | Where the wiki is, as a reader outside the server follows it: the
-- addresses a feed, a sitemap and a link preview give, which have to be
-- absolute (WP4.14 of docs/PLAN.md).
--
-- The wiki's public address is the one set in the panel's Server section
-- (WP4.4), which is what the wiki is known by behind a proxy or a name.
-- Without one, the request's own: its @Host@ (or the @X-Forwarded-Host@ a
-- proxy in front sets), the scheme a proxy says it was reached by
-- (@X-Forwarded-Proto@, else @http@, since the server itself speaks plain
-- HTTP), and the place the listener serves the wiki at.
module Wiki.Server.Address
  ( publicAddress
  , addressOf
  , hrefAddress
  )
where

import Data.CaseInsensitive qualified as CI
import Data.List (lookup)
import Data.Text qualified as T
import Network.Wai (Request (..))
import Protolude
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.Server.Storage (Storage, readServerSettings)

-- | The wiki's public address for a request to a listener that serves the
-- wiki at this place: always ending in a slash.
publicAddress :: Storage -> Text -> Request -> IO Text
publicAddress storage mount request = do
  settings <- readServerSettings storage
  pure (fromMaybe (requestAddress mount request) settings.publicUrl)

-- | The address a request names the wiki by: its host, as the browser or a
-- proxy in front of the server asked for it, under the listener's place.
requestAddress :: Text -> Request -> Text
requestAddress mount request = scheme <> "://" <> host <> mount
  where
    header name = decodeUtf8With lenientDecode <$> lookup (CI.mk name) (requestHeaders request)
    firstOf = T.strip . T.takeWhile (/= ',')
    host = maybe "localhost" firstOf (header "X-Forwarded-Host" <|> (decodeUtf8With lenientDecode <$> requestHeaderHost request))
    scheme = case T.toLower . firstOf <$> header "X-Forwarded-Proto" of
      Just "https" -> "https"
      _ -> "http"

-- | An address of the wiki's (a path relative to its place, as the API's
-- links are, @api\/v1\/…@) under its public address.
addressOf :: Text -> Text -> Text
addressOf base path = base <> T.dropWhile (== '/') path

-- | An address the router wrote, under the listener's place, under the
-- public address instead.
hrefAddress :: Text -> Text -> Text -> Text
hrefAddress base mount href = addressOf base (fromMaybe href (T.stripPrefix mount href))
