-- | Kinds of box ("Wiki.Core.Markdown.Box"): the settings take a kind's
-- name by the rule the parser reads one by, so a kind an administrator
-- defines is always one a page can write, and the stylesheet's own class
-- names cannot be kinds.
module Test.Markdown.Box (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.QuickCheck
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Box

-- | A kind of box with this name, as typed.
named :: Text -> BoxKind
named name = BoxKind {name, label = "", colour = Blue, icon = NoIcon}

-- | Names of a few characters, from those a name has and some it may not.
names :: Gen Text
names = T.pack <$> resize 8 (listOf (elements "abzAZ-_ 1é"))

-- | Whether a page reads a box of its own kind with this name.
pageReads :: Text -> Bool
pageReads name = case parseMarkdown ("> [!" <> name <> "]\n> x") of
  Right [Alert (Custom k) _ _] -> k == T.toLower name
  _ -> False

spec :: Spec
spec = describe "Markdown.Box" $ do
  it "takes in the settings exactly the names a page reads as kinds of its own" $
    property $
      forAll names $ \name ->
        let trimmed = T.strip name
         in (trimmed == name) ==> isRight (checkBoxKinds [named name]) === pageReads name

  it "refuses the five, and the names of a box's own parts" $
    for_ ["note", "Tip", "title", "icon", "ICON"] $ \name -> do
      checkBoxKinds [named name] `shouldSatisfy` isLeft
      validKindName (T.toLower name) `shouldBe` False

  it "reads a quotation marked with a part's name as a quotation" $
    for_ ["TITLE", "ICON"] $ \name ->
      parseMarkdown ("> [!" <> name <> "]\n> x") `shouldBe` Right [BlockQuote [Para [Str ("[!" <> name <> "]"), SoftBreak, Str "x"]]]

  it "titles a box with its definition's label, or its kind's name" $ do
    boxLabel (Just (named "exercise") {label = "Try it"}) (Custom "exercise") `shouldBe` "Try it"
    boxLabel (Just (named "fun-fact")) (Custom "fun-fact") `shouldBe` "Fun fact"
    boxLabel Nothing Note `shouldBe` "Note"
    definedKind [named "note"] Note `shouldBe` Nothing
    definedKind [named "aside"] (Custom "aside") `shouldBe` Just (named "aside")
