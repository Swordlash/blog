-- | The in-memory wiki as the browser keeps it between visits: the records
-- of a 'MemState' in IndexedDB ("Web.Storage.IndexedDB"), one record per
-- user, group, space, page, attachment and space's grants, each under its
-- id in a store of its own, and the state read back from them.
--
-- The records are JSON written and read by "Wiki.Core.Export", the codec of
-- the export archive, so that a record kept and a record exported are one
-- format, with the same rules for what may change without a new version: a
-- page is the export's page record with its attachments' records in a
-- field @attachments@, and an attachment's bytes are kept as bytes, under
-- the id of its blob. Besides the records, the store @meta@ keeps the id
-- counter (ids are made from it, and a counter that started over would make
-- an id again that a record already has), the global grants, and the
-- accounts' flags (which users are disabled, and which have a password),
-- which the export's user records do not have. Who is
-- signed in, and the object URLs a tab has made for attachments, last as
-- long as the tab does. Drafts ("Wiki.Core.Draft") are kept too, in a store
-- of their own, though the export has none: the demo's author may close the
-- tab and come back to their draft, which is what drafts are for. So are the
-- pages' versions ("Wiki.Core.Version"), every one of them, a record each:
-- one full title and body per save, so that a page saved a hundred times
-- takes a hundred times its size.
--
-- Everything here is pure: "Wiki.App.Backend.Mem" reads and writes the
-- store, and works out what to write from two sets of 'records' with
-- 'changes'.
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
  , storeNames

    -- * Records
  , Records
  , records
  , changes
  , Stored (..)
  , restore
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (Value (..), eitherDecodeStrict', object, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Map.Lazy qualified as LazyMap
import Data.Map.Merge.Strict qualified as Merge
import Data.Map.Strict qualified as Map
import Data.Time (Day (ModifiedJulianDay), UTCTime (..))
import Data.Time.Format.ISO8601 (iso8601Show)
import Numeric.Natural (Natural)
import Protolude
import Web.Storage.IndexedDB (Database (..), StoreName)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem.State (MemState (..), Saved (..), completeVersions, emptyState, prepareSearch)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export
import Wiki.Core.Id (BlobId (..), GroupId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (Grants (..), SpaceGrant (..))
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), User (..))

-- | The database a wiki is kept in under this name. Its stores are made
-- when it is first opened; adding one later is a version bump, on which
-- IndexedDB makes the new store and keeps the others with what they hold.
-- Version 2 added 'draftsStore', version 3 'versionsStore'.
memDatabase :: Text -> Database
memDatabase name = Database {name, version = 3, stores = storeNames}

usersStore, groupsStore, spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore, draftsStore, versionsStore :: StoreName

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

-- | The id counter, under @counter@ (a wiki that has never been written out
-- has none), the global grants, under @globalGrants@, and the accounts'
-- flags, under @accounts@ (a wiki written out before there were any has
-- none: nobody is disabled, and nobody has a password).
metaStore = "meta"

-- | Each user's draft of a page, under 'draftKey'.
draftsStore = "drafts"

-- | Each version of each page, under 'versionKey'. A database from before
-- there was this store has none: its pages' histories start with the pages
-- as they are ('completeVersions').
versionsStore = "versions"

-- | Every store of 'memDatabase'.
storeNames :: [StoreName]
storeNames = [usersStore, groupsStore, spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore, draftsStore, versionsStore]

-- | A draft's key: its page's id and its author's, which are one draft's.
draftKey :: Draft -> Text
draftKey d = d.page.text <> "/" <> d.author.text

-- | A version's key: its page's id and its time, which are one version's.
versionKey :: PageId -> UTCTime -> Text
versionKey page at = page.text <> "/" <> toS (iso8601Show at)

-- | What a store holds, by store and key.
type Records = Map StoreName (Map Text ByteString)

counterKey, globalGrantsKey, accountsKey :: Text
counterKey = "counter"
globalGrantsKey = "globalGrants"
accountsKey = "accounts"

-- | The state as the stores keep it: every store, even an empty one.
records :: MemState -> Records
records st =
  Map.fromList
    [ (usersStore, Map.fromList [(u.id.text, encodeJson (encodeUser u)) | u <- Map.elems st.users])
    , (groupsStore, Map.fromList [(g.id.text, encodeJson (encodeGroup g (Map.findWithDefault mempty g.id st.membership))) | g <- Map.elems st.groups])
    , (spacesStore, Map.fromList [(s.id.text, encodeJson (encodeSpace s)) | s <- Map.elems st.spaces])
    , (pagesStore, Map.fromList [(p.id.text, encodeJson (storedPage p)) | p <- Map.elems st.pages])
    , (attachmentsStore, Map.mapKeys (\b -> b.text) st.blobs)
    , (grantsStore, Map.fromList [(sid.text, encodeJson (map encodeSpaceGrant gs)) | (sid, gs) <- Map.toList (spaceGrants st)])
    ,
      ( metaStore
      , Map.fromList
          [ (counterKey, encodeJson st.counter)
          , (globalGrantsKey, encodeJson (map encodeGlobalGrant st.grants.global))
          , (accountsKey, encodeJson (object ["disabled" .= st.disabled, "passwords" .= st.passwords]))
          ]
      )
    , (draftsStore, Map.fromList [(draftKey d, encodeJson (encodeDraft d)) | d <- Map.elems st.drafts])
    , -- Lazily: a version never changes once made, so 'changes' writes one
      -- only when its key is new, and only then is its record made. Every
      -- write would otherwise encode the whole history again.
      (versionsStore, LazyMap.fromList [(versionKey page at, encodeJson (encodeVersion page at v)) | (page, kept) <- Map.toList st.versions, (at, v) <- Map.toList kept])
    ]

