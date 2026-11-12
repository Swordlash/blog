-- | 'Wiki.Server.Sha256' is SHA-256 for the server's own code: the
-- 32-byte digest of some bytes, computed at once ('sha256') or in parts
-- ('sha256Init', 'sha256Update', 'sha256Finalize'). It is crypton's
-- ("Crypto.Hash"), and this module is the one place that names the
-- library for it.
--
-- Some of these digests are stored, so they must never change: a blob's
-- file and id are its SHA-256 in hex ("Wiki.Server.Storage.Blobs"), the
-- database keeps a session id's ('Wiki.Server.Password.tokenHash'), a
-- vault key's id is the start of its key's ('Wiki.Server.Vault.keyIdOf'),
-- and the guide's record keeps one for each page
-- ('Wiki.Server.Guide.writtenHash'). The tests ("Test.Server.Sha256") hold
-- values the earlier library, cryptohash-sha256, computed for each of them.
--
-- The passkeys' checks ("Wiki.Server.WebAuthn") and the unsubscribe links'
-- HMAC ("Wiki.Server.Storage.Notifications") call crypton themselves: the
-- webauthn package takes crypton's own digest type.
module Wiki.Server.Sha256
  ( sha256
  , Sha256Context
  , sha256Init
  , sha256Update
  , sha256Finalize
  )
where

import Crypto.Hash (Context, Digest, SHA256 (..), hashFinalize, hashInit, hashUpdate, hashWith)
import Data.ByteArray (convert)
import Protolude

-- | The SHA-256 of some bytes: 32 bytes.
sha256 :: ByteString -> ByteString
sha256 = convert . hashWith SHA256

-- | A SHA-256 computed in parts: the bytes given so far. A file of any
-- size is hashed so with one chunk in memory at a time. A context in
-- weak head normal form has taken its bytes in, so a loop that forces it
-- at each chunk holds no chunk.
newtype Sha256Context = Sha256Context (Context SHA256)

-- | The context of no bytes yet.
sha256Init :: Sha256Context
sha256Init = Sha256Context hashInit

-- | The context with these bytes added after those it has.
sha256Update :: Sha256Context -> ByteString -> Sha256Context
sha256Update (Sha256Context c) bytes = Sha256Context (hashUpdate c bytes)

-- | The SHA-256 of all the bytes a context was given: 32 bytes.
sha256Finalize :: Sha256Context -> ByteString
sha256Finalize (Sha256Context c) = convert (hashFinalize c :: Digest SHA256)
