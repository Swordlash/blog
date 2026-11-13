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
      firstChain "o" `shouldBe` Chain 1 Nothing (Just "o")
      chainAfter "t1" (Just (firstChain "o")) `shouldBe` Chain 2 (Just "t1") (Just "o")
      chainAfter "t2" (Just (Chain 2 (Just "t1") Nothing)) `shouldBe` Chain 3 (Just "t2") Nothing
      -- On a version of format 1, which has no number: the first of the
      -- chain, naming it.
      chainAfter "old" Nothing `shouldBe` Chain 1 (Just "old") Nothing

    it "binds the chain into the additional data, apart from format 1's" $ do
      let at = contentData (SpaceId "s") (PageId "p") (KeyId "k") "t2"
      at Nothing TitleField `shouldBe` fieldData (SpaceId "s") (PageId "p") (KeyId "k") "t2" TitleField
      at (Just (Chain 2 (Just "t1") Nothing)) TitleField `shouldBe` "wiki-page/2 s p k t2 2 t1 title"
      at (Just (firstChain "o")) BodyField `shouldBe` "wiki-page/3 s p k t2 1 - o body"
      at (Just (Chain 1 Nothing Nothing)) BodyField `shouldBe` "wiki-page/2 s p k t2 1 - body"
      -- Another number, another previous version, another origin, another
      -- field: other data.
      length (ordNub [at c f | c <- [Nothing, Just (firstChain "o"), Just (firstChain "p"), Just (Chain 2 (Just "t1") Nothing), Just (Chain 2 (Just "t0") Nothing)], f <- [TitleField, BodyField]]) `shouldBe` 10

    it "keeps a version's chain in its JSON, and reads a version of format 1 without one" $ do
      let contentWith chain = SealedContent {tag = "t2", keyId = KeyId "k", chain, title = sealed, body = sealed}
          content = contentWith (Just (Chain 2 (Just "t1") Nothing))
      eitherDecode (encode content) `shouldBe` Right content
      eitherDecode (encode (contentWith Nothing)) `shouldBe` Right (contentWith Nothing)
      ("chain" `T.isInfixOf` decodeUtf8 (toS (encode (contentWith Nothing)))) `shouldBe` False
      eitherDecode (encode (headingOf content)) `shouldBe` Right (headingOf content)

  describe "a browser's checks" $ do
    let seen = Seen {number = 5, tag = "t5", origin = Nothing}
    it "takes the latest version when it is the one seen, or later, or when none was seen" $ do
      judgeHead [] "t1" (Just (firstChain "o")) `shouldBe` Right Agrees
      judgeHead [] "old" Nothing `shouldBe` Right Agrees
      judgeHead [seen] "t5" (Just (Chain 5 (Just "t4") Nothing)) `shouldBe` Right Agrees
      judgeHead [seen] "t7" (Just (Chain 7 (Just "t6") Nothing)) `shouldBe` Right (Advanced 2)

    it "finds a latest version older than the one seen, or another one under the same number" $ do
      judgeHead [seen] "t4" (Just (Chain 4 (Just "t3") Nothing)) `shouldBe` Left (Older 5 4)
      judgeHead [seen] "old" Nothing `shouldBe` Left (Older 5 0)
      judgeHead [seen] "x5" (Just (Chain 5 (Just "t4") Nothing)) `shouldBe` Left (Forked 5)

    it "takes a later version only when the history starts at it and joins it, version by version, to the one seen" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int)))) Nothing))
      linkedFrom seen (v 7) [v 7, v 6, v 5, v 4] `shouldBe` Right ()
      -- Over two pages of the history, in order: the join between them is
      -- checked as any other.
      linkedFrom seen (v 7) ([v 7, v 6] <> [v 5, v 4]) `shouldBe` Right ()
      linkedFrom seen (v 7) ([v 7, v 6] <> [v 4]) `shouldBe` Left (Gap 4)
      -- Version 6 is missing, or out of order.
      linkedFrom seen (v 7) [v 7, v 5] `shouldBe` Left (Gap 5)
      linkedFrom seen (v 7) [v 7, v 5, v 6] `shouldBe` Left (Gap 5)
      -- Another editor saved since the page was read: the history starts
      -- above the version checked, which it still joins to the one seen.
      linkedFrom seen (v 7) [v 9, v 8, v 7, v 6, v 5] `shouldBe` Right ()

    it "refuses a later version that the history does not join to the version seen" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int)))) Nothing))
          forked6 = ("f6", Just (Chain 6 (Just "t5") Nothing))
      -- The review's case: a forked version 6 shown, a history of the
      -- authentic version 5 alone.
      linkedFrom seen forked6 [v 5] `shouldBe` Left (Unlinked 5 6)
      -- The history without the version shown.
      linkedFrom seen forked6 [v 6, v 5] `shouldBe` Left (Unlinked 5 6)
      linkedFrom seen forked6 [v 7, v 6, v 5] `shouldBe` Left (Unlinked 5 6)
      linkedFrom seen (v 7) [v 6, v 5] `shouldBe` Left (Unlinked 5 7)
      linkedFrom seen (v 7) [] `shouldBe` Left (Unlinked 5 7)
      -- A history that stops above the version seen.
      linkedFrom seen (v 9) [v 9, v 8, v 7] `shouldBe` Left (Unlinked 5 9)
      -- One that reaches its number with another version: not where the
      -- version above it names, or, named by it, not the one seen.
      linkedFrom seen (v 6) [v 6, ("x5", Just (Chain 5 (Just "t4") Nothing))] `shouldBe` Left (Gap 5)
      linkedFrom seen ("t6", Just (Chain 6 (Just "x5") Nothing)) [("t6", Just (Chain 6 (Just "x5") Nothing)), ("x5", Just (Chain 5 (Just "t4") Nothing))] `shouldBe` Left (Forked 5)
      -- A forked 6 that names the version seen joins it: a version this
      -- browser has not read, after the one it read, is no fork.
      linkedFrom seen forked6 [forked6, v 5] `shouldBe` Right ()

    it "remembers a version only forward, and a fork not at all" $ do
      keepIn [] seen `shouldBe` (KeptNow, [seen])
      keepIn [seen] Seen {number = 6, tag = "t6", origin = Nothing} `shouldBe` (KeptNow, [Seen {number = 6, tag = "t6", origin = Nothing}])
      keepIn [seen] seen `shouldBe` (KeptNow, [seen])
      keepIn [seen] Seen {number = 4, tag = "t4", origin = Nothing} `shouldBe` (KeptLater, [seen])
      keepIn [seen] Seen {number = 5, tag = "x5", origin = Nothing} `shouldBe` (KeptFork, [seen])

    -- #213: a page encrypted again starts a new chain, which the browser
    -- that encrypts it names (its origin, bound by every version's
    -- encryption): a reader who read the old one takes it, and keeps the
    -- old chain's record, so that the old chain shown again is caught.
    it "takes a page encrypted again as a new chain, and the chain before it shown again as the page as it was" $ do
      let again = Seen {number = 2, tag = "n2", origin = Just "o2"}
          first' = Seen {number = 5, tag = "t5", origin = Just "o1"}
      -- Read under the first encryption, then under the second.
      judgeHead [first'] "n1" (Just (firstChain "o2")) `shouldBe` Right Agrees
      judgeHead [seen] "n1" (Just (firstChain "o2")) `shouldBe` Right Agrees
      keepIn [first'] Seen {number = 1, tag = "n1", origin = Just "o2"} `shouldBe` (KeptNow, [first', Seen {number = 1, tag = "n1", origin = Just "o2"}])
      let both = [first', again]
      -- Within the latest chain, as before: a fork is a fork.
      judgeHead both "x2" (Just (Chain 2 (Just "n1") (Just "o2"))) `shouldBe` Left (Forked 2)
      judgeHead both "n3" (Just (Chain 3 (Just "n2") (Just "o2"))) `shouldBe` Right (Advanced 1)
      -- The first chain shown again, at the version read or past it, and a
      -- version from before chains had origins: the page as it was.
      judgeHead both "t5" (Just (Chain 5 (Just "t4") (Just "o1"))) `shouldBe` Left Superseded
      judgeHead both "t6" (Just (Chain 6 (Just "t5") (Just "o1"))) `shouldBe` Left Superseded
      judgeHead both "t5" (Just (Chain 5 (Just "t4") Nothing)) `shouldBe` Left Superseded
      judgeHead both "old" Nothing `shouldBe` Left Superseded
      -- Remembered: the earlier chain stays as it was, and a version of it
      -- is not remembered over the latest.
      keepIn both Seen {number = 6, tag = "t6", origin = Just "o1"} `shouldBe` (KeptLater, both)
      keepIn both Seen {number = 3, tag = "n3", origin = Just "o2"} `shouldBe` (KeptNow, [first', Seen {number = 3, tag = "n3", origin = Just "o2"}])
      -- A version of one chain does not follow on a version of another.
      linkedFrom again ("n3", Just (Chain 3 (Just "n2") (Just "o3"))) [("n3", Just (Chain 3 (Just "n2") (Just "o3"))), ("n2", Just (Chain 2 (Just "n1") (Just "o2")))] `shouldBe` Left (Gap 2)

    it "reads what a browser remembered before origins as the record of the chain without one" $
      eitherDecode "{\"number\":5,\"tag\":\"t5\"}" `shouldBe` Right seen

    it "finds the first break in a page of the history, across the versions of format 1 too" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int)))) Nothing))
          t0 = ("t0", Nothing)
      gapIn [v 3, v 2, v 1, t0, ("older", Nothing)] `shouldBe` Nothing
      gapIn [v 3, v 1, t0] `shouldBe` Just (Gap 1)
      gapIn [v 2, v 1, ("other", Nothing)] `shouldBe` Just (Gap 0)
      -- A version of format 1 after a numbered one: the history was cut.
      gapIn [("late", Nothing), v 1, t0] `shouldBe` Just (Gap 1)

    -- The ends of a whole history, which no neighbour vouches for: its
    -- oldest version must be a chain's first. The boundary of chains begun
    -- on a page written before versions were chained: version 1 names the
    -- version of format 1 below it, which must be there; versions of
    -- format 1 below that cannot be checked.
    it "finds a whole history that does not begin where its chain begins" $ do
      let v n = (VersionTag ("t" <> show n), Just (Chain n (Just (VersionTag ("t" <> show (n - 1 :: Int)))) Nothing))
          o n = (VersionTag ("o" <> show n), Just (Chain n (if n == 1 then Nothing else Just (VersionTag ("o" <> show (n - 1 :: Int)))) (Just "origin")))
          t0 = ("t0", Nothing)
      -- A chain of its own origin, from its first: whole; its first left out.
      historyStart [o 3, o 2, o 1] `shouldBe` Nothing
      historyStart [o 3, o 2] `shouldBe` Just (Truncated 2)
      gapIn [o 3, o 2] `shouldBe` Nothing
      -- A chain begun on a page of format 1: whole with the version it
      -- names, and with any versions of format 1 below that; cut without it.
      historyStart [v 2, v 1, t0] `shouldBe` Nothing
      historyStart [v 2, v 1, t0, ("older", Nothing)] `shouldBe` Nothing
      historyStart [v 2, v 1] `shouldBe` Just (Truncated 1)
      historyStart [v 3, v 2] `shouldBe` Just (Truncated 2)
      -- The first version of a page chained before origins (number 1,
      -- after nothing), and a page of format 1 alone.
      historyStart [("u2", Just (Chain 2 (Just "u1") Nothing)), ("u1", Just (Chain 1 Nothing Nothing))] `shouldBe` Nothing
      historyStart [t0] `shouldBe` Nothing
      historyStart [] `shouldBe` Nothing
  where
    sealed = Sealed (Nonce "n") (Ciphertext "c")
