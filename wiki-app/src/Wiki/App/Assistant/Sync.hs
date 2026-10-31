-- | 'MonadVault': the server's half of the assistant's keys across
-- devices (WP5.21 of docs/PLAN.md, "Wiki.Api.Vault"): the vault the server
-- keeps for the signed-in user, and the passkeys that unlock it. The
-- browser's half (WebCrypto, WebAuthn, this device's key) is
-- "Wiki.App.Assistant"'s, and "Wiki.App.Assistant.Keys" puts the two
-- together.
--
-- The HTTP backend asks the server ("Wiki.App.Backend.Http"). The demo has
-- no server, so nothing syncs there ('vaultSync' is 'False'): its keys
-- stay in the browser, in a vault of the same format.
module Wiki.App.Assistant.Sync
  ( MonadVault (..)
  , Fetched (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Halogen.VDom.DOM.Monad (BrowserDOM)
import Halogen.VDom.DOM.Monad.Mem (MemDOM)
import Protolude
import Wiki.Api.Vault (AssertionOptions, AssertionResponse, PasskeyInfo, RegistrationOptions, RegistrationResponse, StoredVault)
import Wiki.App.Account (SignInError (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Mem (MemWiki)
import Wiki.Core.Assistant.Vault (CredentialId, Vault, VaultTag)
import Wiki.Core.User (Password)

-- | 'Fetched': the server's answer to a device that asks for the vault.
data Fetched
  = -- | The user has no vault: synchronisation is off.
    NoVault
  | -- | The vault is the version the device has.
    Unchanged
  | -- | The vault, at another version than the device's.
    Fetched StoredVault
  deriving stock (Eq, Show)

-- | 'MonadVault': the vault and the passkeys, as the server keeps them for
-- the signed-in user.
class (Monad m) => MonadVault m where
  -- | Whether a server keeps a vault at all: over HTTP, not in the demo.
  vaultSync :: m Bool
  default vaultSync :: (MonadTrans t, m ~ t n, MonadVault n) => m Bool
  vaultSync = lift vaultSync

  -- | The vault, unless it is the version the given tag names.
  fetchVault :: Maybe VaultTag -> m (Either WikiError Fetched)
  default fetchVault :: (MonadTrans t, m ~ t n, MonadVault n) => Maybe VaultTag -> m (Either WikiError Fetched)
  fetchVault = lift . fetchVault

  -- | Store a new version of the vault over the one the tag names, or,
  -- without one, a first vault. 'Conflict' when the server has another.
  storeVault :: Maybe VaultTag -> Vault -> m (Either WikiError StoredVault)
  default storeVault :: (MonadTrans t, m ~ t n, MonadVault n) => Maybe VaultTag -> Vault -> m (Either WikiError StoredVault)
  storeVault tag = lift . storeVault tag

  -- | Turn synchronisation off: the vault and every passkey go.
  deleteVault :: m (Either WikiError ())
  default deleteVault :: (MonadTrans t, m ~ t n, MonadVault n) => m (Either WikiError ())
  deleteVault = lift deleteVault

  -- | The user's passkeys.
  listPasskeys :: m (Either WikiError [PasskeyInfo])
  default listPasskeys :: (MonadTrans t, m ~ t n, MonadVault n) => m (Either WikiError [PasskeyInfo])
  listPasskeys = lift listPasskeys

  -- | The options of a new passkey, with the server's challenge.
  beginRegistration :: Maybe Password -> m (Either SignInError RegistrationOptions)
  default beginRegistration :: (MonadTrans t, m ~ t n, MonadVault n) => Maybe Password -> m (Either SignInError RegistrationOptions)
  beginRegistration = lift . beginRegistration

  -- | The browser's answer to a registration, which the server checks and
  -- stores.
  finishRegistration :: RegistrationResponse -> m (Either WikiError PasskeyInfo)
  default finishRegistration :: (MonadTrans t, m ~ t n, MonadVault n) => RegistrationResponse -> m (Either WikiError PasskeyInfo)
  finishRegistration = lift . finishRegistration

  -- | The options of a use of one of the user's passkeys, with the
  -- server's challenge.
  beginAssertion :: m (Either WikiError AssertionOptions)
  default beginAssertion :: (MonadTrans t, m ~ t n, MonadVault n) => m (Either WikiError AssertionOptions)
  beginAssertion = lift beginAssertion

  -- | The browser's answer to an assertion, which the server checks.
  finishAssertion :: AssertionResponse -> m (Either WikiError PasskeyInfo)
  default finishAssertion :: (MonadTrans t, m ~ t n, MonadVault n) => AssertionResponse -> m (Either WikiError PasskeyInfo)
  finishAssertion = lift . finishAssertion

  -- | Remove one of the user's passkeys, with its copy of the vault key.
  -- The result is the passkeys left.
  dropPasskey :: CredentialId -> m (Either WikiError [PasskeyInfo])
  default dropPasskey :: (MonadTrans t, m ~ t n, MonadVault n) => CredentialId -> m (Either WikiError [PasskeyInfo])
  dropPasskey = lift . dropPasskey

-- | A component's handlers ask through its monad.
instance (MonadVault m) => MonadVault (HalogenM st act slots output m)

instance (MonadVault m) => MonadVault (ReaderT r m)

-- | The demo's instance: no server, so no vault to sync, and every request
-- of one refused, saying why.
instance (Monad m) => MonadVault (MemWiki m) where
  vaultSync = pure False
  fetchVault _ = pure (Right NoVault)
  storeVault _ _ = pure (Left unavailable)
  deleteVault = pure (Right ())
  listPasskeys = pure (Right [])
  beginRegistration _ = pure (Left (SignInFailed unavailable))
  finishRegistration _ = pure (Left unavailable)
  beginAssertion = pure (Left unavailable)
  finishAssertion _ = pure (Left unavailable)
  dropPasskey _ = pure (Left unavailable)

-- | The browser's DOM alone has no server either: what runs in it
-- directly (the browser tests' own reads of the settings) keeps the keys
-- in this browser, as the demo does.
instance MonadVault BrowserDOM where
  vaultSync = pure False
  fetchVault _ = pure (Right NoVault)
  storeVault _ _ = pure (Left unavailable)
  deleteVault = pure (Right ())
  listPasskeys = pure (Right [])
  beginRegistration _ = pure (Left (SignInFailed unavailable))
  finishRegistration _ = pure (Left unavailable)
  beginAssertion = pure (Left unavailable)
  finishAssertion _ = pure (Left unavailable)
  dropPasskey _ = pure (Left unavailable)

-- | Nor has the in-memory document of the prerender and the native tests.
instance MonadVault MemDOM where
  vaultSync = pure False
  fetchVault _ = pure (Right NoVault)
  storeVault _ _ = pure (Left unavailable)
  deleteVault = pure (Right ())
  listPasskeys = pure (Right [])
  beginRegistration _ = pure (Left (SignInFailed unavailable))
  finishRegistration _ = pure (Left unavailable)
  beginAssertion = pure (Left unavailable)
  finishAssertion _ = pure (Left unavailable)
  dropPasskey _ = pure (Left unavailable)

-- | The demo's refusal: syncing the keys is a server's.
unavailable :: WikiError
unavailable = Invalid "This demo has no server: the assistant's keys stay in this browser."
