-- | Passwords, kept as argon2id hashes (decision 8 of docs/PLAN.md), and the
-- random ids of sessions.
--
-- A hash is written in the PHC string format that argon2's reference
-- implementation, libsodium and most others write:
--
-- > $argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>
--
-- with the salt and the hash in unpadded base64. The parameters a password
-- was hashed with are in its string, so that 'verifyPassword' checks it
-- against those, and the parameters for new hashes ('parameters') can be
-- raised later without making anyone's password stop working.
--
-- The parameters are OWASP's first recommendation for argon2id (its
-- Password Storage Cheat Sheet): 19 MiB of memory, two passes, one lane.
-- That costs a few tens of milliseconds a sign-in on an ordinary machine
-- and the memory makes guessing on graphics cards expensive; together with
-- the limit on attempts ("Wiki.Server.Limiter") it is plenty for a wiki's
-- passwords. One lane, because crypton computes lanes one after another,
-- so more would cost time and buy nothing. The hashing is crypton's, whose
-- C is compiled into the program: there is no system library to install
-- (the owner's machine has none).
module Wiki.Server.Password
  ( -- * Hashes
    hashPassword
  , verifyPassword
  , Parameters (..)
  , parameters
  , hashWith

    -- * Rules
  , checkPassword
  , minimumLength
  , maximumLength

    -- * Session ids
  , newToken
  , tokenHash
  )
where

import Crypto.Error (CryptoFailable (..))
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.KDF.Argon2 qualified as Argon2
import Crypto.Random (getRandomBytes)
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Protolude

-- | What a hash is made with: memory in KiB, passes, lanes.
data Parameters = Parameters
  { memory :: Word32
  , iterations :: Word32
  , parallelism :: Word32
  }
  deriving stock (Eq, Show)

-- | The parameters new hashes are made with (see the module's Haddock).
parameters :: Parameters
parameters = Parameters {memory = 19 * 1024, iterations = 2, parallelism = 1}

-- | A password's hash, with a salt of its own, as a PHC string.
hashPassword :: Text -> IO Text
hashPassword password = do
  salt <- getRandomBytes 16
  pure (hashWith parameters salt password)

-- | A password's hash with these parameters and this salt (at least eight
-- bytes): the tests' way to a known hash.
hashWith :: Parameters -> ByteString -> Text -> Text
hashWith p salt password =
  T.intercalate
    "$"
    [ ""
    , "argon2id"
    , "v=19"
    , "m=" <> show p.memory <> ",t=" <> show p.iterations <> ",p=" <> show p.parallelism
    , base64 salt
    , base64 (derive p salt (encodeUtf8 password))
    ]

-- | Whether a password is the one a PHC string was made from. A string this
-- module would not have written (another algorithm, a broken one) matches
-- no password. The comparison of the hashes takes as long whatever they
-- hold.
verifyPassword :: Text -> Text -> Bool
verifyPassword phc password = case T.splitOn "$" phc of
  ["", "argon2id", "v=19", params, salt64, hash64]
    | Just p <- readParameters params
    , Right salt <- unbase64 salt64
    , Right expected <- unbase64 hash64
    , BS.length salt >= 8
    , BS.length expected >= 16 ->
        constEq expected (deriveLength (BS.length expected) p salt (encodeUtf8 password))
  _ -> False

-- | The parameters of a PHC string's @m=…,t=…,p=…@, kept within what a
-- server can afford: a string asking for more than a gibibyte or a hundred
-- passes is not one this server wrote.
readParameters :: Text -> Maybe Parameters
readParameters t = case map (T.breakOn "=") (T.splitOn "," t) of
  [("m", m), ("t", i), ("p", l)] -> do
    memory <- number m
    iterations <- number i
    parallelism <- number l
    guard (memory >= 8 * parallelism && memory <= 1024 * 1024 && iterations >= 1 && iterations <= 100 && parallelism >= 1 && parallelism <= 16)
    pure Parameters {memory, iterations, parallelism}
  _ -> Nothing
  where
    number v = T.stripPrefix "=" v >>= readMaybe . T.unpack

derive :: Parameters -> ByteString -> ByteString -> ByteString
derive = deriveLength 32

deriveLength :: Int -> Parameters -> ByteString -> ByteString -> ByteString
deriveLength size p salt password =
  case Argon2.hash options password salt size of
    CryptoPassed out -> out
    -- Only a salt or an output too short, or parameters argon2 refuses,
    -- fail, and both are checked before: no hash matches then.
    CryptoFailed _ -> ""
  where
    options =
      Argon2.Options
        { Argon2.iterations = p.iterations
        , Argon2.memory = p.memory
        , Argon2.parallelism = p.parallelism
        , Argon2.variant = Argon2.Argon2id
        , Argon2.version = Argon2.Version13
        }

-- | Bytes in base64 without its padding, as PHC strings have them.
base64 :: ByteString -> Text
base64 = T.dropWhileEnd (== '=') . decodeUtf8 . convertToBase @ByteString Base64

unbase64 :: Text -> Either [Char] ByteString
unbase64 t = convertFromBase Base64 (encodeUtf8 (padded t))
  where
    padded s = s <> T.replicate ((4 - T.length s `mod` 4) `mod` 4) "="

-- | Why a password cannot be one, if it cannot: shorter than
-- 'minimumLength' characters, or longer than 'maximumLength'.
checkPassword :: Text -> Either Text Text
checkPassword p
  | T.length p < minimumLength = Left ("A password needs at least " <> show minimumLength <> " characters.")
  | T.length p > maximumLength = Left ("A password has at most " <> show maximumLength <> " characters.")
  | otherwise = Right p

-- | The shortest password the server takes: NIST's minimum for a password
-- chosen by its user (SP 800-63B).
minimumLength :: Int
minimumLength = 8

-- | The longest: long enough for any passphrase, short enough that hashing
-- one is not a way to keep the server busy.
maximumLength :: Int
maximumLength = 1024

-- | A new session id: 32 random bytes, as the cookie carries them (base64
-- for URLs, unpadded, which a cookie's value may hold as it is).
newToken :: IO Text
newToken = decodeUtf8 . convertToBase Base64URLUnpadded <$> (getRandomBytes 32 :: IO ByteString)

-- | What the database keeps of a session id: its SHA-256, in hex. A
-- database that leaks signs nobody in, and the id is random and long
-- enough that a hash with no salt and no cost is enough.
tokenHash :: Text -> Text
tokenHash = decodeUtf8 . convertToBase @ByteString Base16 . SHA256.hash . encodeUtf8
