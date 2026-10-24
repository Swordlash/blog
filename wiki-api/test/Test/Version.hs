-- | A page's version as an entity tag.
module Test.Version (spec) where

import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Protolude
import Test.Gen (genUtcTime)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Web.HttpApiData (parseHeader, parseUrlPiece, toHeader, toUrlPiece)
import Wiki.Api.Version

spec :: Spec
spec = describe "Wiki.Api.Version" $ do
  let t = UTCTime (fromGregorian 2026 10 24) (picosecondsToDiffTime 34212345678000000)

  it "is the time in ISO 8601, quoted, with every digit of the second" $
    toUrlPiece (PageVersion t) `shouldBe` "\"2026-10-24T09:30:12.345678Z\""

  prop "reads back every time exactly, to the picosecond" $ forAll genUtcTime $ \time ->
    parseHeader (toHeader (PageVersion time)) === Right (PageVersion time)

  prop "names a version in a path by its time, read back exactly" $ forAll genUtcTime $ \time ->
    parseUrlPiece (toUrlPiece (VersionTime time)) === Right (VersionTime time)

  it "writes a version's time unquoted, and refuses a piece that is not a time" $ do
    toUrlPiece (VersionTime t) `shouldBe` "2026-10-24T09:30:12.345678Z"
    parseUrlPiece "\"2026-10-24T09:30:12.345678Z\"" `shouldSatisfy` (isLeft :: Either Text VersionTime -> Bool)

  it "refuses a weak tag, an unquoted one and one that is not a time" $ do
    parseUrlPiece "W/\"2026-10-24T09:30:12.345678Z\"" `shouldSatisfy` (isLeft :: Either Text PageVersion -> Bool)
    parseUrlPiece "2026-10-24T09:30:12.345678Z" `shouldSatisfy` (isLeft :: Either Text PageVersion -> Bool)
    parseUrlPiece "\"abc\"" `shouldSatisfy` (isLeft :: Either Text PageVersion -> Bool)
    parseUrlPiece "*" `shouldSatisfy` (isLeft :: Either Text PageVersion -> Bool)
