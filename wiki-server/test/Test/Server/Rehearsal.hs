-- | The upgrade's rehearsal (WP5.75 of docs/PLAN.md, "Wiki.Server.Rehearsal"):
-- the pages check's comparison of the pages read before the migration
-- with those read after. The rehearsal itself runs two programs, and is
-- tested end to end by toolchain/rehearse-ci.sh in CI.
module Test.Server.Rehearsal (unitSpec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Server.Rehearsal (PageRead (..), comparePages)

unitSpec :: Spec
unitSpec = describe "the upgrade's rehearsal, the pages check" $ do
  let first' = PageRead {space = "s1", page = "p1", title = "First", body = "# First\n\nText."}
      second' = PageRead {space = "s1", page = "p2", title = "Second", body = "More."}
  it "passes when every page reads the same, in whatever order" $
    comparePages [first', second'] [second', first'] `shouldBe` Right ()
  it "names a page whose source changed, one whose title changed, one gone and one new" $ do
    let changed = first' {body = "# First\n\nOther text."}
        renamed = second' {title = "Second, renamed"}
        third = PageRead {space = "s2", page = "p3", title = "Third", body = ""}
        why = either identity (const "") (comparePages [first', second'] [changed, renamed, third])
    why `shouldSatisfy` T.isInfixOf "page p1 (First) has another source"
    why `shouldSatisfy` T.isInfixOf "page p2 (Second) has another title: Second, renamed"
    why `shouldSatisfy` T.isInfixOf "page p3 (Third) is new"
    comparePages [first', second'] [first'] `shouldSatisfy` isLeft
  it "tells the same page id in two spaces apart" $
    comparePages [first'] [first' {space = "s2"}] `shouldSatisfy` isLeft
  it "names five differences and counts the rest" $ do
    let pages = [PageRead {space = "s", page = show i, title = "t", body = "b"} | i <- [1 .. 8 :: Int]]
        why = either identity (const "") (comparePages pages [])
    why `shouldSatisfy` T.isInfixOf "and 3 more"
