-- | The wiki kept by the server: in an SQLite database, with attachments'
-- bytes on disk under their content hash, behind the application's own
-- interface, 'MonadWiki'.
--
-- 'SqliteWiki' is a 'MonadWiki' like the demo's in-memory backend, and
-- passes the same contract ("Wiki.App.Backend.Contract"): the server's
-- handlers ask it what the application would ask any backend, and get the
-- same answers the demo gives, the same errors in the same order included.
-- Every operation does what "Wiki.App.Backend.Mem.State" does for the demo,
-- with the same functions of @wiki-core@ (the permission rules, the orders,
-- paths and slugs, the search), over the rows it reads instead of a map in
-- memory.
--
-- = Who is asking
--
-- A program runs as someone ('Who'), given when it is run rather than kept
-- anywhere: a reader nobody has signed in ('Anonymous'), one of the wiki's
-- users ('AsUser'), or 'Administrator', the operator of the server (on its
-- loopback admin listener: decision 11 of docs/PLAN.md), who passes every
-- check. The server says who for each
-- request; nothing here knows about requests.
--
-- = Transactions
--
-- One connection, used by one operation at a time: each operation is one
-- transaction, which reads what it needs (every space and grant, since every
-- rule is about a space's ancestors; the pages it is about), checks what the
-- class's Haddock says it checks, in that order, and only then writes. An
-- operation that fails writes nothing, and one that throws (a full disk)
-- rolls back. The database is in WAL mode, so a backup taken by another
-- process meanwhile reads without waiting ("Wiki.Server.Storage.Backup").
--
-- = The wiki's settings
--
-- Whom the wiki lets in ("Wiki.Core.Access") is asked on every request
-- (the listener's gate, and every rule through the grants), so the storage
-- keeps the settings in memory once read ('readSettings'), and a change
-- made through it puts the new ones there before anything else can use the
-- connection. A change made by another process (none does) would be seen
-- at the next start.
module Wiki.Server.Storage
  ( -- * The storage
    Storage
  , Config (..)
  , defaultConfig
  , openStorage
  , closeStorage
  , withStorage
  , withStorageAside
  , withDatabase
  , storageDataDir

    -- * The wiki's settings
  , readSettings
  , settingsWith

    -- * Who is asking
  , Who (..)
  , administratorId
  , administratorUser
  , userByLogin

    -- * The wiki
  , SqliteWiki
  , runSqliteWiki
  , attachmentFile

    -- * Whole wikis
  , importArchive
  , exportArchive
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID (..))
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.SQLite.Simple (Connection, Only (..), close, execute, execute_, open, query, query_, withConnection)
import Protolude
import System.Directory (createDirectoryIfMissing)
import Wiki.Api.Account (Account, NewAccount (..))
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), WikiSettings (..), checkEmail, invitationLifetime)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), anonymous, anonymousIn, maxAttachmentSize)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, childrenInOrder, nextPosition, orderName, renumber, reposition)
import Wiki.Core.Page (Page (..), pageTreeOrder)
import Wiki.Core.Path (ancestry, childrenOf, findChild, pathOf, resolvePath)
import Wiki.Core.Permission
  ( GlobalGrant (..)
  , GlobalPermission (..)
  , Grants (..)
  , Principal (..)
  , SpaceAccess (..)
  , SpaceGrant (..)
  , SpacePermission (..)
  , Subject (..)
  , canAdministerSpace
  , canEdit
  , canView
  , hasGlobalPermission
  , isFor
  , mayCreateSpace
  , mayMovePage
  , mayMoveSpace
  )
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), Searchable (..), bodyText, folded, searchPlain)
import Wiki.Core.Slug (Slug, freshSlug, mkSlug, slugText, slugify)
import Wiki.Core.Space (Space (..), positionSpace, spaceTreeOrder)
import Wiki.Core.User (Group (..), Standing (..), User (..), checkLogin, checkPassword)
import Wiki.Core.Version (Author (..), Version (..), VersionInfo, versionInfo)
import Wiki.Server.Password (hashPassword, newToken, tokenHash)
import Wiki.Server.Storage.Backup (backupFiles)
import Wiki.Server.Storage.Blobs (blobFile, collectBlobs, readBlob, storeBlob)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir, databaseFile)
import Wiki.Server.Storage.Migrate (migrate)
import Wiki.Server.Storage.Rows

--------------------------------------------------------------------------------
-- The storage

-- | An open storage: the database's connection, and the directory it and
-- the attachments are in.
data Storage = Storage
  { connection :: MVar Connection
  , dataDir :: FilePath
  , config :: Config
  , settings :: IORef (Maybe WikiSettings)
  -- ^ The wiki's settings, once read: filled and changed only by whoever
  -- holds the connection, so that one read before a change is never put
  -- there after it.
  }

-- | What a storage is opened with besides its directory.
newtype Config = Config
  { attachmentAddress :: Attachment -> Text
  -- ^ Where a browser fetches the bytes of an attachment the storage keeps:
  -- the server's route for them, which serves 'attachmentFile'.
  }

-- | Attachments at @\/api\/v1\/attachments\/\<id\>@.
defaultConfig :: Config
defaultConfig = Config {attachmentAddress = \a -> "/api/v1/attachments/" <> a.id.text}

-- | Open the storage in a data directory ("Wiki.Server.Storage.Layout"),
-- made if it is not there: the database is created or brought up to this
-- program's schema ("Wiki.Server.Storage.Migrate"), and the attachments'
-- files that neither it nor any backup refers to any more are deleted
-- ("Wiki.Server.Storage.Blobs" says why then). A database a newer program
-- has migrated is refused with an exception, and nothing is changed.
openStorage :: Config -> FilePath -> IO Storage
openStorage = openWith True

-- | Open the storage beside a server that may be running on it (the
-- console's @wiki-server users …@): migrated as 'openStorage' does, but
-- deleting no attachment's file, since the server may be writing one that
-- its database does not name yet. A write waits for the server's (up to
-- ten seconds) rather than fail at once.
withStorageAside :: FilePath -> (Storage -> IO a) -> IO a
withStorageAside dir = bracket (openWith False defaultConfig dir) closeStorage

openWith :: Bool -> Config -> FilePath -> IO Storage
openWith collect config dataDir = do
  createDirectoryIfMissing True dataDir
  c <- open (databaseFile dataDir)
  flip onException (close c) $ do
    execute_ c "PRAGMA busy_timeout = 10000"
    -- A pragma that answers with a row, which execute_ would refuse.
    _ <- query_ c "PRAGMA journal_mode = WAL" :: IO [Only Text]
    execute_ c "PRAGMA synchronous = NORMAL"
    execute_ c "PRAGMA foreign_keys = ON"
    _ <- migrate c
    when collect (collectGarbage c dataDir)
  connection <- newMVar c
  settings <- newIORef Nothing
  pure Storage {connection, dataDir, config, settings}

