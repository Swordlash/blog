-- | What a page's comments ask of wherever the wiki is kept (WP4.5 of
-- docs/PLAN.md): its threads ("Wiki.Core.Comment"), inline (about a quote
-- of the page, "Wiki.Core.Anchor") or about the whole page, and their
-- comments.
--
-- A class of its own beside 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Admin.MonadAdmin' is, and like it every backend has
-- it: the demo's in memory (and in IndexedDB), the one over HTTP (the
-- API's @pages\/\<page>\/threads@, "Wiki.Api.Comments") and the server's
-- storage. They pass the same contract (@Wiki.App.Backend.Contract.Comments@
-- in @wiki-app:contract@).
--
-- = Who may
--
-- As "Wiki.Core.Comment" says: reading a page's threads takes what reading
-- the page does; commenting, and resolving and reopening a thread, take
-- that and being signed in; a comment is edited by its author alone, and
-- deleted by its author or whoever administers the page's space; a whole
-- thread is deleted by whoever administers the space, or by its opener
-- while every comment in it is theirs.
--
-- = Errors
--
-- In "Wiki.App.Backend"'s order: a page that is not there is 'NotFound';
-- one the user may not read is 'Forbidden', before anything else is looked
-- for, so that whoever may not read a page learns nothing of its threads;
-- then a thread or a comment that is not on that page is 'NotFound'; then
-- an operation the rules do not allow them is 'Forbidden'; then a request
-- that cannot be carried out is 'Invalid': a blank comment or quote, one
-- too long, a thread about the whole page resolved, or the first comment
-- of a thread deleted while it has replies (delete the thread instead).
--
-- = Order
--
-- A page's threads come in the order they were opened, each with its
-- comments in the order they were made. A comment's author is given with
-- the name they have now; the server's operator, who is no user, is
-- named as they are in a page's history.
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

-- | A page's comments.
--
-- The methods have lifted defaults, as 'Wiki.App.Backend.MonadWiki''s do,
-- so that a component's handlers call them in 'HalogenM'.
class (Monad m) => MonadComments m where
  -- | Every thread of a page, with its comments.
  listThreads :: PageId -> m (Either WikiError [Thread])
  default listThreads :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> m (Either WikiError [Thread])
  listThreads = lift . listThreads

  -- | Open a thread on a page, about a quote of it or ('Nothing') about the
  -- whole page, with its first comment's Markdown: the thread.
  openThread :: PageId -> Maybe Anchor -> Text -> m (Either WikiError Thread)
  default openThread :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> Maybe Anchor -> Text -> m (Either WikiError Thread)
  openThread p a = lift . openThread p a

  -- | Reply to a thread: the reply, last in the thread.
  reply :: PageId -> CommentThreadId -> Text -> m (Either WikiError Comment)
  default reply :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> Text -> m (Either WikiError Comment)
  reply p t = lift . reply p t

  -- | Give one's own comment new Markdown: the comment, edited now.
  editComment :: PageId -> CommentThreadId -> CommentId -> Text -> m (Either WikiError Comment)
  default editComment :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> CommentId -> Text -> m (Either WikiError Comment)
  editComment p t c = lift . editComment p t c

  -- | Delete a comment. The first comment of a thread is the thread: it
  -- goes with it, which only a thread without replies may.
  deleteComment :: PageId -> CommentThreadId -> CommentId -> m (Either WikiError ())
  default deleteComment :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> CommentId -> m (Either WikiError ())
  deleteComment p t = lift . deleteComment p t

  -- | Delete a thread with its comments.
  deleteThread :: PageId -> CommentThreadId -> m (Either WikiError ())
  default deleteThread :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> m (Either WikiError ())
  deleteThread p = lift . deleteThread p

  -- | Resolve an inline thread ('True'), or reopen it: the thread. Doing
  -- either twice changes nothing more and succeeds.
  setResolved :: PageId -> CommentThreadId -> Bool -> m (Either WikiError Thread)
  default setResolved :: (MonadTrans t, m ~ t n, MonadComments n) => PageId -> CommentThreadId -> Bool -> m (Either WikiError Thread)
  setResolved p t = lift . setResolved p t

-- | A component's handlers reach the backend through its monad.
instance (MonadComments m) => MonadComments (HalogenM st act slots output m)
