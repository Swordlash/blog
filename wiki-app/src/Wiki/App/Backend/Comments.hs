-- | The comments' backend interface: 'MonadComments' is every read and
-- write of a page's comments (WP4.5 of docs/PLAN.md). Comments come in
-- threads ("Wiki.Core.Comment"), either inline (about a quote of the page,
-- "Wiki.Core.Anchor") or about the whole page.
--
-- It is a separate class from 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Admin.MonadAdmin' is, and like it every backend
-- implements it: the demo's in-memory backend (saved in IndexedDB), the
-- HTTP backend (the API's @pages\/\<page>\/threads@, "Wiki.Api.Comments")
-- and the server's storage. They pass the same contract tests
-- (@Wiki.App.Backend.Contract.Comments@ in @wiki-app:contract@).
--
-- = Who may
--
-- The rules are in "Wiki.Core.Comment". Reading a page's threads needs
-- what reading the page needs. Commenting, and resolving and reopening a
-- thread, need that and being signed in. Only a comment's author may edit
-- it. Its author or an administrator of the page's space may delete it. A
-- whole thread may be deleted by an administrator of the space, or by the
-- person who opened it while every comment in it is theirs.
--
-- = Errors
--
-- In "Wiki.App.Backend"'s order: a page that does not exist is
-- 'NotFound', and so is a page the user may not read, checked before
-- anything else is looked up, so that someone who may not read a page
-- learns nothing about its threads, nor whether it exists. Then a thread
-- or a comment that is not on that page is 'NotFound'. Then an operation
-- the rules do not allow is 'Forbidden'. Then a request that cannot be carried out is 'Invalid': a
-- blank or too long comment or quote, resolving a thread about the whole
-- page, or deleting the first comment of a thread that has replies (delete
-- the thread instead).
--
-- = Order
--
-- A page's threads come in the order they were opened, each with its
-- comments in the order they were made. A comment's author is given with
-- their current name. The server's operator, who is not a user, is named
-- as in a page's history.
module Wiki.App.Backend.Comments
  ( MonadComments (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Comment (Comment, Thread)
import Wiki.Core.Id (CommentId, CommentThreadId, PageId)

-- | 'MonadComments' is the backend interface for a page's comments.
--
-- Every method has a default that lifts it through a monad transformer,
-- as 'Wiki.App.Backend.MonadWiki''s do, so that a component's handlers
-- call them in 'HalogenM'.
class (Monad m) => MonadComments m where
  -- | Every thread of a page, with its comments.
  listThreads :: PageId -> m (Either WikiError [Thread])
  default listThreads :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> m (Either WikiError [Thread])
  listThreads = lift . listThreads

  -- | Open a thread on a page, about a quote of it or ('Nothing') about the
  -- whole page, with its first comment's Markdown. The result is the
  -- thread.
  openThread :: PageId -> Maybe Anchor -> Text -> m (Either WikiError Thread)
  default openThread :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> Maybe Anchor -> Text -> m (Either WikiError Thread)
  openThread p a = lift . openThread p a

  -- | Reply to a thread. The result is the reply, last in the thread.
  reply :: PageId -> CommentThreadId -> Text -> m (Either WikiError Comment)
  default reply :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> Text -> m (Either WikiError Comment)
  reply p t = lift . reply p t

  -- | Change one's own comment's Markdown. The result is the edited
  -- comment.
  editComment :: PageId -> CommentThreadId -> CommentId -> Text -> m (Either WikiError Comment)
  default editComment :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> CommentId -> Text -> m (Either WikiError Comment)
  editComment p t c = lift . editComment p t c

  -- | Delete a comment. Deleting the first comment of a thread deletes the
  -- whole thread, which is allowed only for a thread without replies.
  deleteComment :: PageId -> CommentThreadId -> CommentId -> m (Either WikiError ())
  default deleteComment :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> CommentId -> m (Either WikiError ())
  deleteComment p t = lift . deleteComment p t

  -- | Delete a thread with its comments.
  deleteThread :: PageId -> CommentThreadId -> m (Either WikiError ())
  default deleteThread :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> m (Either WikiError ())
  deleteThread p = lift . deleteThread p

  -- | Resolve an inline thread ('True'), or reopen it. The result is the
  -- thread. Doing either twice changes nothing more and succeeds.
  setResolved :: PageId -> CommentThreadId -> Bool -> m (Either WikiError Thread)
  default setResolved :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> Bool -> m (Either WikiError Thread)
  setResolved p t = lift . setResolved p t

-- | A component's handlers reach the backend through its monad.
instance (MonadComments m) => MonadComments (HalogenM st act slots output m)
