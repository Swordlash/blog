-- | How the demo saves its in-memory wiki in the browser between visits:
-- the records of a 'MemState' in IndexedDB ("Web.Storage.IndexedDB"), one
-- record per user, group, space, page, attachment and space's grants, each
-- under its id in a store of its own; and how the state is loaded back
-- from them.
--
-- The records are JSON, written and read by "Wiki.Core.Export", the codec
-- of the export archive. So a saved record and an exported record have one
-- format, with the same rules for what may change without a new format
-- version. A space's and a page's records are those of version 1 of the
-- export: they name their parent, and a page its space and its body,
-- which version 2 takes from the archive's tree of directories. A page is
-- the export's page record, with its attachments' records in a field
-- @attachments@. An attachment's bytes are saved as bytes, under the id of
-- its blob.
--
-- Besides those records, the store @meta@ holds what the export's user
-- records lack: the id counter (new ids are made from it, and a counter
-- that started over would make an id a record already has), the global
-- grants, and the accounts' flags (which users are disabled, and which
-- have a password). Who is signed in, and the object URLs a tab has made
-- for attachments, last only as long as the tab.
--
-- Some data is saved although the export leaves it out. Drafts
-- ("Wiki.Core.Draft") have their own store: the demo's author may close
-- the tab and come back to their draft, which is what drafts are for.
-- Every version of every page ("Wiki.Core.Version") is a record: one full
-- title and body per save, so a page saved a hundred times takes a hundred
-- times its size. A user's notifications, what they watch,
-- and how they want to be notified ("Wiki.Core.Notification") are one
-- record, under the user's id.
--
-- Everything here is pure. "Wiki.App.Backend.Mem" reads and writes the
-- database, and works out what to write by comparing two sets of
-- 'records' with 'changes'.
--
-- Two stores are large, and are read only in part when the demo starts:
-- the attachments' bytes and the versions. "Wiki.App.Backend.Mem" reads
-- their keys only ('lazyStores'), and 'restore' gives a wiki that knows
-- those records are there without holding them ('unreadBlobs',
-- 'unreadVersions'). A record is read when it is needed. In 'Records', a
-- record that has not been read is 'Nothing'.
--
-- A write saves only the stores whose records it may have changed
-- ('touched'), so that saving a draft does not encode every page again.
--
-- A page's comment threads ("Wiki.Core.Comment") are in the export, but
-- saved here in a record of their own: the threads' JSON encoding, under
-- the page's id. That record is older than the export's @comments.json@,
-- and changing it would make the comments of every demo saved before
-- unreadable.
module Wiki.App.Backend.Mem.Persist
  ( -- * The database
    memDatabase
  , usersStore
  , groupsStore
  , spacesStore
  , pagesStore
  , attachmentsStore
  , grantsStore
  , metaStore
  , draftsStore
  , versionsStore
  , threadsStore
  , notificationsStore
  , storeNames
  , lazyStores
  , versionKey

    -- * Records
  , Records
  , records
  , changes
  , changesIn
  , touched
  , Stored (..)
  , restore
  , readVersion
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (Value (..), eitherDecodeStrict', object, parseJSON, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Map.Lazy qualified as LazyMap
import Data.Map.Merge.Strict qualified as Merge
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (Day (ModifiedJulianDay), UTCTime (..))
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Numeric.Natural (Natural)
import Protolude
import System.Mem.StableName (makeStableName)
import Web.Storage.IndexedDB (Database (..), StoreName)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem.State (Choices (..), MemState (..), Saved (..), completeVersions, emptyState, prepareSearch)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export
import Wiki.Core.Id (BlobId (..), GroupId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Notification (Mark, Notification, WatchTarget (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (Grants (..), SpaceGrant (..))
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), User (..))

-- | The database a wiki is saved in under this name. Its stores are
-- created when it is first opened. Adding a store later needs a new
-- database version, on which IndexedDB creates the new store and keeps
-- the others with their contents. Version 2 added 'draftsStore', version 3
-- 'versionsStore', version 4 'threadsStore', version 5
-- 'notificationsStore'.
memDatabase :: Text -> Database
memDatabase name = Database {name, version = 5, stores = storeNames}

usersStore, groupsStore, spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore, draftsStore, versionsStore, threadsStore, notificationsStore :: StoreName

-- | A user's record, under their id.
usersStore = "users"

-- | A group's record, with its members, under its id.
groupsStore = "groups"

-- | A space's record, under its id.
spacesStore = "spaces"

-- | A page's record with its attachments' records, under its id.
pagesStore = "pages"

-- | An uploaded attachment's bytes, under the id of its blob, which the
-- attachment on its page names.
attachmentsStore = "attachments"

-- | The grants on a space, a list of records, under the space's id.
grantsStore = "grants"

-- | The id counter, under @counter@ (a wiki that has never been saved has
-- none); the global grants, under @globalGrants@; and the accounts' flags,
-- under @accounts@ (a wiki saved before the flags existed has none: nobody
-- is disabled, and nobody has a password).
metaStore = "meta"

-- | Each user's draft of a page, under 'draftKey'.
draftsStore = "drafts"

-- | Each version of each page, under 'versionKey'. A database from before
-- this store existed has none: its pages' histories start with the pages
-- as they are ('completeVersions').
versionsStore = "versions"

-- | A page's threads, with their comments, as a list, under the page's
-- id. A database from before this store existed has none: no page has
-- comments.
threadsStore = "threads"

-- | A user's notifications, the marks of what they watch, and their
-- choices, as one record under their id. A database from before this
-- store existed has none: nobody has been notified, or chosen anything.
notificationsStore = "notifications"

-- | Every store of 'memDatabase'.
storeNames :: [StoreName]
storeNames = [usersStore, groupsStore, spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore, draftsStore, versionsStore, threadsStore, notificationsStore]

-- | The stores that "Wiki.App.Backend.Mem" reads the keys of when the
-- demo starts, and each record of only when it is needed: the
-- attachments' bytes and the versions, which hold most of a wiki's bytes
-- and are seldom all needed.
lazyStores :: [StoreName]
lazyStores = [attachmentsStore, versionsStore]

-- | A draft's key: its page's id and its author's id, which identify one
-- draft.
draftKey :: Draft -> Text
draftKey d = d.page.text <> "/" <> d.author.text

-- | A version's key: its page's id and its time, which identify one
-- version.
versionKey :: PageId -> UTCTime -> Text
versionKey page at = page.text <> "/" <> toS (iso8601Show at)

-- | The page and the time a version's key names; 'Nothing' for a key
-- 'versionKey' did not make.
versionOfKey :: Text -> Maybe (PageId, UTCTime)
versionOfKey key = case T.breakOnEnd "/" key of
  (page, at) | T.length page > 1 -> (PageId (T.dropEnd 1 page),) <$> iso8601ParseM (T.unpack at)
  _ -> Nothing

-- | What a store holds, by store and key. A record of one of the
-- 'lazyStores' that has not been read is 'Nothing': the store has it, and
-- this program does not know what it holds.
type Records = Map StoreName (Map Text (Maybe ByteString))

counterKey, globalGrantsKey, accountsKey :: Text
counterKey = "counter"
globalGrantsKey = "globalGrants"
accountsKey = "accounts"

-- | The state as records, by store: every store, even an empty one.
--
-- Each store's records are worked out when that store is first looked at,
-- not before: a write that saves the drafts encodes the drafts only
-- ('touched'). Each store's records come from the fields of the state
-- that 'touched' names for it, and from no other.
records :: MemState -> Records
records st =
  LazyMap.fromList
    [ (usersStore, encoded [(u.id.text, encodeJson (encodeUser u)) | u <- Map.elems st.users])
    , (groupsStore, encoded [(g.id.text, encodeJson (encodeGroup g (Map.findWithDefault mempty g.id st.membership))) | g <- Map.elems st.groups])
    , (spacesStore, encoded [(s.id.text, encodeJson (encodeSpace s)) | s <- Map.elems st.spaces])
    , (pagesStore, encoded [(p.id.text, encodeJson (storedPage p)) | p <- Map.elems st.pages])
    , (attachmentsStore, Map.fromList ([(b.text, Just bytes) | (b, bytes) <- Map.toList st.blobs] <> [(b.text, Nothing) | b <- Set.toList st.unreadBlobs]))
    , (grantsStore, encoded [(sid.text, encodeJson (map encodeSpaceGrant gs)) | (sid, gs) <- Map.toList (spaceGrants st)])
    ,
      ( metaStore
      , encoded
          [ (counterKey, encodeJson st.counter)
          , (globalGrantsKey, encodeJson (map encodeGlobalGrant st.grants.global))
          , (accountsKey, encodeJson (object ["disabled" .= st.disabled, "passwords" .= st.passwords]))
          ]
      )
    , (draftsStore, encoded [(draftKey d, encodeJson (encodeDraft d)) | d <- Map.elems st.drafts])
    , -- Lazily: a version never changes once made, so 'changes' writes it
      -- only when its key is new, and only then is its record encoded.
      -- Otherwise every write would encode the whole history again.

      ( versionsStore
      , LazyMap.fromList
          ( [(versionKey page at, Just (encodeJson (encodeVersion page at v))) | (page, kept) <- Map.toList st.versions, (at, v) <- Map.toList kept]
              <> [(versionKey page at, Nothing) | (page, ats) <- Map.toList st.unreadVersions, at <- Set.toList ats]
          )
      )
    , (threadsStore, encoded [(page.text, encodeJson (toJSON ts)) | (page, ts) <- Map.toList st.threads])
    , (notificationsStore, encoded [(u.text, encodeJson (encodeNotified st u)) | u <- Set.toList (Map.keysSet st.notices <> Map.keysSet st.watches <> Map.keysSet st.choices)])
    ]
  where
    encoded = Map.fromList . map (second Just)

-- | The stores whose records may differ between two states: those whose
-- fields of the state (the ones 'records' makes them from) are not the
-- very same values in memory. A write leaves the fields it does not change
-- as they were, the same values, so this costs a look at the address of
-- each field ('makeStableName') and never compares or encodes a record.
-- Two equal values that are not the same object count as different, which
-- costs an encoding that finds nothing to write; never the other way
-- round, so a store with a change is never missed.
touched :: MemState -> MemState -> IO [StoreName]
touched old new = do
  users <- same (\x -> x.users)
  groups <- same (\x -> x.groups)
  membership <- same (\x -> x.membership)
  spaces <- same (\x -> x.spaces)
  pages <- same (\x -> x.pages)
  blobs <- same (\x -> x.blobs)
  unreadBlobs <- same (\x -> x.unreadBlobs)
  grants <- same (\x -> x.grants)
  disabled <- same (\x -> x.disabled)
  passwords <- same (\x -> x.passwords)
  drafts <- same (\x -> x.drafts)
  versions <- same (\x -> x.versions)
  unreadVersions <- same (\x -> x.unreadVersions)
  threads <- same (\x -> x.threads)
  notices <- same (\x -> x.notices)
  watches <- same (\x -> x.watches)
  choices <- same (\x -> x.choices)
  pure
    [ store
    | (store, unchanged) <-
        [ (usersStore, users)
        , (groupsStore, groups && membership)
        , (spacesStore, spaces)
        , (pagesStore, pages)
        , (attachmentsStore, blobs && unreadBlobs)
        , (grantsStore, grants)
        , (metaStore, old.counter == new.counter && grants && disabled && passwords)
        , (draftsStore, drafts)
        , (versionsStore, versions && unreadVersions)
        , (threadsStore, threads)
        , (notificationsStore, notices && watches && choices)
        ]
    , not unchanged
    ]
  where
    -- A stable name is the same for one object, whatever pointer to it
    -- is given, and different for two objects.
    same :: (MemState -> a) -> IO Bool
    same field = (==) <$> (makeStableName =<< evaluate (field old)) <*> (makeStableName =<< evaluate (field new))

-- | A user's record of notifications: what they were notified of, what
-- they marked to watch or not, and their choices.
encodeNotified :: MemState -> UserId -> Value
encodeNotified st u =
  object
    [ "user" .= u
    , "notifications" .= Map.findWithDefault [] u st.notices
    , "watches" .= [object [targetField t .= targetId t, "watching" .= w] | (t, w) <- Map.toList (Map.findWithDefault mempty u st.watches)]
    , "mail" .= (Map.lookup u st.choices >>= \c -> c.mail)
    , "watchOwn" .= maybe True (\c -> c.watchOwn) (Map.lookup u st.choices)
    ]
  where
    targetField = \case
      WatchPage _ -> "page"
      WatchSpace _ -> "space"
    targetId = \case
      WatchPage p -> p.text
      WatchSpace s -> s.text

-- | Parse a user's record of notifications: whose it is, their
-- notifications, their marks, and their choices if they have made any.
parseNotified :: Value -> Parser (UserId, [Notification], Mark, Maybe Choices)
parseNotified = withObject "notifications" $ \o -> do
  u <- o .: "user"
  ns <- o .:? "notifications" .!= []
  marks <- o .:? "watches" .!= [] >>= traverse (withObject "watch" (\w -> (,) <$> target w <*> w .: "watching"))
  mail <- o .:? "mail"
  watchOwn <- o .:? "watchOwn" .!= True
  pure (u, ns, Map.fromList marks, if isNothing mail && watchOwn then Nothing else Just Choices {mail, watchOwn})
  where
    target w =
      (w .:? "page") >>= \case
        Just p -> pure (WatchPage (PageId p))
        Nothing -> WatchSpace . SpaceId <$> w .: "space"

-- | A version's record, with named fields, like a draft's.
encodeVersion :: PageId -> UTCTime -> Saved -> Value
encodeVersion page at v =
  object
    [ "page" .= page
    , "updatedAt" .= at
    , "title" .= v.title
    , "body" .= v.body
    , "author" .= v.author
    ]

-- | Parse a version's record: its page, its time and what was saved.
parseVersion :: Value -> Parser (PageId, UTCTime, Saved)
parseVersion = withObject "version" $ \o -> do
  page <- o .: "page"
  at <- o .: "updatedAt"
  saved <- Saved <$> o .: "title" <*> o .: "body" <*> o .:? "author"
  pure (page, at, saved)

-- | A version read from its record in 'versionsStore', if the record is
-- that version's.
readVersion :: PageId -> UTCTime -> ByteString -> Maybe Saved
readVersion page at bytes = case decodeJson parseVersion bytes of
  Right (p, t, v) | p == page && t == at -> Just v
  _ -> Nothing

-- | Parse the accounts' flags: the users who are disabled, and those who
-- have a password.
parseAccounts :: Value -> Parser (Set UserId, Set UserId)
parseAccounts = withObject "accounts" $ \o -> (,) <$> o .:? "disabled" .!= mempty <*> o .:? "passwords" .!= mempty

-- | A draft's record, with named fields, like the export's records.
encodeDraft :: Draft -> Value
encodeDraft d =
  object
    [ "page" .= d.page
    , "author" .= d.author
    , "title" .= d.title
    , "body" .= d.body
    , "base" .= d.base
    , "savedAt" .= d.savedAt
    ]

parseDraft :: Value -> Parser Draft
parseDraft = withObject "draft" $ \o ->
  Draft
    <$> o
    .: "page"
    <*> o .: "author"
    <*> o .:? "title" .!= ""
    <*> o .:? "body" .!= ""
    <*> o .: "base"
    <*> o .: "savedAt"

-- | A page as the database stores it: the export's record, with its
-- attachments' records inside it.
storedPage :: Page -> Value
storedPage p = case encodePage p of
  Object o -> Object (KeyMap.insert "attachments" (toJSON [encodeAttachment p.id x | x <- p.attachments]) o)
  other -> other

parseStoredPage :: Value -> Parser Page
parseStoredPage value = do
  page <- parsePage value
  attached <- withObject "page" (\o -> o .:? "attachments" .!= []) value
  xs <- traverse parseAttachment attached
  pure page {attachments = map (\r -> r.attachment) xs}

-- | The grants on each space that has any, in the order the state has them.
spaceGrants :: MemState -> Map SpaceId [SpaceGrant]
spaceGrants st = Map.fromListWith (flip (<>)) [(g.space, [g]) | g <- st.grants.spaces]

-- | The writes that turn the first set of records into the second. A
-- record that is new or different is written, one that is gone is
-- deleted, and the rest are left alone, so that one change to the wiki
-- writes only what it changed. Given what the stores hold and a whole
-- wiki's records, it writes that wiki over whatever was there.
--
-- A version never changes once it is made, so two version records under
-- the same key are taken to be equal without being compared (or encoded:
-- see 'records'). The key names the page and the time, which no other
-- version of the page has: a save is always later than the one before,
-- ids are never made twice, and a whole wiki written over another (an
-- import) gives one of its pages the other's time and id only if it is
-- that very version, exported and imported again.
--
-- A record that has not been read ('Nothing') is never written: the store
-- has it already. A record the store has unread and the second set holds
-- is written, except a version, by the rule above: only a wiki written
-- over another (an import) has the bytes of an attachment the other had
-- unread, and they may be other bytes under the same id.
changes :: Records -> Records -> [IDB.Write]
changes before after =
  concat . Map.elems $
    Merge.merge
      (Merge.mapMissing (\store old -> [(store, k, Nothing) | k <- Map.keys old]))
      (Merge.mapMissing (\store new -> [(store, k, Just v) | (k, Just v) <- Map.toList new]))
      (Merge.zipWithMatched (\store old new -> inStore store old new))
      before
      after
  where
    inStore store old new =
      Map.elems $
        Merge.merge
          (Merge.mapMissing (\k _ -> (store, k, Nothing)))
          (Merge.mapMaybeMissing (\k v -> (store,k,) . Just <$> v))
          (Merge.zipWithMaybeMatched (\k v w -> if store == versionsStore || isNothing w || v == w then Nothing else Just (store, k, w)))
          old
          new

-- | 'changes' in these stores only: the writes that save a change to the
-- wiki that 'touched' only these stores. The records of the other stores
-- are not looked at, and so not encoded.
changesIn :: [StoreName] -> Records -> Records -> [IDB.Write]
changesIn stores before after = changes (Map.restrictKeys before kept) (Map.restrictKeys after kept)
  where
    kept = Set.fromList stores

-- | What 'restore' found in the stores.
data Stored
  = -- | Nothing saved by this program: no counter, whatever else there is.
    Unseeded
  | -- | A record that does not parse as what it should be, and why.
    Unreadable Text
  | -- | A wiki.
    Stored MemState
  deriving stock (Eq, Show)

-- | The wiki the stores hold, with nobody signed in (the caller sets who
-- is) and no attachment with an object URL yet: the tab makes one when it
-- is first needed, as it does for an upload. An attachment's bytes or a
-- version that has not been read is in the wiki's 'unreadBlobs' or
-- 'unreadVersions', to be read when it is needed.
restore :: Records -> Stored
restore stored = case Map.lookup counterKey (holding metaStore) of
  Nothing -> Unseeded
  Just counterBytes -> either Unreadable Stored $ do
    counter <- first (failure metaStore counterKey . toS) (eitherDecodeStrict' counterBytes :: Either [Char] Natural)
    global <- maybe (Right []) (decoding metaStore globalGrantsKey (listOf parseGlobalGrant)) (Map.lookup globalGrantsKey (holding metaStore))
    (disabled, passwords) <- maybe (Right mempty) (decoding metaStore accountsKey parseAccounts) (Map.lookup accountsKey (holding metaStore))
    users <- keyed usersStore parseUser (\u -> u.id.text) UserId
    groupsAndMembers <- keyed groupsStore parseGroup (\(g, _) -> g.id.text) GroupId
    pages <- keyed pagesStore parseStoredPage (\p -> p.id.text) PageId
    -- A space saved before spaces had a creation time is taken to have
    -- been created with its first page, or, without one, with the first
    -- page of the wiki: the nearest time the records give.
    let firstPage = fromMaybe (UTCTime (ModifiedJulianDay 0) 0) (minimumMay [p.createdAt | p <- Map.elems pages])
    spaces <- keyed spacesStore (parseSpace (spaceCreatedDefault firstPage (Map.elems pages))) (\s -> s.id.text) SpaceId
    kept <- keyed draftsStore parseDraft draftKey identity
    history <- keyed versionsStore parseVersion (\(page, at, _) -> versionKey page at) identity
    unread <- for [k | (k, Nothing) <- Map.toList (Map.findWithDefault mempty versionsStore stored)] $ \k ->
      maybe (Left (failure versionsStore k "is not a version's key")) Right (versionOfKey k)
    discussed <- fmap Map.fromList . for (Map.toList (holding threadsStore)) $ \(key, bytes) -> do
      ts <- decoding threadsStore key (parseJSON :: Value -> Parser [Thread]) bytes
      if all (\t -> t.page.text == key) ts
        then Right (PageId key, ts)
        else Left (failure threadsStore key "has threads of another page")
    notified <- keyed notificationsStore parseNotified (\(u, _, _, _) -> u.text) UserId
    grants <- fmap concat . for (Map.toList (holding grantsStore)) $ \(key, bytes) -> do
      gs <- decoding grantsStore key (listOf parseSpaceGrant) bytes
      if all (\g -> g.space.text == key) gs
        then Right gs
        else Left (failure grantsStore key "has grants on another space")
    pure . completeVersions . prepareSearch $
      emptyState
        { users
        , groups = map fst groupsAndMembers
        , membership = map snd groupsAndMembers
        , spaces
        , pages
        , blobs = Map.mapKeys BlobId (holding attachmentsStore)
        , unreadBlobs = Set.fromList [BlobId k | (k, Nothing) <- Map.toList (Map.findWithDefault mempty attachmentsStore stored)]
        , drafts = Map.fromList [((d.page, d.author), d) | d <- Map.elems kept]
        , -- The versions of pages that exist: deleting a page deletes its
          -- versions in the same transaction, so there are no others.
          versions = Map.intersection (Map.fromListWith (<>) [(page, Map.singleton at v) | (page, at, v) <- Map.elems history]) pages
        , unreadVersions = Map.intersection (Map.fromListWith (<>) [(page, Set.singleton at) | (page, at) <- unread]) pages
        , -- Like versions: deleting a page deletes its threads.
          threads = Map.intersection discussed pages
        , notices = Map.filter (not . null) (map (\(_, ns, _, _) -> ns) notified)
        , watches = Map.filter (not . null) (map (\(_, _, marks, _) -> marks) notified)
        , choices = Map.mapMaybe (\(_, _, _, cs) -> cs) notified
        , -- Whom the demo is open to is not saved: it is open whenever it
          -- starts, as its prerendered pages are.
          grants = Grants {global, spaces = grants, access = Open}
        , disabled
        , passwords
        , counter
        }
  where
    -- The records of a store that have been read.
    holding store = Map.mapMaybe identity (Map.findWithDefault mempty store stored)

    keyed :: (Ord k) => StoreName -> (Value -> Parser a) -> (a -> Text) -> (Text -> k) -> Either Text (Map k a)
    keyed store parse idOf key = fmap Map.fromList . for (Map.toList (holding store)) $ \(k, bytes) -> do
      a <- decoding store k parse bytes
      if idOf a == k then Right (key k, a) else Left (failure store k ("holds " <> idOf a))

    decoding :: StoreName -> Text -> (Value -> Parser a) -> ByteString -> Either Text a
    decoding store k parse = first (failure store k) . decodeJson parse

    failure :: StoreName -> Text -> Text -> Text
    failure store k why = "the record " <> show store <> " " <> show k <> ": " <> why

    listOf :: (Value -> Parser a) -> Value -> Parser [a]
    listOf parse = \case
      Array values -> traverse parse (toList values)
      _ -> fail "not a list"
