-- | The arithmetic of a second factor (WP4.11 of docs/PLAN.md):
-- time-based one-time passwords as RFC 6238 defines them, which every
-- authenticator application computes (SHA-1, a 30-second step, six
-- digits); the URI that gives an application its secret, drawn as a QR
-- code; and the recovery codes that replace the application when it is
-- lost.
--
-- The codes are one-time-password's (WP5.27): its HOTP over HMAC-SHA-1,
-- which needs libsodium initialised, as every program that uses this
-- module does first ('Sel.secureMain'). The URI, the QR code and the
-- recovery codes are the wiki's.
--
-- Everything here is pure except generating random secrets, so that the
-- tests check it against the RFCs' own test vectors. Which code was used
-- last, and so may not be used again, is stored by the storage
-- ("Wiki.Server.SecondFactor").
module Wiki.Server.Totp
  ( -- * Codes
    hotp
  , counterAt
  , codeAt
  , matchingCounter
  , window

    -- * Secrets
  , Secret
  , newSecret
  , secretText
  , secretFromText
  , otpauthUri
  , qrRows

    -- * Recovery codes
  , newRecoveryCodes
  , recoveryKey
  )
where

import Codec.QRCode (ErrorLevel (..), QRImage (..), TextEncoding (..), defaultQRCodeOptions, encodeText)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Display (display)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Vector.Unboxed qualified as V
import Network.HTTP.Types.URI (urlEncode)
import OTP.Commons (Digits, mkDigits)
import OTP.HOTP (hotpSHA1)
import Protolude
import Sel.HMAC.SHA256 qualified as HMAC
import Text.Show (Show (showsPrec))

--------------------------------------------------------------------------------
-- Codes

-- | The HMAC-based one-time password of RFC 4226 (section 5.3) with this
-- many digits (six or more), for a key and a counter, with leading zeros
-- kept: one-time-password's 'hotpSHA1'.
--
-- The package takes a key of exactly 32 bytes, and the wiki's secrets are
-- 20 ('newSecret'). HMAC pads a key shorter than its block (64 bytes for
-- SHA-1) with zero bytes, so a key and the same key with zero bytes after
-- it give the same codes: the secret is given to the package padded to 32
-- bytes. A key longer than 32 bytes cannot be given to it: no key of 32
-- bytes gives the same codes as one of 33 to 64. For such a key, and for
-- fewer than six digits, which the package refuses, there is no code
-- ('Nothing'). The wiki makes no such key ('secretFromText' refuses one).
hotp :: Int -> ByteString -> Word64 -> Maybe Text
hotp digits key counter = do
  d <- mkDigits (fromIntegral digits)
  k <- paddedKey key
  pure (hotpWith d k counter)

-- | 'hotp' with the key as the package takes it, made once ('paddedKey'):
-- each key the package makes is a buffer of libsodium's own, with guard
-- pages around it, so a 'Secret' carries its key made already.
hotpWith :: Digits -> HMAC.AuthenticationKey -> Word64 -> Text
hotpWith digits key counter = display (hotpSHA1 key counter digits)

-- | Six digits, as every authenticator application shows its codes.
sixDigits :: Digits
sixDigits = fromMaybe (panic "six digits are a number of digits the package takes") (mkDigits 6)

-- | A key of at most 32 bytes as the package takes it: padded with zero
-- bytes to 32. 'Nothing' for a longer key.
paddedKey :: ByteString -> Maybe HMAC.AuthenticationKey
paddedKey key
  | BS.length key > 32 = Nothing
  | otherwise = rightToMaybe (HMAC.authenticationKeyFromHexByteString (convertToBase Base16 (key <> BS.replicate (32 - BS.length key) 0)))

-- | The RFC 6238 time step a moment falls in: the number of whole
-- 30-second periods since the Unix epoch.
counterAt :: UTCTime -> Word64
counterAt t = floor (utcTimeToPOSIXSeconds t / 30)

-- | The six-digit code of a secret at a moment, as an application shows it.
codeAt :: Secret -> UTCTime -> Text
codeAt secret t = hotpWith sixDigits secret.key (counterAt t)

-- | How many steps either side of now a code is accepted from: one, so
-- that a clock thirty seconds off, or a code typed as it changed, still
-- works.
window :: Word64
window = 1

-- | The time step of a code typed now, if it is one of the secret's codes
-- within the 'window' and later than the last code accepted (so that a
-- code someone saw being typed cannot be used again). Spaces typed in it
-- are ignored.
matchingCounter :: Secret -> UTCTime -> Maybe Word64 -> Text -> Maybe Word64
matchingCounter secret t lastUsed typed =
  find
    (\c -> maybe True (c >) lastUsed && encodeUtf8 (hotpWith sixDigits secret.key c) `BA.constEq` encodeUtf8 code)
    [now - window .. now + window]
  where
    now = max window (counterAt t)
    code = T.filter (not . isSpace) typed

