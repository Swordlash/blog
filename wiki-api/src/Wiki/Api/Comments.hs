{-# LANGUAGE TemplateHaskell #-}

-- | A page's comments over HTTP (WP4.5 of docs/PLAN.md): its threads, at
-- @pages\/\<page>\/threads@, each operation one of @MonadComments@'s
-- (@wiki-app@'s "Wiki.App.Backend.Comments"), with its request bodies.
--
-- A thread and a comment are addressed under their page, so that the
-- address says whose rules apply: one that is not on the page named is
-- 'Wiki.Api.Error.NotFound', as one that is nowhere is. The responses
-- are "Wiki.Core.Comment"'s records as JSON, with their field names.
module Wiki.Api.Comments
  ( CommentsApi (..)
  , NewThread (..)
  , CommentText (..)
  , ThreadResolution (..)
  )
where

import Protolude
import Servant.API
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Comment (Comment, Thread)
import Wiki.Core.Id
import Wiki.Core.Json (defaultOptions, deriveValueJSON)

-- | A page's threads, below @pages\/\<page>\/threads@.
data CommentsApi mode = CommentsApi
  { list :: mode :- Get '[JSON] [Thread]
  -- ^ @listThreads@: every thread of the page, in the order they were
  -- opened, each with its comments.
  , open :: mode :- ReqBody '[JSON] NewThread :> PostCreated '[JSON] Thread
  -- ^ @openThread@: a new thread, inline (with an anchor) or about the
  -- page, with its first comment.
  , reply :: mode :- Capture "thread" CommentThreadId :> "comments" :> ReqBody '[JSON] CommentText :> PostCreated '[JSON] Comment
  -- ^ @reply@: a comment at the end of a thread.
  , edit :: mode :- Capture "thread" CommentThreadId :> "comments" :> Capture "comment" CommentId :> ReqBody '[JSON] CommentText :> Put '[JSON] Comment
  -- ^ @editComment@: one's own comment's new Markdown.
  , deleteComment :: mode :- Capture "thread" CommentThreadId :> "comments" :> Capture "comment" CommentId :> DeleteNoContent
  -- ^ @deleteComment@; the first comment of a thread with no replies
  -- takes the thread with it.
  , delete :: mode :- Capture "thread" CommentThreadId :> DeleteNoContent
  -- ^ @deleteThread@, with all its comments.
  , resolve :: mode :- Capture "thread" CommentThreadId :> "resolved" :> ReqBody '[JSON] ThreadResolution :> Put '[JSON] Thread
  -- ^ @setResolved@: resolve an inline thread, or reopen it.
  }
  deriving stock (Generic)

-- | A new thread: what it is about, and its first comment.
data NewThread = NewThread
  { anchor :: Maybe Anchor
  -- ^ The quote it is about; @null@ for a thread about the whole page.
  , body :: Text
  }
  deriving stock (Eq, Show)

-- | A comment's Markdown, new or edited.
newtype CommentText = CommentText {body :: Text}
  deriving stock (Eq, Show)

-- | Whether a thread is resolved.
newtype ThreadResolution = ThreadResolution {resolved :: Bool}
  deriving stock (Eq, Show)

-- The JSON instances, last, since declarations above name types declared
-- below them ("Wiki.Core.Json" says why that matters), each after those
-- of the types it holds.
deriveValueJSON defaultOptions ''NewThread
deriveValueJSON defaultOptions ''CommentText
deriveValueJSON defaultOptions ''ThreadResolution
