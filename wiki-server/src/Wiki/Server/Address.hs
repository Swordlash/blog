-- | The wiki's absolute addresses, as a reader outside the server follows
-- them: the addresses a feed, a sitemap and a link preview give, which
-- must be absolute (WP4.14 of docs/PLAN.md).
--
-- The wiki's public address is the one set in the panel's Server section
-- (WP4.4), which is the address the wiki is known by behind a proxy or a
-- domain name. Without one, the request's own is used: its @Host@ (or the
-- @X-Forwarded-Host@ a proxy in front sets), the scheme a proxy says it was
-- reached by (@X-Forwarded-Proto@, else @http@, since the server itself
-- speaks plain HTTP), and the path where the listener serves the wiki.
module Wiki.Server.Address
  ( publicAddress
  , requestOrigin
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
import Wiki.Core.Url (Url (..))
import Wiki.Server.Storage (Storage, readServerSettings)

-- | The wiki's public address for a request to a listener that serves the
-- wiki at this path, always ending in a slash.
publicAddress :: Storage -> Text -> Request -> IO Text
publicAddress storage mount request = do
  settings <- readServerSettings storage
  pure (maybe (requestAddress mount request) (\u -> u.text) settings.publicUrl)

-- | The address a request names the wiki by: its host, as the browser or
-- a proxy in front of the server requested it, under the listener's path.
requestAddress :: Text -> Request -> Text
requestAddress mount request = requestOrigin request <> mount

-- | The origin a request names the wiki by: the scheme and the host, as
-- the browser or a proxy in front of the server requested them.
requestOrigin :: Request -> Text
requestOrigin request = scheme <> "://" <> host
  where
    header name = decodeUtf8With lenientDecode <$> lookup (CI.mk name) (requestHeaders request)
    firstOf = T.strip . T.takeWhile (/= ',')
    host = maybe "localhost" firstOf (header "X-Forwarded-Host" <|> (decodeUtf8With lenientDecode <$> requestHeaderHost request))
    scheme = case T.toLower . firstOf <$> header "X-Forwarded-Proto" of
      Just "https" -> "https"
      _ -> "http"

-- | An address in the wiki (a path relative to the wiki's path, as the
-- API's links are, @api\/v1\/…@), under its public address.
addressOf :: Text -> Text -> Text
addressOf base path = base <> T.dropWhile (== '/') path

-- | An address the router wrote, under the listener's path, moved under
-- the public address instead.
hrefAddress :: Text -> Text -> Text -> Text
hrefAddress base mount href = addressOf base (fromMaybe href (T.stripPrefix mount href))
