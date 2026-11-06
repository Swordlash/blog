-- | The user's vault: secrets of the user's, sealed in their browser
-- under one key, and that key wrapped for each way the user can unlock
-- it (WP5.21 and WP5.74 of docs/PLAN.md). The writing assistant's
-- settings are one such secret ("Wiki.Core.Assistant.Vault"); others are
-- added beside them as named items.
--
-- = How the vault is locked
--
-- A random key, the vault key (AES-GCM, 256 bits), seals each item. An
-- item ('Item') is a nonce and a ciphertext, with the id of the key it
-- holds when it holds one. Items are kept by name ('ItemName'), and the
-- names are open: a vault keeps an item it does not know, so that an
-- older version of the wiki does not lose what a newer one sealed.
--
-- The vault key itself is encrypted ("wrapped", 'WrappedKey') once for
-- each way to unlock the vault ('Unlock'): once per passkey, with a key
-- derived (HKDF-SHA256) from the output of the passkey's PRF extension on
-- the vault's salt, and, where the user chose it, once with a key derived
-- from their password. The browser never sends the vault key, the PRF
-- output or what the password derives. The server stores the 'Vault' as
-- the browser sends it and gives it back; it cannot open it.
--
-- The cryptography runs in the browser, with WebCrypto
-- (@wiki-app\/jsbits\/vault.js@). This module is the format, pure.
--
-- = Formats
--
-- A vault of format 1 (WP5.21) held one sealed text, the assistant's
-- settings, and the vault key wrapped by credential id. It is read as a
-- vault of the current format with one item, @assistant@, and one wrap per
-- passkey. Format 2 writes the items by name and the wraps by what
-- unlocks them. A vault of a later format is refused as made by a newer
-- wiki, rather than misread; a browser that refuses it keeps what it had
-- and changes nothing on the server.
module Wiki.Core.Vault
  ( -- * Bytes as the browser writes them
    Salt (..)
  , Nonce (..)
  , Ciphertext (..)

    -- * The vault
  , Vault (..)
  , vaultFormat
  , VaultTag (..)
  , Sealed (..)
  , WrappedKey (..)
  , CredentialId (..)
  , KeyId (..)
  , ItemName (..)
  , Item (..)
  , Unlock (..)
  , unlockText
  , readUnlock

    -- * Reading and changing a vault
  , itemOf
  , withItem
  , withoutItem
  , wrapFor
  , withWrap
  , withoutWrap
  , passkeyWraps

    -- * The user's key pair
  , PublicKey (..)
  , identityItem
  , identityData
  , identityDataPrefix
  , fingerprintGroups
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), FromJSONKey (..), FromJSONKeyFunction (..), ToJSON (..), ToJSONKey (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, toJSONKeyText)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)

--------------------------------------------------------------------------------
-- Bytes as the browser writes them

