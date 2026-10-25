-- | The addresses of the API's endpoints, made from its type: what the
-- browser's backend over HTTP requests, so that it cannot ask for a path the
-- server does not serve.
--
-- Every address is relative, without a leading slash (@api\/v1\/spaces@): a
-- browser resolves it against the page's base address, the @\<base href>@
-- the application is served under, so that a wiki served below a path
-- (@HALOGEN_BASE_PATH@) finds its API below the same path.
module Wiki.Api.Links
  ( links
  , linkText
  , attachmentUrl
  , spaceIconUrl
  , pageExportUrl
  , spaceExportUrl
  , searchUrl
  , searchQueryOf
  )
where

import Protolude
import Servant.API (Link, toUrlPiece)
import Servant.Links (AsLink, allLinks')
import Wiki.Api (AttachmentsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..), api)
import Wiki.Api.Export (ExportFormat)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Space (Icon (..), Space (..))

-- | Every endpoint's address, as a function of its captures and parameters:
-- @links.spaces.rename spaceId@ is @api\/v1\/spaces\/\<id>\/name@. An
-- endpoint's body and headers are not part of its address.
links :: WikiApi (AsLink Text)
links = allLinks' linkText api

-- | A link as the relative address it is.
linkText :: Link -> Text
linkText = toUrlPiece

-- | Where a browser fetches an attachment from: @attachmentUrl@ over HTTP.
-- One that lives on the web is at its own URL; one whose bytes the server
-- keeps is at its address in the API, which ends in its name.
attachmentUrl :: Attachment -> Text
attachmentUrl a = case a.source of
  SourceUrl url -> url
  SourceBlob _ -> links.attachments.content a.id a.name

-- | Where a browser fetches the image a space is pictured with:
-- @spaceIconUrl@ over HTTP. The empty text for a space whose icon is no
-- image.
spaceIconUrl :: Space -> Text
spaceIconUrl s = case s.icon of
  Just (IconImage blob _) -> links.spaces.icon s.id blob
  _ -> ""

-- | Where a browser downloads a page exported as a document: a link the
-- application writes for the browser to follow, never fetches itself.
pageExportUrl :: PageId -> ExportFormat -> Text
pageExportUrl = links.pages.export

-- | Where a browser downloads a space's pages exported as one document.
spaceExportUrl :: SpaceId -> ExportFormat -> Text
spaceExportUrl = links.spaces.export

-- | The address of a search: every field of the query is in it, so the
-- server reads back the query that was asked.
searchUrl :: SearchQuery -> Text
searchUrl q = links.search (Just q.text) q.space (not q.includeSubspaces) (Just q.limit)

-- | The query a search's parameters ask for: @q@ (no words, so no hits, if
-- it is missing), @space@ (every space if missing), @only@ (only that
-- space, not its subspaces) and @limit@ ('searchQuery''s if missing).
searchQueryOf :: Maybe Text -> Maybe SpaceId -> Bool -> Maybe Int -> SearchQuery
searchQueryOf q space only limit =
  SearchQuery
    { text = fromMaybe "" q
    , space
    , includeSubspaces = not only
    , limit = fromMaybe (searchQuery "").limit limit
    }
