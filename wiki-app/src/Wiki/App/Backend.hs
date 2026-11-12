-- | The backend interface: 'MonadWiki' is every read and write the
-- application makes on the wiki, whatever stores it.
--
-- Components never know which backend they run on: they are polymorphic in
-- their monad and ask for @'MonadWiki' m@. There are two implementations in
-- the browser. The in-memory backend ("Wiki.App.Backend.Mem") keeps the
-- wiki in the browser, for the serverless demo, and saves it in
-- IndexedDB. The HTTP backend ("Wiki.App.Backend.Http") talks to
-- @wiki-server@ over its API. The server has a third, over SQLite
-- ("Wiki.Server.Storage").
-- All of them pass the same contract tests ("Wiki.App.Backend.Contract", the
-- library @wiki-app:contract@), which check what this module's
-- documentation promises.
--
-- = Errors
--
-- Every method that can fail returns @'Either' 'WikiError'@ and never
-- throws for a reason in 'WikiError': a component shows what went wrong
-- rather than dying of it. When more than one error applies, the first in
-- this order is returned:
--
-- 1. 'NotFound': an id or a path names nothing, or it names a space the
--    current user may not view, or something in such a space (a page, an
--    attachment, a comment, a version, a draft, a watch, a subspace).
-- 2. 'Forbidden': it names something the current user may view but not do
--    this to. Permissions are checked before the arguments are validated,
--    so someone who may not act learns nothing about whether their request
--    was otherwise well-formed.
-- 3. 'Invalid': the request cannot be carried out as asked (a blank title, a
--    move that would make a space its own ancestor, an attachment too large).
-- 4. 'Conflict': the request was right when it was made, but the wiki has
--    changed since (a save based on an older version of the page).
--
-- A space the current user may not view answers exactly as a space that
-- does not exist, so nobody learns from a refusal that a space or a page
-- exists. The permission to view a space is checked before a page in it
-- is looked up, so a page's path in such a space is 'NotFound' whether
-- the page exists or not. A search scoped to such a space finds nothing,
-- as a search scoped to a space that does not exist does. The
-- administration is the exception ("Wiki.App.Backend.Admin"): it checks
-- the global 'Wiki.Core.Permission.Administer' before it looks up any id,
-- so whoever does not administer the wiki gets 'Forbidden' whatever they
-- name. The ancestors of a space the user may view are listed by
-- 'listSpaces' with their names and slugs, but reading one of them
-- ('getSpace', 'listPages') is 'NotFound' all the same.
--
-- The HTTP backend, whose wiki is on the server, can fail to reach it at
-- all: the network is down, the server does not answer in time, or it
-- breaks. That is 'Unreachable'. No rule causes it, and a retry may
-- well work, so a component offers to try again. Five reads cannot be
-- refused, so they return no @Either@: 'session', 'listSpaces',
-- 'pageCounts' and 'searchPages' here, and
-- 'Wiki.App.Backend.Notifications.mentionable'. They throw 'Unreachable'
-- instead, and the component that shows their result catches it with
-- 'attempt' (see "Loading" below).
--
-- = Permissions
--
-- Every read returns only what the current user may view (except for the
-- names and slugs of the ancestors of what they may view, which 'listSpaces'
-- includes so that its spaces have paths), and every write checks the rules
-- of "Wiki.Core.Permission" against the current user before it changes
-- anything. The rules for each write are those of
-- "Wiki.Core.Permission" (its rules for writes), which say in one place what
-- each method needs:
--
-- * creating a top-level space needs the global 'CreateSpaces';
-- * creating a subspace needs 'CreateSpaces' or 'AdministerSpace' on the
--   parent, and the parent has to be visible;
-- * moving a space needs 'AdministerSpace' on it and, for the destination,
--   'CreateSpaces' to make it top-level or 'AdministerSpace' on the new
--   parent;
-- * renaming a space, deleting it, making it public or private, giving
--   it math macros, choosing the order of its children, setting its
--   profile ('setSpaceProfile', 'uploadSpaceIcon'), and reading and
--   changing who is granted what on it ('spaceAccess', 'setSpaceGrant')
--   need 'AdministerSpace' on it;
-- * creating, saving, moving and deleting pages, making a page a template
--   or not ('setPageTemplate'), and uploading and deleting attachments,
--   need 'Edit' on the page's space (on both spaces, for a page moved from
--   one to another);
-- * moving a child up or down its list by hand needs 'Edit' on the space
--   whose list it is: a page's own space, a subspace's parent;
-- * reading, saving and discarding one's draft of a page need someone signed
--   in, with 'Edit' on the page's space;
-- * reading a page's history ('listVersions', 'getVersion') needs what
--   reading the page does, 'View' on its space, and restoring a version
--   ('restoreVersion') what saving it does, 'Edit'.
--
-- Whoever creates a space is granted 'AdministerSpace' on it, so that a user
-- with 'CreateSpaces' alone can do something with the space they made.
--
-- = Home pages
--
-- A space opens at its home page ('Wiki.Core.Space.homePage'), one of its
-- own pages. 'createSpace' makes the space with one, titled "Home", from a
-- template ('Wiki.Core.Space.homeBody'), whose first version is its
-- creator's, and the space keeps it: nobody chooses another
-- ('setSpaceProfile' does not name one). Every space has one but the
-- container of personal spaces and an encrypted space
-- ('Wiki.Core.Space.hasHome'). Deleting the home page, and moving it, to
-- another space or within its own, are 'Invalid'; so are deleting a page
-- with the home page under it and moving such a page to another space.
-- Moving it up or down among its siblings ('shiftPage') needs 'Edit', as
-- for any page. Changing it needs 'AdministerSpace' on its space
-- ('Wiki.Core.Permission.canEditPage'): saving it, which renames it too,
-- restoring a version of it, its drafts, and its attachments' upload and
-- deletion. Someone who only edits the space gets 'Forbidden' for those,
-- and may still create a page under it.
--
-- = Loading
--
-- A backend answers at once when it returns the result synchronously,
-- without waiting for the network. The in-memory backend always can. The
-- HTTP backend can only when the response is cached
-- ("Wiki.App.Backend.Http.Cache"). When the backend can answer at once
-- ('atOnce'), a component loads its data in its initial state, so that its
-- first render is the page a prerender shows. Otherwise it renders a
-- loading state and fetches in its initializer, on a fiber, so that the
-- tree's loop never waits on the network (decision 18 of the plan). A
-- fiber is a lightweight thread running a component's program in
-- haskell-halogen: its synchronous part runs on the tree's main loop, and
-- a wait (here, for the network) runs on a worker thread, so the rest of
-- the tree goes on meanwhile (see "Flow of a component" in
-- haskell-halogen's @AGENTS.md@).
-- 'MonadLoad' provides this. It is a separate class from 'MonadWiki'
-- because its methods take a backend program as an argument instead of
-- returning one, and a monad transformer cannot lift such a method. So a
-- component uses it in its own monad, in an initial state or through
-- 'Halogen.Query.HalogenM.lift', never in 'HalogenM'.
--
-- The HTTP backend caches page content (pages, lists of pages, searches,
-- version lists) only until the reader first goes to another route. Those
-- responses are the ones the server prerendered the page with, and they
-- make the program's first render match that page. The shell tells the
-- backend when the route changes ('endPreload'). From then on page content
-- is always fetched, so a page shown again shows what the server holds
-- now, also when someone else changed it meanwhile (WP5.14 of the plan).
--
-- = Order
--
-- A space lists its subspaces in one order and its pages in another, each
-- chosen by whoever administers it: by name (natural order, the default),
-- by date, newest or oldest first, or by hand ("Wiki.Core.Order"). The
-- class's methods return lists in those orders, each parent followed by
-- its children, so that a client can show a list as it is. The order
-- depends only on what the list holds, so a client that sorts again with
-- "Wiki.Core.Order" gets the same order. The top-level spaces have no
-- parent to choose for them and are listed by name.
--
-- In the order by hand, each child has a position among its siblings. A
-- new child, and one moved in from elsewhere, goes last. Moving a child up,
-- down, to the top or to the bottom ('shiftPage', 'shiftSpace') renumbers
-- its siblings in their new order. A deletion leaves the other positions
-- as they are. When a space switches to the order by hand, its children
-- keep the order they were shown in: they are given positions in that
-- order. Moving a child among its siblings changes no address.
--
-- = Addresses
--
-- Spaces and pages keep their slugs when they are renamed, so that links to
-- them keep working; a new slug is only made when a node is created, and when
-- a move brings it among siblings that already use its slug ('freshSlug').
-- A title or name with nothing a slug can be made of (only punctuation, or a
-- script with no ASCII spelling) gets the slug @page@ or @space@, made unique
-- in the same way.
module Wiki.App.Backend
  ( -- * The interface
    MonadWiki (..)
  , WikiError (..)
  , UrlOwner (..)
  , noUrlOwner

    -- * Loading
  , MonadLoad (..)
  , unreachable

    -- * Who is asking
  , Session (..)
  , anonymous
  , anonymousIn
  , shutOut
  , sessionPrincipal
  , currentUser
  , withOwnUser
  , sameAsking

    -- * Exports
  , ExportTarget (..)
  , Document (..)

    -- * Limits
  , maxAttachmentSize
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Time (UTCTime)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.Export (ExportFormat)
import Wiki.Api.ServerSettings (AssistantService, HomePage, defaultHomePage)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Backlink (Backlink)
import Wiki.Core.Blog (PostDetails)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxKind)
import Wiki.Core.Notification (PageLocation)
import Wiki.Core.Order (ChildOrder, Children, Shift)
import Wiki.Core.Page (Page, PageSummary)
import Wiki.Core.Permission (Grants (..), Principal (..), SpaceAccess, SpacePermission, Subject)
import Wiki.Core.Search (SearchHit, SearchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space, SpaceProfile)
import Wiki.Core.User (Avatar, SignInProvider, Standing (..), User (..))
import Wiki.Core.Version (Version, VersionInfo, VersionsQuery)

-- | Why a request was not carried out. See the module's Haddock for which is
-- returned when.
data WikiError
  = -- | Nothing has that id or path, or nothing the current user may see:
    -- a space they may not view, and everything in it, is not found.
    NotFound
  | -- | The current user may see it, but may not do that to it.
    Forbidden
  | -- | Something has changed since the request was made: the text says
    -- what, for a person to read.
    Conflict Text
  | -- | The request cannot be carried out as it is: the text says why, for a
    -- person to read.
    Invalid Text
  | -- | The backend could not be asked, or failed to answer: the network is
    -- down, the server took too long or broke. Nothing was refused, and
    -- trying again may well work. The text says what happened, for a
    -- person to read. The in-memory backend never gives it.
    Unreachable Text
  deriving stock (Eq, Show)

-- | So that the reads that return no @Either@ (the five in "Errors" in the
-- module's Haddock) can throw 'Unreachable', and 'attempt' can catch it.
instance Exception WikiError

-- | Throw 'Unreachable', from a read that returns no @Either@ to report
-- it in.
unreachable :: (MonadIO m) => Text -> m a
unreachable = liftIO . throwIO . Unreachable

-- | 'Session' describes the current user: who they are, their groups and
-- their grants. The client uses it to run the permission rules itself and
-- hide what the user cannot do.
data Session = Session
  { user :: Maybe User
  -- ^ 'Nothing' for someone who is not signed in.
  , groups :: Set GroupId
  -- ^ The groups the user is in; empty when nobody is signed in.
  , grants :: Grants
  -- ^ The grants given to the user or to one of their groups: global ones,
  -- and those on spaces. Grants to others are left out, since the rules
  -- would not count them anyway and they are nobody else's business. Nobody
  -- who is not signed in holds a grant: what they see is the public spaces.
  , standing :: Standing
  -- ^ How the user is signed in, which says whether they may sign in or
  -- sign out, on a backend where people sign in.
  , providers :: [SignInProvider]
  -- ^ The providers one may sign in with instead of a password, on a
  -- backend that has any (a server whose configuration names them, WP3.6
  -- of docs/PLAN.md). They are part of the session so that the page the
  -- server prerenders and the program's first render offer the same ones.
  , exports :: [ExportFormat]
  -- ^ The document formats the backend can export pages and spaces to
  -- ("Wiki.Api.Export"), which the page and space views offer. The demo has
  -- none, because it has no pandoc. A server offers the PDF formats only if
  -- it found a TeX engine. Part of the session for the same reason as
  -- 'providers'.
  , homePage :: HomePage
  -- ^ The public configuration of the shared front page.
  , boxes :: [BoxKind]
  -- ^ The kinds of box the administration defined, with their labels,
  -- colours and icons ("Wiki.Core.Markdown.Box"), which every page is
  -- rendered with. Part of the session for the same reason as 'providers':
  -- the prerendered page and the program's first render draw the same
  -- boxes.
  , mathMacros :: Maybe Text
  -- ^ The wiki's built-in math macros as the administration keeps them
  -- (WP5.41 of docs/PLAN.md), which every formula is set with; 'Nothing'
  -- for the ones the wiki ships with (@web/src/katex-macros.tex@). Part
  -- of the session for the same reason as 'boxes'.
  , assistantServices :: [AssistantService]
  -- ^ The services besides Anthropic's and OpenAI's own that the writing
  -- assistant may use, as a server's administration lists them (WP5.60
  -- of docs/PLAN.md): the assistant's settings offer them. The demo has
  -- no server, and offers none.
  , whatsNew :: Maybe Int
  -- ^ Whether the backend has the page "What's new?" (WP5.66 of
  -- docs/PLAN.md, "Wiki.Api.WhatsNew"): 'Nothing' for none (the demo, or
  -- a server started with @--no-whats-new@), and otherwise the number of
  -- the newest entry it has, 0 for none. The shell links to the page at
  -- the bottom of the spaces' sidebar, and marks the link while this is
  -- newer than the newest entry the reader has seen.
  }
  deriving stock (Eq, Show)

-- | The session of someone who is not signed in, in an open wiki.
anonymous :: Session
anonymous = anonymousIn Open

-- | The session of someone who is not signed in, in a wiki with this
-- access setting. They hold no grant, and their grants record whom the
-- wiki is open to ("Wiki.Core.Access"), so that the application knows
-- before anyone signs in whether there is anything to show them.
anonymousIn :: Access -> Session
anonymousIn access = Session {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access}, standing = NotSignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Nothing}

