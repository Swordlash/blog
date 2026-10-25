-- | Who edits which page, as the live channel keeps it
-- ("Wiki.Server.Presence"), by itself: a tab that opens an editor, says so
-- twice, closes it; one person in two tabs counted once; a tab never told
-- of itself; a connection that ends taking its editing with it.
module Test.Server.Presence (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Id (PageId (..), UserId (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Presence

ada, edgar :: Author
ada = Author {id = UserId "user-admin", name = "Ada Admin"}
edgar = Author {id = UserId "user-editor", name = "Edgar Editor"}

notes, hello :: PageId
notes = PageId "notes"
hello = PageId "hello"

-- | A change, keeping only the presence it leaves.
then' :: (Presence -> (Presence, b)) -> Presence -> Presence
then' change = fst . change

spec :: Spec
spec = describe "who edits which page" $ do
  it "starts with nobody, and names whoever opens an editor to every other connection" $ do
    editorsFor 1 notes nobodyEditing `shouldBe` []
    let p = then' (startEditing 2 notes edgar) nobodyEditing
    editorsFor 1 notes p `shouldBe` [edgar]
    editorsFor 3 notes p `shouldBe` [edgar]
    editorsFor 1 hello p `shouldBe` []
    -- Never the connection itself.
    editorsFor 2 notes p `shouldBe` []

  it "says whether a change changed anything" $ do
    let (p, started) = startEditing 2 notes edgar nobodyEditing
    started `shouldBe` True
    snd (startEditing 2 notes edgar p) `shouldBe` False
    snd (stopEditing 2 notes p) `shouldBe` True
    snd (stopEditing 2 hello p) `shouldBe` False
    snd (stopEditing 3 notes p) `shouldBe` False

  it "names a person editing in two tabs once, in the order the connections came" $ do
    let p = then' (startEditing 4 notes ada) (then' (startEditing 3 notes edgar) (then' (startEditing 2 notes ada) nobodyEditing))
    editorsFor 1 notes p `shouldBe` [ada, edgar]
    -- Ada's other tab hears of her first tab, and of Edgar.
    editorsFor 4 notes p `shouldBe` [ada, edgar]
    editorsFor 3 notes p `shouldBe` [ada]

  it "stops naming a tab that closed its editor, and keeps what else it edits" $ do
    let p = then' (startEditing 2 hello edgar) (then' (startEditing 2 notes edgar) nobodyEditing)
        q = then' (stopEditing 2 notes) p
    editorsFor 1 notes q `shouldBe` []
    editorsFor 1 hello q `shouldBe` [edgar]
    editedBy 2 q `shouldBe` [hello]
    then' (stopEditing 2 hello) q `shouldBe` nobodyEditing

  it "drops everything a connection edited when it ends, and says which pages" $ do
    let p = then' (startEditing 3 notes ada) (then' (startEditing 2 hello edgar) (then' (startEditing 2 notes edgar) nobodyEditing))
        (q, edited) = leave 2 p
    sort edited `shouldBe` sort [notes, hello]
    editorsFor 1 notes q `shouldBe` [ada]
    editorsFor 1 hello q `shouldBe` []
    snd (leave 2 q) `shouldBe` []
