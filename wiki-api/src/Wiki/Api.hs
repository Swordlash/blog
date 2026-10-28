-- | The wiki's HTTP API, as a servant type: every operation of @MonadWiki@
-- (@wiki-app@'s backend interface), under @\/api\/v1@, plus the operations
-- only the server has (export, import, the server's description).
--
-- The server serves this type (@wiki-server@), and the HTTP backend in the
-- browser builds its request URLs from it ("Wiki.Api.Links"), so the two
-- cannot disagree about a path, a parameter or a header. The type compiles
-- for every target, including WebAssembly in the browser: servant's core
-- and servant-multipart's API types are pure Haskell, and only their
-- server side (servant-server, servant-multipart) is native.
--
-- The API is a record of routes per resource ('SpacesApi', 'PagesApi',
-- 'AttachmentsApi', 'ArchiveApi', 'AdminApi', a page's 'CommentsApi', and
-- the user's 'NotificationsApi'). Each field is one endpoint, named after
-- the @MonadWiki@ method it implements. 'WikiApi' collects them, together
-- with signing in and out and reading the session. docs/api.md lists every
-- endpoint with its method, path, body, response and errors.
--
-- = Conventions
--
-- * Bodies are JSON ("Wiki.Api.Types" for requests, the domain's types for
--   responses), except an attachment's file and an archive, which are
--   multipart forms ("Wiki.Api.Upload") or raw bytes.
-- * Any endpoint may refuse a request with an error status and an
--   'Wiki.Api.Error.ApiError' body: 404, 403, 409 or 400, as
--   "Wiki.Api.Error" describes. These errors are not in the types, because
--   servant's types have no place for them.
-- * Spaces and pages are addressed by id, except where @MonadWiki@ looks
--   them up by path: @…\/at\/\<slug>\/\<slug>…@.
-- * A response with a page carries the page's version as its @ETag@, and a
--   save sends the version back as @If-Match@ ("Wiki.Api.Version").
-- * Creating something responds 201 with the created record; deleting
--   responds 204.
-- * The server decides who makes each request: the user of the session
--   named by the request's cookie on the public listener, the operator on
--   the admin listener. Every request that changes something must carry
--   the header 'requestMarker', which a page of another site cannot make a
--   browser send. A request without it is refused with 403.
-- * A closed wiki ("Wiki.Core.Access") responds to a visitor who is not
--   signed in with 'Wiki.Api.Error.Unauthenticated' (401) on every endpoint
--   except 'info', 'session' (to read the session, sign in and sign out),
--   'register' (which refuses by itself), 'invitations' and the endpoints
--   of links sent by mail ('passwordReset', 'emailVerification',
--   'unsubscribe').
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
  , PasswordResetApi (..)
  , CommentsApi (..)
  , NotificationsApi (..)

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
import Wiki.Api.Activity (Activity)
import Wiki.Api.Admin (AdministratorFlag, CreateSpacesFlag, Directory, GroupName, Invitations, Invited, NewInvitation, ServerStatus, WikiSettings)
import Wiki.Api.Backups (BackupSettingsChange, Backups)
import Wiki.Api.Comments (CommentsApi (..))
import Wiki.Api.Export (ExportFormat)
import Wiki.Api.Import (ImportPlan, ImportSummary)
import Wiki.Api.Info (ServerInfo)
import Wiki.Api.Notifications (NotificationsApi (..))
import Wiki.Api.Security (CurrentPassword, EmailChange, EmailState, MailToken, NewPasswordByMail, OneTimeCode, RecoveryCodes, ResetRequest, SecondFactorState, SessionRef, SessionSummary, TotpEnrolment)
import Wiki.Api.ServerSettings (MailTest, MailTestResult, ProviderChange, ProviderCheck, ServerSettings, ServerSettingsChange)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload, AttachmentUpload, ImportApply)
import Wiki.Api.Version (PageVersion, VersionTime, pageVersion)
import Wiki.Api.Zip (Zip)
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Blog (PostDetails)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id
import Wiki.Core.Page (Page, PageSummary)
import Wiki.Core.Permission (SpaceAccess)
import Wiki.Core.Search (SearchHit)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space, SpaceProfile)
import Wiki.Core.User (Group)
import Wiki.Core.Version (Version, VersionInfo)

-- | The whole API, at @\/api\/v1@.
type Api = "api" :> "v1" :> NamedRoutes WikiApi

api :: Proxy Api
api = Proxy

-- | 'WikiApi': the API's resources.
data WikiApi mode = WikiApi
  { info :: mode :- "info" :> Get '[JSON] ServerInfo
  -- ^ The server's description of itself.
  , session :: mode :- "session" :> Get '[JSON] SessionInfo
  -- ^ The current user, if any: @session@.
  , signIn :: mode :- "session" :> ReqBody '[JSON] Credentials :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Sign in ("Wiki.Api.Account"). The response is the user's new session
  -- and the cookie that carries it. A login and password that do not
  -- match are 'Wiki.Api.Error.Unauthenticated', too many failed attempts
  -- 'Wiki.Api.Error.TooManyRequests'.
  , signOut :: mode :- "session" :> Delete '[JSON] (WithCookie SessionInfo)
  -- ^ Sign out: the session ends and its cookie is cleared. The response
  -- is the new session state, with no user.
  , secondFactor :: mode :- "session" :> "second-factor" :> ReqBody '[JSON] OneTimeCode :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Complete a sign-in that 'signIn' answered with
  -- 'Wiki.Api.Error.SecondFactorRequired' ("Wiki.Api.Security"). The
  -- request carries a code from the user's authenticator application or
  -- one of their recovery codes, and the cookie that 'signIn' response
  -- set. The response is the user's new session, as for 'signIn'. A wrong
  -- code is 'Wiki.Api.Error.Unauthenticated', counted as a failed sign-in;
  -- a sign-in that has expired or was never started in this browser is
  -- 'Wiki.Api.Error.Invalid'.
  , passwordReset :: mode :- "password-reset" :> NamedRoutes PasswordResetApi
  , emailVerification :: mode :- "email-verification" :> Capture "token" MailToken :> PostNoContent
  -- ^ Follow a link that verifies an e-mail address: the address the link
  -- was sent to becomes the user's verified address, if it is still the
  -- user's address. A link that has been used or has expired, or whose
  -- address is no longer the user's, is 'Wiki.Api.Error.NotFound'.
  , register :: mode :- "accounts" :> ReqBody '[JSON] NewAccount :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Create an account for oneself, in an open wiki, and sign in with it;
  -- the response is as for 'signIn'. A closed wiki refuses with
  -- 'Wiki.Api.Error.Forbidden', a login another user has is
  -- 'Wiki.Api.Error.Conflict', and too many attempts from one address are
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
          :> QueryFlag "templates"
          :> Get '[JSON] [SearchHit]
  -- ^ @searchPages@. The parameters are those of the application's own
  -- search address (@\/search\/?q=…&space=…&only@), plus @templates@ to
  -- include the spaces' templates, except that @space@ is the space's id
  -- rather than its path, since a 'Wiki.Core.Search.SearchQuery' holds the
  -- id. "Wiki.Api.Links" builds the address from a query, and
  -- 'Wiki.Api.Links.searchQueryOf' builds the query from the parameters,
  -- so that both sides fill in missing parameters the same way.
  , archive :: mode :- NamedRoutes ArchiveApi
  , admin :: mode :- "admin" :> NamedRoutes AdminApi
  , comments :: mode :- "pages" :> Capture "page" PageId :> "threads" :> NamedRoutes CommentsApi
  -- ^ A page's comments ("Wiki.Api.Comments"), with the operations of
  -- @MonadComments@. The live channel that sends comment changes to a tab
  -- as they happen is not a servant route: the server upgrades @events@ to
  -- a WebSocket itself ("Wiki.Api.Events").
  , notifications :: mode :- "notifications" :> NamedRoutes NotificationsApi
  -- ^ The signed-in user's notifications, the pages they watch, and how
  -- they are notified ("Wiki.Api.Notifications").
  , unsubscribe :: mode :- "unsubscribe" :> Capture "token" MailToken :> PostNoContent
  -- ^ Follow the unsubscribe link in a notification mail: notification
  -- mail is turned off for the user the link names, without signing in. An
  -- invalid link is 'Wiki.Api.Error.NotFound'.
  }
  deriving stock (Generic)

-- | 'SpacesApi': spaces, and the pages of each.
data SpacesApi mode = SpacesApi
  { list :: mode :- Get '[JSON] [Space]
  -- ^ @listSpaces@.
  , pageCounts :: mode :- "page-counts" :> Get '[JSON] (Map SpaceId Int)
  -- ^ @pageCounts@: the number of pages in each space the requester may
  -- view, as an object keyed by space id.
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
  , setProfile :: mode :- Capture "space" SpaceId :> "profile" :> ReqBody '[JSON] SpaceProfile :> Put '[JSON] Space
  -- ^ @setSpaceProfile@: its description, icon and home page.
  , uploadIcon :: mode :- Capture "space" SpaceId :> "icon" :> MultipartForm Mem AttachmentUpload :> Post '[JSON] Space
  -- ^ @uploadSpaceIcon@: an image for the space's icon, as a form's file
  -- part, as for an attachment ("Wiki.Api.Upload"). The part's file name
  -- is ignored.
  , icon :: mode :- Capture "space" SpaceId :> "icon" :> Capture "blob" BlobId :> RawM
  -- ^ The image of a space's icon, at the URL @spaceIconUrl@ returns
  -- ("Wiki.Api.Links.spaceIconUrl"). The URL contains the image's blob id,
  -- so that a new image has a new URL; a blob id that is not the space's
  -- icon is 'Wiki.Api.Error.NotFound'. Served like an attachment (see
  -- 'AttachmentsApi'), to anyone who may view the space.
  , setOrder :: mode :- Capture "space" SpaceId :> "order" :> ReqBody '[JSON] SpaceOrder :> Put '[JSON] Space
  -- ^ @setSpaceOrder@.
  , move :: mode :- Capture "space" SpaceId :> "move" :> ReqBody '[JSON] SpaceMove :> Post '[JSON] Space
  -- ^ @moveSpace@.
  , shift :: mode :- Capture "space" SpaceId :> "shift" :> ReqBody '[JSON] ShiftBy :> Post '[JSON] Space
  -- ^ @shiftSpace@.
  , delete :: mode :- Capture "space" SpaceId :> DeleteNoContent
  -- ^ @deleteSpace@.
  , access :: mode :- Capture "space" SpaceId :> "grants" :> Get '[JSON] SpaceAccess
  -- ^ @spaceAccess@: the grants on the space and its ancestors, and the
  -- users and groups a grant may be given to, for an administrator of the
  -- space.
  , setGrant :: mode :- Capture "space" SpaceId :> "grants" :> ReqBody '[JSON] SpaceGrantChange :> PutNoContent
  -- ^ @setSpaceGrant@: give a user or a group a permission on the space,
  -- or remove it.
  , listPages :: mode :- Capture "space" SpaceId :> "pages" :> Get '[JSON] [PageSummary]
  -- ^ @listPages@: summaries of the space's pages, without their bodies,
  -- in the space's page order.
  , postDetails :: mode :- Capture "space" SpaceId :> "post-details" :> Get '[JSON] (Map PageId PostDetails)
  -- ^ @postDetails@: the details each page of the space is listed with as
  -- a blog post (its first author, its number of comments and its
  -- excerpt), as an object keyed by page id.
  , pageAt :: mode :- Capture "space" SpaceId :> "pages" :> "at" :> CaptureAll "path" Slug :> Get '[JSON] (Versioned Page)
  -- ^ @getPage@: the page at a path of slugs from the space's top level.
  , createPage :: mode :- Capture "space" SpaceId :> "pages" :> ReqBody '[JSON] NewPage :> PostCreated '[JSON] (Versioned Page)
  -- ^ @createPage@.
  , export :: mode :- Capture "space" SpaceId :> "export" :> Capture "format" ExportFormat :> RawM
  -- ^ The space's pages as one document ("Wiki.Api.Export"), in the
  -- space's order, after a title page and a table of contents, for anyone
  -- who may view the space. Raw, like a page's export (see 'PagesApi').
  }
  deriving stock (Generic)

-- | 'PagesApi': pages, by id, with their attachment uploads, their drafts
-- and their histories.
data PagesApi mode = PagesApi
  { save :: mode :- Capture "page" PageId :> IfMatch :> ReqBody '[JSON] PageEdit :> Put '[JSON] (Versioned Page)
  -- ^ @savePage@, against the version in @If-Match@.
  , move :: mode :- Capture "page" PageId :> "move" :> ReqBody '[JSON] PageMove :> Post '[JSON] Page
  -- ^ @movePage@.
  , shift :: mode :- Capture "page" PageId :> "shift" :> ReqBody '[JSON] ShiftBy :> Post '[JSON] Page
  -- ^ @shiftPage@.
  , template :: mode :- Capture "page" PageId :> "template" :> ReqBody '[JSON] PageTemplate :> Put '[JSON] Page
  -- ^ @setPageTemplate@: whether the page is one of its space's templates.
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
  -- ^ @listVersions@: the page's history, latest first.
  , version :: mode :- Capture "page" PageId :> "versions" :> Capture "version" VersionTime :> Get '[JSON] Version
  -- ^ @getVersion@: one version, by its time.
  , restore :: mode :- Capture "page" PageId :> "versions" :> Capture "version" VersionTime :> "restore" :> IfMatch :> Post '[JSON] (Versioned Page)
  -- ^ @restoreVersion@: save that version's title and body as the page's
  -- latest version, against the version in @If-Match@, like a save.
  , export :: mode :- Capture "page" PageId :> "export" :> Capture "format" ExportFormat :> RawM
  -- ^ The page as a document ("Wiki.Api.Export"), for anyone who may read
  -- it, as a download (@Content-Disposition: attachment@) named after its
  -- title. Raw, because the response's media type is the format's, and
  -- servant's types cannot make it depend on a capture. A format the
  -- server cannot produce (a PDF without a TeX engine, a presentation of a
  -- page that is not a deck) is 'Wiki.Api.Error.Invalid', and so is a
  -- document pandoc or TeX failed to produce, with the reason. An export
  -- requested while the same user's previous export is still running is
  -- 'Wiki.Api.Error.TooManyRequests'.
  }
  deriving stock (Generic)

-- | 'AttachmentsApi': attachments, by id.
data AttachmentsApi mode = AttachmentsApi
  { delete :: mode :- Capture "attachment" AttachmentId :> DeleteNoContent
  -- ^ @deleteAttachment@.
  , content :: mode :- Capture "attachment" AttachmentId :> Capture "name" Text :> RawM
  -- ^ An attachment's bytes, at the URL @attachmentUrl@ returns
  -- ("Wiki.Api.Links.attachmentUrl"). The name is the attachment's, so
  -- that the URL ends in the file's name; a different name is
  -- 'Wiki.Api.Error.NotFound'.
  --
  -- Raw rather than a typed response, because this endpoint needs what
  -- servant's types cannot express: the response's @Content-Type@ is the
  -- attachment's own media type, the file is streamed from disk rather
  -- than read into memory, and a request for a byte range (which a
  -- @\<video>@ makes to seek) gets that range. The server responds to
  -- @GET@ and @HEAD@.
  }
  deriving stock (Generic)

-- | 'ArchiveApi': a whole wiki as an archive ("Wiki.Core.Export"), exported and imported.
data ArchiveApi mode = ArchiveApi
  { export :: mode :- "export" :> Get '[Zip] (Headers '[Disposition] LByteString)
  -- ^ The wiki as a zip file, as a download ('exportDisposition').
  , importPreview :: mode :- "import" :> "preview" :> MultipartForm Mem ArchiveUpload :> Post '[JSON] ImportPlan
  -- ^ A preview of what importing an archive would do ("Wiki.Api.Import").
  , importApply :: mode :- "import" :> "apply" :> MultipartForm Mem ImportApply :> Post '[JSON] ImportSummary
  -- ^ Import an archive, with the choices made after the preview.
  }
  deriving stock (Generic)