-- | Close the storage's database.
closeStorage :: Storage -> IO ()
closeStorage st = withMVar st.connection close

-- | Run something with the storage open, and close it afterwards.
withStorage :: Config -> FilePath -> (Storage -> IO a) -> IO a
withStorage config dir = bracket (openStorage config dir) closeStorage

-- | The database itself, for what the interface does not do: the tests'
-- look inside, and maintenance. Nothing else runs on it meanwhile.
withDatabase :: Storage -> (Connection -> IO a) -> IO a
withDatabase st = withMVar st.connection

-- | The data directory a storage was opened in.
storageDataDir :: Storage -> FilePath
storageDataDir st = st.dataDir

-- | The wiki's settings as they are now: from memory, once they have been
-- read.
readSettings :: Storage -> IO WikiSettings
readSettings st = readIORef st.settings >>= maybe (withMVar st.connection (settingsWith st)) pure

-- | The wiki's settings, for someone who holds the storage's connection
-- (inside 'withDatabase'): read from it the first time, and kept.
settingsWith :: Storage -> Connection -> IO WikiSettings
settingsWith st c =
  readIORef st.settings >>= \case
    Just s -> pure s
    Nothing -> do
      s <- loadSettings c
      writeIORef st.settings (Just s)
      pure s

-- | Delete the attachments' files that nothing refers to: not the database,
-- and not one of the backups kept, which a restore would bring back. A
-- backup that cannot be read might refer to any of them, so then nothing is
-- deleted.
collectGarbage :: Connection -> FilePath -> IO ()
collectGarbage c dataDir = do
  live <- blobsIn c
  kept <- traverse (\b -> try @SomeException (withConnection b blobsIn)) =<< backupFiles (backupsDir dataDir)
  case sequence kept of
    Left _ -> pass
    Right fromBackups -> void (collectBlobs (attachmentsDir dataDir) (Set.unions (live : fromBackups)))
  where
    blobsIn d = Set.fromList . map (BlobId . fromOnly) <$> query_ d "SELECT DISTINCT blob FROM attachments WHERE blob IS NOT NULL"

--------------------------------------------------------------------------------
-- Who is asking

-- | Who an operation is run as.
data Who
  = -- | Nobody who has signed in: they see the public spaces.
    Anonymous
  | -- | One of the wiki's users, with what is granted to them and to their
    -- groups. An id that is no user's, or a disabled user's, is nobody.
    AsUser UserId
  | -- | The server's operator, who passes every check, as a holder of the
    -- global 'Administer' would. They are no user of the wiki, and are shown
    -- to the application as 'administratorUser'.
    Administrator
  deriving stock (Eq, Show)

