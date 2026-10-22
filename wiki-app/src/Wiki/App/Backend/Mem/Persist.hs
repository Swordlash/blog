-- | The in-memory wiki as the browser keeps it between visits: the records
-- of a 'MemState' in IndexedDB ("Web.Storage.IndexedDB"), one record per
-- space, page, attachment and space's grants, each under its id in a store
-- of its own, and the state read back from them.
--
-- Only what the wiki's writes change is kept. The demo's people (users,
-- groups, who is in which) and its global grants are never changed by a
-- 'Wiki.App.Backend.MonadWiki' method, so they come from the program each
-- time, as the seed 'restore' is given; who is signed in, and the object
-- URLs a tab has made for attachments, last as long as the tab does.
--
-- Records are JSON through the same @aeson@ instances the server's API will
-- use, but for an attachment's bytes, which are kept as bytes. The id
-- counter is kept as well (store @meta@, key @counter@): ids are made from
-- it, and a counter that started over would make an id again that a record
-- already has.
--
-- Everything here is pure: "Wiki.App.Backend.Mem" reads and writes the
-- store, and works out what to write from two sets of 'records' with
-- 'changes'.
module Wiki.App.Backend.Mem.Persist
  ( -- * The database
    memDatabase
  , spacesStore
  , pagesStore
  , attachmentsStore
  , grantsStore
  , metaStore
  , storeNames

    -- * Records
  , Records
  , records
  , changes
  , Stored (..)
  , restore
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Merge.Strict qualified as Merge
import Data.Map.Strict qualified as Map
import Protolude
import Web.Storage.IndexedDB (Database (..), StoreName)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.Core.Id (BlobId (..), PageId (..), SpaceId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (Grants (..), SpaceGrant (..))
import Wiki.Core.Space (Space (..))

-- | The database a wiki is kept in under this name. Its stores are made
-- when it is first opened; adding one later is a version bump.
memDatabase :: Text -> Database
memDatabase name = Database {name, version = 1, stores = storeNames}

spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore :: StoreName

-- | A space's JSON, under its id.
spacesStore = "spaces"

-- | A page's JSON, with its attachments' names, types and sizes, under its id.
pagesStore = "pages"

-- | An uploaded attachment's bytes, under the id of its blob, which the
-- attachment on its page names.
attachmentsStore = "attachments"

-- | The grants on a space, a JSON list, under the space's id.
grantsStore = "grants"

-- | The id counter, under @counter@; a wiki that has never been written out
-- has none.
metaStore = "meta"

-- | Every store of 'memDatabase'.
storeNames :: [StoreName]
storeNames = [spacesStore, pagesStore, attachmentsStore, grantsStore, metaStore]

-- | What a store holds, by store and key.
type Records = Map StoreName (Map Text ByteString)

counterKey :: Text
counterKey = "counter"

-- | The state as the stores keep it: every store, even an empty one.
records :: MemState -> Records
records st =
  Map.fromList
    [ (spacesStore, Map.fromList [(s.id.text, json s) | s <- Map.elems st.spaces])
    , (pagesStore, Map.fromList [(p.id.text, json p) | p <- Map.elems st.pages])
    , (attachmentsStore, Map.mapKeys (\b -> b.text) st.blobs)
    , (grantsStore, Map.fromList [(sid.text, json gs) | (sid, gs) <- Map.toList (spaceGrants st)])
    , (metaStore, Map.singleton counterKey (json st.counter))
    ]
  where
    json :: (ToJSON a) => a -> ByteString
    json = BSL.toStrict . encode

-- | The grants on each space that has any, in the order the state has them.
spaceGrants :: MemState -> Map SpaceId [SpaceGrant]
spaceGrants st = Map.fromListWith (flip (<>)) [(g.space, [g]) | g <- st.grants.spaces]

-- | The writes that turn the first records into the second: a record that
-- is new or different is written, one that is gone is deleted, and the rest
-- are left alone, so that one change to the wiki writes only what it
-- changed. From what the stores hold to a whole wiki's records, it writes
-- that wiki out over whatever was there.
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
          (Merge.zipWithMaybeMatched (\k v w -> if v == w then Nothing else Just (store, k, Just w)))
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

-- | The wiki the stores hold, with the rest of the state (the people, the
-- global grants) from the seed. Nobody is signed in, and no attachment has
-- an object URL yet: the tab makes one when one is first asked for, as it
-- does for an upload.
restore :: MemState -> Records -> Stored
restore seed stored = case Map.lookup counterKey (holding metaStore) of
  Nothing -> Unseeded
  Just counterBytes -> either Unreadable Stored $ do
    counter <- decoding metaStore counterKey counterBytes
    spaces <- keyed spacesStore (\s -> s.id.text) SpaceId
    pages <- keyed pagesStore (\p -> p.id.text) PageId
    grants <- fmap concat . for (Map.toList (holding grantsStore)) $ \(key, bytes) -> do
      gs <- decoding grantsStore key bytes
      if all (\g -> g.space.text == key) gs
        then Right gs
        else Left (failure grantsStore key "has grants on another space")
    pure
      seed
        { spaces
        , pages
        , blobs = Map.mapKeys BlobId (holding attachmentsStore)
        , grants = Grants {global = seed.grants.global, spaces = grants}
        , objectUrls = mempty
        , counter
        }
  where
    holding store = Map.findWithDefault mempty store stored

    keyed :: (FromJSON a, Ord k) => StoreName -> (a -> Text) -> (Text -> k) -> Either Text (Map k a)
    keyed store idOf key = fmap Map.fromList . for (Map.toList (holding store)) $ \(k, bytes) -> do
      a <- decoding store k bytes
      if idOf a == k then Right (key k, a) else Left (failure store k ("holds " <> idOf a))

    decoding :: (FromJSON a) => StoreName -> Text -> ByteString -> Either Text a
    decoding store k = first (failure store k . toS) . eitherDecodeStrict'

    failure :: StoreName -> Text -> Text -> Text
    failure store k why = "the record " <> show store <> " " <> show k <> " " <> why