-- | 'AdminApi': the endpoints only an administrator may call
-- ("Wiki.Api.Admin"), that is a user with the global administer
-- permission. The operator on the server's admin listener always has it.
-- Anyone else is refused ('Wiki.Api.Error.Forbidden') before any record
-- named in the request is looked up.
data AdminApi mode = AdminApi
  { status :: mode :- "status" :> Get '[JSON] ServerStatus
  -- ^ The server's version, data directory and counts, its schema
  -- version, the newest backup, and the last errors it logged.
  , activity :: mode :- "activity" :> QueryParam "actor" UserId :> QueryParam "offset" Int :> Get '[JSON] Activity
  -- ^ @activity@: a page of the audit log ("Wiki.Api.Activity"), newest
  -- first, starting at @offset@ (0 if missing), with one actor's entries or
  -- everyone's.
  , directory :: mode :- "directory" :> Get '[JSON] Directory
  -- ^ @directory@: the users, which of them are administrators, the groups
  -- and their members.
  , setAdministrator :: mode :- "users" :> Capture "user" UserId :> "administrator" :> ReqBody '[JSON] AdministratorFlag :> PutNoContent
  -- ^ @setAdministrator@: grant a user the global administer permission,
  -- or remove it, including the caller's own.
  , setCreateSpaces :: mode :- "users" :> Capture "user" UserId :> "create-spaces" :> ReqBody '[JSON] CreateSpacesFlag :> PutNoContent
  -- ^ @setCreateSpaces@: grant a user the global create-spaces permission,
  -- or remove it.
  , createGroup :: mode :- "groups" :> ReqBody '[JSON] GroupName :> PostCreated '[JSON] Group
  -- ^ @createGroup@.
  , renameGroup :: mode :- "groups" :> Capture "group" GroupId :> "name" :> ReqBody '[JSON] GroupName :> Put '[JSON] Group
  -- ^ @renameGroup@.
  , deleteGroup :: mode :- "groups" :> Capture "group" GroupId :> DeleteNoContent
  -- ^ @deleteGroup@, together with its memberships and the grants to it.
  , addMember :: mode :- "groups" :> Capture "group" GroupId :> "members" :> Capture "user" UserId :> PutNoContent
  -- ^ @addMember@.
  , removeMember :: mode :- "groups" :> Capture "group" GroupId :> "members" :> Capture "user" UserId :> DeleteNoContent
  -- ^ @removeMember@.
  , createUser :: mode :- "users" :> ReqBody '[JSON] NewAccount :> PostCreated '[JSON] Account
  -- ^ @createUser@: create a user who signs in with a password
  -- ("Wiki.Api.Account"). A login another user has is
  -- 'Wiki.Api.Error.Conflict'.
  , setPassword :: mode :- "users" :> Capture "user" UserId :> "password" :> ReqBody '[JSON] NewPassword :> Put '[JSON] Account
  -- ^ @setPassword@: give a user a new password, which ends their
  -- sessions. A user who cannot have a password (who signs in only with a
  -- sign-in provider, 'Wiki.Api.Account.providerOnly') is
  -- 'Wiki.Api.Error.Invalid'.
  , sendPasswordLink :: mode :- "users" :> Capture "user" UserId :> "password-link" :> PostNoContent
  -- ^ @sendPasswordLink@: send a user, at their verified address, the same
  -- link to choose a new password that "Forgot your password?" sends
  -- ("Wiki.Api.Security", WP5.6 of docs/PLAN.md). When the server sends no
  -- mail, or the user has no verified address, is disabled or cannot have
  -- a password, the response is 'Wiki.Api.Error.Invalid' with the reason;
  -- a second link within a minute of the last is
  -- 'Wiki.Api.Error.TooManyRequests'.
  , setDisabled :: mode :- "users" :> Capture "user" UserId :> "disabled" :> ReqBody '[JSON] AccountDisabled :> Put '[JSON] Account
  -- ^ @setDisabled@: disable a user's account, which ends their sessions,
  -- or enable it again.
  , settings :: mode :- "settings" :> Get '[JSON] WikiSettings
  -- ^ @wikiSettings@: who the wiki lets in, and what a new account may do.
  , setSettings :: mode :- "settings" :> ReqBody '[JSON] WikiSettings :> Put '[JSON] WikiSettings
  -- ^ @setWikiSettings@: change the settings; the response is the settings
  -- after the change.
  , invitations :: mode :- "invitations" :> Get '[JSON] Invitations
  -- ^ @invitations@: the unused invitations, and whether the server sends them by mail.
  , invite :: mode :- "invitations" :> ReqBody '[JSON] NewInvitation :> PostCreated '[JSON] Invited
  -- ^ @invite@: invite an e-mail address. The server sends the link by
  -- mail if it can; otherwise the response contains the link.
  , revokeInvitation :: mode :- "invitations" :> Capture "invitation" InvitationId :> DeleteNoContent
  -- ^ @revokeInvitation@: the invitation's link can no longer create an account.
  , removeSecondFactor :: mode :- "users" :> Capture "user" UserId :> "second-factor" :> DeleteNoContent
  -- ^ @removeSecondFactor@: the user signs in with their password alone
  -- again (WP4.11 of docs/PLAN.md). This is for a user who has lost their
  -- authenticator and their recovery codes. A user without a second
  -- factor is 'Wiki.Api.Error.NotFound'.
  , unlinkIdentity :: mode :- "users" :> Capture "user" UserId :> "identities" :> Capture "provider" Text :> DeleteNoContent
  -- ^ @unlinkUserIdentity@: the user can no longer sign in with that
  -- provider's account (WP3.6 of docs/PLAN.md), and their sessions end.
  -- Allowed even when it was their last way to sign in: an administrator
  -- may be removing an account that should never have been connected, and
  -- then gives the user a password. A provider the user has no identity
  -- with is 'Wiki.Api.Error.NotFound'.
  , -- The server's own settings (WP4.4 of docs/PLAN.md,
    -- "Wiki.Api.ServerSettings"): its public address, its mail server and
    -- the sign-in providers. Their secrets can be written but are never
    -- returned.
    server :: mode :- "server" :> Get '[JSON] ServerSettings
  -- ^ @serverSettings@: the settings, with each secret shown only as whether it is set.
  , setServer :: mode :- "server" :> ReqBody '[JSON] ServerSettingsChange :> Put '[JSON] ServerSettings
  -- ^ @setServerSettings@: replace the settings, each secret kept,
  -- replaced or cleared; the response is the settings after the change.
  -- They take effect from the next request.
  , checkProvider :: mode :- "server" :> "providers" :> Capture "provider" Text :> "check" :> ReqBody '[JSON] (Maybe ProviderChange) :> Post '[JSON] ProviderCheck
  -- ^ @checkProvider@: run a sign-in provider's discovery, with the
  -- provider's current settings or with the settings in the body.
  , testMail :: mode :- "server" :> "mail" :> "test" :> ReqBody '[JSON] MailTest :> Post '[JSON] MailTestResult
  -- ^ @sendTestMail@: send a mail to an address through the configured
  -- mail server.
  , -- The server's automatic backups (WP4.9 of docs/PLAN.md,
    -- "Wiki.Api.Backups"), off until they are turned on here.
    backups :: mode :- "server" :> "backups" :> Get '[JSON] Backups
  -- ^ @backups@: the settings (with the rclone configuration shown only as
  -- whether it is set), the last backup made or attempted, and any backup
  -- in progress.
  , setBackups :: mode :- "server" :> "backups" :> ReqBody '[JSON] BackupSettingsChange :> Put '[JSON] Backups
  -- ^ @setBackupSettings@: replace the settings, the configuration kept,
  -- replaced or cleared; they take effect immediately.
  , backUpNow :: mode :- "server" :> "backups" :> "run" :> Post '[JSON] Backups
  -- ^ @backUpNow@: make a backup now, if backups are on. The response
  -- comes when the backup is done, or after a timeout with the backup
  -- still in progress.
  }
  deriving stock (Generic)

