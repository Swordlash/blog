-- | The wiki's HTTP API, as a servant type: every operation of @MonadWiki@
-- (@wiki-app@'s backend interface), under @\/api\/v1@, plus what the server
-- alone does (export, import, its own description).
--
-- The server serves this type (@wiki-server@), and the browser's backend over
-- HTTP builds its requests' addresses from it ("Wiki.Api.Links"), so the two
-- cannot disagree about a path, a parameter or a header. The type builds on
-- every target, the browser's WebAssembly included: servant's core and
-- servant-multipart's API types are pure Haskell, and only the server's
-- side of them (servant-server, servant-multipart) is native.
--
-- The API is a record of routes per resource ('SpacesApi', 'PagesApi',
-- 'AttachmentsApi', 'ArchiveApi', 'AdminApi'), each field one endpoint named for the
-- @MonadWiki@ method it carries, gathered in 'WikiApi'. docs/api.md lists
-- every endpoint with its method, path, body, response and errors.
--
-- = Conventions
--
-- * Bodies are JSON ("Wiki.Api.Types" for requests, the domain's types for
--   responses), except an attachment's file and an archive, which are
--   multipart forms ("Wiki.Api.Upload") or bytes.
-- * A refusal is a status and an 'Wiki.Api.Error.ApiError' body, from any
--   endpoint: 404, 403, 409 or 400, as "Wiki.Api.Error" says. Such errors
--   are not listed in the types, as servant has no place for them.
-- * Spaces and pages are addressed by id, except where @MonadWiki@ looks
--   them up by path: @…\/at\/\<slug>\/\<slug>…@.
-- * A page's responses carry its version as their @ETag@, and a save sends
--   it back as @If-Match@ ("Wiki.Api.Version").
-- * Making something answers 201 with what was made; deleting answers 204.
module Wiki.Api
  ( -- * The API
    Api
  , api
  , WikiApi (..)
  , SpacesApi (..)
  , PagesApi (..)
  , AttachmentsApi (..)
  , ArchiveApi (..)
  , AdminApi (..)

    -- * Versions
  , Versioned
  , IfMatch
  , versioned

    -- * Archives
  , Disposition
  , exportDisposition
  )
where

import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Protolude
import Servant.API
import Servant.Multipart.API (Mem, MultipartForm)
import Wiki.Api.Admin (ServerStatus)
import Wiki.Api.Import (ImportPlan, ImportSummary)
import Wiki.Api.Info (ServerInfo)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload, AttachmentUpload, ImportApply)
import Wiki.Api.Version (PageVersion, VersionTime, pageVersion)
import Wiki.Api.Zip (Zip)
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id
import Wiki.Core.Page (Page)
import Wiki.Core.Search (SearchHit)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.Version (Version, VersionInfo)

-- | The whole API, at @\/api\/v1@.
type Api = "api" :> "v1" :> NamedRoutes WikiApi

api :: Proxy Api
api = Proxy

-- | The API's resources.
data WikiApi mode = WikiApi
  { info :: mode :- "info" :> Get '[JSON] ServerInfo
  -- ^ What the server says about itself.
  , session :: mode :- "session" :> Get '[JSON] SessionInfo
  -- ^ Who is asking: @session@.
  , spaces :: mode :- "spaces" :> NamedRoutes SpacesApi
  , pages :: mode :- "pages" :> NamedRoutes PagesApi
  , attachments :: mode :- "attachments" :> NamedRoutes AttachmentsApi
  , search
      :: mode
        :- "search"
          :> QueryParam "q" Text
          :> QueryParam "space" SpaceId
          :> QueryFlag "only"
          :> QueryParam "limit" Int
          :> Get '[JSON] [SearchHit]
  -- ^ @searchPages@. The parameters are those of the application's own
  -- search address (@\/search\/?q=…&space=…&only@), except that @space@ is
  -- the space's id rather than its path, since that is what a
  -- 'Wiki.Core.Search.SearchQuery' holds. "Wiki.Api.Links" makes the
  -- address from a query, and 'Wiki.Api.Links.searchQueryOf' the query from
  -- the parameters, so that both sides fill in what is missing alike.
  , archive :: mode :- NamedRoutes ArchiveApi
  , admin :: mode :- "admin" :> NamedRoutes AdminApi
  }
  deriving stock (Generic)

