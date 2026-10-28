-- | 'Counting' is a monad over another that records every IndexedDB call
-- made through it before making it. The tests open the demo's wiki in it
-- ('Wiki.App.Backend.Mem.openMemWiki' reads and writes through the monad
-- it was opened in) to see which records a load, a write or a view reads
-- or writes.
module Test.Counting
  ( Counting
  , Call (..)
  , runCounting
  , isRead
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.IORef (IORef, atomicModifyIORef')
import Protolude hiding (get, put)
import Web.Storage.IndexedDB (MonadIndexedDB (..), StoreName)
import Web.Storage.IndexedDB qualified as IDB

-- | 'Call' is one IndexedDB call: what it did, to which store, and with
-- which keys.
data Call
  = -- | 'get' of a key.
    Got StoreName Text
  | -- | 'keys' of a store.
    Listed StoreName
  | -- | 'getAll' of a store: every record's bytes.
    GotAll StoreName
  | -- | 'writeMany', with the store and key of each write, in order.
    Wrote [(StoreName, Text)]
  | -- | 'put', 'delete', 'clear' or 'deleteDatabase'.
    Changed
  deriving stock (Eq, Ord, Show)

-- | Whether a call reads the records of a store: a record's bytes, or
-- every record's.
isRead :: StoreName -> Call -> Bool
isRead store = \case
  Got s _ -> s == store
  GotAll s -> s == store
  _ -> False

-- | A monad over @m@ that records its IndexedDB calls in an 'IORef', the
-- latest first.
newtype Counting m a = Counting (ReaderT (IORef [Call]) m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

-- | Run a program, recording its IndexedDB calls here.
runCounting :: IORef [Call] -> Counting m a -> m a
runCounting calls (Counting program) = runReaderT program calls

instance (MonadIndexedDB m, MonadIO m) => MonadIndexedDB (Counting m) where
  get db store key = recorded (Got store key) (IDB.get db store key)
  put db store key bytes = recorded Changed (IDB.put db store key bytes)
  delete db store key = recorded Changed (IDB.delete db store key)
  keys db store = recorded (Listed store) (IDB.keys db store)
  getAll db store = recorded (GotAll store) (IDB.getAll db store)
  clear db store = recorded Changed (IDB.clear db store)
  writeMany db writes = recorded (Wrote [(store, key) | (store, key, _) <- writes]) (IDB.writeMany db writes)
  deleteDatabase name = recorded Changed (IDB.deleteDatabase name)

-- | Record a call, then make it.
recorded :: (MonadIO m) => Call -> m a -> Counting m a
recorded call act = Counting $ do
  calls <- ask
  liftIO (atomicModifyIORef' calls (\cs -> (call : cs, ())))
  lift act
