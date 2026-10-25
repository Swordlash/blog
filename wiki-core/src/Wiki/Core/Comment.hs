{-# LANGUAGE DeriveAnyClass #-}

-- | Comments on a page, as Confluence has them (WP4.5 and decision 23 of
-- docs/PLAN.md): threads, each opened by a comment and answered by
-- replies, either anchored to a quote of the page's text (an /inline/
-- thread, shown beside the page, its quote highlighted: "Wiki.Core.Anchor")
-- or about the page as a whole (a /page/ thread, shown under it).
--
-- A thread is one level deep: its first comment opened it and the rest
-- answer it, in the order they were made. A comment is Markdown, rendered
-- as a page is, the allowlist of raw HTML included.
--
-- = Who may
--
-- The rules, shared by every backend and by the application, which hides
-- what they forbid:
--
-- * reading a page's threads takes what reading the page does, 'View' on
--   its space, signed in or not;
-- * commenting (opening a thread, replying) takes that and being signed in
--   ('mayComment'), and so do resolving and reopening an inline thread;
-- * a comment is edited by its author alone ('mayEditComment');
-- * a comment is deleted by its author or by whoever administers the page's
--   space ('mayDeleteComment'), and a whole thread by whoever administers
--   the space, or by the one who opened it while every comment in it is
--   theirs ('mayDeleteThread').
--
-- A thread's first comment is the thread: deleting it deletes the thread,
-- which is allowed only while nobody has replied (Confluence's rule too: a
-- comment with replies is not deleted from under them); a space's
-- administrator deletes the whole thread instead.
module Wiki.Core.Comment
  ( -- * Threads and comments
    Thread (..)
  , Comment (..)
  , isInline
  , opener

    -- * Rules
  , mayComment
  , mayEditComment
  , mayDeleteComment
  , mayDeleteThread
  , checkCommentBody
  , maxCommentLength

    -- * Keeping a page's threads up to date
  , withThread
  , withComment
  , withoutComment
  , withoutThread
  , resolvedAs
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Id
import Wiki.Core.Permission (Grants, Principal (..), canAdministerSpace, canView)
import Wiki.Core.Space (Space)
import Wiki.Core.Version (Author (..))

-- | A thread of comments on a page.
data Thread = Thread
  { id :: CommentThreadId
  , page :: PageId
  , anchor :: Maybe Anchor
  -- ^ The quote it is about, for an inline thread; 'Nothing' for a thread
  -- about the whole page.
  , resolved :: Bool
  -- ^ Whether it is done with: an inline thread is resolved (and its quote
  -- no longer highlighted) or reopened; a page thread never is.
  , createdAt :: UTCTime
  , comments :: [Comment]
  -- ^ Its comments, the oldest first: the first opened it, the rest are
  -- replies. Never empty.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A comment.
data Comment = Comment
  { id :: CommentId
  , thread :: CommentThreadId
  , author :: Author
  -- ^ Who wrote it, by their id and their display name as it is now.
  , body :: Text
  -- ^ Its Markdown.
  , createdAt :: UTCTime
  , editedAt :: Maybe UTCTime
  -- ^ When it was last edited, if it has been.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether a thread is about a quote of the page, rather than the page.
isInline :: Thread -> Bool
isInline t = isJust t.anchor

-- | Who opened a thread: the author of its first comment.
opener :: Thread -> Maybe UserId
opener t = (\c -> c.author.id) <$> head t.comments

-- | Whether someone may comment on a page of the space at the end of the
-- chain: they are signed in, and may read it.
mayComment :: Maybe Principal -> Grants -> [Space] -> Bool
mayComment who grants chain = isJust who && canView who grants chain

-- | Whether someone may edit a comment: it is theirs.
mayEditComment :: Maybe Principal -> Comment -> Bool
mayEditComment who c = fmap (\p -> p.user) who == Just c.author.id

-- | Whether someone may delete a comment on a page of the space at the end
-- of the chain: it is theirs, or they administer the space.
mayDeleteComment :: Maybe Principal -> Grants -> [Space] -> Comment -> Bool
mayDeleteComment who grants chain c = mayEditComment who c || canAdministerSpace who grants chain

-- | Whether someone may delete a whole thread on a page of the space at the
-- end of the chain: they administer the space, or every comment in it is
-- theirs.
mayDeleteThread :: Maybe Principal -> Grants -> [Space] -> Thread -> Bool
mayDeleteThread who grants chain t =
  canAdministerSpace who grants chain || (isJust who && all (mayEditComment who) t.comments)

-- | The longest comment, in characters: a long one is a page.
maxCommentLength :: Int
maxCommentLength = 20000

-- | A comment's Markdown as it is kept: as written, with the blank lines
-- around it dropped; or why it cannot be.
checkCommentBody :: Text -> Either Text Text
checkCommentBody body
  | T.all isSpace body = Left "A comment cannot be blank."
  | T.length body > maxCommentLength = Left ("A comment can be at most " <> show maxCommentLength <> " characters long.")
  | otherwise = Right (T.dropWhileEnd isSpace (T.intercalate "\n" (dropWhile (T.all isSpace) (T.splitOn "\n" body))))

-- | A page's threads with this one in them: in place of the thread with its
-- id, or last, as a new one is. The same thread given twice changes
-- nothing, so that a client that made a thread and then hears of it from
-- the server keeps one.
withThread :: Thread -> [Thread] -> [Thread]
withThread t ts
  | any (\x -> x.id == t.id) ts = map (\x -> if x.id == t.id then t else x) ts
  | otherwise = ts <> [t]

-- | A page's threads with this comment in its thread: in place of the
-- comment with its id, or last, as a reply is. A comment of a thread that
-- is not there changes nothing.
withComment :: Comment -> [Thread] -> [Thread]
withComment c = map $ \t ->
  if t.id /= c.thread
    then t
    else
      t
        { comments =
            if any (\x -> x.id == c.id) t.comments
              then map (\x -> if x.id == c.id then c else x) t.comments
              else t.comments <> [c]
        }

-- | A page's threads without this comment. A thread left with none is
-- gone, as deleting its first comment deletes it.
withoutComment :: CommentThreadId -> CommentId -> [Thread] -> [Thread]
withoutComment tid cid = mapMaybe $ \t ->
  if t.id /= tid
    then Just t
    else case filter (\x -> x.id /= cid) t.comments of
      [] -> Nothing
      rest -> Just t {comments = rest}

-- | A page's threads without this one.
withoutThread :: CommentThreadId -> [Thread] -> [Thread]
withoutThread tid = filter (\t -> t.id /= tid)

-- | A page's threads with this one resolved, or reopened.
resolvedAs :: CommentThreadId -> Bool -> [Thread] -> [Thread]
resolvedAs tid resolved = map (\t -> if t.id == tid then t {resolved} else t)