-- | 'InvitationsApi': an invitation, addressed by the secret token in its
-- link, as the invited person uses it.
data InvitationsApi mode = InvitationsApi
  { details :: mode :- Capture "token" InvitationToken :> Get '[JSON] InvitationInfo
  -- ^ The address it was sent to and when it expires, if it can still be
  -- used. One that has been used, revoked or has expired is
  -- 'Wiki.Api.Error.NotFound'.
  , accept :: mode :- Capture "token" InvitationToken :> ReqBody '[JSON] NewAccount :> Post '[JSON] (WithCookie SessionInfo)
  -- ^ Create the account the invitation is for, with the chosen login,
  -- name and password, and sign in with it. The invitation is then used
  -- up. Like 'register', but in an open or a closed wiki.
  }
  deriving stock (Generic)

-- | 'AccountApi': the signed-in user's own account (WP3.6 of
-- docs/PLAN.md): the sign-in providers' identities they sign in with, and
-- their password (WP3.7). Signing in with a provider, and connecting one,
-- are not here but at the server's own addresses
-- (@auth\/\<provider>\/start@, "Wiki.Api.Auth"), which the browser
-- navigates to rather than fetches. A visitor who is not signed in is
-- refused with 'Wiki.Api.Error.Unauthenticated', and the server's
-- operator, who has no account, with 'Wiki.Api.Error.Invalid'.
data AccountApi mode = AccountApi
  { identities :: mode :- "identities" :> Get '[JSON] SignInMethods
  -- ^ Whether the user has a password, and their identities.
  , unlinkIdentity :: mode :- "identities" :> Capture "provider" Text :> Delete '[JSON] SignInMethods
  -- ^ Disconnect a provider's identity. The response is the user's sign-in
  -- methods after the change. Disconnecting the last way to sign in (no
  -- password, no other identity) is 'Wiki.Api.Error.Conflict', and a
  -- provider the user has no identity with is 'Wiki.Api.Error.NotFound'.
  , changePassword :: mode :- "password" :> ReqBody '[JSON] PasswordChange :> Put '[JSON] SignInMethods
  -- ^ Change the user's password, or set one if they have none. The
  -- response is their sign-in methods after the change. Where they have a
  -- password, the request must carry the correct current one, or it is
  -- 'Wiki.Api.Error.Unauthenticated'. Wrong passwords are counted as failed
  -- sign-ins of their login from that address
  -- ('Wiki.Api.Error.TooManyRequests' when there have been too many). An
  -- invalid new password is 'Wiki.Api.Error.Invalid'. Their other sessions
  -- end; the current session stays.
  , sessions :: mode :- "sessions" :> Get '[JSON] [SessionSummary]
  -- ^ The user's sessions, with the current one marked, most recently used
  -- first (WP4.11 of docs/PLAN.md, "Wiki.Api.Security").
  , endSession :: mode :- "sessions" :> Capture "session" SessionRef :> Delete '[JSON] [SessionSummary]
  -- ^ End one of the user's sessions other than the current one (which
  -- ends with 'signOut'). The response is their remaining sessions. A
  -- session they do not have is 'Wiki.Api.Error.NotFound', the current
  -- session 'Wiki.Api.Error.Invalid'.
  , endOtherSessions :: mode :- "sessions" :> Delete '[JSON] [SessionSummary]
  -- ^ End every session of the user except the current one: "Sign out
  -- everywhere". The response is their remaining sessions, the current one
  -- only.
  , secondFactorState :: mode :- "second-factor" :> Get '[JSON] SecondFactorState
  -- ^ Whether the user has a second factor.
  , enrolTotp :: mode :- "second-factor" :> "totp" :> ReqBody '[JSON] CurrentPassword :> Post '[JSON] TotpEnrolment
  -- ^ Start setting up a second factor, with the user's current password
  -- where they have one (a wrong password is
  -- 'Wiki.Api.Error.Unauthenticated', counted as a failed sign-in). The
  -- response is a new secret for an authenticator application; sign-in
  -- does not ask for a code until it is confirmed. A user who already has
  -- a second factor is 'Wiki.Api.Error.Conflict'.
  , confirmTotp :: mode :- "second-factor" :> "totp" :> ReqBody '[JSON] OneTimeCode :> Put '[JSON] RecoveryCodes
  -- ^ Confirm the second factor with a code the application shows. From
  -- then on every sign-in asks for a code, and the response is the
  -- recovery codes, shown only this once. A wrong code is
  -- 'Wiki.Api.Error.Unauthenticated', counted as a failed sign-in.
  , removeSecondFactor :: mode :- "second-factor" :> "remove" :> ReqBody '[JSON] OneTimeCode :> Post '[JSON] SecondFactorState
  -- ^ Remove the second factor, with a code or a recovery code (a wrong
  -- code is 'Wiki.Api.Error.Unauthenticated', counted as a failed
  -- sign-in). The user then signs in with their password alone again.
  , email :: mode :- "email" :> Get '[JSON] EmailState
  -- ^ The user's e-mail address, whether it is verified, and whether the
  -- server sends mail.
  , setEmail :: mode :- "email" :> ReqBody '[JSON] EmailChange :> Put '[JSON] EmailState
  -- ^ Set the user's e-mail address, or remove it. A new address is not
  -- verified until the user follows the link sent to it. Changing or
  -- removing the address needs the current password where the user has
  -- one (a wrong password is 'Wiki.Api.Error.Unauthenticated', counted as
  -- a failed sign-in). Without a mail server it is 'Wiki.Api.Error.Invalid'.
  }
  deriving stock (Generic)

