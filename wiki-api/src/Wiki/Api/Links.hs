-- | API links: the URLs of the API's endpoints, built from its type.
--
-- These links are for two uses. The application puts some of them into
-- its pages, for the browser to follow or load rather than for the
-- application to fetch: an attachment's bytes ('attachmentUrl') and an
-- SVG's interactive form ('attachmentFrameUrl'), a
-- space's icon ('spaceIconUrl'), a user's avatar ('avatarUrl'), the exports ('pageExportUrl',
-- 'spaceExportUrl', 'archiveExportUrl'). And the server's tests of the API
-- send their requests to 'links' and 'searchUrl'.
--
-- The application's own requests do not use these links. Its HTTP backend
-- sends them through a client derived from the API's type
-- (@Wiki.App.Backend.Http.Client@), which fixes each request's method,
-- headers and body as well as its address. servant's client writes some
-- addresses differently from these links: a list in the query is
-- @login=a&login=b@ rather than @login[]=a&login[]=b@, and a colon in a
-- path segment is not percent-encoded. The server reads both forms. A test
-- of the application that answers the client's requests by their address
-- names the address with the client (@endpointUrl@), not with 'links'.
--
-- Every URL is relative, without a leading slash (@api\/v1\/spaces@). A
-- browser resolves it against the page's base URL, the @\<base href>@ the
-- application is served under, so that a wiki served under a path prefix
-- (@HALOGEN_BASE_PATH@) finds its API under the same prefix.
module Wiki.Api.Links
  ( links
  , linkText
  , attachmentUrl
  , attachmentFrameUrl
  , interactiveForm
  , interactiveParameter
  , spaceIconUrl
  , avatarUrl
  , pageExportUrl
  , spaceExportUrl
  , archiveExportUrl
  , searchUrl
  , searchParameters
  , searchQueryOf
  )
where

import Protolude
import Servant.API (Link, toUrlPiece)
import Servant.Links (AsLink, allLinks')
import Servant.Multipart.API (Tmp)
import Wiki.Api (ArchiveApi (..), AttachmentsApi (..), PagesApi (..), SpacesApi (..), UsersApi (..), WikiApi (..), api)
import Wiki.Api.Export (ExportFormat)
import Wiki.Core.Attachment (Attachment (..), MimeType (..), Source (..))
import Wiki.Core.Id (PageId, SpaceId, UserId)
import Wiki.Core.Markdown.Frame (framesInteractively)
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Avatar (..))

-- | Every endpoint's URL, as a function of its captures and parameters:
-- @links.spaces.rename spaceId@ is @api\/v1\/spaces\/\<id>\/name@. An
-- endpoint's body and headers are not part of its URL.
links :: WikiApi Tmp (AsLink Text)
links = allLinks' linkText api

-- | A link as its relative URL.
linkText :: Link -> Text
linkText = toUrlPiece

-- | The URL a browser fetches an attachment from: @attachmentUrl@ over
-- HTTP. An attachment stored elsewhere on the web has its own URL; one
-- whose bytes the server stores is at its API URL, which ends in its name.
attachmentUrl :: Attachment -> Text
attachmentUrl a = case a.source of
  SourceUrl url -> url.text
  SourceBlob _ -> links.attachments.content a.id a.name

-- | The URL a frame loads an SVG attachment's interactive form from: the
-- attachment's own URL with @?interactive@ ('interactiveForm'), which the
-- server answers with the headers that let the SVG's scripts run cut off
-- from the wiki ("Wiki.Core.Markdown.Frame"). Only an attachment whose
-- bytes the server stores and whose stored type is SVG has one
-- ('Wiki.Core.Markdown.Frame.framesInteractively'); an attachment that
-- lives elsewhere on the web is never framed.
attachmentFrameUrl :: Attachment -> Maybe Text
attachmentFrameUrl a = case a.source of
  SourceBlob _ | framesInteractively a.mediaType.text -> Just (interactiveForm (attachmentUrl a))
  _ -> Nothing

-- | An attachment's URL as its interactive form: with the query parameter
-- 'interactiveParameter'.
interactiveForm :: Text -> Text
interactiveForm url = url <> "?" <> interactiveParameter

-- | The query parameter that asks the server for an attachment's
-- interactive form. Its presence is what counts; a value is ignored.
interactiveParameter :: Text
interactiveParameter = "interactive"

-- | The URL a browser fetches a space's icon image from: @spaceIconUrl@
-- over HTTP. The empty text for a space whose icon is not an image.
spaceIconUrl :: Space -> Text
spaceIconUrl s = case s.icon of
  Just (IconImage blob _) -> links.spaces.icon s.id blob
  _ -> ""

-- | The URL a browser fetches a user's avatar from: @avatarUrl@ over HTTP,
-- @api\/v1\/users\/\<id>\/avatar\/\<blob>@. The blob is in the URL, so
-- that a new picture has a new URL and a browser's cached copy of the old
-- one is never shown for it.
avatarUrl :: UserId -> Avatar -> Text
avatarUrl u a = links.users.avatar u a.blob

-- | The URL a browser downloads a page from, exported as a document: a
-- link the application renders for the browser to follow, never fetched
-- by the application itself.
pageExportUrl :: PageId -> ExportFormat -> Text
pageExportUrl = links.pages.export

-- | The URL a browser downloads a space's pages from, exported as one document.
spaceExportUrl :: SpaceId -> ExportFormat -> Text
spaceExportUrl = links.spaces.export

-- | The URL a browser downloads the whole wiki from, as an archive.
archiveExportUrl :: Text
archiveExportUrl = links.archive.export

-- | The URL of a search. Every field of the query is in it, so the server
-- parses back the query that was sent.
searchUrl :: SearchQuery -> Text
searchUrl = searchParameters links.search

-- | Give the search endpoint's parameters for a query to a function of
-- them: its URL ('searchUrl'), or the client's call of it. Every field of
-- the query is a parameter, and 'searchQueryOf' reads them back.
searchParameters :: (Maybe Text -> Maybe SpaceId -> Bool -> Maybe Int -> Bool -> r) -> SearchQuery -> r
searchParameters endpoint q = endpoint (Just q.text) q.space (not q.includeSubspaces) (Just q.limit) q.templates

-- | The query a search's parameters describe: @q@ (no words, so no
-- results, if missing), @space@ (every space if missing), @only@ (only
-- that space, not its subspaces), @limit@ ('searchQuery''s default if
-- missing) and @templates@ (include the templates).
searchQueryOf :: Maybe Text -> Maybe SpaceId -> Bool -> Maybe Int -> Bool -> SearchQuery
searchQueryOf q space only limit templates =
  SearchQuery
    { text = fromMaybe "" q
    , space
    , includeSubspaces = not only
    , limit = fromMaybe (searchQuery "").limit limit
    , templates
    }
