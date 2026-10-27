-- | Pages' comments as the database stores them (migration
-- @0006-comments.sql@): reading a page's threads with their comments, and
-- writing them, row by row, for "Wiki.Server.Storage"'s transactions,
-- which check the rules first.
module Wiki.Server.Storage.Comments
  ( loadThreads
  , insertThread
  , insertComment
  , updateCommentBody
  , deleteCommentRow
  , deleteThreadRow
  , updateResolved
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Database.SQLite.Simple (Connection, Only (..), Query, execute, query, queryWith)
import Database.SQLite.Simple.FromRow (RowParser, field)
import Protolude
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Version (Author)
import Wiki.Server.Storage.Rows (Stamp (..), stamp)

-- | Every thread of a page, in the order they were opened, each with its
-- comments in the order they were made, their authors named by the given
-- function (from their id and the name the users table has for them, if
-- any).
loadThreads :: (UserId -> Maybe Text -> Author) -> Connection -> PageId -> IO [Thread]
loadThreads named c page = do
  threads <-
    queryWith
      threadRow
      c
      "SELECT id, page_id, quote, prefix, suffix, resolved, created_at FROM threads WHERE page_id = ? ORDER BY seq"
      (Only page.text)
  comments <-
    queryWith
      (commentRow named)
      c
      "SELECT c.id, c.thread_id, c.author, u.display_name, c.body, c.created_at, c.edited_at FROM comments c JOIN threads t ON t.id = c.thread_id LEFT JOIN users u ON u.id = c.author WHERE t.page_id = ? ORDER BY c.thread_id, c.seq"
      (Only page.text)
  let byThread = Map.fromListWith (flip (<>)) [(x.thread, [x]) | x <- comments]
  pure [t {comments = Map.findWithDefault [] t.id byThread} | t <- threads]

threadRow :: RowParser Thread
threadRow = do
  id <- CommentThreadId <$> field
  page <- PageId <$> field
  quote <- field
  prefix <- field
  suffix <- field
  resolved <- field
  createdAt <- stamp
  pure
    Thread
      { id
      , page
      , anchor = Anchor <$> quote <*> prefix <*> suffix
      , resolved
      , createdAt
      , comments = []
      }

commentRow :: (UserId -> Maybe Text -> Author) -> RowParser Comment
commentRow named = do
  id <- CommentId <$> field
  thread <- CommentThreadId <$> field
  author <- named . UserId <$> field <*> field
  body <- field
  createdAt <- stamp
  editedAt <- fmap (\(Stamp t) -> t) <$> field
  pure Comment {id, thread, author, body, createdAt, editedAt}

-- | Add a thread, last among its page's, without its comments, which are
-- each added by 'insertComment'.
insertThread :: Connection -> CommentThreadId -> PageId -> Maybe Anchor -> UTCTime -> IO ()
insertThread c tid page anchor at = do
  next <- nextSeq c "SELECT coalesce(max(seq) + 1, 0) FROM threads WHERE page_id = ?" page.text
  execute
    c
    "INSERT INTO threads (id, page_id, quote, prefix, suffix, resolved, created_at, seq) VALUES (?, ?, ?, ?, ?, 0, ?, ?)"
    (tid.text, page.text, (\a -> a.exact) <$> anchor, (\a -> a.prefix) <$> anchor, (\a -> a.suffix) <$> anchor, Stamp at, next)

-- | Add a comment, last in its thread.
insertComment :: Connection -> CommentId -> CommentThreadId -> UserId -> Text -> UTCTime -> IO ()
insertComment c cid tid author body at = do
  next <- nextSeq c "SELECT coalesce(max(seq) + 1, 0) FROM comments WHERE thread_id = ?" tid.text
  execute
    c
    "INSERT INTO comments (id, thread_id, author, body, created_at, edited_at, seq) VALUES (?, ?, ?, ?, ?, NULL, ?)"
    (cid.text, tid.text, author.text, body, Stamp at, next)

-- | The position after the last of a page's threads, or of a thread's
-- comments.
nextSeq :: Connection -> Query -> Text -> IO Int
nextSeq c q key = maybe 0 fromOnly . head <$> query c q (Only key)

-- | Set a comment's new Markdown, edited at this time.
updateCommentBody :: Connection -> CommentId -> Text -> UTCTime -> IO ()
updateCommentBody c cid body at = execute c "UPDATE comments SET body = ?, edited_at = ? WHERE id = ?" (body, Stamp at, cid.text)

deleteCommentRow :: Connection -> CommentId -> IO ()
deleteCommentRow c cid = execute c "DELETE FROM comments WHERE id = ?" (Only cid.text)

-- | Delete a thread, and its comments with it.
deleteThreadRow :: Connection -> CommentThreadId -> IO ()
deleteThreadRow c tid = execute c "DELETE FROM threads WHERE id = ?" (Only tid.text)

updateResolved :: Connection -> CommentThreadId -> Bool -> IO ()
updateResolved c tid resolved = execute c "UPDATE threads SET resolved = ? WHERE id = ?" (resolved, tid.text)
