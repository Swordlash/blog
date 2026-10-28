{-# LANGUAGE DeriveAnyClass #-}

-- | Comments on a page, as Confluence has them (WP4.5 and decision 23 of
-- docs/PLAN.md). Comments come in threads: a thread starts with one
-- comment, and the other comments are replies. A thread is either anchored
-- to a quote of the page's text (an /inline/ thread, shown beside the page,
-- with its quote highlighted: "Wiki.Core.Anchor") or about the page as a
-- whole (a /page/ thread, shown under the page).
--
-- A thread is one level deep: its first comment starts it and the rest
-- reply to it, in the order they were written. A comment is Markdown,
-- rendered as a page is, including the allowlist of raw HTML.
--
-- = Permissions
--
-- The rules, shared by every backend and by the application, which hides
-- the actions they forbid:
--
-- * reading a page's threads needs what reading the page needs, 'View' on
--   its space, signed in or not;
-- * commenting (starting a thread, replying) needs that and being signed
--   in ('mayComment'), and so do resolving and reopening an inline thread;
-- * only a comment's author may edit it ('mayEditComment');
-- * a comment may be deleted by its author or by an administrator of the
--   page's space ('mayDeleteComment'); a whole thread by an administrator
--   of the space, or by the user who started it as long as every comment
--   in it is theirs ('mayDeleteThread').
--
-- A thread's first comment stands for the thread: deleting it deletes the
-- thread, which is allowed only while nobody has replied (Confluence has
-- the same rule: a comment with replies is not deleted from under them). A
-- space's administrator deletes the whole thread instead.
module Wiki.Core.Comment
  ( -- * Threads and comments
    Thread (..)
  , Comment (..)
  , isInline
  , opener

    -- * Authors who are not users
  , formerAuthor
  , formerAuthorName
  , absentAuthor

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

-- | 'Thread': a thread of comments on a page.
data Thread = Thread
  { id :: CommentThreadId
  , page :: PageId
  , anchor :: Maybe Anchor
  -- ^ The quote the thread is about, for an inline thread; 'Nothing' for a
  -- thread about the whole page.
  , resolved :: Bool
  -- ^ Whether the thread is finished: an inline thread can be resolved
  -- (and its quote is then no longer highlighted) or reopened; a page
  -- thread is never resolved.
  , createdAt :: UTCTime
  , comments :: [Comment]
  -- ^ Its comments, oldest first: the first one started the thread, the
  -- others are replies. Never empty.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A comment.
data Comment = Comment
  { id :: CommentId
  , thread :: CommentThreadId
  , author :: Author
  -- ^ The author, by user id and current display name.
  , body :: Text
  -- ^ Its Markdown.
  , createdAt :: UTCTime
  , editedAt :: Maybe UTCTime
  -- ^ When it was last edited, if it has been.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether a thread is about a quote of the page, rather than the whole page.
isInline :: Thread -> Bool
isInline t = isJust t.anchor

-- | Who started a thread: the author of its first comment.
opener :: Thread -> Maybe UserId
opener t = (\c -> c.author.id) <$> head t.comments

-- | 'formerAuthor' is the user id a comment keeps for an author who is
-- not a user of this wiki: a person whose comments came in an import
-- ("Wiki.Core.Export") and whose login matches nobody here. The id holds
-- the person's name, so that the comment can still say who wrote it. It
-- starts with @~@, which no login and no other user id starts with, so it
-- never names a real user, and nobody may edit the comment.
formerAuthor :: Text -> UserId
formerAuthor name = UserId (formerPrefix <> name)

-- | The name kept in a 'formerAuthor' id, or 'Nothing' for any other id.
formerAuthorName :: UserId -> Maybe Text
formerAuthorName u = T.stripPrefix formerPrefix u.text

formerPrefix :: Text
formerPrefix = "~former:"

-- | 'absentAuthor' is how a comment or a version names an author who is
-- not among the wiki's users. An author kept by 'formerAuthor' is shown by
-- their name, marked as not a user here. Any other id is shown as it is,
-- since the id is all that is left of that person.
absentAuthor :: UserId -> Author
absentAuthor u = Author {id = u, name = maybe u.text (<> " (not a user here)") (formerAuthorName u)}

-- | Whether a user may comment on a page of the space at the end of the
-- chain: they are signed in, and may read the page.
mayComment :: Maybe Principal -> Grants -> [Space] -> Bool
mayComment who grants chain = isJust who && canView who grants chain

-- | Whether a user may edit a comment: they wrote it.
mayEditComment :: Maybe Principal -> Comment -> Bool
mayEditComment who c = fmap (\p -> p.user) who == Just c.author.id

-- | Whether a user may delete a comment on a page of the space at the end
-- of the chain: they wrote it, or they administer the space.
mayDeleteComment :: Maybe Principal -> Grants -> [Space] -> Comment -> Bool
mayDeleteComment who grants chain c = mayEditComment who c || canAdministerSpace who grants chain

-- | Whether a user may delete a whole thread on a page of the space at the
-- end of the chain: they administer the space, or they wrote every comment
-- in the thread.
mayDeleteThread :: Maybe Principal -> Grants -> [Space] -> Thread -> Bool
mayDeleteThread who grants chain t =
  canAdministerSpace who grants chain || (isJust who && all (mayEditComment who) t.comments)

-- | The longest comment, in characters: anything longer should be a page.
maxCommentLength :: Int
maxCommentLength = 20000

-- | A comment's Markdown as it is stored: as written, with the blank lines
-- around it removed; or why it is invalid.
checkCommentBody :: Text -> Either Text Text
checkCommentBody body
  | T.all isSpace body = Left "A comment cannot be blank."
  | T.length body > maxCommentLength = Left ("A comment can be at most " <> show maxCommentLength <> " characters long.")
  | otherwise = Right (T.dropWhileEnd isSpace (T.intercalate "\n" (dropWhile (T.all isSpace) (T.splitOn "\n" body))))

-- | A page's threads with this thread added: in place of the thread with
-- the same id, or at the end for a new thread. Adding the same thread twice
-- changes nothing, so that a client that created a thread and then
-- receives it from the server keeps one copy.
withThread :: Thread -> [Thread] -> [Thread]
withThread t ts
  | any (\x -> x.id == t.id) ts = map (\x -> if x.id == t.id then t else x) ts
  | otherwise = ts <> [t]

-- | A page's threads with this comment added to its thread: in place of
-- the comment with the same id, or at the end for a reply. A comment whose
-- thread is not in the list changes nothing.
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

-- | A page's threads without this comment. A thread left with no comments
-- is removed, as deleting its first comment deletes it.
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
