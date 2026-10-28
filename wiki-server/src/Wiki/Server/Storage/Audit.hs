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
import Data.Time (getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.Beam (QExpr, aggregate_, all_, asc_, desc_, filter_, insert, insertValues, limit_, min_, offset_, orderBy_, runInsert, runSelectReturningList, runSelectReturningOne, select, val_, (&&.), (<.), (<=.), (==.), (>.), (||.))
import Database.Beam.Backend.SQL.BeamExtensions (anyConflict, insertOnConflict, onConflictDoNothing)
import Protolude
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize)
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (micro)
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

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
operator = Actor {id = UserId "~administrator", login = Login "administrator"}

-- | The address recorded for a write made from the server's console
-- (@wiki-server users …@).
consoleAddress :: Text
consoleAddress = "console"

-- | Record a write, now, in the running transaction.
insertAudit :: (Backend be) => Recorded -> Db be ()
insertAudit r = do
  i <- liftIO (UUID.toText <$> generateV4)
  t <- liftIO getCurrentTime
  runInsert (insert wikiDb.audit_log (insertValues [rowOf AuditEntry {id = i, at = t, actor = r.actor, action = r.action, subject = r.subject, detail = Map.fromList r.detail, address = r.address}]))

-- | Add an archive's entries, each one not already here (by its id): an
-- import of the same archive twice adds them once.
restoreAudit :: (Backend be) => [AuditEntry] -> Db be ()
restoreAudit = traverse_ (\e -> runInsert (insertOnConflict wikiDb.audit_log (insertValues [rowOf e]) anyConflict onConflictDoNothing))

rowOf :: AuditEntry -> S.AuditLog Identity
rowOf e =
  S.AuditRow
    { id = e.id
    , at = micro e.at
    , actor_id = e.actor.id.text
    , actor_login = e.actor.login.text
    , action = e.action
    , subject_kind = e.subject.kind
    , subject_id = e.subject.id
    , subject_name = e.subject.name
    , detail = decodeUtf8 (BSL.toStrict (encode e.detail))
    , address = e.address
    }

entryOf :: S.AuditLog Identity -> AuditEntry
entryOf r =
  AuditEntry
    { id = r.id
    , at = r.at
    , actor = Actor {id = UserId r.actor_id, login = Login r.actor_login}
    , action = r.action
    , subject = Subject {kind = r.subject_kind, id = r.subject_id, name = r.subject_name}
    , detail = fromMaybe mempty (decodeStrict' (encodeUtf8 r.detail))
    , address = r.address
    }

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
-- @audit_log_actor@ (each step the smallest actor id after the last), and
-- each one's latest login by one look into the same index. So the list
-- costs a few reads per actor, not a read of every entry of the log.
loadActivity :: forall be. (Backend be) => ActivityQuery -> Db be Activity
loadActivity q = do
  let skipped = max 0 q.offset
      most = fromIntegral (activityPageSize + 1)
      byActor :: forall s. S.AuditLog (QExpr be s) -> QExpr be s Bool
      byActor e = maybe (val_ True) (\u -> e.actor_id ==. val_ u.text) q.actor
  after <- for q.before $ \i -> runSelectReturningOne (select ((\e -> (e.at, e.id)) <$> filter_ (\e -> e.id ==. val_ i) (all_ wikiDb.audit_log)))
  rows <- case after of
    Just Nothing -> pure []
    Just (Just (at, i)) ->
      runSelectReturningList . select . limit_ most . orderBy_ (\e -> (desc_ e.at, desc_ e.id)) $
        filter_ (\e -> byActor e &&. e.at <=. val_ at &&. (e.at <. val_ at ||. e.id <. val_ i)) (all_ wikiDb.audit_log)
    Nothing ->
      runSelectReturningList . select . limit_ most . offset_ (fromIntegral skipped) . orderBy_ (\e -> (desc_ e.at, desc_ e.id)) $
        filter_ byActor (all_ wikiDb.audit_log)
  named <- actors Nothing []
  pure
    Activity
      { available = True
      , entries = map entryOf (take activityPageSize rows)
      , more = length rows > activityPageSize
      , actors = sortOn (\a -> (T.toCaseFold a.login.text, a.id)) named
      }
  where
    actors after found = do
      next <- join <$> runSelectReturningOne (select (aggregate_ (\e -> min_ e.actor_id) (filter_ (\e -> maybe (val_ True) (\a -> e.actor_id >. val_ a) after) (all_ wikiDb.audit_log))))
      case next of
        Nothing -> pure (reverse found)
        Just a -> do
          login <- runSelectReturningOne (select (limit_ 1 ((\e -> e.actor_login) <$> orderBy_ (\e -> (desc_ e.at, desc_ e.id)) (filter_ (\e -> e.actor_id ==. val_ a) (all_ wikiDb.audit_log)))))
          actors (Just a) (Actor {id = UserId a, login = Login (fromMaybe a login)} : found)

-- | The whole log, the oldest first: what an export contains.
loadAuditLog :: (Backend be) => Db be [AuditEntry]
loadAuditLog = map entryOf <$> runSelectReturningList (select (orderBy_ (\e -> (asc_ e.at, asc_ e.id)) (all_ wikiDb.audit_log)))