-- | Whether the wiki is closed to whoever is asking: it is closed, and they
-- have not signed in. They are shown the way to sign in and nothing else.
shutOut :: Session -> Bool
shutOut s = s.grants.access == Closed && isNothing s.user

-- | The current user in the form the rules of "Wiki.Core.Permission" take,
-- or 'Nothing' when nobody is signed in.
sessionPrincipal :: Session -> Maybe Principal
sessionPrincipal s = (\u -> Principal {user = u.id, groups = s.groups}) <$> s.user

-- | The session with the signed-in user's record as it now is, after a
-- change of their own (their avatar), which changes nothing else of it.
withOwnUser :: User -> Session -> Session
withOwnUser u s = Session {user = Just u, groups = s.groups, grants = s.grants, standing = s.standing, providers = s.providers, exports = s.exports, homePage = s.homePage, boxes = s.boxes, mathMacros = s.mathMacros, assistantServices = s.assistantServices, whatsNew = s.whatsNew}

-- | Whether two sessions are of the same requester with the same rights:
-- the same user (or nobody), groups, grants and standing. The user's own
-- record (their name, their avatar) may differ: a session announced after
-- such a change needs nothing reloaded but what shows the user.
sameAsking :: Session -> Session -> Bool
sameAsking a b = ((\u -> u.id) <$> a.user) == ((\u -> u.id) <$> b.user) && a.groups == b.groups && a.grants == b.grants && a.standing == b.standing

