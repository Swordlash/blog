-- | The server's SHA-256 ("Wiki.Server.Sha256"): NIST's known answers,
-- and for each digest the server stores or compares with a stored one,
-- the value cryptohash-sha256 computed for it before the server moved to
-- crypton. Those values were computed with the earlier library and written
-- here as constants: a stored blob, session hash, key id or guide record
-- must still be found after the change.
module Test.Server.Sha256 (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Wiki.Core.Id (BlobId (..))
import Wiki.Core.Vault (KeyId (..), PublicKey (..))
import Wiki.Server.Guide (writtenHash)
import Wiki.Server.Oidc (challengeOf)
import Wiki.Server.Password (tokenHash)
import Wiki.Server.Sha256 (sha256, sha256Finalize, sha256Init, sha256Update)
import Wiki.Server.Storage.Blobs (blobOf, storeBlobFile)
import Wiki.Server.Vault (keyIdOf)

spec :: Spec
spec = describe "SHA-256" $ do
  it "gives NIST's digests of the empty string, of abc and of a million a's" $ do
    hex (sha256 "") `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    hex (sha256 "abc") `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    hex (sha256 (BS.replicate 1000000 97)) `shouldBe` "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  it "gives 32 bytes, and the same digest in parts as at once" $ do
    BS.length (sha256 "abc") `shouldBe` 32
    let parts = ["", "a", "bc", BS.replicate 70000 120, "", "end"]
    sha256Finalize (foldl' sha256Update sha256Init parts) `shouldBe` sha256 (mconcat parts)
    sha256Finalize sha256Init `shouldBe` sha256 ""

  describe "the stored digests, as cryptohash-sha256 computed them" $ do
    it "a session id's hash, which the database keeps" $
      tokenHash "wiki-session-0123456789abcdef" `shouldBe` "b6822e7518da93e52c911057392dbb89c1b1995c2c49892912a69f906e7ad9ca"

    it "a vault key's id, the start of its public key's digest" $
      fmap (\k -> k.text) (keyIdOf (PublicKey "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")) `shouldBe` Just "Yw3NKWbEM2aRElRIu7JbTw"

    it "the guide's record of a page's title and text" $
      writtenHash "Getting started" "# Welcome\n\nThis is the guide. Zażółć gęślą jaźń." `shouldBe` "7b11c67c09e40919bb5b9cd9223f43ad649fab692dfaa425286f8ccfb2797336"

    it "a blob's id, which names its file" $
      (blobOf "hello attachment\n").text `shouldBe` "2852d7262f1fd6339a426560101d5840edf5b8999b90eb6b2eea86c8b9f7e298"

    it "a blob stored from a file, hashed in chunks of 64 KiB" $
      withSystemTempDirectory "wiki-sha256" $ \dir -> do
        -- 200001 bytes: three whole chunks and part of a fourth.
        let bytes = BS.pack [fromIntegral ((i * 7 + 3) `mod` 256) | i <- [0 .. 200000 :: Int]]
            expected = "1970db0a48824f8ba0539caee0025c2187acb21292b6e104aee526cd437121c1"
        BS.writeFile (dir </> "upload") bytes
        (blob, size) <- storeBlobFile (dir </> "blobs") (dir </> "upload")
        (blob.text, size) `shouldBe` (expected, 200001)
        (blobOf bytes).text `shouldBe` expected
        BS.readFile (dir </> "blobs" </> "19" </> toS expected) `shouldReturn` bytes

  it "the PKCE challenge of a sign-in's verifier, which the provider compares" $
    challengeOf "dBjftJeZ4CVP-mB92K0uhvzW8xQlvBzbn2GuzsGhvWg" `shouldBe` "3NiU-6Omfe9UImQMbWKazU98DbCoyCs5UxUqiY_xRS0"
  where
    hex :: ByteString -> Text
    hex = decodeUtf8 . BSL.toStrict . toLazyByteString . byteStringHex
