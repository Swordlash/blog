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
import Wiki.Api.Encrypted (ConversionInfo, SpaceEncryption)
import Wiki.App.Backend (WikiError (..))
import Wiki.App.DecryptedExport (DecryptedExport)
import Wiki.Core.Encrypted (ChainProblem)
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Space (Conversion, Space)

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

  -- | What this browser found wrong with the versions of a page of an
  -- encrypted space the server sent ("Wiki.Core.Encrypted"'s chain of
  -- versions), since the page was opened in this tab: an older version
  -- than one read before, another one under the same number, or a version
  -- missing from its history. A page with a problem is shown with it, and
  -- not saved from this tab.
  chainProblem :: PageId -> m (Maybe ChainProblem)
  default chainProblem :: (MonadTrans t, m ~ t n, MonadEncryption n) => PageId -> m (Maybe ChainProblem)
  chainProblem = lift . chainProblem

  -- | The space and those of its subspaces whose keys this browser can
  -- open, decrypted here into an archive of the wiki's own format, zipped
  -- and checked ("Wiki.App.DecryptedExport"): the file to save, and the
  -- subspaces left out, with why. A subspace whose key does not open here
  -- is left out with the subspaces under it; anything else that does not
  -- decrypt refuses the whole export, naming it, so that the file never
  -- lacks something silently. Nothing decrypted is sent to the server.
  exportDecrypted :: SpaceId -> m (Either WikiError DecryptedExport)
  default exportDecrypted :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError DecryptedExport)
  exportDecrypted = lift . exportDecrypted

  -- | The space's conversion ("Wiki.Core.Space"'s 'Conversion'): the one
  -- under way with the pages it has left, or why none could start now.
  conversionOf :: SpaceId -> m (Either WikiError ConversionInfo)
  default conversionOf :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError ConversionInfo)
  conversionOf = lift . conversionOf

  -- | Start encrypting a space that has pages, and the plain spaces below
  -- it, with new keys made here and granted to the user; or start turning
  -- the encryption of an encrypted space, and of the spaces below it, off.
  -- Its pages are then converted by 'convertNext'.
  startConversion :: SpaceId -> Conversion -> m (Either WikiError ConversionInfo)
  default startConversion :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> Conversion -> m (Either WikiError ConversionInfo)
  startConversion sid = lift . startConversion sid

  -- | Convert the next page the conversion of the space has left, here:
  -- read it, encrypt or decrypt it, stage it, read back what was staged
  -- and check it, and commit it. The pages left after it; none once the
  -- conversion has ended.
  convertNext :: SpaceId -> m (Either WikiError Int)
  default convertNext :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError Int)
  convertNext = lift . convertNext

  -- | Turn the conversion the space is in round ("Stop and turn back"):
  -- it goes the other way over the pages converted so far, which
  -- 'convertNext' then converts back, and the space ends as it began.
  reverseConversion :: SpaceId -> m (Either WikiError ConversionInfo)
  default reverseConversion :: (MonadTrans t, m ~ t n, MonadEncryption n) => SpaceId -> m (Either WikiError ConversionInfo)
  reverseConversion = lift . reverseConversion

-- | A component's handlers reach the backend through its monad.
instance (MonadEncryption m) => MonadEncryption (HalogenM st act slots output m)

instance (MonadEncryption m) => MonadEncryption (ReaderT r m)
