-- | Pages' comments as the database stores them: reading a page's threads
-- with their comments, and writing them, row by row, for
-- "Wiki.Server.Storage"'s transactions, which check the rules first.
module Wiki.Server.Storage.Comments
  ( loadThreads
  , loadAllThreads
  , insertThread
  , restoreThread
  , insertComment
  , updateCommentBody
  , deleteCommentRow
  , deleteThreadRow
  , updateResolved
  , threadPage
  , commentExists
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Database.Beam (QExpr, aggregate_, all_, asc_, delete, filter_, insert, insertValues, join_, leftJoin_, max_, orderBy_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Protolude
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Version (Author (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (micro)
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

-- | Every thread of a page, in the order they were opened, each with its
-- comments in the order they were made, their authors named by the given
-- function (from their id and the name the users table has for them, if
-- any).
loadThreads :: (Backend be) => (UserId -> Maybe Text -> Author) -> PageId -> Db be [Thread]
loadThreads named page = do
  threads <- runSelectReturningList (select (orderBy_ (\t -> asc_ t.seq) (filter_ (\t -> t.page_id ==. val_ page.text) (all_ wikiDb.threads))))
  comments <- commentsWhere named (\t -> t.page_id ==. val_ page.text)
  pure (withComments comments (map threadOf threads))

-- | Every thread of every page, by page, each with its comments, as
-- 'loadThreads' gives them. The export reads them all at once, with two
-- queries rather than two per page.
loadAllThreads :: (Backend be) => (UserId -> Maybe Text -> Author) -> Db be (Map PageId [Thread])
loadAllThreads named = do
  threads <- runSelectReturningList (select (orderBy_ (\t -> (asc_ t.page_id, asc_ t.seq)) (all_ wikiDb.threads)))
  comments <- commentsWhere named (const (val_ True))
  pure (Map.fromListWith (flip (<>)) [(t.page, [t]) | t <- withComments comments (map threadOf threads)])

-- | Threads with their comments, each thread's in order.
withComments :: [Comment] -> [Thread] -> [Thread]
withComments comments threads = [t {comments = Map.findWithDefault [] t.id byThread} | t <- threads]
  where
    byThread = Map.fromListWith (flip (<>)) [(x.thread, [x]) | x <- comments]

-- | The comments of the threads a condition picks, each thread's in
-- order, their authors named.
commentsWhere :: (Backend be) => (UserId -> Maybe Text -> Author) -> (forall s. S.Threads (QExpr be s) -> QExpr be s Bool) -> Db be [Comment]
commentsWhere named cond = do
  rows <- runSelectReturningList . select . orderBy_ (\(c, _) -> (asc_ c.thread_id, asc_ c.seq)) $ do
    c <- all_ wikiDb.comments
    _ <- join_ wikiDb.threads (\t -> t.id ==. c.thread_id &&. cond t)
    u <- leftJoin_ (all_ wikiDb.users) (\u -> u.id ==. c.author)
    pure (c, u.display_name)
  pure
    [ Comment {id = CommentId c.id, thread = CommentThreadId c.thread_id, author = named (UserId c.author) name, body = c.body, createdAt = c.created_at, editedAt = c.edited_at}
    | (c, name) <- rows
    ]

threadOf :: S.Threads Identity -> Thread
threadOf r =
  Thread
    { id = CommentThreadId r.id
    , page = PageId r.page_id
    , anchor = Anchor <$> r.quote <*> r.prefix <*> r.suffix
    , resolved = r.resolved
    , createdAt = r.created_at
    , comments = []
    }

-- | The position after the last of a page's threads.
nextThreadSeq :: (Backend be) => PageId -> Db be Int32
nextThreadSeq page = maybe 0 (+ 1) . join <$> runSelectReturningOne (select (aggregate_ (\t -> max_ t.seq) (filter_ (\t -> t.page_id ==. val_ page.text) (all_ wikiDb.threads))))

-- | The position after the last of a thread's comments.
nextCommentSeq :: (Backend be) => CommentThreadId -> Db be Int32
nextCommentSeq tid = maybe 0 (+ 1) . join <$> runSelectReturningOne (select (aggregate_ (\c -> max_ c.seq) (filter_ (\c -> c.thread_id ==. val_ tid.text) (all_ wikiDb.comments))))

-- | Add a thread, last among its page's, without its comments, which are
-- each added by 'insertComment'.
insertThread :: (Backend be) => CommentThreadId -> PageId -> Maybe Anchor -> UTCTime -> Db be ()
insertThread tid page anchor at = do
  next <- nextThreadSeq page
  runInsert . insert wikiDb.threads $
    insertValues
      [ S.ThreadRow
          { id = tid.text
          , page_id = page.text
          , quote = (\a -> a.exact) <$> anchor
          , prefix = (\a -> a.prefix) <$> anchor
          , suffix = (\a -> a.suffix) <$> anchor
          , resolved = False
          , created_at = micro at
          , seq = next
          }
      ]

-- | Add a comment, last in its thread.
insertComment :: (Backend be) => CommentId -> CommentThreadId -> UserId -> Text -> UTCTime -> Db be ()
insertComment cid tid author body at = do
  next <- nextCommentSeq tid
  runInsert (insert wikiDb.comments (insertValues [S.CommentRow {id = cid.text, thread_id = tid.text, author = author.text, body, created_at = micro at, edited_at = Nothing, seq = next}]))

-- | Add a whole thread, as an import brings it: last among its page's
-- threads, resolved or not, with its comments in order, each with its
-- author, its times and whether it was edited. The thread and its
-- comments keep the ids they are given.
restoreThread :: (Backend be) => Thread -> Db be ()
restoreThread t = do
  next <- nextThreadSeq t.page
  runInsert . insert wikiDb.threads $
    insertValues
      [ S.ThreadRow
          { id = t.id.text
          , page_id = t.page.text
          , quote = (\a -> a.exact) <$> t.anchor
          , prefix = (\a -> a.prefix) <$> t.anchor
          , suffix = (\a -> a.suffix) <$> t.anchor
          , resolved = t.resolved && isJust t.anchor
          , created_at = micro t.createdAt
          , seq = next
          }
      ]
  for_ (zip [0 :: Int32 ..] t.comments) $ \(ordinal, x) ->
    runInsert . insert wikiDb.comments $
      insertValues [S.CommentRow {id = x.id.text, thread_id = t.id.text, author = x.author.id.text, body = x.body, created_at = micro x.createdAt, edited_at = micro <$> x.editedAt, seq = ordinal}]

-- | Set a comment's new Markdown, edited at this time.
updateCommentBody :: (Backend be) => CommentId -> Text -> UTCTime -> Db be ()
updateCommentBody cid body at = runUpdate (update wikiDb.comments (\c -> (c.body <-. val_ body) <> (c.edited_at <-. val_ (Just (micro at)))) (\c -> c.id ==. val_ cid.text))

deleteCommentRow :: (Backend be) => CommentId -> Db be ()
deleteCommentRow cid = runDelete (delete wikiDb.comments (\c -> c.id ==. val_ cid.text))

-- | Delete a thread, and its comments with it.
deleteThreadRow :: (Backend be) => CommentThreadId -> Db be ()
deleteThreadRow tid = runDelete (delete wikiDb.threads (\t -> t.id ==. val_ tid.text))

updateResolved :: (Backend be) => CommentThreadId -> Bool -> Db be ()
updateResolved tid resolved = runUpdate (update wikiDb.threads (\t -> t.resolved <-. val_ resolved) (\t -> t.id ==. val_ tid.text))

-- | The page a thread is on, if the thread is there.
threadPage :: (Backend be) => CommentThreadId -> Db be (Maybe PageId)
threadPage tid = fmap PageId <$> runSelectReturningOne (select ((\t -> t.page_id) <$> filter_ (\t -> t.id ==. val_ tid.text) (all_ wikiDb.threads)))

-- | Whether a comment with this id is there.
commentExists :: (Backend be) => CommentId -> Db be Bool
commentExists cid = isJust <$> runSelectReturningOne (select ((\c -> c.id) <$> filter_ (\c -> c.id ==. val_ cid.text) (all_ wikiDb.comments)))
