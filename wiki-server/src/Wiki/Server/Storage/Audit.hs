-- | The audit log's rows (WP4.10 of docs/PLAN.md, "Wiki.Core.Audit"): one
-- for each write to the wiki's administration, inserted by the operation
-- that makes the write, in its transaction ('insertAudit'), and read by the
-- administration's "Activity", newest first ('loadActivity'), and by an
-- export, oldest first ('loadAuditLog'). An import brings an archive's
-- entries in, each once ('restoreAudit').
--
-- Nothing here checks who may: these run inside a transaction that has.
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
import Database.SQLite.Simple (Connection, Query (..), execute, query, query_, (:.) (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize)
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Storage.Rows (Stamp (..))

-- | What a write records: everything of an entry but its id and time,
-- which 'insertAudit' gives it.
data Recorded = Recorded
  { actor :: Actor
  , action :: Text
  , subject :: Subject
  , detail :: [(Text, Text)]
  , address :: Text
  }

-- | The server's operator, as an entry names them: the administrator of
-- the admin listener, and of the console. The id is the administrator's
-- ("Wiki.Server.Storage"'s @administratorId@), which no user has.
operator :: Actor
operator = Actor {id = UserId "~administrator", login = "administrator"}

-- | Where a write made from the server's console (@wiki-server users …@)
-- comes from.
consoleAddress :: Text
consoleAddress = "console"

-- | A time as the log's column has it: ISO 8601 in UTC with exactly six
-- digits of the fraction of a second, so that the text sorts as the time
-- does (which 'Stamp''s, with as many digits as there are, does not within
-- a second), and reads back as a 'Stamp'.
newtype LogTime = LogTime UTCTime

instance ToField LogTime where
  toField (LogTime t) =
    toField
      ( T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" t)
          <> "."
          <> T.justifyRight 6 '0' (show (diffTimeToPicoseconds (utctDayTime t) `div` 1000000 `mod` 1000000))
          <> "Z"
      )

-- | Record a write, now, in the transaction under way.
insertAudit :: Connection -> Recorded -> IO ()
insertAudit c r = do
  i <- UUID.toText <$> generateV4
  t <- getCurrentTime
  insertEntry c "INSERT INTO" AuditEntry {id = i, at = t, actor = r.actor, action = r.action, subject = r.subject, detail = Map.fromList r.detail, address = r.address}

-- | Bring in an archive's entries, each one that is not here already (by
-- its id): an import of the same archive twice brings them in once.
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

-- | A page of the log, the newest first, and whom it can be filtered by.
loadActivity :: Connection -> ActivityQuery -> IO Activity
loadActivity c q = do
  let offset = max 0 q.offset
      limit = activityPageSize + 1
  rows <- case q.actor of
    Nothing -> query c (Query ("SELECT " <> columns <> " FROM audit_log ORDER BY at DESC, id DESC LIMIT ? OFFSET ?")) (limit, offset)
    Just u -> query c (Query ("SELECT " <> columns <> " FROM audit_log WHERE actor_id = ? ORDER BY at DESC, id DESC LIMIT ? OFFSET ?")) (u.text, limit, offset)
  -- Each actor by the login of their latest entry.
  named <- query_ c "SELECT actor_id, actor_login FROM audit_log a WHERE at = (SELECT max(at) FROM audit_log b WHERE b.actor_id = a.actor_id) GROUP BY actor_id"
  pure
    Activity
      { available = True
      , entries = map entryOf (take activityPageSize rows)
      , more = length rows > activityPageSize
      , actors = sortOn (\a -> (T.toCaseFold a.login, a.id)) [Actor {id = UserId i, login} | (i, login) <- named]
      }

-- | The whole log, the oldest first: what an export carries.
loadAuditLog :: Connection -> IO [AuditEntry]
loadAuditLog c = map entryOf <$> query_ c (Query ("SELECT " <> columns <> " FROM audit_log ORDER BY at, id"))