-- | Spaces, and the pages of each.
data SpacesApi mode = SpacesApi
  { list :: mode :- Get '[JSON] [Space]
  -- ^ @listSpaces@.
  , atPath :: mode :- "at" :> CaptureAll "path" Slug :> Get '[JSON] Space
  -- ^ @getSpace@: the space at a path of slugs from the top level.
  , create :: mode :- ReqBody '[JSON] NewSpace :> PostCreated '[JSON] Space
  -- ^ @createSpace@.
  , rename :: mode :- Capture "space" SpaceId :> "name" :> ReqBody '[JSON] SpaceName :> Put '[JSON] Space
  -- ^ @renameSpace@.
  , setPublic :: mode :- Capture "space" SpaceId :> "public" :> ReqBody '[JSON] SpacePublic :> Put '[JSON] Space
  -- ^ @setSpacePublic@.
  , setMathMacros :: mode :- Capture "space" SpaceId :> "math-macros" :> ReqBody '[JSON] SpaceMathMacros :> Put '[JSON] Space
  -- ^ @setSpaceMathMacros@.
  , setOrder :: mode :- Capture "space" SpaceId :> "order" :> ReqBody '[JSON] SpaceOrder :> Put '[JSON] Space
  -- ^ @setSpaceOrder@.
  , move :: mode :- Capture "space" SpaceId :> "move" :> ReqBody '[JSON] SpaceMove :> Post '[JSON] Space
  -- ^ @moveSpace@.
  , shift :: mode :- Capture "space" SpaceId :> "shift" :> ReqBody '[JSON] ShiftBy :> Post '[JSON] Space
  -- ^ @shiftSpace@.
  , delete :: mode :- Capture "space" SpaceId :> DeleteNoContent
  -- ^ @deleteSpace@.
  , listPages :: mode :- Capture "space" SpaceId :> "pages" :> Get '[JSON] [Page]
  -- ^ @listPages@.
  , pageAt :: mode :- Capture "space" SpaceId :> "pages" :> "at" :> CaptureAll "path" Slug :> Get '[JSON] (Versioned Page)
  -- ^ @getPage@: the page at a path of slugs from the space's top level.
  , createPage :: mode :- Capture "space" SpaceId :> "pages" :> ReqBody '[JSON] NewPage :> PostCreated '[JSON] (Versioned Page)
  -- ^ @createPage@.
  }
  deriving stock (Generic)

-- | Pages, by id, with their attachments' uploads, their drafts and their
-- histories.
data PagesApi mode = PagesApi
  { save :: mode :- Capture "page" PageId :> IfMatch :> ReqBody '[JSON] PageEdit :> Put '[JSON] (Versioned Page)
  -- ^ @savePage@, against the version in @If-Match@.
  , move :: mode :- Capture "page" PageId :> "move" :> ReqBody '[JSON] PageMove :> Post '[JSON] Page
  -- ^ @movePage@.
  , shift :: mode :- Capture "page" PageId :> "shift" :> ReqBody '[JSON] ShiftBy :> Post '[JSON] Page
  -- ^ @shiftPage@.
  , delete :: mode :- Capture "page" PageId :> DeleteNoContent
  -- ^ @deletePage@.
  , upload :: mode :- Capture "page" PageId :> "attachments" :> MultipartForm Mem AttachmentUpload :> PostCreated '[JSON] Attachment
  -- ^ @uploadAttachment@.
  , draft :: mode :- Capture "page" PageId :> "draft" :> Get '[JSON] (Maybe Draft)
  -- ^ @getDraft@: the signed-in user's draft of the page, @null@ if they
  -- have none.
  , saveDraft :: mode :- Capture "page" PageId :> "draft" :> ReqBody '[JSON] DraftEdit :> Put '[JSON] Draft
  -- ^ @saveDraft@.
  , discardDraft :: mode :- Capture "page" PageId :> "draft" :> DeleteNoContent
  -- ^ @discardDraft@.
  , versions :: mode :- Capture "page" PageId :> "versions" :> Get '[JSON] [VersionInfo]
  -- ^ @listVersions@: the page's history, the latest first.
  , version :: mode :- Capture "page" PageId :> "versions" :> Capture "version" VersionTime :> Get '[JSON] Version
  -- ^ @getVersion@: one version, by its time.
  , restore :: mode :- Capture "page" PageId :> "versions" :> Capture "version" VersionTime :> "restore" :> IfMatch :> Post '[JSON] (Versioned Page)
  -- ^ @restoreVersion@: save that version's title and body as the page's
  -- latest, against the version in @If-Match@, as a save is.
  }
  deriving stock (Generic)