-- | 'PasswordResetApi': a password reset by mail ("Wiki.Api.Security"),
-- for a user who is not signed in.
data PasswordResetApi mode = PasswordResetApi
  { request :: mode :- ReqBody '[JSON] ResetRequest :> PostNoContent
  -- ^ Request a reset link, by login or e-mail address. The response is the
  -- same whether or not the request names a user, and the link is sent
  -- only to a user's verified address. Too many requests from one address
  -- are 'Wiki.Api.Error.TooManyRequests'; a server that sends no mail
  -- responds 'Wiki.Api.Error.Invalid', for every login alike.
  , reset :: mode :- Capture "token" MailToken :> ReqBody '[JSON] NewPasswordByMail :> PostNoContent
  -- ^ Set a new password with a reset link, which ends every session the
  -- user had; they then sign in with the new password. A link that has
  -- been used or has expired is 'Wiki.Api.Error.NotFound'; an invalid
  -- password is 'Wiki.Api.Error.Invalid'.
  }
  deriving stock (Generic)

-- | 'WithCookie': a response that sets or clears the session cookie. The
-- value is the whole @Set-Cookie@ header, which the server writes and the
-- browser stores; the application never reads it.
type WithCookie a = Headers '[Header "Set-Cookie" Text] a

-- | The header the application's own requests carry, as its name and
-- value. The server refuses a request that changes something without it.
--
-- The server uses it to tell its application's requests from requests a
-- page of another site makes a browser send with the wiki's cookie (a
-- form posted to the wiki, a link followed, an image loaded). Such a page
-- can send a form, but not a header of its own choosing, because a
-- browser asks the server first (CORS) and this server always refuses.
-- Browsers do report a request's origin themselves (@Sec-Fetch-Site@),
-- but only to an origin served over HTTPS or on the local machine, and
-- the wiki may also be served over plain HTTP on a private network
-- (decision 20).
requestMarker :: (Text, Text)
requestMarker = ("X-Wiki-Request", "1")

-- | 'Versioned': a response that carries a page's version as its @ETag@.
type Versioned a = Headers '[Header "ETag" PageVersion] a

-- | 'IfMatch': the version a save was made against, which a save must send.
type IfMatch = Header' '[Required, Strict] "If-Match" PageVersion

-- | A page, with its version.
versioned :: Page -> Versioned Page
versioned p = addHeader (pageVersion p) p

-- | 'Disposition': the header that makes a browser save a response as a file.
type Disposition = Header "Content-Disposition" Text

-- | The @Content-Disposition@ of an export made at this time: a file named
-- as the demo names its own exports, @wiki-\<date>.zip@.
exportDisposition :: UTCTime -> Text
exportDisposition t = "attachment; filename=\"wiki-" <> toS (formatTime defaultTimeLocale "%Y-%m-%d" t) <> ".zip\""