-- | The user who is signed in, if anyone is.
currentUser :: (MonadWiki m) => m (Maybe User)
currentUser = (\s -> s.user) <$> session

-- | 'ExportTarget' is what an export is made of: a page, or a space's
-- pages as one document ('fetchExport').
data ExportTarget
  = ExportPage PageId
  | ExportSpace SpaceId
  deriving stock (Eq, Show)

-- | 'Document' is an exported document as the backend fetched it: the file
-- name the server gave it (from its @Content-Disposition@), its media type
-- and its bytes.
data Document = Document
  { fileName :: Text
  , mediaType :: Text
  , bytes :: ByteString
  }
  deriving stock (Eq, Show)

-- | The largest attachment a backend accepts, in bytes: 50 MB.
maxAttachmentSize :: Natural
maxAttachmentSize = 50 * 1024 * 1024

-- | 'UrlOwner': who holds the addresses of attachments a backend makes
-- in the browser (the object URLs of an encrypted page's attachments,
-- decrypted): a view, for as long as it shows them. A view asks for an
-- owner ('newUrlOwner'), asks for addresses under it, and lets it go
-- ('releaseUrls') when what it shows is replaced or it closes.
newtype UrlOwner = UrlOwner Int
  deriving stock (Eq, Ord, Show)

-- | The owner no backend registers: addresses asked for under it are
-- those that need no owner (a server's, the demo's), and none of an
-- encrypted page's. A view asks under it before its life has begun (in
-- its initial state, which may run for a view that never starts, and so
-- never ends), and registers an owner of its own when it starts.
noUrlOwner :: UrlOwner
noUrlOwner = UrlOwner 0