-- | The id the administrator has where one is needed: their drafts are kept
-- under it, and the versions they save name it. No user has it (users' ids
-- are UUIDs, or an imported wiki's @user-N@).
administratorId :: UserId
administratorId = UserId "~administrator"

-- | The administrator as the application sees them: signed in, holding the
-- global 'Administer'.
administratorUser :: User
administratorUser = User {id = administratorId, login = "administrator", displayName = "Administrator"}

-- | The user with a login.
userByLogin :: Storage -> Text -> IO (Maybe User)
userByLogin st login = withDatabase st (`loadUserByLogin` login)

--------------------------------------------------------------------------------
-- Transactions

-- | What an operation knows as it runs: the connection, every space and
-- grant as the transaction began, and who is asking.
data Ctx = Ctx
  { conn :: Connection
  , blobs :: FilePath
  , spaces :: Map SpaceId Space
  , grants :: Grants
  -- ^ The wiki's, and for the administrator one more: 'Administer' for them.
  , principal :: Maybe Principal
  -- ^ Who is asking, as the rules see them.
  , user :: Maybe User
  -- ^ Who is asking, as the application sees them.
  , author :: Maybe UserId
  -- ^ The id their drafts and the versions they save are kept under.
  , creator :: Maybe UserId
  -- ^ The user a space they create is granted to: nobody for the
  -- administrator, who needs no grant.
  , wiki :: WikiSettings
  -- ^ The wiki's settings as the transaction began.
  }

-- | An operation, in a transaction: what it finds wrong ends it with a
-- 'WikiError', and the transaction is rolled back.
newtype Tx a = Tx (ReaderT Ctx (ExceptT WikiError IO) a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader Ctx, MonadError WikiError)

-- | Whether a transaction writes: one that does takes the database's write
-- lock as it begins, so that what it read is still so when it writes.
data Mode = Reads | Writes

-- | Run an operation as someone, in a transaction of its own: committed if
-- it succeeds, rolled back if it fails or throws.
transact :: Storage -> Who -> Mode -> Tx a -> IO (Either WikiError a)
transact st who mode body = transactThen st who mode body (const pass)

-- | 'transact', and once the transaction has committed, and before anyone
-- else may use the connection, something done with what it gave.
transactThen :: Storage -> Who -> Mode -> Tx a -> (a -> IO ()) -> IO (Either WikiError a)
transactThen st who mode (Tx body) committed = withMVar st.connection $ \c -> do
  execute_ c (case mode of Reads -> "BEGIN"; Writes -> "BEGIN IMMEDIATE")
  result <- (context st c who >>= runExceptT . runReaderT body) `onException` execute_ c "ROLLBACK"
  case result of
    Left _ -> execute_ c "ROLLBACK"
    Right a -> do
      execute_ c "COMMIT" `onException` execute_ c "ROLLBACK"
      committed a
  pure result

-- | What an operation starts from: the grants with whom the wiki is open
-- to, which the rules take from them.
context :: Storage -> Connection -> Who -> IO Ctx
context st c who = do
  spaces <- loadSpaces c
  rows <- loadGrants c
  wiki <- settingsWith st c
  let stored = Grants {global = rows.global, spaces = rows.spaces, access = wiki.access}
  let ctx grants principal user author creator = Ctx {conn = c, blobs = attachmentsDir st.dataDir, spaces, grants, principal, user, author, creator, wiki}
  case who of
    Anonymous -> pure (ctx stored Nothing Nothing Nothing Nothing)
    AsUser u ->
      loadActiveUser c u >>= \case
        Nothing -> pure (ctx stored Nothing Nothing Nothing Nothing)
        Just found -> do
          groups <- loadGroupsOf c u
          pure (ctx stored (Just Principal {user = u, groups}) (Just found) (Just u) (Just u))
    Administrator ->
      pure
        ( ctx
            (stored <> Grants {global = [GlobalGrant {subject = SubjectUser administratorId, permission = Administer}], spaces = [], access = Open})
            (Just Principal {user = administratorId, groups = mempty})
            (Just administratorUser)
            (Just administratorId)
            Nothing
        )

-- | Something done with the connection.
db :: (Connection -> IO a) -> Tx a
db f = asks (\x -> x.conn) >>= liftIO . f

failWith :: WikiError -> Tx a
failWith = throwError

invalid :: Text -> Tx a
invalid = failWith . Invalid

-- | 'Forbidden' unless the condition holds.
require :: Bool -> Tx ()
require ok = unless ok (failWith Forbidden)

-- | A space's chain from the top level, or none if it is not there.
chainOf :: Ctx -> SpaceId -> [Space]
chainOf ctx sid = fromMaybe [] (ancestry (`Map.lookup` ctx.spaces) sid)

-- | Whether a chain goes through the given space.
within :: SpaceId -> [Space] -> Bool
within sid = any (\s -> s.id == sid)

-- | A space by id, with its chain.
findSpace :: SpaceId -> Tx (Space, [Space])
findSpace sid = do
  ctx <- ask
  maybe (failWith NotFound) (\s -> pure (s, chainOf ctx sid)) (Map.lookup sid ctx.spaces)

-- | A page by id, as a node.
findNode :: PageId -> Tx PageNode
findNode pid = db (`pageNode` pid) >>= maybe (failWith NotFound) pure

-- | A page by id, whole.
findPage :: PageId -> Tx Page
findPage pid = db (`loadPage` pid) >>= maybe (failWith NotFound) pure

-- | The chain of a page's space.
chainOfPage :: PageNode -> Tx [Space]
chainOfPage p = asks (`chainOf` p.space)

requireView :: [Space] -> Tx ()
requireView c = ask >>= \x -> require (canView x.principal x.grants c)

requireEdit :: [Space] -> Tx ()
requireEdit c = requireView c >> ask >>= \x -> require (canEdit x.principal x.grants c)

requireAdminister :: [Space] -> Tx ()
requireAdminister c = requireView c >> ask >>= \x -> require (canAdministerSpace x.principal x.grants c)

-- | A name or title with the blanks around it trimmed, or 'Invalid' if
-- nothing is left.
nonBlank :: Text -> Text -> Tx Text
nonBlank what t = case T.strip t of
  "" -> invalid (what <> " cannot be blank.")
  stripped -> pure stripped

-- | A new id: a UUID.
newId :: Tx Text
newId = liftIO (UUID.toText <$> generateV4)

now :: Tx UTCTime
now = liftIO getCurrentTime

-- | A slug for a name with nothing a slug can be made of.
fallbackSlug :: Text -> Slug
fallbackSlug t = either (\e -> panic ("not a slug: " <> t <> ", " <> show e)) identity (mkSlug t)

--------------------------------------------------------------------------------
-- The wiki

-- | The wiki in a storage, as someone; over any base monad that does IO,
-- so that what runs in another monad (a component rendered on the server)
-- can run over it.
newtype SqliteWiki m a = SqliteWiki (ReaderT Env m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

data Env = Env
  { storage :: Storage
  , who :: Who
  }

instance (MonadUUID m) => MonadUUID (SqliteWiki m) where
  generateV4 = SqliteWiki (lift generateV4)

-- | Run a program against the wiki in a storage, as someone.
runSqliteWiki :: Storage -> Who -> SqliteWiki m a -> m a
runSqliteWiki storage who (SqliteWiki program) = runReaderT program Env {storage, who}

run :: (MonadIO m) => Mode -> Tx a -> SqliteWiki m (Either WikiError a)
run mode tx = SqliteWiki $ do
  env <- ask
  liftIO (transact env.storage env.who mode tx)

-- | A read that cannot fail; the 'Left' it cannot give is the default.
answer :: (MonadIO m) => a -> Tx a -> SqliteWiki m a
answer fallback tx = fromRight fallback <$> run Reads tx

instance (MonadIO m) => MonadWiki (SqliteWiki m) where
  session = answer anonymous sessionTx
  listSpaces = answer [] listSpacesTx
  getSpace = run Reads . getSpaceTx
  createSpace parent = run Writes . createSpaceTx parent
  renameSpace sid = run Writes . renameSpaceTx sid
  setSpacePublic sid public = run Writes (adjustSpace sid (\s -> pure s {public}))
  setSpaceMathMacros sid macros = run Writes (adjustSpace sid (\s -> pure s {mathMacros = trimLines macros}))
  spaceAccess = run Reads . spaceAccessTx
  setSpaceGrant sid subject permission = run Writes . setSpaceGrantTx sid subject permission
  moveSpace sid = run Writes . moveSpaceTx sid
  deleteSpace = run Writes . deleteSpaceTx
  setSpaceOrder sid kind = run Writes . setSpaceOrderTx sid kind
  shiftSpace sid = run Writes . shiftSpaceTx sid
  shiftPage pid = run Writes . shiftPageTx pid
  listPages = run Reads . listPagesTx
  getPage sid = run Reads . getPageTx sid
  createPage sid parent title = run Writes . createPageTx sid parent title
  savePage pid base title = run Writes . savePageTx pid base title
  movePage pid sid = run Writes . movePageTx pid sid
  deletePage = run Writes . deletePageTx
  uploadAttachment pid name mediaType = run Writes . uploadAttachmentTx pid name mediaType
  deleteAttachment = run Writes . deleteAttachmentTx
  attachmentUrl a = case a.source of
    SourceUrl url -> pure url
    SourceBlob _ -> do
      address <- SqliteWiki (asks (\env -> env.storage.config.attachmentAddress))
      answer "" (maybe "" (const (address a)) <$> db (`loadAttachment` a.id))
  searchPages = answer [] . searchPagesTx
  getDraft = run Reads . getDraftTx
  saveDraft pid base title = run Writes . saveDraftTx pid base title
  discardDraft = run Writes . discardDraftTx
  listVersions = run Reads . listVersionsTx
  getVersion pid = run Reads . getVersionTx pid
  restoreVersion pid at = run Writes . restoreVersionTx pid at

-- | The administration's, as the class's Haddock says
-- ("Wiki.App.Backend.Admin"): each operation one transaction that first
-- checks that whoever is asking holds the global administer, which the
-- administrator always does and a user does by a grant.
instance (MonadIO m) => MonadAdmin (SqliteWiki m) where
  directory = run Reads directoryTx
  setAdministrator u = run Writes . setGlobalGrantTx Administer u
  setCreateSpaces u = run Writes . setGlobalGrantTx CreateSpaces u

  -- A password is checked and hashed before the transaction that keeps
  -- it, since hashing takes tens of milliseconds the database should not
  -- wait for; and only for an administrator, so that nobody else can make
  -- the server spend them. The transaction checks again.
  createUser new =
    run Reads requireAdministrator >>= \case
      Left e -> pure (Left e)
      Right () -> case (,) <$> checkLogin new.login <*> checkPassword new.password of
        Left why -> pure (Left (Invalid why))
        Right (login, password) -> do
          phc <- liftIO (hashPassword password)
          uid <- liftIO (UUID.toText <$> generateV4)
          let name = case T.strip new.displayName of
                "" -> login
                n -> n
          run Writes $ do
            requireAdministrator
            db (\c -> insertAccount c (UserId uid) login name (Just phc)) >>= \case
              Left taken -> failWith (Conflict ("There is a user with the login " <> taken <> " already."))
              Right account -> pure account
  setPassword u password =
    run Reads (requireAdministrator >> findUser u) >>= \case
      Left e -> pure (Left e)
      Right _ -> case checkPassword password of
        Left why -> pure (Left (Invalid why))
        Right p -> do
          phc <- liftIO (hashPassword p)
          run Writes $ changeAccountTx u $ \c -> updatePasswordHash c u phc >> deleteSessionsOf c u
  setDisabled u disabled =
    run Writes $ changeAccountTx u $ \c -> do
      updateDisabled c u disabled
      when disabled (deleteSessionsOf c u)
  createGroup = run Writes . createGroupTx
  renameGroup g = run Writes . renameGroupTx g
  deleteGroup = run Writes . deleteGroupTx
  addMember g = run Writes . setMemberTx True g
  removeMember g = run Writes . setMemberTx False g
  wikiSettings = run Reads (requireAdministrator >> asks (\x -> x.wiki))

  -- The settings kept in memory are the new ones as soon as they are
  -- committed, before the connection is let go.
  setWikiSettings new = SqliteWiki $ do
    env <- ask
    liftIO (transactThen env.storage env.who Writes (setWikiSettingsTx new) (writeIORef env.storage.settings . Just))

  -- The storage mails nothing: whether the server does, it says itself
  -- ("Wiki.Server.Api").
  invitations = run Reads invitationsTx
  invite email = liftIO newToken >>= run Writes . inviteTx email
  revokeInvitation = run Writes . revokeInvitationTx

-- | An attachment someone may view (they may view its page), and the file
-- its bytes are in when the storage keeps them; 'Nothing' for one that lives
-- on the web. What the server's route for an attachment's bytes serves.
attachmentFile :: (MonadIO m) => AttachmentId -> SqliteWiki m (Either WikiError (Attachment, Maybe FilePath))
attachmentFile aid = run Reads $ do
  (pid, a) <- db (`loadAttachment` aid) >>= maybe (failWith NotFound) pure
  page <- findNode pid
  requireView =<< chainOfPage page
  dir <- asks (\x -> x.blobs)
  pure
    ( a
    , case a.source of
        SourceBlob b -> blobFile dir b
        SourceUrl _ -> Nothing
    )

--------------------------------------------------------------------------------
-- Reads

sessionTx :: Tx Session
sessionTx = do
  ctx <- ask
  pure $ case (,) <$> ctx.user <*> ctx.principal of
    Nothing -> anonymousIn ctx.grants.access
    Just (u, p) ->
      Session
        { user = Just u
        , groups = p.groups
        , grants =
            Grants
              { global = filter (\g -> isFor p g.subject) ctx.grants.global
              , spaces = filter (\g -> isFor p g.subject) ctx.grants.spaces
              , access = ctx.grants.access
              }
        , -- The administrator is the operator; anyone else named is a user
          -- the server took the request for, which is whoever signed in.
          standing = if u.id == administratorId then Operator else SignedIn
        }

listSpacesTx :: Tx [Space]
listSpacesTx = do
  ctx <- ask
  let visible = filter (canView ctx.principal ctx.grants) (map (chainOf ctx) (Map.keys ctx.spaces))
      listed = Set.fromList (map (\s -> s.id) (concat visible))
  pure (spaceTreeOrder (Map.elems (Map.restrictKeys ctx.spaces listed)))

getSpaceTx :: [Slug] -> Tx Space
getSpaceTx path = do
  ctx <- ask
  case resolvePath (findChild (Map.elems ctx.spaces)) path of
    Right c | Just s <- lastMay c -> requireView c $> s
    _ -> failWith NotFound

listPagesTx :: SpaceId -> Tx [Page]
listPagesTx sid = do
  (s, c) <- findSpace sid
  requireView c
  pageTreeOrder s.pageOrder <$> db (`loadPages` sid)

getPageTx :: SpaceId -> [Slug] -> Tx Page
getPageTx sid path = do
  (_, c) <- findSpace sid
  requireView c
  nodes <- db (`pageNodes` sid)
  case resolvePath (findChild nodes) path of
    Right ps | Just p <- lastMay ps -> findPage p.id
    _ -> failWith NotFound

-- | The search, as the demo's: 'searchPlain' over the pages of the spaces
-- the query asks for that the user may view, each from the text prepared
-- when it was saved, folded as the matcher wants it (which, unlike parsing
-- the Markdown, is quick).
searchPagesTx :: SearchQuery -> Tx [SearchHit]
searchPagesTx q = do
  ctx <- ask
  rows <- db loadSearchRows
  let nodes = Map.fromList [(r.node.id, r.node) | r <- rows]
      wanted c = case q.space of
        Nothing -> True
        Just sid
          | q.includeSubspaces -> within sid c
          | otherwise -> fmap (\s -> s.id) (lastMay c) == Just sid
      searched =
        Map.filter
          (\c -> wanted c && canView ctx.principal ctx.grants c)
          (Map.mapWithKey (\sid _ -> chainOf ctx sid) ctx.spaces)
  pure . searchPlain q $
    [ Candidate
        { page = r.node.id
        , space = r.node.space
        , spacePath = map (\s -> s.slug) c
        , pagePath
        , text = Searchable {title = folded r.node.title, body = folded r.text}
        }
    | r <- rows
    , Just c <- [Map.lookup r.node.space searched]
    , Just pagePath <- [pathOf (`Map.lookup` nodes) r.node.id]
    ]

--------------------------------------------------------------------------------
-- Spaces

createSpaceTx :: Maybe SpaceId -> Text -> Tx Space
createSpaceTx parent name = do
  ctx <- ask
  parentChain <- traverse (fmap snd . findSpace) parent
  require (mayCreateSpace ctx.principal ctx.grants parentChain)
  n <- nonBlank "A space's name" name
  i <- newId
  time <- now
  let others = Map.elems ctx.spaces
      space =
        Space
          { id = SpaceId i
          , name = n
          , slug = freshSlug (isJust . findChild others parent) (fromMaybe (fallbackSlug "space") (slugify n))
          , parent
          , public = False
          , mathMacros = ""
          , createdAt = time
          , position = nextPosition (childrenOf others parent)
          , subspaceOrder = ByName
          , pageOrder = ByName
          }
  db (`insertSpace` space)
  for_ ctx.creator $ \u ->
    db $ \c -> insertGrants c Grants {global = [], spaces = [SpaceGrant {space = space.id, subject = SubjectUser u, permission = AdministerSpace}], access = Open}
  pure space

-- | Change a space, as someone who administers it.
adjustSpace :: SpaceId -> (Space -> Tx Space) -> Tx Space
adjustSpace sid f = do
  (s, c) <- findSpace sid
  requireAdminister c
  s' <- f s
  db (`updateSpace` s')
  pure s'

-- | Who may do what on a space, for whoever administers it.
spaceAccessTx :: SpaceId -> Tx SpaceAccess
spaceAccessTx sid = do
  (_, c) <- findSpace sid
  requireAdminister c
  -- The wiki's own grants, as they are kept: not the context's, which has
  -- the operator's grant of everything in it.
  stored <- db loadGrants
  users <- db loadUsers
  groups <- db loadGroups
  pure
    SpaceAccess
      { grants = [g | s <- reverse c, g <- stored.spaces, g.space == s.id]
      , users = sortOn (\u -> u.login) users
      , groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) groups
      }

-- | Give someone a permission on a space, or take it from them.
setSpaceGrantTx :: SpaceId -> Subject -> SpacePermission -> Bool -> Tx ()
setSpaceGrantTx sid subject permission granted = do
  (_, c) <- findSpace sid
  requireAdminister c
  when granted $ case subject of
    SubjectUser u -> db (`loadUser` u) >>= maybe (invalid "There is no such user.") (const pass)
    SubjectGroup g -> db loadGroups >>= maybe (invalid "There is no such group.") (const pass) . find (\x -> x.id == g)
  let grant = SpaceGrant {space = sid, subject, permission}
  db $ \conn ->
    if granted
      then insertGrants conn Grants {global = [], spaces = [grant], access = Open}
      else deleteSpaceGrant conn grant

renameSpaceTx :: SpaceId -> Text -> Tx Space
renameSpaceTx sid name = adjustSpace sid $ \s -> do
  n <- nonBlank "A space's name" name
  pure
    Space
      { id = s.id
      , name = n
      , slug = s.slug
      , parent = s.parent
      , public = s.public
      , mathMacros = s.mathMacros
      , createdAt = s.createdAt
      , position = s.position
      , subspaceOrder = s.subspaceOrder
      , pageOrder = s.pageOrder
      }

-- | Math macros as they are kept: as written, but for blank lines at the
-- ends.
trimLines :: Text -> Text
trimLines = T.intercalate "\n" . reverse . dropWhile blank . reverse . dropWhile blank . T.lines
  where
    blank = T.null . T.strip

moveSpaceTx :: SpaceId -> Maybe SpaceId -> Tx Space
moveSpaceTx sid destination = do
  ctx <- ask
  (s, c) <- findSpace sid
  destinationChain <- traverse (fmap snd . findSpace) destination
  requireView c
  require (mayMoveSpace ctx.principal ctx.grants c destinationChain)
  when (maybe False (within sid) destinationChain) $
    invalid "A space cannot be moved into itself or one of its subspaces."
  let others = Map.elems (Map.delete sid ctx.spaces)
      (slug, position)
        | destination == s.parent = (s.slug, s.position)
        | otherwise = (freshSlug (isJust . findChild others destination) s.slug, nextPosition (childrenOf others destination))
      s' = respace destination slug position s
  db (`updateSpace` s')
  pure s'

-- | Delete a space: its subspaces, their pages, the pages' versions,
-- attachments and drafts, and the grants on all of them go with it, as the
-- schema's foreign keys cascade.
deleteSpaceTx :: SpaceId -> Tx ()
deleteSpaceTx sid = do
  (_, c) <- findSpace sid
  requireAdminister c
  db $ \x -> execute x "DELETE FROM spaces WHERE id = ?" (Only sid.text)

-- | A space in another place in the tree, at a position there. Written out
-- in full, because a record update of fields that pages have too could not
-- tell which record it is.
respace :: Maybe SpaceId -> Slug -> Int -> Space -> Space
respace parent slug position s =
  Space
    { id = s.id
    , name = s.name
    , slug
    , parent
    , public = s.public
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    }

--------------------------------------------------------------------------------
-- Order

setSpaceOrderTx :: SpaceId -> Children -> ChildOrder -> Tx Space
setSpaceOrderTx sid kind order = do
  (s, c) <- findSpace sid
  requireAdminister c
  let old = case kind of
        ChildSpaces -> s.subspaceOrder
        ChildPages -> s.pageOrder
  -- Switched to by hand, the children are given the positions of the
  -- order they are shown in, so that the list stays as it was.
  when (order == ByHand && old /= ByHand) $ placeAsShown s kind
  let s' = case kind of
        ChildSpaces -> s {subspaceOrder = order}
        ChildPages -> s {pageOrder = order}
  db (`updateSpace` s')
  pure s'

-- | Give a space's children of one kind the positions of the order they
-- are shown in now: its subspaces, or each set of sibling pages in it.
placeAsShown :: Space -> Children -> Tx ()
placeAsShown s = \case
  ChildSpaces -> do
    ctx <- ask
    placeSpaces (childrenInOrder s.subspaceOrder (Map.elems ctx.spaces) (Just s.id))
  ChildPages -> do
    nodes <- db (`pageNodes` s.id)
    for_ (ordNub (map (\p -> p.parent) nodes)) $ \parent ->
      placePages (childrenInOrder s.pageOrder nodes parent)

-- | Number these spaces 0, 1, 2, … in the order given.
placeSpaces :: [Space] -> Tx ()
placeSpaces siblings = db $ \c ->
  for_ (Map.toList (renumber (\x -> x.id) siblings)) $ \(sid, n) ->
    execute c "UPDATE spaces SET position = ? WHERE id = ?" (n, sid.text)

-- | Number these pages 0, 1, 2, … in the order given.
placePages :: [PageNode] -> Tx ()
placePages siblings = db $ \c ->
  for_ (Map.toList (renumber (\x -> x.id) siblings)) $ \(pid, n) ->
    execute c "UPDATE pages SET position = ? WHERE id = ?" (n, pid.text)

shiftSpaceTx :: SpaceId -> Shift -> Tx Space
shiftSpaceTx sid how = do
  ctx <- ask
  (s, c) <- findSpace sid
  case s.parent of
    Nothing -> do
      requireView c
      invalid "The top-level spaces are listed by name, so they cannot be moved by hand."
    Just parentId -> do
      (parent, parentChain) <- findSpace parentId
      requireEdit parentChain
      unless (parent.subspaceOrder == ByHand) $
        invalid (parent.name <> " lists its subspaces " <> T.toLower (orderName parent.subspaceOrder) <> ", not by hand.")
      let moved = reposition (\x -> x.id) how sid (childrenInOrder ByHand (Map.elems ctx.spaces) (Just parentId))
      placeSpaces moved
      pure (maybe s (`positionSpace` s) (Map.lookup sid (renumber (\x -> x.id) moved)))

shiftPageTx :: PageId -> Shift -> Tx Page
shiftPageTx pid how = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireEdit c
  unless (s.pageOrder == ByHand) $
    invalid (s.name <> " lists its pages " <> T.toLower (orderName s.pageOrder) <> ", not by hand.")
  nodes <- db (`pageNodes` p.space)
  placePages (reposition (\x -> x.id) how pid (childrenInOrder ByHand nodes p.parent))
  findPage pid

--------------------------------------------------------------------------------
-- Pages

createPageTx :: SpaceId -> Maybe PageId -> Text -> Text -> Tx Page
createPageTx sid parent title body = do
  (_, c) <- findSpace sid
  parentPage <- traverse findNode parent
  requireEdit c
  when (any (\p -> p.space /= sid) parentPage) $
    invalid "A page's parent has to be in the same space."
  t <- nonBlank "A page's title" title
  nodes <- db (`pageNodes` sid)
  i <- newId
  time <- now
  let page =
        Page
          { id = PageId i
          , space = sid
          , parent
          , title = t
          , slug = freshSlug (isJust . findChild nodes parent) (fromMaybe (fallbackSlug "page") (slugify t))
          , body
          , attachments = []
          , createdAt = time
          , updatedAt = time
          , position = nextPosition (childrenOf nodes parent)
          }
  author <- asks (\x -> x.author)
  db $ \x -> insertPage x page >> insertVersion x page author
  pure page

-- | Save a page as a new version of it, if nobody has saved one since the
-- version given: the page's row and its prepared search text change, a
-- version is kept, and the saver's draft goes, all in this transaction.
savePageTx :: PageId -> UTCTime -> Text -> Text -> Tx Page
savePageTx pid base title body = do
  p <- findPage pid
  requireEdit =<< asks (`chainOf` p.space)
  t <- nonBlank "A page's title" title
  when (p.updatedAt /= base) $
    failWith (Conflict "The page has been saved by someone else since this edit began.")
  time <- now
  -- Later than the version saved over even if the clock says otherwise, so
  -- that no two versions of a page have the same time.
  let updatedAt = if time > p.updatedAt then time else addUTCTime 0.000001 p.updatedAt
      p' =
        Page
          { id = p.id
          , space = p.space
          , parent = p.parent
          , title = t
          , slug = p.slug
          , body
          , attachments = p.attachments
          , createdAt = p.createdAt
          , updatedAt
          , position = p.position
          }
  author <- asks (\x -> x.author)
  db $ \c -> do
    execute
      c
      "UPDATE pages SET title = ?, body = ?, updated_at = ?, search_text = ? WHERE id = ?"
      (t, body, Stamp updatedAt, bodyText body, pid.text)
    insertVersion c p' author
    for_ author $ \u -> execute c "DELETE FROM drafts WHERE page_id = ? AND author = ?" (pid.text, u.text)
  pure p'

-- | A page and the pages under it, by id, among the nodes of its space.
subtreeOf :: [PageNode] -> PageId -> Set PageId
subtreeOf nodes pid =
  Set.fromList
    [ n.id
    | n <- nodes
    , maybe False (any (\a -> a.id == pid)) (ancestry (`Map.lookup` byId) n.id)
    ]
  where
    byId = Map.fromList [(n.id, n) | n <- nodes]

movePageTx :: PageId -> SpaceId -> Maybe PageId -> Tx Page
movePageTx pid destination parent = do
  ctx <- ask
  p <- findNode pid
  (_, target) <- findSpace destination
  parentPage <- traverse findNode parent
  let source = chainOf ctx p.space
  requireView source
  requireView target
  require (mayMovePage ctx.principal ctx.grants source target)
  when (any (\q -> q.space /= destination) parentPage) $
    invalid "A page's parent has to be in the same space."
  subtree <- (`subtreeOf` pid) <$> db (`pageNodes` p.space)
  when (any (`Set.member` subtree) parent) $
    invalid "A page cannot be moved under itself or a page under it."
  others <- filter (\q -> q.id /= pid) <$> db (`pageNodes` destination)
  let (slug, position)
        | destination == p.space && parent == p.parent = (p.slug, p.position)
        | otherwise = (freshSlug (isJust . findChild others parent) p.slug, nextPosition (childrenOf others parent))
  db $ \c -> do
    execute
      c
      "UPDATE pages SET space_id = ?, parent = ?, slug = ?, position = ? WHERE id = ?"
      (destination.text, fmap (\x -> x.text) parent, slugText slug, position, pid.text)
    for_ (Set.delete pid subtree) $ \q -> execute c "UPDATE pages SET space_id = ? WHERE id = ?" (destination.text, q.text)
  findPage pid

-- | Delete a page: the pages under it, and the versions, attachments and
-- drafts of all of them, go with it, as the schema's foreign keys cascade.
deletePageTx :: PageId -> Tx ()
deletePageTx pid = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  db $ \c -> execute c "DELETE FROM pages WHERE id = ?" (Only pid.text)

--------------------------------------------------------------------------------
-- Attachments

-- | Attach a file, its bytes kept under their hash. The size is checked
-- before anything is hashed or written, so that a file too large costs
-- nothing but its reading.
uploadAttachmentTx :: PageId -> Text -> Text -> ByteString -> Tx Attachment
uploadAttachmentTx pid name mediaType bytes = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  n <- nonBlank "An attachment's name" name
  when (T.any (\ch -> ch == '/' || ch == '\\' || isControl ch) n) $
    invalid "An attachment's name cannot have slashes or control characters in it."
  when (fromIntegral (BS.length bytes) > maxAttachmentSize) $
    invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB.")
  let declared = T.strip mediaType
      mt = if T.null declared then "application/octet-stream" else declared
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (storeBlob dir bytes)
  i <- newId
  let attachment = Attachment {id = AttachmentId i, name = n, mediaType = mt, size = fromIntegral (BS.length bytes), source = SourceBlob blob}
  db $ \c -> do
    -- One of the same name is replaced, in its place among the page's.
    replaced <- query c "SELECT id, ordinal FROM attachments WHERE page_id = ? AND name = ?" (pid.text, n)
    ordinal <- case replaced of
      (old, at) : _ -> execute c "DELETE FROM attachments WHERE id = ?" (Only (old :: Text)) $> at
      [] -> maybe 0 fromOnly . head <$> query c "SELECT coalesce(max(ordinal) + 1, 0) FROM attachments WHERE page_id = ?" (Only pid.text)
    insertAttachment c pid ordinal attachment
  pure attachment

deleteAttachmentTx :: AttachmentId -> Tx ()
deleteAttachmentTx aid = do
  (pid, _) <- db (`loadAttachment` aid) >>= maybe (failWith NotFound) pure
  p <- findNode pid
  requireEdit =<< chainOfPage p
  db $ \c -> execute c "DELETE FROM attachments WHERE id = ?" (Only aid.text)

--------------------------------------------------------------------------------
-- Drafts

-- | A page someone signed in may edit, and the id their drafts are under.
draftable :: PageId -> Tx UserId
draftable pid = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  asks (\x -> x.author) >>= maybe (failWith Forbidden) pure

getDraftTx :: PageId -> Tx (Maybe Draft)
getDraftTx pid = draftable pid >>= \u -> db (\c -> loadDraft c pid u)

saveDraftTx :: PageId -> UTCTime -> Text -> Text -> Tx Draft
saveDraftTx pid base title body = do
  u <- draftable pid
  savedAt <- now
  db $ \c ->
    execute
      c
      "INSERT OR REPLACE INTO drafts (page_id, author, title, body, base, saved_at) VALUES (?, ?, ?, ?, ?, ?)"
      (pid.text, u.text, title, body, Stamp base, Stamp savedAt)
  pure Draft {page = pid, author = u, title, body, base, savedAt}

discardDraftTx :: PageId -> Tx ()
discardDraftTx pid = do
  u <- draftable pid
  db $ \c -> execute c "DELETE FROM drafts WHERE page_id = ? AND author = ?" (pid.text, u.text)

--------------------------------------------------------------------------------
-- History

-- | A version as the class gives it, its author named: a user by their
-- display name, the administrator as 'administratorUser', and anyone else
-- (no longer a user) by their id.
versionOf :: PageId -> VersionRow -> Version
versionOf page r =
  Version {page, updatedAt = r.updatedAt, title = r.title, body = r.body, author = named <$> r.author}
  where
    named u
      | u == administratorId = Author {id = u, name = administratorUser.displayName}
      | otherwise = Author {id = u, name = fromMaybe u.text r.authorName}

listVersionsTx :: PageId -> Tx [VersionInfo]
listVersionsTx pid = do
  p <- findNode pid
  requireView =<< chainOfPage p
  map (versionInfo . versionOf pid) . sortOn (Down . (\r -> r.updatedAt)) <$> db (`loadVersions` pid)

-- | A version of a page someone may view (or, for a restore, edit): the
-- page's permission checked first, so that whoever may not see the page
-- learns nothing of its history.
findVersion :: PageId -> UTCTime -> Tx Version
findVersion pid at = db (\c -> loadVersion c pid at) >>= maybe (failWith NotFound) (pure . versionOf pid)

getVersionTx :: PageId -> UTCTime -> Tx Version
getVersionTx pid at = do
  p <- findNode pid
  requireView =<< chainOfPage p
  findVersion pid at

-- | Restore a version: a save of its title and body, as any save, in this
-- transaction, against the version the restorer saw.
restoreVersionTx :: PageId -> UTCTime -> UTCTime -> Tx Page
restoreVersionTx pid at base = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  v <- findVersion pid at
  savePageTx pid base v.title v.body

--------------------------------------------------------------------------------
-- Administration

-- | Whoever is asking holds the global administer: checked before anything
-- an administration's operation is given is looked for.
requireAdministrator :: Tx ()
requireAdministrator = ask >>= \x -> require (hasGlobalPermission x.principal x.grants Administer)

-- | A user by id; the administrator, who is no user, is not found.
findUser :: UserId -> Tx User
findUser u = db (`loadUser` u) >>= maybe (failWith NotFound) pure

-- | A group by id.
findGroup :: GroupId -> Tx Group
findGroup g = db loadGroups >>= maybe (failWith NotFound) pure . find (\x -> x.id == g)

directoryTx :: Tx Directory
directoryTx = do
  requireAdministrator
  users <- db loadUsers
  groups <- db loadGroups
  membership <- db loadMembership
  stored <- db loadGrants
  (disabled, withPassword) <- db loadAccountFlags
  let ids = Set.fromList (map (\u -> u.id) users)
      holding p = Set.fromList [u | GlobalGrant (SubjectUser u) p' <- stored.global, p' == p, u `Set.member` ids]
  pure
    Directory
      { users = sortOn (\u -> u.login) users
      , administrators = holding Administer
      , creators = holding CreateSpaces
      , disabled
      , withPassword
      , groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) groups
      , membership = Map.filter (not . Set.null) (Map.restrictKeys membership (Set.fromList (map (\g -> g.id) groups)))
      }

-- | Give a user a global permission themself, or take it from them: the
-- global administer, themself included (the admin listener can always give
-- it back), or create-spaces.
setGlobalGrantTx :: GlobalPermission -> UserId -> Bool -> Tx ()
setGlobalGrantTx permission u granted = do
  requireAdministrator
  _ <- findUser u
  let grant = GlobalGrant {subject = SubjectUser u, permission}
  db $ \c ->
    if granted
      then insertGrants c Grants {global = [grant], spaces = [], access = Open}
      else deleteGlobalGrant c grant

-- | Change the account of a user who is there, as an administrator, and
-- give it back as it then is.
changeAccountTx :: UserId -> (Connection -> IO ()) -> Tx Account
changeAccountTx u change = do
  requireAdministrator
  _ <- findUser u
  db change
  db (`loadAccount` u) >>= maybe (failWith NotFound) pure

-- | A group's name, checked: not blank, and no other group's but for case.
groupNameTx :: Maybe GroupId -> Text -> Tx Text
groupNameTx self name = do
  n <- nonBlank "A group's name" name
  groups <- db loadGroups
  for_ (head [g | g <- groups, Just g.id /= self, T.toCaseFold g.name == T.toCaseFold n]) $ \g ->
    invalid ("There is a group called " <> g.name <> " already.")
  pure n

createGroupTx :: Text -> Tx Group
createGroupTx name = do
  requireAdministrator
  n <- groupNameTx Nothing name
  g <- (\i -> Group {id = GroupId i, name = n}) <$> newId
  db (`insertGroup` g)
  pure g

renameGroupTx :: GroupId -> Text -> Tx Group
renameGroupTx gid name = do
  requireAdministrator
  _ <- findGroup gid
  n <- groupNameTx (Just gid) name
  db (\c -> renameGroupRow c gid n)
  pure Group {id = gid, name = n}

deleteGroupTx :: GroupId -> Tx ()
deleteGroupTx gid = do
  requireAdministrator
  _ <- findGroup gid
  db (`deleteGroupRows` gid)

-- | Put a user in a group, or take them out; either is done once.
setMemberTx :: Bool -> GroupId -> UserId -> Tx ()
setMemberTx member gid u = do
  requireAdministrator
  _ <- findGroup gid
  _ <- findUser u
  db (\c -> (if member then insertMember else deleteMember) c gid u)

--------------------------------------------------------------------------------
-- Whom the wiki lets in

setWikiSettingsTx :: WikiSettings -> Tx WikiSettings
setWikiSettingsTx new = do
  requireAdministrator
  db (`storeSettings` new)
  pure new

invitationsTx :: Tx Invitations
invitationsTx = do
  requireAdministrator
  t <- now
  listed <- db (`loadInvitations` t)
  pure Invitations {mailing = False, invitations = listed}

-- | An invitation for an address, with this secret for its link, in place
-- of any the address had.
inviteTx :: Text -> Text -> Tx Invited
inviteTx raw token = do
  requireAdministrator
  email <- either invalid pure (checkEmail raw)
  i <- InvitationId <$> newId
  t <- now
  let invitation = Invitation {id = i, email, createdAt = t, expiresAt = addUTCTime invitationLifetime t, expired = False}
  db (\c -> insertInvitation c invitation (tokenHash token))
  pure Invited {invitation, token = Just token, mailError = Nothing}

revokeInvitationTx :: InvitationId -> Tx ()
revokeInvitationTx i = do
  requireAdministrator
  gone <- db (`deleteInvitation` i)
  unless gone (failWith NotFound)

--------------------------------------------------------------------------------
-- Whole wikis

-- | Put a whole wiki, an export archive ("Wiki.Core.Export", which
-- 'Wiki.Core.Export.readArchive' has checked), into a storage that has
-- none: its people, groups, grants, spaces and pages with their ids, each
-- page as its first version, and its attachments' bytes kept under their
-- hashes (so the blobs' ids are hashes from then on). A storage with a wiki
-- in it already is refused, and left as it was: bringing one wiki into
-- another is a merge, which is the import's of docs/PLAN.md's WP2.8.
importArchive :: Storage -> Archive -> IO (Either Text ())
importArchive st a = withDatabase st $ \c -> do
  execute_ c "BEGIN IMMEDIATE"
  flip onException (execute_ c "ROLLBACK") $ do
    counts <- for ["users", "groups", "spaces"] $ \table -> query_ c ("SELECT count(*) FROM " <> table)
    let unkept = [x | p <- a.pages, x <- p.attachments, SourceBlob b <- [x.source], Map.notMember b a.blobs]
    case (any (/= [Only (0 :: Int)]) counts, unkept) of
      (True, _) -> execute_ c "ROLLBACK" $> Left "The server has a wiki already: an archive is imported into an empty one only."
      (_, x : _) -> execute_ c "ROLLBACK" $> Left ("The archive has no bytes for the attachment " <> show x.id.text <> ".")
      (False, []) -> do
        -- Spaces and pages are given in any order, a child before its
        -- parent too: the foreign keys are checked at the commit.
        execute_ c "PRAGMA defer_foreign_keys = ON"
        traverse_ (insertUser c) a.users
        traverse_ (insertGroup c) a.groups
        for_ (Map.toList a.membership) $ \(g, members) -> traverse_ (insertMember c g) (Set.toList members)
        insertGrants c a.grants
        traverse_ (insertSpace c) a.spaces
        hashes <- traverse (storeBlob (attachmentsDir st.dataDir)) a.blobs
        for_ a.pages $ \p -> do
          insertPage c p
          insertVersion c p Nothing
          for_ (zip [0 ..] p.attachments) $ \(ordinal, x) ->
            let source = case x.source of
                  SourceBlob b -> maybe x.source SourceBlob (Map.lookup b hashes)
                  url -> url
             in insertAttachment c p.id ordinal x {source}
        execute_ c "COMMIT"
        pure (Right ())

-- | The whole wiki as an export archive, written now by this program
-- (@app@ names it): what "Export the wiki" downloads. An attachment whose
-- file is missing makes it fail, saying which, rather than leave the
-- attachment out of an archive meant to be the whole wiki.
exportArchive :: Storage -> Text -> IO (Either Text Archive)
exportArchive st app = do
  createdAt <- getCurrentTime
  (users, groups, membership, grants, spaces, pages) <-
    withDatabase st $ \c -> do
      execute_ c "BEGIN"
      records <-
        (,,,,,)
          <$> loadUsers c
          <*> loadGroups c
          <*> loadMembership c
          <*> loadGrants c
          <*> (Map.elems <$> loadSpaces c)
          <*> loadAllPages c
      execute_ c "COMMIT"
      pure records
  blobs <- for [(x, b) | p <- pages, x <- p.attachments, SourceBlob b <- [x.source]] $ \(x, b) ->
    maybe (Left ("The file of the attachment " <> show x.id.text <> " (" <> x.name <> ") is missing.")) (Right . (b,))
      <$> readBlob (attachmentsDir st.dataDir) b
  pure $ (\kept -> Archive {createdAt, app, users, groups, membership, grants, spaces, pages, blobs = Map.fromList kept}) <$> sequence blobs
