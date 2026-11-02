-- | Kinds of box ("Wiki.Core.Markdown.Box"): the settings take a kind's
-- name by the rule the parser reads one by, so a kind an administrator
-- defines is always one a page can write, and the stylesheet's own class
-- names cannot be kinds.
module Test.Markdown.Box (spec) where

import Data.Aeson (decode, encode)
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.QuickCheck
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Box
import Wiki.Core.Space (SpaceProfile (..))

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

  it "takes a custom colour as a hex code, in lower case, and refuses anything else" $ do
    map (\k -> k.colour) <$> checkBoxKinds [(named "aside") {colour = CustomColour " #1A7F37 "}] `shouldBe` Right [CustomColour "#1a7f37"]
    for_ ["#1a7f3", "1a7f37", "#1a7f37; x: y", "red", "#gggggg"] $ \c ->
      checkBoxKinds [(named "aside") {colour = CustomColour c}] `shouldSatisfy` isLeft
    readColour "teal" `shouldBe` Just Teal
    readColour "#00AAff" `shouldBe` Just (CustomColour "#00aaff")
    readColour "#00aaf" `shouldBe` Nothing
    decode "\"#00aaff\"" `shouldBe` Just (CustomColour "#00aaff")
    decode "\"url(x)\"" `shouldBe` (Nothing :: Maybe BoxColour)
    encode (CustomColour "#00aaff") `shouldBe` "\"#00aaff\""
    boxStyle (named "aside") {colour = CustomColour "#00aaff"} `shouldBe` "--box-colour: #00aaff"

  it "reads a space written before boxes had numbers as numbering within the page" $ do
    for_ numberings $ \n -> decode (encode n) `shouldBe` Just n
    (\p -> p.boxNumbering) <$> (decode "{\"description\": \"\", \"icon\": null, \"homePage\": null, \"blog\": false}" :: Maybe SpaceProfile) `shouldBe` Just InPage

  it "counts each kind apart, and the sections when they are numbered" $ do
    let count kinds c = evalState (traverse (\k -> state (countBox k)) kinds) c
        page2 form = startCounting Numbering {form, number = Just 2}
    count [Tip, Tip, Note, Custom "exercise", Tip] (page2 InPage) `shouldBe` map Just ["1", "2", "1", "1", "3"]
    count [Tip, Note] (page2 WithPage) `shouldBe` map Just ["2.1", "2.1"]
    count [Tip, Note] (page2 NoNumbers) `shouldBe` [Nothing, Nothing]
    count [Tip, Tip] (countSection (countSection (page2 WithSection))) `shouldBe` map Just ["2.2.1", "2.2.2"]
    count [Tip] (countSection (snd (countBox Tip (page2 WithSection)))) `shouldBe` [Just "2.1.1"]
    count [Tip] (countSection (snd (countBox Tip (page2 WithPage)))) `shouldBe` [Just "2.2"]
    count [Tip, Tip] (startCounting Numbering {form = WithSection, number = Nothing}) `shouldBe` map Just ["1", "2"]

  it "captions a box with its label and number, before its own title" $ do
    boxCaption Nothing Tip (Just "2.1") False `shouldBe` "Tip 2.1"
    boxCaption Nothing Tip (Just "3") True `shouldBe` "Tip 3: "
    boxCaption (Just (named "exercise") {label = "Try it"}) (Custom "exercise") (Just "1") False `shouldBe` "Try it 1"
    boxCaption Nothing Tip Nothing True `shouldBe` ""
    boxCaption Nothing (Custom "fun-fact") Nothing False `shouldBe` "Fun fact"
