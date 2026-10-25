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
-- 'AttachmentsApi', 'ArchiveApi', 'AdminApi', and a page's comments'
-- 'CommentsApi'), each field one endpoint named for the
-- @MonadWiki@ method it carries, gathered in 'WikiApi', with signing in
-- and out beside the session's own read. docs/api.md lists
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
-- * Who is asking is the server's to say, per request: the session the
--   request's cookie names on the public listener, the operator on the
--   admin listener. Every request that changes something must carry the
--   header of 'requestMarker', which a page of another site
--   cannot make a browser send here, and is refused with a 403 otherwise.
-- * A closed wiki ("Wiki.Core.Access") answers someone who has not signed
--   in with 'Wiki.Api.Error.Unauthenticated' (401) everywhere but 'info',
--   'session' (to read it, sign in and out), 'register' (which refuses
--   them itself) and 'invitations'.
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
  , InvitationsApi (..)
  , AccountApi (..)
  , CommentsApi (..)

    -- * Sessions
  , WithCookie
  , requestMarker

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
import Wiki.Api.Account (Account, AccountDisabled, Credentials, InvitationInfo, InvitationToken, NewAccount, NewPassword, PasswordChange, SignInMethods)
import Wiki.Api.Admin (AdministratorFlag, CreateSpacesFlag, Directory, GroupName, Invitations, Invited, NewInvitation, ServerStatus, WikiSettings)
import Wiki.Api.Comments (CommentsApi (..))
import Wiki.Api.Import (ImportPlan, ImportSummary)
import Wiki.Api.Info (ServerInfo)
import Wiki.Api.ServerSettings (MailTest, MailTestResult, ProviderChange, ProviderCheck, ServerSettings, ServerSettingsChange)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload, AttachmentUpload, ImportApply)
import Wiki.Api.Version (PageVersion, VersionTime, pageVersion)
import Wiki.Api.Zip (Zip)
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id
import Wiki.Core.Page (Page)
import Wiki.Core.Permission (SpaceAccess)
import Wiki.Core.Search (SearchHit)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.User (Group)
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
  , signIn :: mode :- "session" :> ReqBody '[JSON] Credentials :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Sign in ("Wiki.Api.Account"): the session the user now has, and the
  -- cookie that carries it. A login and password that do not match are
  -- 'Wiki.Api.Error.Unauthenticated', too many failed attempts
  -- 'Wiki.Api.Error.TooManyRequests'.
  , signOut :: mode :- "session" :> Delete '[JSON] (WithCookie SessionInfo)
  -- ^ Sign out: the session ends, its cookie is cleared, and the answer is
  -- who the asker is now, nobody.
  , register :: mode :- "accounts" :> ReqBody '[JSON] NewAccount :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Make oneself an account, in an open wiki, and be signed in as it, as
  -- 'signIn' answers. A closed wiki refuses with
  -- 'Wiki.Api.Error.Forbidden', a login another user has is
  -- 'Wiki.Api.Error.Conflict', and too many attempts from one address
  -- 'Wiki.Api.Error.TooManyRequests'.
  , invitations :: mode :- "invitations" :> NamedRoutes InvitationsApi
  , account :: mode :- "account" :> NamedRoutes AccountApi
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
  , comments :: mode :- "pages" :> Capture "page" PageId :> "threads" :> NamedRoutes CommentsApi
  -- ^ A page's comments ("Wiki.Api.Comments"), whose operations are
  -- @MonadComments@'s. The live channel that tells a tab of them as they
  -- happen is no servant route: the server upgrades @events@ to a
  -- WebSocket itself ("Wiki.Api.Events").
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
  , access :: mode :- Capture "space" SpaceId :> "grants" :> Get '[JSON] SpaceAccess
  -- ^ @spaceAccess@: the grants on the space and its ancestors, and whom a
  -- grant may be given to, for whoever administers the space.
  , setGrant :: mode :- Capture "space" SpaceId :> "grants" :> ReqBody '[JSON] SpaceGrantChange :> PutNoContent
  -- ^ @setSpaceGrant@: give a user or a group a permission on the space,
  -- or take it away.
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