-- | 'MonadWiki' is the backend interface: every read and write the
-- application makes on the wiki.
--
-- Every method has a default that lifts it through a monad transformer, so
-- a transformer over a backend is a backend too. 'HalogenM' is such a
-- transformer, so a component's handlers call these methods directly. A
-- call waits for the backend in whatever way that backend waits; in a
-- component, it waits on the component's own fiber (its lightweight
-- thread; see "Loading" above), as any other @lift@ does.
class (Monad m) => MonadWiki m where
  -- | The session of the current user.
  session :: m Session
  default session :: (MonadTrans t, m ~ t n, MonadWiki n) => m Session
  session = lift session

  -- | The real document backing the shared wiki root.
  getHomeDocument :: m (Either WikiError (Space, Page))
  default getHomeDocument :: (MonadTrans t, m ~ t n, MonadWiki n) => m (Either WikiError (Space, Page))
  getHomeDocument = lift getHomeDocument

  -- * Spaces

  -- | Every space the current user may view, together with the ancestors of
  -- each, so that the list is always a whole tree from its top-level spaces
  -- down: the client can build every path and breadcrumb from it with
  -- "Wiki.Core.Path". An ancestor that the user may not view itself (because
  -- the grant they have is on a subspace of it) is listed for its name and
  -- slug only: 'getSpace' and 'listPages' answer 'NotFound' for it, and
  -- the client can tell this in advance from the permission rules.
  --
  -- The whole tree, rather than one level at a time, because a wiki has tens
  -- of spaces rather than thousands and the sidebar shows all of them.
  -- Each space comes before its subspaces, which come in its order (see
  -- "Order" above).
  listSpaces :: m [Space]
  default listSpaces :: (MonadTrans t, m ~ t n, MonadWiki n) => m [Space]
  listSpaces = lift listSpaces

  -- | The space at a path of slugs from the top level. The empty path names
  -- no space.
  getSpace :: [Slug] -> m (Either WikiError Space)
  default getSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => [Slug] -> m (Either WikiError Space)
  getSpace = lift . getSpace

  -- | Create a private space, at the top level or as a subspace of
  -- another, with this name and a slug made from it. It goes last among its
  -- siblings, lists its children by name, has no description and the
  -- default icon, and has one page, its home page (see "Home pages" above).
  -- Its creator is granted 'Wiki.Core.Permission.AdministerSpace' on it.
  createSpace :: Maybe SpaceId -> Text -> m (Either WikiError Space)
  default createSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => Maybe SpaceId -> Text -> m (Either WikiError Space)
  createSpace p = lift . createSpace p

  -- | Give a space a new name; its slug stays.
  renameSpace :: SpaceId -> Text -> m (Either WikiError Space)
  default renameSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Text -> m (Either WikiError Space)
  renameSpace s = lift . renameSpace s

  -- | Make a space readable by everyone (and its subspaces with it), or not.
  setSpacePublic :: SpaceId -> Bool -> m (Either WikiError Space)
  default setSpacePublic :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Bool -> m (Either WikiError Space)
  setSpacePublic s = lift . setSpacePublic s

  -- | Make a space private from its parent ('Wiki.Core.Space.sealed'), or
  -- not: sealed, it inherits no grant and no public flag from the spaces
  -- above it, so that only those granted on it (or a global
  -- administrator) see it. Like 'setSpacePublic', it needs
  -- 'Wiki.Core.Permission.AdministerSpace' on the space, which its
  -- parent's administrators have by inheritance. Sealing the space would
  -- take that from them, so whoever seals a space and would no longer
  -- administer it is granted 'Wiki.Core.Permission.AdministerSpace' on
  -- it.
  setSpaceSealed :: SpaceId -> Bool -> m (Either WikiError Space)
  default setSpaceSealed :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Bool -> m (Either WikiError Space)
  setSpaceSealed s = lift . setSpaceSealed s

  -- * Personal spaces

  -- | The current user's personal space ('Wiki.Core.Space.owner'), shown
  -- or not ('Wiki.Core.Space.active'), or 'Nothing' if they have none.
  -- Someone not signed in, and the server's operator, have none and may
  -- have none: 'Forbidden'.
  personalSpace :: m (Either WikiError (Maybe Space))
  default personalSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => m (Either WikiError (Maybe Space))
  personalSpace = lift personalSpace

  -- | Turn the current user's personal space on ('True') or off. The first
  -- time it is turned on, it is made: a public space named after them
  -- ('Wiki.Core.Space.personalName'), with their login as its slug, a home
  -- page, and 'Wiki.Core.Permission.AdministerSpace' for them, in the
  -- container of personal spaces ("User subspaces"), which is made too
  -- when no user has had a personal space yet. Turned off, the space is
  -- hidden from everyone, its content kept; turned on again, it is shown
  -- as it was. Turning off a personal space the user does not have is
  -- 'NotFound'. A personal space is otherwise an ordinary space, but it
  -- cannot be renamed or moved ('Invalid'); deleting it, which its owner
  -- may, lets them make a new one. The result is the space.
  setPersonalSpace :: Bool -> m (Either WikiError Space)
  default setPersonalSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => Bool -> m (Either WikiError Space)
  setPersonalSpace = lift . setPersonalSpace

  -- * Avatars

  -- | Give the current user an avatar ('Wiki.Core.User.Avatar'): its media
  -- type and its bytes, checked as 'Wiki.Core.Space.checkAvatarUpload'
  -- checks them ('Invalid' if they do not pass). The bytes are stored as a
  -- space icon's are, and the picture replaces the one the user had. The
  -- result is the user with it. Someone not signed in, and the server's
  -- operator, have no account to give one: 'Forbidden'.
  --
  -- A personal space with no icon of its own shows its owner's avatar
  -- ('Wiki.Core.Space.withOwnerAvatar'), wherever the backend answers with
  -- it. Every comment, version and page author shows the avatar the user
  -- has now: nothing is stored with them.
  setAvatar :: Text -> ByteString -> m (Either WikiError User)
  default setAvatar :: (MonadTrans t, m ~ t n, MonadWiki n) => Text -> ByteString -> m (Either WikiError User)
  setAvatar t = lift . setAvatar t

  -- | Take the current user's avatar away; the result is the user without
  -- it. Refused as 'setAvatar' is.
  removeAvatar :: m (Either WikiError User)
  default removeAvatar :: (MonadTrans t, m ~ t n, MonadWiki n) => m (Either WikiError User)
  removeAvatar = lift removeAvatar

  -- | The URL a browser fetches a user's avatar from, as 'spaceIconUrl'
  -- gives a space's icon: an object URL in the demo (a @data:@ URL
  -- natively), the server's address for it on the HTTP backend. The empty
  -- text for an avatar whose bytes the backend does not have.
  avatarUrl :: UserId -> Avatar -> m Text
  default avatarUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => UserId -> Avatar -> m Text
  avatarUrl u = lift . avatarUrl u

  -- | Give a space its math macros ('Wiki.Core.Space.mathMacros'), which
  -- its subspaces inherit; the empty text for none. Blank lines at either
  -- end are dropped. The text is stored as it is. The browser checks
  -- whether KaTeX can parse it while it is edited, and a block KaTeX cannot
  -- parse never stops a page from rendering.
  setSpaceMathMacros :: SpaceId -> Text -> m (Either WikiError Space)
  default setSpaceMathMacros :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Text -> m (Either WikiError Space)
  setSpaceMathMacros s = lift . setSpaceMathMacros s

  -- | Give a space its profile: its description, its icon (an emoji, a
  -- colour, the image it has, or the default) and its home page (one of
  -- its pages, or none), checked as 'Wiki.Core.Space.checkProfile' checks
  -- them; what does not pass is 'Invalid'. An image is uploaded with
  -- 'uploadSpaceIcon'. An image the space had, which the new profile does
  -- not keep, is removed from the space.
  --
  -- The space behind the wiki's home page ('getHomeDocument') takes only
  -- an icon (WP5.45 of docs/PLAN.md): it is the wiki's own icon, and the
  -- favicon of the pages outside any space. Only an administrator of the
  -- wiki sets it, and the rest of the profile given is ignored: the home's
  -- description, home page and blog are its own.
  setSpaceProfile :: SpaceId -> SpaceProfile -> m (Either WikiError Space)
  default setSpaceProfile :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> SpaceProfile -> m (Either WikiError Space)
  setSpaceProfile s = lift . setSpaceProfile s

  -- | Set a space's icon to an image: its media type and its bytes, checked
  -- as 'Wiki.Core.Space.checkIconUpload' checks them ('Invalid' if they do
  -- not pass). The bytes are stored as an attachment's are, and the image
  -- replaces any image the space had before. For the wiki's home it takes
  -- an administrator of the wiki, as 'setSpaceProfile' does.
  uploadSpaceIcon :: SpaceId -> Text -> ByteString -> m (Either WikiError Space)
  default uploadSpaceIcon :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Text -> ByteString -> m (Either WikiError Space)
  uploadSpaceIcon s t = lift . uploadSpaceIcon s t

  -- | The URL a browser fetches a space's icon image from, as
  -- 'attachmentUrl' gives an attachment's: an object URL in the demo
  -- (a @data:@ URL natively), the server's address for it on the HTTP
  -- backend. The empty text for a space whose icon is no image, or one
  -- whose bytes the backend does not have.
  spaceIconUrl :: Space -> m Text
  default spaceIconUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => Space -> m Text
  spaceIconUrl = lift . spaceIconUrl

  -- | The number of pages in each space the current user may view, by
  -- space, which the directory of spaces shows. A space they may not view
  -- (an ancestor listed only for its name) is left out.
  pageCounts :: m (Map SpaceId Int)
  default pageCounts :: (MonadTrans t, m ~ t n, MonadWiki n) => m (Map SpaceId Int)
  pageCounts = lift pageCounts

  -- | Move a space, with its subspaces and pages, under another space or to
  -- the top level, where it goes last among its new siblings. A move under
  -- the space itself or one of its subspaces is 'Invalid'.
  moveSpace :: SpaceId -> Maybe SpaceId -> m (Either WikiError Space)
  default moveSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Maybe SpaceId -> m (Either WikiError Space)
  moveSpace s = lift . moveSpace s

  -- | Delete a space with its subspaces, their pages and attachments, and the
  -- grants on them.
  deleteSpace :: SpaceId -> m (Either WikiError ())
  default deleteSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError ())
  deleteSpace = lift . deleteSpace

  -- * Permissions on a space

  -- | Who may do what on a space: the grants on it and on its ancestors,
  -- which it inherits, and the users and groups a grant may be given to
  -- ("Wiki.Core.Permission"'s 'SpaceAccess'). The space's own grants come
  -- first, then its parent's, and so on up; each in the order it was
  -- given.
  spaceAccess :: SpaceId -> m (Either WikiError SpaceAccess)
  default spaceAccess :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError SpaceAccess)
  spaceAccess = lift . spaceAccess

  -- | Give a user or a group a permission on a space, which its subspaces
  -- inherit, or take it away (a grant on an ancestor can only be taken
  -- away on that ancestor). A grant given twice, or taken from someone who
  -- does not have it, changes nothing and succeeds. Giving it to a user or
  -- group that does not exist is 'Invalid', not 'NotFound': the request's
  -- address names the space, and only the space can be not found. Like the
  -- other arguments, this is checked after the permission.
  --
  -- An administrator of the space may take the permission away from
  -- themself. The backend allows it, but the space's view does not offer it
  -- (see 'Wiki.Core.Permission.keepsAdministering'), just as the
  -- administration does not offer taking away one's own global administer.
  setSpaceGrant :: SpaceId -> Subject -> SpacePermission -> Bool -> m (Either WikiError ())
  default setSpaceGrant :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Subject -> SpacePermission -> Bool -> m (Either WikiError ())
  setSpaceGrant s who p = lift . setSpaceGrant s who p

  -- * Order

  -- | Choose the order a space lists its subspaces or its pages in. Chosen
  -- 'ByHand', the children keep the order they had: they are given
  -- positions in it.
  setSpaceOrder :: SpaceId -> Children -> ChildOrder -> m (Either WikiError Space)
  default setSpaceOrder :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Children -> ChildOrder -> m (Either WikiError Space)
  setSpaceOrder s c = lift . setSpaceOrder s c

  -- | Move a subspace up, down, to the top or to the bottom of its parent's
  -- list. Its parent has to list its subspaces 'ByHand', and a top-level
  -- space has no parent; both cases are 'Invalid'. A move past the end of
  -- the list (up from the top) changes nothing and succeeds. The result is
  -- the space with its new position.
  shiftSpace :: SpaceId -> Shift -> m (Either WikiError Space)
  default shiftSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Shift -> m (Either WikiError Space)
  shiftSpace s = lift . shiftSpace s

  -- | Move a page up, down, to the top or to the bottom among its siblings
  -- (the pages with the same parent). Its space has to list its pages
  -- 'ByHand', or it is 'Invalid'; otherwise as 'shiftSpace'.
  shiftPage :: PageId -> Shift -> m (Either WikiError Page)
  default shiftPage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> Shift -> m (Either WikiError Page)
  shiftPage p = lift . shiftPage p

  -- * Pages

  -- | Every page of a space, its whole tree, each page before the pages
  -- under it, siblings in the space's page order (see "Order" above). Each
  -- page is a summary, without its body and attachments: 'getPage' reads
  -- those.
  listPages :: SpaceId -> m (Either WikiError [PageSummary])
  default listPages :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError [PageSummary])
  listPages = lift . listPages

  -- | The details each page of a space is listed with as a blog post
  -- ("Wiki.Core.Blog"): who wrote it (the author of its first version),
  -- how many comments it has, and its excerpt, by page, for every page of
  -- the space, whether the space is shown as a blog or not. Only a post
  -- ('Wiki.Core.Blog.isPost') has an excerpt; the excerpt of any other
  -- page is empty. Refused as 'listPages' is.
  postDetails :: SpaceId -> m (Either WikiError (Map PageId PostDetails))
  default postDetails :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError (Map PageId PostDetails))
  postDetails = lift . postDetails

  -- | The page at a path of slugs from the space's top-level pages. The empty
  -- path names no page.
  getPage :: SpaceId -> [Slug] -> m (Either WikiError Page)
  default getPage :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> [Slug] -> m (Either WikiError Page)
  getPage s = lift . getPage s

  -- | Where a page is now, by its id, which never changes: its space's
  -- path and its own path there ('Wiki.Core.Space.pagePath'). A page's
  -- permanent address ("Wiki.App.Route"'s 'Wiki.App.Route.PermanentLink')
  -- is read with it. The wiki's own home page ('getHomeDocument') is in a
  -- space with no path, and its path is empty too. A page in a space the
  -- current user may not view is 'NotFound', exactly as an id no page has,
  -- so that nobody learns from the answer that the page exists. A page of
  -- an encrypted space has a path like any other: its slugs are random,
  -- and say nothing of its title.
  pageLocation :: PageId -> m (Either WikiError PageLocation)
  default pageLocation :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> m (Either WikiError PageLocation)
  pageLocation = lift . pageLocation

  -- | The pages that link to a page, its backlinks (issue #189): each page
  -- whose text has a link that leads to it, as "Wiki.App.Backlinks" counts
  -- a link, listed once, in 'Wiki.Core.Backlink.backlinkOrder'. A page's
  -- link to itself is not listed. Only the pages the current user may view
  -- are listed, and nothing says how many others there are. The front
  -- page's and an encrypted space's pages have none, and are not listed
  -- ('Wiki.App.Backlinks.counted'). A page the current user may not view
  -- is 'NotFound', as for 'pageLocation'.
  pageBacklinks :: PageId -> m (Either WikiError [Backlink])
  default pageBacklinks :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> m (Either WikiError [Backlink])
  pageBacklinks = lift . pageBacklinks

  -- | A new page in a space, at its top level or under another of its pages,
  -- with a title (its slug made from it) and a Markdown body. It goes last
  -- among its siblings.
  createPage :: SpaceId -> Maybe PageId -> Text -> Text -> m (Either WikiError Page)
  default createPage :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Maybe PageId -> Text -> Text -> m (Either WikiError Page)
  createPage s p t = lift . createPage s p t

  -- | Save a page's title and body. The time is the 'Wiki.Core.Page.Page'
  -- @updatedAt@ of the version the edit started from: if the page has been
  -- saved since, the save is a 'Conflict' rather than a silent overwrite of
  -- someone else's work. On success @updatedAt@ is later than it was, the
  -- slug is unchanged, and the saver's draft of the page ('saveDraft') is
  -- gone.
  savePage :: PageId -> UTCTime -> Text -> Text -> m (Either WikiError Page)
  default savePage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> UTCTime -> Text -> Text -> m (Either WikiError Page)
  savePage p v t = lift . savePage p v t

  -- | Move a page, with the pages under it, to the top level of a space or
  -- under another page of it; the space may be another one. Moved to
  -- another parent, it goes last among its new siblings. A move under the
  -- page itself or one of the pages under it is 'Invalid'.
  movePage :: PageId -> SpaceId -> Maybe PageId -> m (Either WikiError Page)
  default movePage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> SpaceId -> Maybe PageId -> m (Either WikiError Page)
  movePage p s = lift . movePage p s

  -- | Make a page one of its space's templates, or an ordinary page again
  -- ('Wiki.Core.Page.template'). It needs what saving the page needs,
  -- 'Edit' on its space. It is not a save: the page keeps its title, its
  -- body, its history and its @updatedAt@, so an editor open on it saves
  -- as before. Making a template of a page that is one, or the other way
  -- round, changes nothing and succeeds. A space's home page cannot be a
  -- template ('Invalid'), since it opens the space.
  setPageTemplate :: PageId -> Bool -> m (Either WikiError Page)
  default setPageTemplate :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> Bool -> m (Either WikiError Page)
  setPageTemplate p = lift . setPageTemplate p

  -- | Delete a page with the pages under it and their attachments.
  deletePage :: PageId -> m (Either WikiError ())
  default deletePage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> m (Either WikiError ())
  deletePage = lift . deletePage

  -- * Attachments

  -- | Attach a file to a page: its name (which the page's Markdown refers to
  -- it by), its media type and its bytes. An attachment the page already has
  -- under that name is replaced. The page's @updatedAt@ does not change,
  -- since that is the version an open editor saves against. A name must be
  -- non-blank, without slashes or control characters, and the file at most
  -- 'maxAttachmentSize'.
  --
  -- The bytes rather than a browser @File@, so that the interface is the
  -- same on every backend; the application reads a file into bytes.
  uploadAttachment :: PageId -> Text -> Text -> ByteString -> m (Either WikiError Attachment)
  default uploadAttachment :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> Text -> Text -> ByteString -> m (Either WikiError Attachment)
  uploadAttachment p n t = lift . uploadAttachment p n t

  -- | Remove an attachment from its page.
  deleteAttachment :: AttachmentId -> m (Either WikiError ())
  default deleteAttachment :: (MonadTrans t, m ~ t n, MonadWiki n) => AttachmentId -> m (Either WikiError ())
  deleteAttachment = lift . deleteAttachment

  -- | A new 'UrlOwner', for a view to ask for attachments' addresses
  -- under, and to let go of with 'releaseUrls'.
  newUrlOwner :: m UrlOwner
  default newUrlOwner :: (MonadTrans t, m ~ t n, MonadWiki n) => m UrlOwner
  newUrlOwner = lift newUrlOwner

  -- | Let go of the addresses made for an owner: the object URLs of the
  -- decrypted bytes of an encrypted page's attachments, and the bytes
  -- they hold in memory. An address asked for under an owner let go is
  -- not made. Nothing else is let go: an owner's addresses live until
  -- the view that holds them lets them go (and until the user signs out
  -- or another signs in), never because another view asked for its own.
  releaseUrls :: UrlOwner -> m ()
  default releaseUrls :: (MonadTrans t, m ~ t n, MonadWiki n) => UrlOwner -> m ()
  releaseUrls = lift . releaseUrls

  -- | The URL a browser fetches an attachment from, for the owner given.
  -- An attachment that lives on the web has its own URL. For one whose
  -- bytes the backend stores, it is an address the backend serves them at
  -- (an object URL in the demo, a server path on the HTTP backend).
  -- Natively the in-memory backend gives a @data:@ URL. For an attachment
  -- of an encrypted page, the HTTP backend decrypts its bytes into an
  -- object URL that the owner holds ('releaseUrls'). An attachment the
  -- backend does not know, or one asked for under an owner let go, gives
  -- the empty text.
  attachmentUrl :: UrlOwner -> Attachment -> m Text
  default attachmentUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => UrlOwner -> Attachment -> m Text
  attachmentUrl o = lift . attachmentUrl o

  -- | The URL a link to an attachment leads to, when it is not its
  -- 'attachmentUrl', for the owner given. Only the HTTP backend has one,
  -- for an attachment of an encrypted page: its bytes, decrypted in the
  -- browser, as a download unless the browser may show them by themselves
  -- ("Wiki.Core.Attachment"'s 'Wiki.Core.Attachment.shownInBrowser'), so
  -- that no link opens the decrypted bytes (an SVG's, say) as a document of
  -- the wiki's own address. 'Nothing' everywhere else, where the server
  -- sends a download itself.
  attachmentDownloadUrl :: UrlOwner -> Attachment -> m (Maybe Text)
  default attachmentDownloadUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => UrlOwner -> Attachment -> m (Maybe Text)
  attachmentDownloadUrl o = lift . attachmentDownloadUrl o

  -- | The URL an interactive SVG's frame loads the attachment from: its
  -- interactive form, which the wiki's server answers with the headers
  -- that let the SVG's scripts run cut off from the wiki
  -- ("Wiki.Core.Markdown.Frame"). Only the server has one, and only for an
  -- attachment it stores as an SVG ("Wiki.Api.Links.attachmentFrameUrl").
  -- The demo has no server to send those headers, and gives 'Nothing': an
  -- SVG embedded as interactive is an image there.
  attachmentFrameUrl :: Attachment -> m (Maybe Text)
  default attachmentFrameUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => Attachment -> m (Maybe Text)
  attachmentFrameUrl = lift . attachmentFrameUrl

  -- * Exports

  -- | A page, or a space's pages, as a document in one of the formats the
  -- session offers ('Session' @exports@, "Wiki.Api.Export"), for the
  -- application to save (WP5.56 of docs/PLAN.md). Fetched rather than
  -- linked to, so that a refusal (a PDF the server's TeX engine could not
  -- make) is shown to the reader with its reason, instead of being saved
  -- as the document. Whoever may read the page or view the space may
  -- export it; the errors are those of reading it, then 'Invalid' with the
  -- reason for a format the backend cannot make. The demo, which has no
  -- pandoc and offers no formats, refuses every one with 'Invalid'.
  fetchExport :: ExportTarget -> ExportFormat -> m (Either WikiError Document)
  default fetchExport :: (MonadTrans t, m ~ t n, MonadWiki n) => ExportTarget -> ExportFormat -> m (Either WikiError Document)
  fetchExport t = lift . fetchExport t

  -- * Search

  -- | The pages whose title and text have every word of the query in them
  -- (see "Wiki.Core.Search" for how words are matched and hits ranked), among
  -- the pages of the spaces the current user may view: of every such space,
  -- or of the query's space, and with 'Wiki.Core.Search.includeSubspaces'
  -- its subspaces' too. Those of a subspace the user may view are found even
  -- when the space above it is one they may not.
  --
  -- A query with no words, a space that is not there and a space the user
  -- may view nothing in all give no hits rather than an error: a search box
  -- shows "no results" for each, and an error would tell whoever is typing
  -- whether a space they may not see exists.
  searchPages :: SearchQuery -> m [SearchHit]
  default searchPages :: (MonadTrans t, m ~ t n, MonadWiki n) => SearchQuery -> m [SearchHit]
  searchPages = lift . searchPages

  -- * Drafts

  -- | The signed-in user's draft of a page ("Wiki.Core.Draft"), if they
  -- have one. Only the user's own: nobody else's draft of the page is ever
  -- given out.
  getDraft :: PageId -> m (Either WikiError (Maybe Draft))
  default getDraft :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> m (Either WikiError (Maybe Draft))
  getDraft = lift . getDraft

  -- | Keep the signed-in user's unsaved title and body of a page as their
  -- draft of it, in place of the one they had. The time is the
  -- 'Wiki.Core.Page.Page' @updatedAt@ of the version the work started from,
  -- as for 'savePage'; the draft's @savedAt@ is now. The title may be blank:
  -- a draft is not checked as a page is, since it is not one yet.
  --
  -- A draft is never shown to anyone but its author: the page, its search
  -- hits and its readers are as they were. 'savePage' discards the saver's
  -- draft of the page, since what was unsaved is then saved; deleting the
  -- page, or its space, discards every draft of it; moving it keeps them.
  saveDraft :: PageId -> UTCTime -> Text -> Text -> m (Either WikiError Draft)
  default saveDraft :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> UTCTime -> Text -> Text -> m (Either WikiError Draft)
  saveDraft p v t = lift . saveDraft p v t

  -- | Discard the signed-in user's draft of a page; nothing happens if they
  -- have none.
  discardDraft :: PageId -> m (Either WikiError ())
  default discardDraft :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> m (Either WikiError ())
  discardDraft = lift . discardDraft

  -- * History

  -- | A page of a page's history ("Wiki.Core.Version"): the versions the
  -- query asks for, the latest first, each with its number. The latest
  -- version is the page as it is now. A page has a version for each save
  -- and one for when it was made. A page that was imported, or that
  -- existed before versions were kept, starts its history with the state
  -- it came in with. Moving a page and changing its attachments make no
  -- version: a version is a title and a body. The versions are deleted
  -- with the page.
  listVersions :: PageId -> VersionsQuery -> m (Either WikiError [VersionInfo])
  default listVersions :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> VersionsQuery -> m (Either WikiError [VersionInfo])
  listVersions p = lift . listVersions p

  -- | One version of a page, by the page's @updatedAt@ at that version.
  -- The checks come in this order: a page that is not there, or one the
  -- user may not view, is 'NotFound', and only then a time that is no
  -- version of it is 'NotFound'. So whoever may not see a page learns
  -- nothing of its history.
  getVersion :: PageId -> UTCTime -> m (Either WikiError Version)
  default getVersion :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> UTCTime -> m (Either WikiError Version)
  getVersion p = lift . getVersion p

  -- | Make an earlier version of a page its current one again: a save of
  -- that version's title and body, as 'savePage' saves, which the history
  -- keeps as a new version (nothing in between is lost). The second time is
  -- the version to restore, the third the @updatedAt@ of the page as the
  -- restorer saw it, checked as a save's is: a page saved since is a
  -- 'Conflict'. Like any save it discards the restorer's draft of the page.
  -- The errors are those of 'getVersion', with 'Edit' needed in place of
  -- 'View'.
  restoreVersion :: PageId -> UTCTime -> UTCTime -> m (Either WikiError Page)
  default restoreVersion :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> UTCTime -> UTCTime -> m (Either WikiError Page)
  restoreVersion p v = lift . restoreVersion p v

-- | A component's handlers reach the backend through its monad.
instance (MonadWiki m) => MonadWiki (HalogenM st act slots output m)

-- | 'MonadLoad' tells whether the backend can answer at once (return the
-- result synchronously, without waiting for the network), and runs reads
-- that may fail to reach it. See "Loading" in the module's Haddock.
--
-- There is deliberately no instance for 'HalogenM'. Both methods take a
-- backend program as an argument, so a component calls them through
-- 'Halogen.Query.HalogenM.lift' (@H.lift (attempt fetchWorld)@), which runs
-- them on a worker thread while the loop goes on.
class (MonadWiki m) => MonadLoad m where
  -- | The result of these reads, if the backend can return all of them
  -- synchronously, without waiting for the network. The in-memory backend
  -- always can; the HTTP backend only when the responses are cached.
  -- 'Nothing' means the reads would have to wait, and then nothing is
  -- sent over the network.
  atOnce :: m a -> m (Maybe a)

  -- | Run a program, and return an 'Unreachable' thrown by one of the
  -- reads that return no @Either@ (the five in "Errors" in the module's
  -- Haddock) as a 'Left' instead of letting it propagate.
  attempt :: m a -> m (Either WikiError a)

  -- | Say that the reader went to another route. The HTTP backend then
  -- drops the page content it cached from the server's prerender, and
  -- fetches page content on every read from then on (see "Loading"). The
  -- shell calls this before it renders the new route. The in-memory
  -- backend has nothing to drop.
  endPreload :: m ()
  endPreload = pass
