-- | The state the shell keeps in the session history's entries
-- ("Wiki.App.Browser"): what is written is read back, in each of its
-- forms, and an entry with no state is an unnumbered one. The entries the
-- previous version wrote as objects are read in a browser only
-- ("Test.Browser.Entries").
module Test.Entries (spec) where

import Data.Foreign (toForeign)
import Protolude
import Test.Hspec
import Wiki.App.Browser (EntryState (..), readEntryState, writeEntryState)

spec :: Spec
spec = describe "the session history's entry state" $ do
  it "reads back each form it writes" $
    for_ [EntryState (Just 12) False, EntryState (Just 12) True, EntryState Nothing True, EntryState Nothing False] $ \entry ->
      readEntryState (writeEntryState entry) `shouldBe` entry
  it "reads an entry with no state as unnumbered and not the preview's" $
    readEntryState (toForeign ()) `shouldBe` EntryState Nothing False
