-- | The chain of a page's versions in an encrypted space
-- ("Wiki.Core.Encrypted", WP5.74b3 of docs/PLAN.md): each version's
-- number and the previous version's tag, in its additional data, and a
-- browser's checks of what the server sends against what it read before.
module Test.Encrypted (spec) where

import Data.Aeson (eitherDecode, encode)
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Encrypted
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), Sealed (..))

spec :: Spec
spec = describe "Wiki.Core.Encrypted" $ do
  describe "the chain of versions" $ do
    it "numbers a page's first version 1, naming no version before it, and each next one after the one it is saved on" $ do
      firstChain `shouldBe` Chain 1 Nothing
      chainAfter "t1" (Just firstChain) `shouldBe` Chain 2 (Just "t1")
      chainAfter "t2" (Just (Chain 2 (Just "t1"))) `shouldBe` Chain 3 (Just "t2")
      -- On a version of format 1, which has no number: the first of the
      -- chain, naming it.
      chainAfter "old" Nothing `shouldBe` Chain 1 (Just "old")

    it "binds the chain into the additional data, apart from format 1's" $ do
      let at = contentData (SpaceId "s") (PageId "p") (KeyId "k") "t2"
      at Nothing TitleField `shouldBe` fieldData (SpaceId "s") (PageId "p") (KeyId "k") "t2" TitleField
      at (Just (Chain 2 (Just "t1"))) TitleField `shouldBe` "wiki-page/2 s p k t2 2 t1 title"
      at (Just firstChain) BodyField `shouldBe` "wiki-page/2 s p k t2 1 - body"
      -- Another number, another previous version, another field: other data.
      length (ordNub [at c f | c <- [Nothing, Just firstChain, Just (Chain 2 (Just "t1")), Just (Chain 2 (Just "t0"))], f <- [TitleField, BodyField]]) `shouldBe` 8

    it "keeps a version's chain in its JSON, and reads a version of format 1 without one" $ do
      let contentWith chain = SealedContent {tag = "t2", keyId = KeyId "k", chain, title = sealed, body = sealed}
          content = contentWith (Just (Chain 2 (Just "t1")))
      eitherDecode (encode content) `shouldBe` Right content
      eitherDecode (encode (contentWith Nothing)) `shouldBe` Right (contentWith Nothing)
      ("chain" `T.isInfixOf` decodeUtf8 (toS (encode (contentWith Nothing)))) `shouldBe` False
      eitherDecode (encode (headingOf content)) `shouldBe` Right (headingOf content)

  describe "a browser's checks" $ do
    let seen = Seen {number = 5, tag = "t5"}
    it "takes the latest version when it is the one seen, or later, or when none was seen" $ do
      judgeHead Nothing "t1" (Just firstChain) `shouldBe` Right Agrees
      judgeHead Nothing "old" Nothing `shouldBe` Right Agrees
      judgeHead (Just seen) "t5" (Just (Chain 5 (Just "t4"))) `shouldBe` Right Agrees
      judgeHead (Just seen) "t7" (Just (Chain 7 (Just "t6"))) `shouldBe` Right (Advanced 2)

    it "finds a latest version older than the one seen, or another one under the same number" $ do
      judgeHead (Just seen) "t4" (Just (Chain 4 (Just "t3"))) `shouldBe` Left (Older 5 4)
      judgeHead (Just seen) "old" Nothing `shouldBe` Left (Older 5 0)
      judgeHead (Just seen) "x5" (Just (Chain 5 (Just "t4"))) `shouldBe` Left (Forked 5)

    it "follows a run of versions down to the one seen, and finds a missing, reordered or forked one" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int))))))
      linkedDown seen [v 7, v 6, v 5, v 4] `shouldBe` Right True
      -- The run ends before the version seen: every link holds, unchecked
      -- below.
      linkedDown seen [v 9, v 8, v 7] `shouldBe` Right False
      -- Version 6 is missing.
      linkedDown seen [v 7, v 5] `shouldBe` Left (Gap 5)
      -- Reordered.
      linkedDown seen [v 6, v 7, v 5] `shouldBe` Left (Gap 7)
      -- Another version 5 than the one seen.
      linkedDown seen [v 6, ("x5", Just (Chain 5 (Just "t4")))] `shouldBe` Left (Gap 5)
      linkedDown seen [("t6", Just (Chain 6 (Just "x5"))), ("x5", Just (Chain 5 (Just "t4")))] `shouldBe` Left (Forked 5)

    it "finds the first break in a page of the history, across the versions of format 1 too" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int))))))
          t0 = ("t0", Nothing)
      gapIn [v 3, v 2, v 1, t0, ("older", Nothing)] `shouldBe` Nothing
      gapIn [v 3, v 1, t0] `shouldBe` Just (Gap 1)
      gapIn [v 2, v 1, ("other", Nothing)] `shouldBe` Just (Gap 0)
      -- A version of format 1 after a numbered one: the history was cut.
      gapIn [("late", Nothing), v 1, t0] `shouldBe` Just (Gap 1)
  where
    sealed = Sealed (Nonce "n") (Ciphertext "c")