-- | A version's record, with named fields, as a draft's.
encodeVersion :: PageId -> UTCTime -> Saved -> Value
encodeVersion page at v =
  object
    [ "page" .= page
    , "updatedAt" .= at
    , "title" .= v.title
    , "body" .= v.body
    , "author" .= v.author
    ]

-- | A version's record: its page, its time and what was saved.
parseVersion :: Value -> Parser (PageId, UTCTime, Saved)
parseVersion = withObject "version" $ \o -> do
  page <- o .: "page"
  at <- o .: "updatedAt"
  saved <- Saved <$> o .: "title" <*> o .: "body" <*> o .:? "author"
  pure (page, at, saved)

-- | The accounts' flags: the users who are disabled, and those who have a
-- password.
parseAccounts :: Value -> Parser (Set UserId, Set UserId)
parseAccounts = withObject "accounts" $ \o -> (,) <$> o .:? "disabled" .!= mempty <*> o .:? "passwords" .!= mempty

-- | A draft's record, with named fields, as the export's records have.
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

-- | A page as the store keeps it: the export's record, with its
-- attachments' records in it.
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

-- | The writes that turn the first records into the second: a record that
-- is new or different is written, one that is gone is deleted, and the rest
-- are left alone, so that one change to the wiki writes only what it
-- changed. From what the stores hold to a whole wiki's records, it writes
-- that wiki out over whatever was there.
--
-- A version is never changed once it is made, so a version's record under
-- a key both have is taken to be the same without being looked at (or
-- made: see 'records'). Its key names its page and its time, which no
-- other version of the page has: a save is always later than the one
-- before, ids are never made twice, and a whole wiki written over another
-- (an import) gives one of its pages the time and id of the other's only
-- if it is that very version, exported and brought back.
changes :: Records -> Records -> [IDB.Write]
changes before after =
  concat . Map.elems $
    Merge.merge
      (Merge.mapMissing (\store old -> [(store, k, Nothing) | k <- Map.keys old]))
      (Merge.mapMissing (\store new -> [(store, k, Just v) | (k, v) <- Map.toList new]))
      (Merge.zipWithMatched (\store old new -> inStore store old new))
      before
      after
  where
    inStore store old new =
      Map.elems $
        Merge.merge
          (Merge.mapMissing (\k _ -> (store, k, Nothing)))
          (Merge.mapMissing (\k v -> (store, k, Just v)))
          (Merge.zipWithMaybeMatched (\k v w -> if store == versionsStore || v == w then Nothing else Just (store, k, Just w)))
          old
          new

-- | What the stores were found to hold.
data Stored
  = -- | Nothing written out by this program: no counter, whatever else.
    Unseeded
  | -- | A record that does not read back as what it should be, and why.
    Unreadable Text
  | -- | A wiki.
    Stored MemState
  deriving stock (Eq, Show)

-- | The wiki the stores hold, with nobody signed in (the caller says who
-- is) and no attachment with an object URL yet: the tab makes one when one
-- is first asked for, as it does for an upload.
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
    -- A space kept before spaces had a time they were made at is taken to
    -- have been made with its first page, or, without one, with the first
    -- page of the wiki: the nearest the records tell.
    let firstPage = fromMaybe (UTCTime (ModifiedJulianDay 0) 0) (minimumMay [p.createdAt | p <- Map.elems pages])
    spaces <- keyed spacesStore (parseSpace (spaceCreatedDefault firstPage (Map.elems pages))) (\s -> s.id.text) SpaceId
    kept <- keyed draftsStore parseDraft draftKey identity
    history <- keyed versionsStore parseVersion (\(page, at, _) -> versionKey page at) identity
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
        , drafts = Map.fromList [((d.page, d.author), d) | d <- Map.elems kept]
        , -- The versions of pages that are there: a page deleted takes its
          -- versions with it in one transaction, so there are no others.
          versions = Map.intersection (Map.fromListWith (<>) [(page, Map.singleton at v) | (page, at, v) <- Map.elems history]) pages
        , grants = Grants {global, spaces = grants}
        , disabled
        , passwords
        , counter
        }
  where
    holding store = Map.findWithDefault mempty store stored

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
