{-# LANGUAGE DeriveAnyClass #-}

-- | Comments API (WP4.5 of docs/PLAN.md): a page's comment threads over
-- HTTP, at @pages\/\<page>\/threads@. Each endpoint implements an
-- operation of @MonadComments@ (@wiki-app@'s
-- "Wiki.App.Backend.Comments"), with its request bodies.
--
-- A thread and a comment are addressed under their page, so that the path
-- says which page's permission rules apply. A thread or comment that is
-- not on the named page is 'Wiki.Api.Error.NotFound', like one that does
-- not exist. The responses are "Wiki.Core.Comment"'s records as JSON,
-- with their field names.
module Wiki.Api.Comments
  ( CommentsApi (..)
  , NewThread (..)
  , CommentText (..)
  , ThreadResolution (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Servant.API
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Comment (Comment, Thread)
import Wiki.Core.Id

-- | 'CommentsApi': a page's threads, under @pages\/\<page>\/threads@.
data CommentsApi mode = CommentsApi
  { list :: mode :- Get '[JSON] [Thread]
  -- ^ @listThreads@: every thread of the page, in the order they were
  -- started, each with its comments.
  , open :: mode :- ReqBody '[JSON] NewThread :> PostCreated '[JSON] Thread
  -- ^ @openThread@: a new thread, inline (with an anchor) or about the
  -- whole page, with its first comment.
  , reply :: mode :- Capture "thread" CommentThreadId :> "comments" :> ReqBody '[JSON] CommentText :> PostCreated '[JSON] Comment
  -- ^ @reply@: a comment at the end of a thread.
  , edit :: mode :- Capture "thread" CommentThreadId :> "comments" :> Capture "comment" CommentId :> ReqBody '[JSON] CommentText :> Put '[JSON] Comment
  -- ^ @editComment@: the new Markdown of the user's own comment.
  , deleteComment :: mode :- Capture "thread" CommentThreadId :> "comments" :> Capture "comment" CommentId :> DeleteNoContent
  -- ^ @deleteComment@. Deleting the first comment of a thread with no
  -- replies also deletes the thread.
  , delete :: mode :- Capture "thread" CommentThreadId :> DeleteNoContent
  -- ^ @deleteThread@, with all its comments.
  , resolve :: mode :- Capture "thread" CommentThreadId :> "resolved" :> ReqBody '[JSON] ThreadResolution :> Put '[JSON] Thread
  -- ^ @setResolved@: resolve an inline thread, or reopen it.
  }
  deriving stock (Generic)

-- | 'NewThread': a new thread, the quote it is about and its first comment.
data NewThread = NewThread
  { anchor :: Maybe Anchor
  -- ^ The quote it is about; @null@ for a thread about the whole page.
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'CommentText': a comment's Markdown, new or edited.
newtype CommentText = CommentText {body :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ThreadResolution': whether a thread is resolved.
newtype ThreadResolution = ThreadResolution {resolved :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