--------------------------------------------------------------------------------
-- Secrets

-- | A shared secret: the key both the server and the application compute
-- the codes with, as its bytes and as the package's key made from them
-- ('paddedKey', once). 'Show' never shows it, since it is all a code
-- needs.
data Secret = Secret
  { bytes :: ByteString
  , key :: HMAC.AuthenticationKey
  }

instance Eq Secret where
  a == b = a.bytes == b.bytes

-- | A secret of these bytes; 'Nothing' for more than 32 of them, which
-- 'hotp' cannot use.
secretOf :: ByteString -> Maybe Secret
secretOf bytes = (\key -> Secret {bytes, key}) <$> paddedKey bytes

instance Show Secret where
  showsPrec _ _ rest = "Secret <hidden>" <> rest

-- | A new secret: 20 random bytes, the length of SHA-1's output, as RFC 4226
-- recommends.
newSecret :: IO Secret
newSecret = getRandomBytes 20 >>= maybe (panic "20 bytes are a key the package takes") pure . secretOf

-- | A secret as people type it into an application and as it is stored:
-- in base32 without padding (32 letters and digits for 20 bytes).
secretText :: Secret -> Text
secretText secret = T.dropWhileEnd (== '=') (decodeUtf8 (convertToBase @ByteString Base32 secret.bytes))

-- | A secret from its text, ignoring case and spaces; 'Nothing' for one of
-- more than 32 bytes, which the wiki never makes and 'hotp' cannot use.
secretFromText :: Text -> Maybe Secret
secretFromText t =
  let cleaned = T.toUpper (T.filter (\c -> not (isSpace c) && c /= '=') t)
      padded = cleaned <> T.replicate ((8 - T.length cleaned `mod` 8) `mod` 8) "="
   in either (const Nothing) secretOf (convertFromBase Base32 (encodeUtf8 padded))

-- | The URI that gives an application a secret (the "Key Uri Format" that
-- Google Authenticator defined and every application reads): who it is
-- for, as @issuer:account@ in its label, the secret, and the parameters,
-- written out even though they are the defaults. one-time-password's
-- 'OTP.TOTP.totpToURI' is not used: it escapes the URI as a whole, not
-- each part, so an issuer or login with @&@, @?@ or @#@ in it would break
-- the URI, and it writes the parameters in another order.
otpauthUri :: Text -> Text -> Secret -> Text
otpauthUri issuer account secret =
  "otpauth://totp/"
    <> escape issuer
    <> ":"
    <> escape account
    <> "?secret="
    <> secretText secret
    <> "&issuer="
    <> escape issuer
    <> "&algorithm=SHA1&digits=6&period=30"
  where
    escape = decodeUtf8 . urlEncode True . encodeUtf8

-- | A text as a QR code's modules, row by row, @1@ for a dark module and
-- @0@ for a light one, without the quiet zone around it: what the account
-- panel draws ("Wiki.App.View.Security"). Error correction is at level M
-- (15 %), which a phone's camera reads off a screen with room to spare.
-- 'Nothing' for a text too long for any QR code.
qrRows :: Text -> Maybe [Text]
qrRows t = do
  image <- encodeText (defaultQRCodeOptions M) Iso8859_1OrUtf8WithoutECI t
  let size = image.qrImageSize
      cell i = if image.qrImageData V.! i then '1' else '0'
  pure [T.pack [cell (row * size + col) | col <- [0 .. size - 1]] | row <- [0 .. size - 1]]

--------------------------------------------------------------------------------
-- Recovery codes

-- | Ten new recovery codes, each 16 characters of base32 (80 random bits)
-- written in four groups of four, lower case, @abcd-efgh-ijkl-mnop@: easy
-- to read out and type, and too many to guess even against their hashes.
newRecoveryCodes :: IO [Text]
newRecoveryCodes = replicateM 10 $ do
  bytes <- getRandomBytes 10 :: IO ByteString
  let letters = T.toLower (decodeUtf8 (convertToBase @ByteString Base32 bytes))
  pure (T.intercalate "-" (T.chunksOf 4 letters))

-- | The normalised form a typed recovery code is checked by: its letters
-- and digits in lower case, without the dashes and spaces it may have been
-- typed with. 'Nothing' for something that is not a recovery code.
recoveryKey :: Text -> Maybe Text
recoveryKey typed =
  let key = T.toLower (T.filter (\c -> c /= '-' && not (isSpace c)) typed)
   in if T.length key == 16 && T.all (\c -> isAscii c && isAlphaNum c) key then Just key else Nothing
