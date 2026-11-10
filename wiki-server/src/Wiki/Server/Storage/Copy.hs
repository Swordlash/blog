{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Copy' copies the wiki's database into another,
-- empty database: a wiki in SQLite into PostgreSQL, the way a wiki that has
-- grown moves (WP5.80a of docs/PLAN.md, issue #203), or any of the two into
-- any. @wiki-server copy-database@ runs it ("Wiki.Server.CopyDatabase").
--
-- = What the copy does
--
-- The source is read in one read transaction, so the copy is of one state
-- of it, and nothing is written to it. The target is written in one write
-- transaction: the schema, made by this program's own steps
-- ('Wiki.Server.Storage.Migrate.migrateWithin'), then every table's rows,
-- then the counters behind generated ids, then the checks. Only when every
-- check has passed is the transaction committed. A failure anywhere rolls
-- it back, schema included, so the target is left empty, as it was.
--
-- The source must be at this program's version of the schema, read whole
-- ('Wiki.Server.Storage.checkConnection'), and hold no table the copy does
-- not know. The target must hold no table at all.
--
-- = Every table
--
-- 'copiedTables' lists every table of the schema but @wiki_schema@, whose
-- rows the target's own steps write. The list is written by hand, in an
-- order that writes a row after the rows it refers to; each table's name
-- comes from "Wiki.Server.Storage.Schema". A table the list lacks is
-- refused before anything is written (a source or a target that holds
-- one), and a test of the server compares the list with the tables a
-- migrated database holds.
--
-- = What the two databases keep differently
--
-- Each row goes through this program's row types, read with the source's
-- decoders and written with the target's encoders, so a boolean (an
-- integer 0 or 1 in SQLite, a @boolean@ in PostgreSQL) and a time (a text
-- in SQLite, a @timestamptz@ in PostgreSQL) are carried as values, not as
-- the source's bytes. Besides that:
--
-- * A time is cut to the microsecond ('Wiki.Server.Storage.Rows.micro')
--   before it is written. PostgreSQL keeps no finer, and would round a
--   finer one where the storage cuts it. The storage writes no finer time
--   itself; a time finer than that is counted, and the count shown.
-- * PostgreSQL's text cannot hold the character NUL, which SQLite's can. A
--   row with one is refused, by name, before it is written ('keepsText').
-- * PostgreSQL makes the ids of a few columns from counters (identity
--   columns, such as @global_grants.seq@); SQLite gives a new row the
--   largest id plus one. The copy writes the source's ids, and then sets
--   each counter past the largest ('advanceCounters').
-- * PostgreSQL's @pages.search_words@, the words its search reads, is a
--   column the database makes from @search_fold@. It is not in the row
--   types and is not written: the target makes it.
-- * A row SQLite accepted that the target refuses (a foreign key SQLite did
--   not check because its connection had them off, a text PostgreSQL's
--   constraints compare otherwise) stops the copy. The refusal names the
--   table and the row by its primary key, never by its other columns,
--   which may be secrets.
--
-- = The order of the rows
--
-- Neither database lets a row refer to a row not yet written, and no
-- foreign key of the schema waits for the commit. So the tables are copied
-- in the order of 'copiedTables'; a space and a page come after the space
-- or page they are under ('parentsFirst'); and a space's home page, a page
-- of the space, is written into the space once the pages are copied.
--
-- = The checks
--
-- Every row of the source is digested as it is copied (SHA-256 of the row
-- as shown, summed, so that the order of the rows does not count). After
-- the copy each table of the target is read back through this program's
-- decoders and digested the same way: its row count and its digest must be
-- the source's. Then the target is read whole as @wiki-server check@ reads
-- a database. Both run in the target's transaction, before the commit.
module Wiki.Server.Storage.Copy
  ( -- * The copy
    copyDatabase
  , TableCopied (..)
  , CopyProblem (..)

    -- * The tables
  , Copied
  , copiedTables
  , copiedName
  , parentsFirst
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List ((\\))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.Beam (Beamable, Columnar, FromBackendRow, SqlSelect (..), Table (..), TableEntity, all_, delete, filter_, in_, insert, insertValues, runDelete, runInsert, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Database.Beam.Backend.SQL (BeamSqlBackendCanSerialize, MonadBeam (..), selectCmd)
import Database.Beam.Schema.Tables (Columnar' (..), DatabaseEntity (..), DatabaseEntityDescriptor (..), FieldsFulfillConstraint, TableField (..), WithConstraint (..), allBeamValues, changeBeamRep, withConstrainedFields)
import GHC.Show qualified
import Protolude
import Wiki.Server.Storage (CheckProblem (..), TableRead (..), checkConnection)
import Wiki.Server.Storage.Backend (Backend (..), withTransactionEither)
import Wiki.Server.Storage.Migrate (migrateWithin)
import Wiki.Server.Storage.Rows (chunksOf, micro)
import Wiki.Server.Storage.Schema

--------------------------------------------------------------------------------
-- The copy

-- | 'TableCopied' is one table as the copy wrote it: its name, its rows,
-- and how many of them had a time finer than a microsecond, cut to the
-- microsecond.
data TableCopied = TableCopied
  { table :: Text
  , rows :: Int
  , timesCut :: Int
  }
  deriving stock (Eq, Show)

-- | 'CopyProblem' is why a copy was refused, or failed. Either way the
-- target is as it was before.
data CopyProblem
  = -- | The source is at the first version of the schema, and this program
    -- copies the second: migrate it first.
    SourceNotMigrated Int Int
  | -- | The source does not read whole as this program reads it: what did
    -- not read.
    SourceUnreadable [Text]
  | -- | These tables are in the source or in the target's new schema, and
    -- the copy does not know them: this program is faulty.
    TablesUnknown [Text]
  | -- | The target holds these tables: it is not empty.
    TargetNotEmpty [Text]
  | -- | The target refused a row of this table: the row by its primary
    -- key, when the copy got as far as one row, and the target's error.
    RowRefused Text (Maybe Text) SomeException
  | -- | A row of this table holds a text the target cannot keep (the
    -- character NUL, in PostgreSQL): the row by its primary key.
    TextNotKept Text Text
  | -- | This table of the target, read back, is not what was copied into
    -- it: what differs.
    CopyDiffers Text Text
  | -- | The target, read whole after the copy, does not read: what did not.
    TargetUnreadable [Text]

-- | Shown with the exception's message, which has no 'Show' of its own
-- worth reading.
instance Show CopyProblem where
  showsPrec _ p = (shown p <>)

shown :: CopyProblem -> [Char]
shown = \case
  SourceNotMigrated at known -> "SourceNotMigrated " <> show at <> " " <> show known
  SourceUnreadable why -> "SourceUnreadable " <> show why
  TablesUnknown ts -> "TablesUnknown " <> show ts
  TargetNotEmpty ts -> "TargetNotEmpty " <> show ts
  RowRefused t row e -> "RowRefused " <> show t <> " " <> show row <> " " <> show (displayException e)
  TextNotKept t row -> "TextNotKept " <> show t <> " " <> show row
  CopyDiffers t why -> "CopyDiffers " <> show t <> " " <> show why
  TargetUnreadable why -> "TargetUnreadable " <> show why

-- | How many rows the copy writes with one statement.
batchSize :: Int
batchSize = 200

-- | Copy the database a connection reads into the empty database the other
-- connection writes, as the module's documentation says. Neither
-- connection may be in a transaction: the copy begins and ends its own.
-- The result is each table with its rows, or why nothing was copied.
--
-- When the target refuses a statement of many rows, the copy is made again
-- from the start with that table's rows written one at a time, so that
-- the refusal names the row.
copyDatabase :: forall s d. (Backend s, Backend d) => Connection s -> Connection d -> IO (Either CopyProblem [TableCopied])
copyDatabase source target =
  withTransactionEither False source . runExceptT $ do
    liftIO (checkConnection source) >>= \case
      Left (NotMigrated at known) -> throwError (SourceNotMigrated at known)
      Left (UnreadableTables tables) -> throwError (SourceUnreadable [t.table <> ": " <> why | t <- tables, Left why <- [t.rows]])
      Left (UnreadableRecords why) -> throwError (SourceUnreadable [why])
      -- A rule of the wiki's broken in the source (a space with a second
      -- page at the top of its pages, an account whose password no sign-in
      -- can use) is refused as the check refuses it. An account with no
      -- way in breaks no rule, and is copied.
      Left (BrokenRecords broken) -> throwError (SourceUnreadable broken)
      Right _ -> pass
    held <- liftIO (runDb source tableNames)
    let unknown = held \\ ("wiki_schema" : map copiedName copiedTables)
    unless (null unknown) (throwError (TablesUnknown unknown))
    ExceptT (attempt Nothing) `catchError` \case
      RowRefused table Nothing _ -> ExceptT (attempt (Just table))
      problem -> throwError problem
  where
    attempt :: Maybe Text -> IO (Either CopyProblem [TableCopied])
    attempt singly = withTransactionEither True target . runExceptT $ do
      present <- liftIO (runDb target tableNames)
      unless (null present) (throwError (TargetNotEmpty present))
      _ <- liftIO (migrateWithin target)
      made <- liftIO (runDb target tableNames)
      let unknown = made \\ ("wiki_schema" : map copiedName copiedTables)
      unless (null unknown) (throwError (TablesUnknown unknown))
      later <- liftIO (newIORef [])
      copied <- for copiedTables $ \c@(Copied entity _) -> do
        let name = copiedName c
            size = if singly == Just name then 1 else batchSize
        written <- copyTable source target size later c
        -- The columns held back until this table was written.
        waiting <- liftIO (readIORef later)
        for_ [w | (after, w) <- waiting, after == name] identity
        pure (written, Checked entity)
      liftIO (advanceCounters target)
      for_ copied $ \(written, Checked entity) -> verify source target entity written
      liftIO (checkConnection target) >>= \case
        Left (NotMigrated at known) -> throwError (TargetUnreadable ["The copy is at version " <> show at <> " of the schema, and this program reads version " <> show known <> "."])
        Left (UnreadableTables tables) -> throwError (TargetUnreadable [t.table <> ": " <> why | t <- tables, Left why <- [t.rows]])
        Left (UnreadableRecords why) -> throwError (TargetUnreadable [why])
        Left (BrokenRecords broken) -> throwError (TargetUnreadable broken)
        Right _ -> pass
      pure (map (\(w, _) -> TableCopied {table = w.name, rows = w.count, timesCut = w.cut}) copied)

-- | A table to check after the copy, whatever its rows' type.
data Checked where
  Checked :: (Copyable t) => (forall be. DatabaseEntity be WikiDb (TableEntity t)) -> Checked

-- | What the copy of one table wrote: its name, its rows, how many had a
-- time cut, and the digest of the rows ('digestOf').
data Written = Written
  { name :: Text
  , count :: Int
  , cut :: Int
  , digest :: Integer
  }

-- | Copy one table's rows, this many to a statement, and add to the list
-- of writes held back ('Held') the ones of this table's rows. The rows are
-- read from the source as they are written, never all at once.
copyTable
  :: forall s d
   . (Backend s, Backend d)
  => Connection s
  -> Connection d
  -> Int
  -> IORef [(Text, ExceptT CopyProblem IO ())]
  -> Copied
  -> ExceptT CopyProblem IO Written
copyTable source target size later c@(Copied entity shape) = do
  let name = copiedName c
  -- What the target's own steps wrote into the table (migration 0002's row
  -- of permissions_generation) gives way to the source's rows.
  liftIO (runDb target (runDelete (delete entity (\_ -> val_ True))))
  tally <- liftIO (newIORef (Written name 0 0 0))
  let write batch = runExceptT $ do
        let cutRows = map toMicro batch
            named r = keyText entity r
        for_ cutRows $ \r -> unless (all (keepsText (Proxy @d)) (textsOf r)) (throwError (TextNotKept name (named r)))
        let written = maybe identity (\Held {cleared} -> map cleared) shape.held cutRows
        ran <- liftIO (tryQuiet (runDb target (writeRows entity written)))
        case ran of
          Left e -> throwError (RowRefused name (case written of [r] -> Just (named r); _ -> Nothing) e)
          Right () -> pass
        for_ shape.held $ \Held {after, restore} ->
          liftIO $ modifyIORef' later (<> [(after, restoreHeld name (named r) w) | r <- cutRows, Just w <- [restore r]])
        liftIO $ modifyIORef' tally $ \w ->
          w
            { count = w.count + length batch
            , cut = w.cut + length (filter identity (zipWith (/=) batch cutRows))
            , digest = w.digest + sum (map digestOf cutRows)
            }
  ExceptT $ case shape.tree of
    Nothing -> runDb source (streamRows (select (all_ entity)) (inBatches size write))
    Just Tree {idOf, parentOf} -> do
      pairs <- runDb source (runSelectReturningList (select (fmap (\r -> (idOf r, parentOf r)) (all_ entity))))
      let fetch ids = do
            found <- runDb source (streamRows (select (filter_ (\r -> idOf r `in_` map val_ ids) (all_ entity))) collect)
            let byId = Map.fromList [(idOf r, r) | r <- found]
            write (mapMaybe (`Map.lookup` byId) ids)
      foldM (\done ids -> either (pure . Left) (\() -> fetch ids) done) (Right ()) (chunksOf size (parentsFirst pairs))
  liftIO (readIORef tally)
  where
    -- A held column's write, which names the row it is of when refused.
    restoreHeld :: Text -> Text -> Db d () -> ExceptT CopyProblem IO ()
    restoreHeld name row w = ExceptT (first (RowRefused name (Just row)) <$> tryQuiet (runDb target w))

-- | Read rows from a source of them and hand them on this many at a time,
-- until there are no more or a hand-over fails.
inBatches :: (MonadIO m) => Int -> ([a] -> IO (Either e ())) -> m (Maybe a) -> m (Either e ())
inBatches size each next = go
  where
    go = do
      batch <- taking size
      if null batch
        then pure (Right ())
        else
          liftIO (each batch) >>= \case
            Left e -> pure (Left e)
            Right ()
              | length batch < size -> pure (Right ())
              | otherwise -> go
    taking 0 = pure []
    taking k = next >>= maybe (pure []) (\r -> (r :) <$> taking (k - 1))

-- | Every row from a source of them.
collect :: (Monad m) => m (Maybe a) -> m [a]
collect next = next >>= maybe (pure []) (\r -> (r :) <$> collect next)

-- | Read a table of the target back and compare it with what was written:
-- its row count and its digest. When they differ, the rows that differ are
-- found, and the first one named.
verify :: (Backend s, Backend d, Copyable t) => Connection s -> Connection d -> (forall be. DatabaseEntity be WikiDb (TableEntity t)) -> Written -> ExceptT CopyProblem IO ()
verify source target entity written = do
  (n, digest) <- liftIO (runDb target (streamRows (select (all_ entity)) (tally 0 0)))
  when (n /= written.count || digest /= written.digest) $ do
    sourceDigests <- liftIO (runDb source (streamRows (select (all_ entity)) (digests (keyText entity) toMicro)))
    targetDigests <- liftIO (runDb target (streamRows (select (all_ entity)) (digests (keyText entity) identity)))
    let missing = Map.difference sourceDigests targetDigests
        extra = Map.difference targetDigests sourceDigests
        counts = "the source has " <> show written.count <> " rows, the copy " <> show n
    throwError . CopyDiffers written.name $ case (Map.elems missing, Map.elems extra) of
      (row : _, _) -> counts <> "; the source's row " <> row <> " is not in the copy as it is in the source"
      ([], row : _) -> counts <> "; the copy's row " <> row <> " is not in the source"
      ([], []) -> counts
  where
    tally !k !acc next = next >>= maybe (pure (k, acc)) (\r -> tally (k + 1) (acc + digestOf r) next)
    digests named f next = go Map.empty
      where
        go !m = next >>= maybe (pure m) (\r -> go (Map.insert (digestBytes (f r)) (named r) m))

-- | Run an action and give back what it threw, but for an asynchronous
-- exception (the thread being stopped), which goes on.
tryQuiet :: IO a -> IO (Either SomeException a)
tryQuiet act =
  try act >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other

-- | A row's digest: SHA-256 of the row as shown, as a number. The digests
-- of a table's rows are summed, so the sum does not depend on their order.
digestOf :: (Show a) => a -> Integer
digestOf = BS.foldl' (\acc w -> acc * 256 + fromIntegral w) 0 . digestBytes

digestBytes :: (Show a) => a -> ByteString
digestBytes = SHA256.hash . encodeUtf8 . show

--------------------------------------------------------------------------------
-- The tables

-- | 'Copyable' is a row type of the schema, as the copy reads, writes,
-- names and compares its rows. Every table's row type is one, with the
-- defaults: they need only what a row type of "Wiki.Server.Storage.Schema"
-- has, and each instance is one line.
class (Beamable t, Table t, Eq (t Identity), Show (t Identity)) => Copyable t where
  -- | Read the rows a query selects, one at a time.
  streamRows :: (Backend be) => SqlSelect be (t Identity) -> (Db be (Maybe (t Identity)) -> Db be a) -> Db be a
  default streamRows :: forall be a. (Backend be, FromBackendRow be (t Identity)) => SqlSelect be (t Identity) -> (Db be (Maybe (t Identity)) -> Db be a) -> Db be a
  streamRows (SqlSelect s) = runReturningMany @be @(Db be) (selectCmd s)

  -- | Write rows into a table, with one statement.
  writeRows :: (Backend be) => DatabaseEntity be WikiDb (TableEntity t) -> [t Identity] -> Db be ()
  default writeRows :: (Backend be, FieldsFulfillConstraint (BeamSqlBackendCanSerialize be) t) => DatabaseEntity be WikiDb (TableEntity t) -> [t Identity] -> Db be ()
  writeRows entity rs = unless (null rs) (runInsert (insert entity (insertValues rs)))

  -- | The row with every time in it cut to the microsecond.
  toMicro :: t Identity -> t Identity
  default toMicro :: (FieldsFulfillConstraint Typeable t) => t Identity -> t Identity
  toMicro = changeBeamRep (\(Columnar' (WithConstraint x)) -> Columnar' (cutTime x)) . withConstrainedFields @Typeable

  -- | Every text in the row.
  textsOf :: t Identity -> [Text]
  default textsOf :: (FieldsFulfillConstraint Typeable t) => t Identity -> [Text]
  textsOf = concat . allBeamValues (\(Columnar' (WithConstraint x)) -> textIn x) . withConstrainedFields @Typeable

  -- | The values of the row's primary key, as shown.
  keyValues :: t Identity -> [Text]
  default keyValues :: (FieldsFulfillConstraint Show (PrimaryKey t)) => t Identity -> [Text]
  keyValues = allBeamValues (\(Columnar' (WithConstraint x)) -> show x) . withConstrainedFields @Show . primaryKey

-- | A time cut to the microsecond; any other value as it is.
cutTime :: forall a. (Typeable a) => a -> a
cutTime x
  | Just Refl <- eqT @a @UTCTime = micro x
  | Just Refl <- eqT @a @(Maybe UTCTime) = micro <$> x
  | otherwise = x

-- | The text a value is, if it is one.
textIn :: forall a. (Typeable a) => a -> [Text]
textIn x
  | Just Refl <- eqT @a @Text = [x]
  | Just Refl <- eqT @a @(Maybe Text) = maybeToList x
  | otherwise = []

instance Copyable Users

instance Copyable Groups

instance Copyable GroupMembers

instance Copyable GlobalGrants

instance Copyable SpaceGrants

instance Copyable Sessions

instance Copyable Invitations

instance Copyable Identities

instance Copyable Totp

instance Copyable RecoveryCodes

instance Copyable ResetTokens

instance Copyable EmailVerifications

instance Copyable Passkeys

instance Copyable Vaults

instance Copyable VaultItems

instance Copyable PublicKeys

instance Copyable KeyGrants

instance Copyable PageKeys

instance Copyable SealedVersions

instance Copyable Spaces

instance Copyable Pages

instance Copyable PageVersions

instance Copyable Attachments

instance Copyable Drafts

instance Copyable Threads

instance Copyable Comments

instance Copyable Watches

instance Copyable Stars

instance Copyable Notifications

instance Copyable Settings

instance Copyable SignInProviders

instance Copyable AuditLog

instance Copyable PermissionsGeneration

-- | 'Copied' is one table of the schema, and what its copy needs beyond
-- its rows ('Shape').
data Copied where
  Copied :: (Copyable t) => (forall be. DatabaseEntity be WikiDb (TableEntity t)) -> Shape t -> Copied

-- | 'Shape' is what one table's copy needs to know of its rows: whether
-- they form a tree, and a column written only once a later table is.
data Shape t = Shape
  { tree :: Maybe (Tree t)
  , held :: Maybe (Held t)
  }

-- | 'Tree' is a table whose rows are under rows of the same table: the
-- column of a row's id, and the column of the id of the row it is under.
data Tree t = Tree
  { idOf :: forall f. t f -> Columnar f Text
  , parentOf :: forall f. t f -> Columnar f (Maybe Text)
  }

-- | 'Held' is a column of a table that refers to the rows of a later one:
-- it is written empty ('cleared') with its row, and set ('restore') once
-- the later table, named by 'after', is written.
data Held t = Held
  { after :: Text
  , cleared :: t Identity -> t Identity
  , restore :: forall be. (Backend be) => t Identity -> Maybe (Db be ())
  }

-- | A table with nothing to know of its rows.
plain :: (Copyable t) => (forall be. DatabaseEntity be WikiDb (TableEntity t)) -> Copied
plain entity = Copied entity Shape {tree = Nothing, held = Nothing}

-- | A table's name, as the schema names it.
copiedName :: Copied -> Text
copiedName (Copied entity _) = nameOf entity

-- | Every table of the schema but @wiki_schema@, in the order the copy
-- writes them: each after the tables its rows refer to.
copiedTables :: [Copied]
copiedTables =
  [ plain wikiDb.users
  , plain wikiDb.groups
  , plain wikiDb.group_members
  , plain wikiDb.global_grants
  , Copied wikiDb.spaces Shape {tree = Just spaceTree, held = Just homePage}
  , plain wikiDb.space_grants
  , Copied wikiDb.pages Shape {tree = Just pageTree, held = Nothing}
  , plain wikiDb.page_versions
  , plain wikiDb.attachments
  , plain wikiDb.drafts
  , plain wikiDb.threads
  , plain wikiDb.comments
  , plain wikiDb.watches
  , plain wikiDb.stars
  , plain wikiDb.notifications
  , plain wikiDb.sessions
  , plain wikiDb.invitations
  , plain wikiDb.identities
  , plain wikiDb.totp
  , plain wikiDb.recovery_codes
  , plain wikiDb.reset_tokens
  , plain wikiDb.email_verifications
  , plain wikiDb.passkeys
  , plain wikiDb.vaults
  , plain wikiDb.vault_items
  , plain wikiDb.public_keys
  , plain wikiDb.key_grants
  , plain wikiDb.page_keys
  , plain wikiDb.sealed_versions
  , plain wikiDb.settings
  , plain wikiDb.sign_in_providers
  , plain wikiDb.audit_log
  , -- Last: the database's triggers count up the generation as the users,
    -- spaces, grants and members above are written, and the copy then
    -- writes the source's.
    plain wikiDb.permissions_generation
  ]
  where
    spaceTree :: Tree Spaces
    spaceTree = Tree {idOf = \r -> r.id, parentOf = \r -> r.parent}
    pageTree :: Tree Pages
    pageTree = Tree {idOf = \r -> r.id, parentOf = \r -> r.parent}
    -- A space's home page is one of its pages, which are copied after it.
    homePage :: Held Spaces
    homePage =
      Held
        { after = "pages"
        , cleared = \r -> r {home_page = Nothing}
        , restore = \r ->
            r.home_page <&> \page ->
              runUpdate (update wikiDb.spaces (\s -> s.home_page <-. val_ (Just page)) (\s -> s.id ==. val_ r.id))
        }

-- | A table's name.
nameOf :: DatabaseEntity be WikiDb (TableEntity t) -> Text
nameOf (DatabaseEntity DatabaseTable {dbTableCurrentName}) = dbTableCurrentName

-- | A row named by its primary key, column by column:
-- @id = "6f1c…"@, which says which row without showing its other columns.
keyText :: (Copyable t) => DatabaseEntity be WikiDb (TableEntity t) -> t Identity -> Text
keyText (DatabaseEntity DatabaseTable {dbTableSettings}) r =
  T.intercalate ", " (zipWith (\column v -> column <> " = " <> v) (allBeamValues (\(Columnar' f) -> _fieldName f) (primaryKey dbTableSettings)) (keyValues r))

-- | The ids of a tree's rows, each after the row it is under: first the
-- rows under no row, then the rows under those, and so on. A row whose
-- parent is not among the rows counts as under none, and a row the order
-- does not reach (a loop of parents) comes last: the target refuses
-- either, and the refusal names it.
parentsFirst :: [(Text, Maybe Text)] -> [Text]
parentsFirst pairs = placed <> [i | (i, _) <- pairs, i `Set.notMember` placedSet]
  where
    ids = Set.fromList (map fst pairs)
    children = Map.fromListWith (flip (<>)) [(p, [i]) | (i, Just p) <- pairs]
    roots = [i | (i, p) <- pairs, maybe True (`Set.notMember` ids) p]
    placed = levels roots
    levels [] = []
    levels level = level <> levels (concatMap (\i -> Map.findWithDefault [] i children) level)
    placedSet = Set.fromList placed