-- | Attachments, by id.
data AttachmentsApi mode = AttachmentsApi
  { delete :: mode :- Capture "attachment" AttachmentId :> DeleteNoContent
  -- ^ @deleteAttachment@.
  , content :: mode :- Capture "attachment" AttachmentId :> Capture "name" Text :> RawM
  -- ^ An attachment's bytes, at the address @attachmentUrl@ gives
  -- ("Wiki.Api.Links.attachmentUrl"). The name is the attachment's, so that
  -- the address ends in the file's name; one that is not the attachment's
  -- is 'Wiki.Api.Error.NotFound'.
  --
  -- Raw rather than a typed response, because what servant's types cannot
  -- say is what this endpoint is for: the response's @Content-Type@ is the
  -- attachment's own media type, the file is streamed from disk rather than
  -- read into memory, and a request for a range of it (which a @\<video>@
  -- makes to seek) gets that range. The server answers @GET@ and @HEAD@.
  }
  deriving stock (Generic)

-- | A whole wiki as an archive ("Wiki.Core.Export"), out and in.
data ArchiveApi mode = ArchiveApi
  { export :: mode :- "export" :> Get '[Zip] (Headers '[Disposition] LByteString)
  -- ^ The wiki as a zip file, to download ('exportDisposition').
  , importPreview :: mode :- "import" :> "preview" :> MultipartForm Mem ArchiveUpload :> Post '[JSON] ImportPlan
  -- ^ What importing an archive would do ("Wiki.Api.Import").
  , importApply :: mode :- "import" :> "apply" :> MultipartForm Mem ImportApply :> Post '[JSON] ImportSummary
  -- ^ Import an archive, as chosen.
  }
  deriving stock (Generic)

-- | What only the administrator may ask ("Wiki.Api.Admin"): on the
-- server's admin listener, where the operator is the administrator, or (from
-- Phase 3) on the public one as an administrator. Phase 3 adds the panel's
-- users and permissions here.
newtype AdminApi mode = AdminApi
  { status :: mode :- "status" :> Get '[JSON] ServerStatus
  -- ^ The server's version, data directory and counts.
  }
  deriving stock (Generic)

-- | A response that carries a page's version as its @ETag@.
type Versioned a = Headers '[Header "ETag" PageVersion] a

-- | The version a save was made against, which a save must send.
type IfMatch = Header' '[Required, Strict] "If-Match" PageVersion

-- | A page, with its version.
versioned :: Page -> Versioned Page
versioned p = addHeader (pageVersion p) p

-- | The header that makes a browser save a response as a file.
type Disposition = Header "Content-Disposition" Text

-- | The @Content-Disposition@ of an export made at this time: a file named
-- as the demo names its own exports, @wiki-\<date>.zip@.
exportDisposition :: UTCTime -> Text
exportDisposition t = "attachment; filename=\"wiki-" <> toS (formatTime defaultTimeLocale "%Y-%m-%d" t) <> ".zip\""