-- | What only an administrator may ask ("Wiki.Api.Admin"): whoever holds
-- the global administer, which the operator on the server's admin listener
-- always does. Anyone else is refused ('Wiki.Api.Error.Forbidden') before
-- anything they named is looked for.
data AdminApi mode = AdminApi
  { status :: mode :- "status" :> Get '[JSON] ServerStatus
  -- ^ The server's version, data directory and counts.
  , directory :: mode :- "directory" :> Get '[JSON] Directory
  -- ^ @directory@: the users, who of them is an administrator, the groups
  -- and their members.
  , setAdministrator :: mode :- "users" :> Capture "user" UserId :> "administrator" :> ReqBody '[JSON] AdministratorFlag :> PutNoContent
  -- ^ @setAdministrator@: grant a user the global administer, or take it
  -- away, their own included.
  , setCreateSpaces :: mode :- "users" :> Capture "user" UserId :> "create-spaces" :> ReqBody '[JSON] CreateSpacesFlag :> PutNoContent
  -- ^ @setCreateSpaces@: grant a user the global create-spaces, or take it
  -- away.
  , createGroup :: mode :- "groups" :> ReqBody '[JSON] GroupName :> PostCreated '[JSON] Group
  -- ^ @createGroup@.
  , renameGroup :: mode :- "groups" :> Capture "group" GroupId :> "name" :> ReqBody '[JSON] GroupName :> Put '[JSON] Group
  -- ^ @renameGroup@.
  , deleteGroup :: mode :- "groups" :> Capture "group" GroupId :> DeleteNoContent
  -- ^ @deleteGroup@, with its members' membership and the grants to it.
  , addMember :: mode :- "groups" :> Capture "group" GroupId :> "members" :> Capture "user" UserId :> PutNoContent
  -- ^ @addMember@.
  , removeMember :: mode :- "groups" :> Capture "group" GroupId :> "members" :> Capture "user" UserId :> DeleteNoContent
  -- ^ @removeMember@.
  , createUser :: mode :- "users" :> ReqBody '[JSON] NewAccount :> PostCreated '[JSON] Account
  -- ^ @createUser@: make a user who signs in with a password
  -- ("Wiki.Api.Account"). A login another user has is
  -- 'Wiki.Api.Error.Conflict'.
  , setPassword :: mode :- "users" :> Capture "user" UserId :> "password" :> ReqBody '[JSON] NewPassword :> Put '[JSON] Account
  -- ^ @setPassword@: give a user a new password, which ends their
  -- sessions.
  , setDisabled :: mode :- "users" :> Capture "user" UserId :> "disabled" :> ReqBody '[JSON] AccountDisabled :> Put '[JSON] Account
  -- ^ @setDisabled@: disable a user's login, which ends their sessions, or
  -- enable it again.
  , settings :: mode :- "settings" :> Get '[JSON] WikiSettings
  -- ^ @wikiSettings@: whom the wiki lets in, and what a new account may do.
  , setSettings :: mode :- "settings" :> ReqBody '[JSON] WikiSettings :> Put '[JSON] WikiSettings
  -- ^ @setWikiSettings@: change them; the answer is the settings as they
  -- then are.
  , invitations :: mode :- "invitations" :> Get '[JSON] Invitations
  -- ^ @invitations@: those not yet used, and whether the server mails them.
  , invite :: mode :- "invitations" :> ReqBody '[JSON] NewInvitation :> PostCreated '[JSON] Invited
  -- ^ @invite@: invite an e-mail address; the server mails the link if it
  -- can, and otherwise the answer carries it.
  , revokeInvitation :: mode :- "invitations" :> Capture "invitation" InvitationId :> DeleteNoContent
  -- ^ @revokeInvitation@: its link no longer makes an account.
  , unlinkIdentity :: mode :- "users" :> Capture "user" UserId :> "identities" :> Capture "provider" Text :> DeleteNoContent
  -- ^ @unlinkUserIdentity@: the user no longer signs in with that
  -- provider's account (WP3.6 of docs/PLAN.md), and their sessions end.
  -- Allowed even when it was their last way in: an administrator may be
  -- taking away an account that should never have been connected, and
  -- gives them a password after. One they do not have is
  -- 'Wiki.Api.Error.NotFound'.
  , -- The server's own settings (WP4.4 of docs/PLAN.md,
    -- "Wiki.Api.ServerSettings"): its public address, its mail server and
    -- the providers people sign in with, whose secrets are written and
    -- never read back.
    server :: mode :- "server" :> Get '[JSON] ServerSettings
  -- ^ @serverSettings@: the settings, each secret as whether it is set.
  , setServer :: mode :- "server" :> ReqBody '[JSON] ServerSettingsChange :> Put '[JSON] ServerSettings
  -- ^ @setServerSettings@: replace them, each secret kept, replaced or
  -- cleared; the answer is the settings as they then are. They take effect
  -- with the next request.
  , checkProvider :: mode :- "server" :> "providers" :> Capture "provider" Text :> "check" :> ReqBody '[JSON] (Maybe ProviderChange) :> Post '[JSON] ProviderCheck
  -- ^ @checkProvider@: ask a provider how to sign in (discovery), as it is
  -- set, or, given in the body, as it would be.
  , testMail :: mode :- "server" :> "mail" :> "test" :> ReqBody '[JSON] MailTest :> Post '[JSON] MailTestResult
  -- ^ @sendTestMail@: send a mail to an address through the mail server
  -- as it is set.
  }
  deriving stock (Generic)

