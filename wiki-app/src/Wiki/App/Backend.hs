-- | What the application asks of wherever the wiki is kept.
--
-- Components never know which backend they run on: they are polymorphic in
-- their monad and ask for @'MonadWiki' m@. There are two implementations, the
-- in-memory one of the serverless demo ("Wiki.App.Backend.Mem") and, from
-- Phase 2, one over HTTP. Both pass the same contract tests
-- (@Test.Backend.Contract@ in @wiki-app-test@), which is what this module's
-- prose promises.
--
-- = Errors
--
-- Every method that can fail returns @'Either' 'WikiError'@ and never
-- throws for a reason in 'WikiError': a component shows what went wrong
-- rather than dying of it. The errors are told apart in this order, and the
-- first that applies is the one returned:
--
-- 1. 'NotFound': an id or a path names nothing.
-- 2. 'Forbidden': it names something the current user may not see, or may
--    see but not do this to. Permissions are checked before the arguments
--    are validated, so someone who may not act learns nothing about whether
--    their request was otherwise well-formed.
-- 3. 'Invalid': the request cannot be carried out as asked (a blank title, a
--    move that would make a space its own ancestor, an attachment too large).
-- 4. 'Conflict': the request was right when it was made, but the wiki has
--    changed since (a save based on an older version of the page).
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
-- * renaming a space, deleting it and making it public or private need
--   'AdministerSpace' on it;
-- * creating, saving, moving and deleting pages, and uploading and deleting
--   attachments, need 'Edit' on the page's space (on both spaces, for a page
--   moved from one to another).
--
-- Whoever creates a space is granted 'AdministerSpace' on it, so that a user
-- with 'CreateSpaces' alone can do something with the space they made.
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

    -- * Who is asking
  , Session (..)
  , anonymous
  , sessionPrincipal
  , currentUser

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
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Id
import Wiki.Core.Page (Page)
import Wiki.Core.Permission (Grants, Principal (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space)
import Wiki.Core.User (User (..))

-- | Why a request was not carried out. See the module's Haddock for which is
-- returned when.
data WikiError
  = -- | Nothing has that id or path.
    NotFound
  | -- | The current user may not see it, or may not do that to it.
    Forbidden
  | -- | Something has changed since the request was made: the text says
    -- what, for a person to read.
    Conflict Text
  | -- | The request cannot be carried out as it is: the text says why, for a
    -- person to read.
    Invalid Text
  deriving stock (Eq, Show)

-- | Who the current user is, as the client needs it to run the permission
-- rules itself and hide what it cannot do.
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
  }
  deriving stock (Eq, Show)

-- | The session of someone who is not signed in.
anonymous :: Session
anonymous = Session {user = Nothing, groups = mempty, grants = mempty}

-- | The current user as the rules of "Wiki.Core.Permission" want them.
sessionPrincipal :: Session -> Maybe Principal
sessionPrincipal s = (\u -> Principal {user = u.id, groups = s.groups}) <$> s.user

-- | The user who is signed in, if anyone is.
currentUser :: (MonadWiki m) => m (Maybe User)
currentUser = (\s -> s.user) <$> session

-- | The largest attachment a backend accepts, in bytes: 50 MB.
maxAttachmentSize :: Natural
maxAttachmentSize = 50 * 1024 * 1024