-- | 'Salt': the vault's salt, 32 random bytes chosen once when the vault
-- is made, in base64url without padding. Every key derived for the vault
-- (from a passkey's PRF output, or from the password) is derived with it.
newtype Salt = Salt {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, IsString)

-- | 'Nonce': the 12-byte nonce of one AES-GCM encryption, in base64url.
newtype Nonce = Nonce {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, IsString)

-- | 'Ciphertext': what AES-GCM made, with its tag, in base64url: a sealed
-- item, or a wrapped key.
newtype Ciphertext = Ciphertext {text :: Text}
  deriving stock (Eq, Ord)
  deriving newtype (FromJSON, ToJSON, IsString)

instance Show Ciphertext where
  showsPrec _ _ rest = "Ciphertext <encrypted>" <> rest

--------------------------------------------------------------------------------
-- The vault

-- | The version of the vault's format that this module writes. A vault of
-- a later version is refused as made by a newer wiki, rather than misread.
vaultFormat :: Int
vaultFormat = 2

-- | 'CredentialId': a passkey's credential id, in base64url without
-- padding, as WebAuthn writes it. The vault keeps a wrapped copy of its
-- key under each passkey that unlocks it.
newtype CredentialId = CredentialId {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'VaultTag': the version of the vault on the server, as its @ETag@
-- gives it. A device keeps the tag of the copy it has, and fetches the
-- vault again only when the server's tag differs; a change is stored
-- only over the version it was made to.
newtype VaultTag = VaultTag {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'KeyId': the id of a key pair: 16 bytes in base64url. An item that
-- holds a private key names its key pair by it, and the additional data
-- it is sealed with names it too.
newtype KeyId = KeyId {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'PublicKey': the public half of a user's key pair, X25519's raw 32
-- bytes in base64url.
newtype PublicKey = PublicKey {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, IsString)

-- | 'Sealed': text encrypted with AES-GCM: the nonce and the ciphertext.
data Sealed = Sealed
  { nonce :: Nonce
  , ciphertext :: Ciphertext
  }
  deriving stock (Eq)

instance Show Sealed where
  showsPrec _ _ rest = "Sealed <ciphertext>" <> rest

instance ToJSON Sealed where
  toJSON s = object ["nonce" .= s.nonce, "ciphertext" .= s.ciphertext]

instance FromJSON Sealed where
  parseJSON = withObject "Sealed" $ \o -> Sealed <$> o .: "nonce" <*> o .: "ciphertext"

-- | 'WrappedKey': the vault key encrypted with the key one way of
-- unlocking gives: the nonce and the encrypted key.
data WrappedKey = WrappedKey
  { nonce :: Nonce
  , key :: Ciphertext
  }
  deriving stock (Eq)

instance Show WrappedKey where
  showsPrec _ _ rest = "WrappedKey <encrypted>" <> rest

instance ToJSON WrappedKey where
  toJSON w = object ["nonce" .= w.nonce, "key" .= w.key]

instance FromJSON WrappedKey where
  parseJSON = withObject "WrappedKey" $ \o -> WrappedKey <$> o .: "nonce" <*> o .: "key"

-- | 'ItemName': the name an item of the vault is kept under: lower-case
-- letters and hyphens, such as @assistant@.
newtype ItemName = ItemName {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey)

-- | 'Item': one sealed item of the vault, with the id of the key pair it
-- holds, for an item that holds a private key.
data Item = Item
  { keyId :: Maybe KeyId
  , sealed :: Sealed
  }
  deriving stock (Eq, Show)

-- | Written as one object: @nonce@, @ciphertext@ and, when there is one,
-- @keyId@.
instance ToJSON Item where
  toJSON i = object (["nonce" .= i.sealed.nonce, "ciphertext" .= i.sealed.ciphertext] <> maybe [] (\k -> ["keyId" .= k]) i.keyId)

instance FromJSON Item where
  parseJSON = withObject "Item" $ \o -> Item <$> o .:? "keyId" <*> (Sealed <$> o .: "nonce" <*> o .: "ciphertext")

-- | 'Unlock': a way to unlock the vault, under which it keeps a wrapped
-- copy of its key.
data Unlock
  = -- | A passkey, by its credential id: the key that wraps comes from
    -- its PRF output.
    ByPasskey CredentialId
  | -- | The user's password: the key that wraps comes from what OPAQUE
    -- gives the browser at a sign-in (its export key).
    ByPassword
  deriving stock (Eq, Ord, Show)

-- | An 'Unlock' as the vault's JSON names it: @passkey:@ and the
-- credential id, or @password@.
unlockText :: Unlock -> Text
unlockText = \case
  ByPasskey c -> "passkey:" <> c.text
  ByPassword -> "password"

-- | An 'Unlock' from its name in the vault's JSON.
readUnlock :: Text -> Maybe Unlock
readUnlock t
  | t == "password" = Just ByPassword
  | Just c <- T.stripPrefix "passkey:" t, not (T.null c) = Just (ByPasskey (CredentialId c))
  | otherwise = Nothing

instance ToJSON Unlock where
  toJSON = toJSON . unlockText

instance FromJSON Unlock where
  parseJSON = withText "Unlock" (\t -> maybe (fail ("not a way to unlock a vault: " <> toS t)) pure (readUnlock t))

instance ToJSONKey Unlock where
  toJSONKey = toJSONKeyText unlockText

instance FromJSONKey Unlock where
  fromJSONKey = FromJSONKeyTextParser (\t -> maybe (fail ("not a way to unlock a vault: " <> toS t)) pure (readUnlock t))

-- | 'Vault': what the server stores for a user. It holds the format's
-- version, the salt, the sealed items by name, and the vault key wrapped
-- for each way to unlock it.
data Vault = Vault
  { format :: Int
  , salt :: Salt
  , items :: Map ItemName Item
  , wraps :: Map Unlock WrappedKey
  }
  deriving stock (Eq, Show)

-- | Written as one object: @format@, @salt@, @items@ (an object by name)
-- and @wraps@ (an object by 'unlockText'). A vault read from format 1 is
-- written in format 2.
instance ToJSON Vault where
  toJSON v =
    object
      [ "format" .= vaultFormat
      , "salt" .= v.salt
      , "items" .= v.items
      , "wraps" .= v.wraps
      ]

instance FromJSON Vault where
  parseJSON = withObject "Vault" $ \o -> do
    format <- o .: "format"
    when (format > vaultFormat) (fail ("a vault of format " <> show format <> ", which a newer version of the wiki made"))
    when (format < 1) (fail ("not a vault's format: " <> show format))
    salt <- o .: "salt"
    if format == 1
      then do
        -- Format 1: the assistant's settings, and the wraps by credential
        -- id. The format read is kept, so that the server can tell a
        -- browser of WP5.21's from a current one.
        sealed <- Sealed <$> o .: "nonce" <*> o .: "ciphertext"
        wrapped <- o .:? "wrapped" .!= (mempty :: Map Text WrappedKey)
        pure
          Vault
            { format
            , salt
            , items = Map.singleton (ItemName "assistant") Item {keyId = Nothing, sealed}
            , wraps = Map.mapKeys (ByPasskey . CredentialId) wrapped
            }
      else Vault format salt <$> (o .:? "items" .!= mempty) <*> (o .:? "wraps" .!= mempty :: Parser (Map Unlock WrappedKey))

--------------------------------------------------------------------------------
-- Reading and changing a vault

-- | The item of a vault kept under a name, if it has one.
itemOf :: ItemName -> Vault -> Maybe Item
itemOf name v = Map.lookup name v.items

-- | A vault with an item kept under a name, in the place of the one it
-- had there, if any. The vault key, the salt and the wraps stay as they
-- were.
withItem :: ItemName -> Item -> Vault -> Vault
withItem name i v = v {items = Map.insert name i v.items}

-- | A vault without the item kept under a name.
withoutItem :: ItemName -> Vault -> Vault
withoutItem name v = v {items = Map.delete name v.items}

-- | The vault key wrapped for a way to unlock it, if the vault has it.
wrapFor :: Unlock -> Vault -> Maybe WrappedKey
wrapFor u v = Map.lookup u v.wraps

-- | A vault with the vault key wrapped for one more way to unlock it, or
-- wrapped anew for one it had.
withWrap :: Unlock -> WrappedKey -> Vault -> Vault
withWrap u w v = v {wraps = Map.insert u w v.wraps}

-- | A vault without a way to unlock it: its wrapped copy of the key goes.
withoutWrap :: Unlock -> Vault -> Vault
withoutWrap u v = v {wraps = Map.delete u v.wraps}

-- | The wraps of the vault key for passkeys, by credential id.
passkeyWraps :: Vault -> Map CredentialId WrappedKey
passkeyWraps v = Map.fromList [(c, w) | (ByPasskey c, w) <- Map.toList v.wraps]

--------------------------------------------------------------------------------
-- The user's key pair

-- | The name the user's private key is kept under in the vault: their
-- X25519 key, as PKCS #8, sealed under the vault key, with the id of its
-- key pair. The public half is in the server's directory under the same
-- id. A user has one key pair at a time; a new one replaces it only when
-- the old one is lost (a password reset with nothing else to unlock the
-- vault).
identityItem :: ItemName
identityItem = ItemName "identity"

-- | The start of the additional data AES-GCM authenticates with the
-- user's private key: the format's name and version, and what the item
-- is. The key pair's id follows it ('identityData'). A ciphertext moved to
-- another item, or under another key id, then fails to open.
identityDataPrefix :: Text
identityDataPrefix = "wiki-vault/2 identity "

-- | The additional data the private key of the key pair with this id is
-- sealed with.
identityData :: KeyId -> Text
identityData k = identityDataPrefix <> k.text

-- | A public key's fingerprint, as the browser computes it (SHA-256 of the
-- raw key, in hexadecimal), cut into groups of four digits for a person
-- to read and compare.
fingerprintGroups :: Text -> [Text]
fingerprintGroups = T.chunksOf 4 . T.toUpper