-- | An invitation, by the secret its link carries: what the person invited
-- does with it.
data InvitationsApi mode = InvitationsApi
  { details :: mode :- Capture "token" InvitationToken :> Get '[JSON] InvitationInfo
  -- ^ Whom it is for, if it may still be used: one that has been used,
  -- revoked or has expired is 'Wiki.Api.Error.NotFound'.
  , accept :: mode :- Capture "token" InvitationToken :> ReqBody '[JSON] NewAccount :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Make the account it invites to, with the login, name and password
  -- chosen, and be signed in as it: the invitation is used up. As
  -- 'register', but in a wiki open or closed.
  }
  deriving stock (Generic)

-- | The account of whoever is asking, signed in (WP3.6 of docs/PLAN.md):
-- the providers' accounts they sign in with, and their password (WP3.7).
-- Signing in with one, and
-- connecting one, are not here but at the server's own addresses
-- (@auth\/\<provider>\/start@, "Wiki.Api.Auth"), which the browser goes to
-- rather than fetches. Someone not signed in is refused with
-- 'Wiki.Api.Error.Unauthenticated', the server's operator, who signs in
-- with nothing, with 'Wiki.Api.Error.Invalid'.
data AccountApi mode = AccountApi
  { identities :: mode :- "identities" :> Get '[JSON] SignInMethods
  -- ^ Whether they have a password, and their identities.
  , unlinkIdentity :: mode :- "identities" :> Capture "provider" Text :> Delete '[JSON] SignInMethods
  -- ^ Disconnect the identity of a provider: how they sign in then. One
  -- that would leave them no way to sign in (no password, no other
  -- identity) is 'Wiki.Api.Error.Conflict', one they do not have
  -- 'Wiki.Api.Error.NotFound'.
  , changePassword :: mode :- "password" :> ReqBody '[JSON] PasswordChange :> Put '[JSON] SignInMethods
  -- ^ Change their password, or set one if they have none: how they sign
  -- in then. The current one, where they have one, must be given and
  -- right, or it is 'Wiki.Api.Error.Unauthenticated', and wrong ones are
  -- counted as failed sign-ins of their login from that address
  -- ('Wiki.Api.Error.TooManyRequests' when there have been too many). A
  -- new one that cannot be a password is 'Wiki.Api.Error.Invalid'. Their
  -- other sessions end; the one asking stays.
  }
  deriving stock (Generic)

-- | A response that sets or clears the session's cookie: the whole
-- @Set-Cookie@ header's value, which the server writes and the browser
-- keeps, unread by the application.
type WithCookie a = Headers '[Header "Set-Cookie" Text] a

-- | The header the application's own requests carry, as its name and value:
-- the server refuses a request that changes something without it.
--
-- It is how the server tells its application's requests from those a page
-- of another site makes a browser send with the wiki's cookie (a form
-- posted at it, a link followed, an image loaded): such a page can
-- send a form, but not a header of its own choosing, since a browser asks
-- the server first (CORS) and this server never says yes. Browsers say
-- where a request comes from themselves (@Sec-Fetch-Site@), but only to an
-- origin served over HTTPS or on the machine itself, and the wiki is
-- served over plain HTTP on a private network too (decision 20).
requestMarker :: (Text, Text)
requestMarker = ("X-Wiki-Request", "1")

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