-- | The wiki, as the application sees it.
--
-- The methods have lifted defaults, so that a monad transformer over a
-- backend is a backend ('HalogenM' is one, so a component's handlers call
-- these directly). A call waits for the backend in whatever way the backend
-- waits; in a component that is on the component's own fiber, as with any
-- other @lift@.
class (Monad m) => MonadWiki m where
  -- | Who is asking.
  session :: m Session
  default session :: (MonadTrans t, m ~ t n, MonadWiki n) => m Session
  session = lift session

  -- * Spaces

  -- | Every space the current user may view, together with the ancestors of
  -- each, so that the list is always a whole tree from its top-level spaces
  -- down: the client can build every path and breadcrumb from it with
  -- "Wiki.Core.Path". An ancestor that the user may not view itself (because
  -- the grant they have is on a subspace of it) is listed for its name and
  -- slug only: 'getSpace' and 'listPages' refuse it, and the rules say so to
  -- the client beforehand.
  --
  -- The whole tree, rather than one level at a time, because a wiki has tens
  -- of spaces rather than thousands and the sidebar shows all of them.
  -- Siblings come in the order of their names (ignoring case), then slugs.
  listSpaces :: m [Space]
  default listSpaces :: (MonadTrans t, m ~ t n, MonadWiki n) => m [Space]
  listSpaces = lift listSpaces

  -- | The space at a path of slugs from the top level. The empty path names
  -- no space.
  getSpace :: [Slug] -> m (Either WikiError Space)
  default getSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => [Slug] -> m (Either WikiError Space)
  getSpace = lift . getSpace

  -- | A new private space, at the top level or as a subspace of another, with
  -- this name and a slug made from it. Its creator is granted
  -- 'Wiki.Core.Permission.AdministerSpace' on it.
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

  -- | Move a space, with its subspaces and pages, under another space or to
  -- the top level. A move under the space itself or one of its subspaces is
  -- 'Invalid'.
  moveSpace :: SpaceId -> Maybe SpaceId -> m (Either WikiError Space)
  default moveSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Maybe SpaceId -> m (Either WikiError Space)
  moveSpace s = lift . moveSpace s

  -- | Delete a space with its subspaces, their pages and attachments, and the
  -- grants on them.
  deleteSpace :: SpaceId -> m (Either WikiError ())
  default deleteSpace :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError ())
  deleteSpace = lift . deleteSpace

  -- * Pages

  -- | Every page of a space, its whole tree. Siblings come in the order of
  -- their titles (ignoring case), then slugs.
  listPages :: SpaceId -> m (Either WikiError [Page])
  default listPages :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> m (Either WikiError [Page])
  listPages = lift . listPages

  -- | The page at a path of slugs from the space's top-level pages. The empty
  -- path names no page.
  getPage :: SpaceId -> [Slug] -> m (Either WikiError Page)
  default getPage :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> [Slug] -> m (Either WikiError Page)
  getPage s = lift . getPage s

  -- | A new page in a space, at its top level or under another of its pages,
  -- with a title (its slug made from it) and a Markdown body.
  createPage :: SpaceId -> Maybe PageId -> Text -> Text -> m (Either WikiError Page)
  default createPage :: (MonadTrans t, m ~ t n, MonadWiki n) => SpaceId -> Maybe PageId -> Text -> Text -> m (Either WikiError Page)
  createPage s p t = lift . createPage s p t

  -- | Save a page's title and body. The time is the 'Wiki.Core.Page.Page'
  -- @updatedAt@ of the version the edit started from: if the page has been
  -- saved since, the save is a 'Conflict' rather than a silent overwrite of
  -- someone else's work. On success @updatedAt@ is later than it was, and
  -- the slug is unchanged.
  savePage :: PageId -> UTCTime -> Text -> Text -> m (Either WikiError Page)
  default savePage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> UTCTime -> Text -> Text -> m (Either WikiError Page)
  savePage p v t = lift . savePage p v t

  -- | Move a page, with the pages under it, to the top level of a space or
  -- under another page of it; the space may be another one. A move under the
  -- page itself or one of the pages under it is 'Invalid'.
  movePage :: PageId -> SpaceId -> Maybe PageId -> m (Either WikiError Page)
  default movePage :: (MonadTrans t, m ~ t n, MonadWiki n) => PageId -> SpaceId -> Maybe PageId -> m (Either WikiError Page)
  movePage p s = lift . movePage p s

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

  -- | Where a browser fetches an attachment from: its URL for one that lives
  -- on the web; for one whose bytes the backend keeps, an address the
  -- backend serves them at (an object URL in the demo, a server path over
  -- HTTP). Natively the in-memory backend gives a @data:@ URL. An attachment
  -- the backend does not know gives the empty text.
  attachmentUrl :: Attachment -> m Text
  default attachmentUrl :: (MonadTrans t, m ~ t n, MonadWiki n) => Attachment -> m Text
  attachmentUrl = lift . attachmentUrl

-- | A component's handlers reach the backend through its monad.
instance (MonadWiki m) => MonadWiki (HalogenM st act slots output m)
