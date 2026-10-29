-- | The arithmetic of a second factor ("Wiki.Server.Totp"), against the
-- test vectors of RFC 4226 (HOTP) and RFC 6238 (TOTP), and what is built on
-- it: the window a code is taken in, the secret as text, the address an
-- application reads, its QR code, and the recovery codes.
module Test.Server.Totp (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Protolude
import Test.Hspec
import Wiki.App.View.Security (qrRuns)
import Wiki.Server.Totp

-- | The secret both RFCs test with: the ASCII digits "1234567890" twice.
rfcKey :: ByteString
rfcKey = "12345678901234567890"

-- | A moment, in seconds since the Unix epoch.
at :: Integer -> UTCTime
at = posixSecondsToUTCTime . fromInteger

spec :: Spec
spec = describe "second factor arithmetic" $ do
  it "computes RFC 4226's HOTP values (appendix D) for counters 0 to 9" $
    map (hotp 6 rfcKey) [0 .. 9]
      `shouldBe` map Just ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]

  it "computes RFC 6238's TOTP values with SHA-1 (appendix B), as eight digits, and their last six as an application shows them" $ do
    let vectors =
          [ (59, "94287082")
          , (1111111109, "07081804")
          , (1111111111, "14050471")
          , (1234567890, "89005924")
          , (2000000000, "69279037")
          , (20000000000, "65353130")
          ]
    for_ vectors $ \(seconds, expected) -> do
      hotp 8 rfcKey (counterAt (at seconds)) `shouldBe` Just expected
      hotp 6 rfcKey (counterAt (at seconds)) `shouldBe` Just (T.takeEnd 6 expected)

  it "computes no code for a key it cannot take, of more than 32 bytes, or for fewer than six digits" $ do
    hotp 6 (BS.replicate 33 1) 0 `shouldBe` Nothing
    hotp 6 (BS.replicate 64 1) 0 `shouldBe` Nothing
    hotp 5 rfcKey 0 `shouldBe` Nothing
    hotp 6 (BS.replicate 32 1) 0 `shouldSatisfy` isJust

  it "counts steps of thirty seconds from the epoch" $ do
    map (counterAt . at) [0, 29, 30, 59, 60, 1111111109] `shouldBe` [0, 0, 1, 1, 2, 37037036]

  it "reads the secret as base32, whatever its case and blanks, and writes it back unpadded" $ do
    secret <- maybe (panic "no secret") pure (secretFromText "gezd gnbv gy3t qojq gezd gnbv gy3t qojq")
    secretText secret `shouldBe` "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    codeAt secret (at 59) `shouldBe` "287082"
    secretFromText "not base32!" `shouldBe` Nothing

  it "takes a code a step either side of now, once, and not one from further away" $ do
    secret <- maybe (panic "no secret") pure (secretFromText "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    let now = at 1111111111
        step = counterAt now
        codeFor offset = codeAt secret (addUTCTime (fromInteger (30 * offset)) now)
    matchingCounter secret now Nothing (codeFor 0) `shouldBe` Just step
    matchingCounter secret now Nothing (codeFor (-1)) `shouldBe` Just (step - 1)
    matchingCounter secret now Nothing (codeFor 1) `shouldBe` Just (step + 1)
    matchingCounter secret now Nothing (codeFor 2) `shouldBe` Nothing
    matchingCounter secret now Nothing (codeFor (-2)) `shouldBe` Nothing
    -- Typed with a blank in the middle, as some applications show it.
    matchingCounter secret now Nothing (T.take 3 (codeFor 0) <> " " <> T.drop 3 (codeFor 0)) `shouldBe` Just step
    -- Used already: not again, nor one before it.
    matchingCounter secret now (Just step) (codeFor 0) `shouldBe` Nothing
    matchingCounter secret now (Just step) (codeFor (-1)) `shouldBe` Nothing
    matchingCounter secret now (Just step) (codeFor 1) `shouldBe` Just (step + 1)
    matchingCounter secret now Nothing "000000x" `shouldBe` Nothing

  it "makes new secrets of 160 random bits" $ do
    a <- newSecret
    b <- newSecret
    a `shouldNotBe` b
    T.length (secretText a) `shouldBe` 32
    show a `shouldBe` ("Secret <hidden>" :: Text)

  it "writes the address an application reads, its label and issuer escaped" $ do
    secret <- maybe (panic "no secret") pure (secretFromText "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    otpauthUri "Wiki wiki.example.org" "ada" secret
      `shouldBe` "otpauth://totp/Wiki%20wiki.example.org:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Wiki%20wiki.example.org&algorithm=SHA1&digits=6&period=30"

  it "draws the address as a QR code: square, of a version's size, with its three finder patterns" $ do
    secret <- newSecret
    rows <- maybe (panic "no QR code") pure (qrRows (otpauthUri "Wiki wiki.example.org" "a-rather-long-login.of-forty-characters" secret))
    let size = length rows
    all ((== size) . T.length) rows `shouldBe` True
    -- 21 modules for version 1, four more for each version after.
    (size - 21) `mod` 4 `shouldBe` 0
    size `shouldSatisfy` (> 21)
    let finder = ["1111111", "1000001", "1011101", "1011101", "1011101", "1000001", "1111111"]
        square x y = [T.take 7 (T.drop x r) | r <- take 7 (drop y rows)]
    square 0 0 `shouldBe` finder
    square (size - 7) 0 `shouldBe` finder
    square 0 (size - 7) `shouldBe` finder
    qrRows (T.replicate 4000 "x") `shouldBe` Nothing

  it "draws a QR code's rows as runs of dark modules" $
    qrRuns ["1101", "0111", "0000"] `shouldBe` [(0, 0, 2), (3, 0, 1), (1, 1, 3)]

  it "makes ten recovery codes, each 80 random bits in four groups, read back whatever their case and dashes" $ do
    codes <- newRecoveryCodes
    length codes `shouldBe` 10
    length (ordNub codes) `shouldBe` 10
    for_ codes $ \c -> do
      T.length c `shouldBe` 19
      map T.length (T.splitOn "-" c) `shouldBe` [4, 4, 4, 4]
      recoveryKey c `shouldBe` Just (T.filter (/= '-') c)
      recoveryKey (T.toUpper (T.replace "-" " " c)) `shouldBe` Just (T.filter (/= '-') c)
    recoveryKey "123456" `shouldBe` Nothing
