-- | The backend interface of encrypted spaces (WP5.74 of docs/PLAN.md,
-- "Wiki.Core.Encrypted"): 'MonadEncryption' is what a view asks about an
-- encrypted space besides reading and writing its pages, which
-- 'Wiki.App.Backend.MonadWiki' does as for any space.
--
-- In an encrypted space the HTTP backend encrypts a page's title and text
-- before they leave the browser, and decrypts them when they come back,
-- through the API's routes of encrypted spaces ("Wiki.Api.Encrypted"), so
-- that a view reads and writes the pages of an encrypted space as it reads
-- any page. What a view needs besides is whether this browser can do that
-- ('KeyState'), the space's turning encrypted, and who is waiting for the
-- space's key.
--
-- The demo's in-memory backend has no server, so nothing there is
-- encrypted: its spaces are plain ('NotEncrypted') and turning one
-- encrypted is 'Invalid'. The server has no implementation of this class:
-- it holds no key.
module Wiki.App.Backend.Encrypted
  ( MonadEncryption (..)
  , KeyState (..)
  , keyStateText
  , noServer
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Encrypted (SpaceEncryption)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Space (Space)

-- | 'KeyState': whether this browser can read and write an encrypted
-- space's pages, and if not, why.
data KeyState
  = -- | The space's pages are plain text.
    NotEncrypted
  | -- | This browser holds the space's key: its pages are read and written.
    KeyReady
  | -- | The page has no WebCrypto: it was opened over plain HTTP.
    NeedsHttps
  | -- | Nobody is signed in.
    SignInFirst
  | -- | The user has a grant, but this device does not hold their private
    -- key: their keys must be unlocked here first (a passkey or the
    -- password), as the account's security does.
    KeysLocked
  | -- | No member has shared the space's key with the user yet: a member
    -- shares it when they next open the space. A user without a key pair
    -- waits too, until their first sign-in on a browser makes one.
    WaitingForKey
  deriving stock (Eq, Show)

-- | What a view says of a state that is not 'KeyReady'.
keyStateText :: KeyState -> Text
keyStateText = \case
  NotEncrypted -> "This space is not encrypted."
  KeyReady -> "This browser holds the space's key."
  NeedsHttps -> "This space is encrypted, and encryption needs the wiki's HTTPS address: a browser offers it only to a secure page. Open the wiki at its HTTPS address to read it."
  SignInFirst -> "This space is encrypted: sign in to read it."
  KeysLocked -> "This space is encrypted, and this device does not hold your keys yet. Unlock them here to read it."
  WaitingForKey -> "This space is encrypted, and no member has shared its key with you yet. A member shares it when they next open the space; until then its pages cannot be read here."

-- | What a backend without a server answers.
noServer :: WikiError
noServer = Invalid "Encrypted spaces need a server: the demo keeps every page in this browser, in plain text."

-- | 'MonadEncryption' is what a view asks of an encrypted space besides its
-- pages. Every method has a default that lifts it through a monad
-- transformer, as 'Wiki.App.Backend.MonadWiki''s do.
class (Monad m) => MonadEncryption m where
  -- | Whether this browser can read and write the space's pages now. It
  -- opens the space's key when it can, and shares the key with the
  -- space's readers waiting for it.
  keyState :: SpaceId -> m (Either WikiError KeyState)
  default keyState :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError KeyState)
  keyState = lift . keyState

  -- | Turn a private space with nothing written in it encrypted, with a new
  -- key made here and granted to the user. One-way: an encrypted space
  -- stays encrypted.
  encryptSpace :: SpaceId -> m (Either WikiError Space)
  default encryptSpace :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError Space)
  encryptSpace = lift . encryptSpace

  -- | The space's key as the user sees it: their grant, and the readers
  -- waiting for the key, for a member who holds it.
  spaceEncryption :: SpaceId -> m (Either WikiError SpaceEncryption)
  default spaceEncryption :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError SpaceEncryption)
  spaceEncryption = lift . spaceEncryption

-- | A component's handlers reach the backend through its monad.
instance (MonadEncryption m) => MonadEncryption (HalogenM st act slots output m)

instance (MonadEncryption m) => MonadEncryption (ReaderT r m)
