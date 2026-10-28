-- | The audit log's rows (WP4.10 of docs/PLAN.md, "Wiki.Core.Audit"): one
-- for each administration write, inserted by the operation that makes the
-- write, in its transaction ('insertAudit'). The administration's
-- "Activity" reads them newest first ('loadActivity'), and an export
-- oldest first ('loadAuditLog'). An import adds an archive's entries, each
-- once ('restoreAudit').
--
-- Nothing here checks permissions: these run inside a transaction that
-- has already checked them.
module Wiki.Server.Storage.Audit
  ( -- * Writing
    Recorded (..)
  , insertAudit
  , restoreAudit
  , operator
  , consoleAddress

    -- * Reading
  , loadActivity
  , loadAuditLog
  )
where

import Control.Monad.UUID (generateV4)
import Data.Aeson (decodeStrict', encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, query, query_, (:.) (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize)
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Storage.Rows (Stamp (..))

-- | What a write records: everything of an entry except its id and time,
-- which 'insertAudit' assigns.
data Recorded = Recorded
  { actor :: Actor
  , action :: Text
  , subject :: Subject
  , detail :: [(Text, Text)]
  , address :: Text
  }

-- | The server's operator, as an entry names them: the administrator of
-- the admin listener, and of the console. The id is the administrator's
-- (@administratorId@ in "Wiki.Server.Storage"), which no user has.
operator :: Actor
operator = Actor {id = UserId "~administrator", login = "administrator"}

-- | The address recorded for a write made from the server's console
-- (@wiki-server users …@).
consoleAddress :: Text
consoleAddress = "console"

-- | A time as the log's column stores it: ISO 8601 in UTC with exactly
-- six digits of fraction, so that the text sorts in time order (which
-- 'Stamp''s format, with as many digits as needed, does not within a
-- second), and parses back as a 'Stamp'.
newtype LogTime = LogTime UTCTime

instance ToField LogTime where
  toField (LogTime t) =
    toField
      ( T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" t)
          <> "."
          <> T.justifyRight 6 '0' (show (diffTimeToPicoseconds (utctDayTime t) `div` 1000000 `mod` 1000000))
          <> "Z"
      )

-- | Record a write, now, in the running transaction.
insertAudit :: Connection -> Recorded -> IO ()
insertAudit c r = do
  i <- UUID.toText <$> generateV4
  t <- getCurrentTime
  insertEntry c "INSERT INTO" AuditEntry {id = i, at = t, actor = r.actor, action = r.action, subject = r.subject, detail = Map.fromList r.detail, address = r.address}

-- | Add an archive's entries, each one not already here (by its id): an
-- import of the same archive twice adds them once.
restoreAudit :: Connection -> [AuditEntry] -> IO ()
restoreAudit c = traverse_ (insertEntry c "INSERT OR IGNORE INTO")

insertEntry :: Connection -> Text -> AuditEntry -> IO ()
insertEntry c verb e =
  execute
    c
    (Query (verb <> " audit_log (id, at, actor_id, actor_login, action, subject_kind, subject_id, subject_name, detail, address) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"))
    ( (e.id, LogTime e.at, e.actor.id.text, e.actor.login, e.action)
        :. (e.subject.kind, e.subject.id, e.subject.name, decodeUtf8 (BSL.toStrict (encode e.detail)), e.address)
    )

type Row = (Text, Stamp, Text, Text, Text) :. (Text, Maybe Text, Text, Text, Text)

entryOf :: Row -> AuditEntry
entryOf ((i, Stamp at, actorId, login, action) :. (kind, subjectId, name, detail, address)) =
  AuditEntry
    { id = i
    , at
    , actor = Actor {id = UserId actorId, login}
    , action
    , subject = Subject {kind, id = subjectId, name}
    , detail = fromMaybe mempty (decodeStrict' (encodeUtf8 detail))
    , address
    }

columns :: Text
columns = "id, at, actor_id, actor_login, action, subject_kind, subject_id, subject_name, detail, address"

-- | A page of the log, the newest first, and the actors it can be
-- filtered by.
--
-- A page after an entry ('before') is found from that entry's place in the
-- index on @(at, id)@ (@audit_log_at@), or on @(actor_id, at, id)@
-- (@audit_log_actor@) for one actor's entries, so it costs one page of
-- rows however far back it is. An entry that is not in the log has
-- nothing after it. A page at an 'offset' is still answered, by counting
-- off the entries before it.
--
-- The actors are found by jumping from one actor to the next in
-- @audit_log_actor@ (a recursive query, each step the smallest actor id
-- after the last), and each one's latest login by one look into the same
-- index. So the list costs a few reads per actor, not a read of every
-- entry of the log.
loadActivity :: Connection -> ActivityQuery -> IO Activity
loadActivity c q = do
  let offset = max 0 q.offset
      limit = activityPageSize + 1
  after <- for q.before $ \i -> head <$> query c "SELECT at, id FROM audit_log WHERE id = ?" (Only i)
  rows <- case (after, q.actor) of
    (Just Nothing, _) -> pure []
    (Just (Just (at, i)), Nothing) ->
      query c (Query ("SELECT " <> columns <> " FROM audit_log WHERE (at, id) < (?, ?) ORDER BY at DESC, id DESC LIMIT ?")) (at :: Text, i :: Text, limit)
    (Just (Just (at, i)), Just u) ->
      query c (Query ("SELECT " <> columns <> " FROM audit_log WHERE actor_id = ? AND (at, id) < (?, ?) ORDER BY at DESC, id DESC LIMIT ?")) (u.text, at, i, limit)
    (Nothing, Nothing) -> query c (Query ("SELECT " <> columns <> " FROM audit_log ORDER BY at DESC, id DESC LIMIT ? OFFSET ?")) (limit, offset)
    (Nothing, Just u) -> query c (Query ("SELECT " <> columns <> " FROM audit_log WHERE actor_id = ? ORDER BY at DESC, id DESC LIMIT ? OFFSET ?")) (u.text, limit, offset)
  -- Each actor by the login of their latest entry.
  named <-
    query_ c . Query $
      "WITH RECURSIVE actor(id) AS (SELECT min(actor_id) FROM audit_log UNION ALL SELECT (SELECT min(actor_id) FROM audit_log WHERE actor_id > actor.id) FROM actor WHERE actor.id IS NOT NULL) "
        <> "SELECT id, (SELECT actor_login FROM audit_log WHERE actor_id = actor.id ORDER BY at DESC, id DESC LIMIT 1) FROM actor WHERE id IS NOT NULL"
  pure
    Activity
      { available = True
      , entries = map entryOf (take activityPageSize rows)
      , more = length rows > activityPageSize
      , actors = sortOn (\a -> (T.toCaseFold a.login, a.id)) [Actor {id = UserId i, login} | (i, login) <- named]
      }

-- | The whole log, the oldest first: what an export contains.
loadAuditLog :: Connection -> IO [AuditEntry]
loadAuditLog c = map entryOf <$> query_ c (Query ("SELECT " <> columns <> " FROM audit_log ORDER BY at, id"))
