module Test.Search (spec) where

import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, arbitrary, chooseInt, elements, forAll, frequency, listOf, listOf1, vectorOf, (===))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search
import Wiki.Core.Slug (Slug, foldLetter, mkSlug)

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

-- | A page with a title and a body, in a space, at a path given as slugs.
page :: Text -> Text -> Text -> [Text] -> Candidate
page spaceSlug title body path =
  candidate
    Page
      { id = PageId (T.intercalate "/" (spaceSlug : path))
      , space = SpaceId spaceSlug
      , parent = Nothing
      , title
      , slug = slug (fromMaybe "page" (lastMay path))
      , body
      , attachments = []
      , createdAt = epoch
      , updatedAt = epoch
      , position = 0
      }
    [slug spaceSlug]
    (map slug path)
  where
    epoch = UTCTime (fromGregorian 2026 1 1) 0

search :: Text -> [Candidate] -> [SearchHit]
search text = searchPlain (searchQuery text)

titles :: [SearchHit] -> [Text]
titles = map (\h -> snippetText h.title)

marks :: Snippet -> [Text]
marks (Snippet pieces) = [p.text | p <- pieces, p.match]

pages :: [Candidate]
pages =
  [ page "docs" "Diagrams" "A `mermaid` fence is drawn by **Mermaid**.\n\n```mermaid\nflowchart TD\n  A --> B\n```" ["diagrams"]
  , page "docs" "Mathematics" "Formulas: $e^{i\\pi} = -1$, drawn by KaTeX." ["mathematics"]
  , page "blog" "Mermaid tails" "A post about fish, not diagrams." ["mermaid-tails"]
  , page "blog" "Zażółć gęślą jaźń" "Polish, with every diacritic. Straße too." ["zazolc"]
  ]

spec :: Spec
spec = describe "Wiki.Core.Search" $ do
  describe "searchPlain" $ do
    it "finds nothing for a query with no words" $ do
      search "" pages `shouldBe` []
      search "   \t " pages `shouldBe` []

    it "ignores case" $ do
      titles (search "MERMAID" pages) `shouldBe` ["Mermaid tails", "Diagrams"]
      titles (search "katex" pages) `shouldBe` ["Mathematics"]

    it "ignores diacritics, as slugs do, and marks the characters as written" $ do
      let hits = search "zazolc GESLA" pages
      titles hits `shouldBe` ["Zażółć gęślą jaźń"]
      map (\h -> marks h.title) hits `shouldBe` [["Zażółć", "gęślą"]]
      titles (search "strasse" pages) `shouldBe` ["Zażółć gęślą jaźń"]
      map (\h -> marks h.snippet) (search "strasse" pages) `shouldBe` [["Straße"]]

    it "wants every word, each in the title or the text, so that a word more narrows" $ do
      titles (search "mermaid" pages) `shouldBe` ["Mermaid tails", "Diagrams"]
      titles (search "mermaid flow" pages) `shouldBe` ["Diagrams"]
      titles (search "mermaid flow xyzzy" pages) `shouldBe` []
      titles (search "tails fish" pages) `shouldBe` ["Mermaid tails"]

    it "searches the text a reader sees, not the Markdown's syntax" $ do
      search "**" pages `shouldBe` []
      search "```" pages `shouldBe` []
      map (\h -> marks h.snippet) (search "drawn by mermaid" (take 1 pages))
        `shouldBe` [["mermaid", "drawn", "by", "Mermaid"]]

    it "searches the sources of code, diagrams and formulas" $ do
      titles (search "flowchart" pages) `shouldBe` ["Diagrams"]
      titles (search "e^{i\\pi}" pages) `shouldBe` ["Mathematics"]

    it "searches the text of HTML in a page, not its tags or what it drops" $ do
      let html = [page "docs" "Markup" "<details>\n<summary>Spoiler</summary>\n<b>hidden</b> answer\n</details>\n\n<div><script>secret()</script></div>" ["markup"]]
      titles (search "spoiler hidden answer" html) `shouldBe` ["Markup"]
      search "details" html `shouldBe` []
      search "secret" html `shouldBe` []

    it "ranks a match in the title above one in the text" $ do
      titles (search "diagrams" pages) `shouldBe` ["Diagrams", "Mermaid tails"]

    it "ranks more of the words in the title above fewer" $ do
      let ps = [page "a" "Alpha" "beta gamma" ["one"], page "b" "Alpha beta" "gamma" ["two"], page "c" "Other" "alpha beta gamma" ["three"]]
      titles (search "alpha beta gamma" ps) `shouldBe` ["Alpha beta", "Alpha", "Other"]

    it "breaks ties by the space's path, then the page's" $ do
      let ps = [page "b" "Note" "x" ["a"], page "a" "Note" "x" ["z"], page "a" "Note" "x" ["b"]]
      map (\h -> (h.spacePath, h.pagePath)) (search "note" ps)
        `shouldBe` [([slug "a"], [slug "b"]), ([slug "a"], [slug "z"]), ([slug "b"], [slug "a"])]

    it "gives at most the limit" $ do
      let q = (searchQuery "mermaid") {limit = 1}
      titles (searchPlain q pages) `shouldBe` ["Mermaid tails"]
      searchPlain q {limit = 0} pages `shouldBe` []

    it "gives each hit its page, space and paths" $
      case search "katex" pages of
        [h] -> (h.page, h.space, h.spacePath, h.pagePath) `shouldBe` (PageId "docs/mathematics", SpaceId "docs", [slug "docs"], [slug "mathematics"])
        hits -> expectationFailure ("expected one hit, got " <> show hits)

  describe "a snippet" $ do
    let long = T.unwords (replicate 40 "lorem ipsum") <> " the needle is here " <> T.unwords (replicate 40 "dolor sit")
        hitIn body = single (search "needle" [page "s" "Long" body ["long"]])

    it "is the start of the text when only the title matched" $ do
      h <- single (search "long" [page "s" "Long" long ["long"]])
      h.snippet `shouldBe` Snippet [Piece (T.take 155 long) False, Piece "…" False]

    it "shows a little of what comes before the first match, and is cut at blanks" $ do
      h <- hitIn long
      let Snippet pieces = h.snippet
          text = snippetText h.snippet
      marks h.snippet `shouldBe` ["needle"]
      take 1 pieces `shouldBe` [Piece "…" False]
      "…" `T.isSuffixOf` text `shouldBe` True
      T.length text `shouldSatisfy` (\n -> n > 120 && n <= snippetLength + 2)
      -- Whole words only: the text between the ellipses is in the body,
      -- with a blank (or the body's end) on either side.
      let inner = T.dropEnd 1 (T.drop 1 text)
      (" " <> inner <> " ") `T.isInfixOf` (" " <> long <> " ") `shouldBe` True
      T.breakOn "needle" inner `shouldSatisfy` (\(lead, _) -> T.length lead >= 30 && T.length lead <= 50)

    it "is the whole text when it is short, without ellipses" $ do
      h <- hitIn "Find the needle."
      h.snippet `shouldBe` Snippet [Piece "Find the " False, Piece "needle" True, Piece "." False]

    it "is in one line" $ do
      h <- hitIn "# Heading\n\nA paragraph\nwith the needle\n\n- and a list"
      snippetText h.snippet `shouldBe` "Heading A paragraph with the needle and a list"

    prop "marks only what folds to the word looked for, in a part of the text" $
      forAll genBody $ \body -> forAll (elements vocabulary) $ \word ->
        let hits = searchPlain (searchQuery (T.toUpper word)) [page "s" "Title" body ["p"]]
         in [ all (\m -> foldText m == word) (marks h.snippet)
                && T.replace "…" "" (snippetText h.snippet) `T.isInfixOf` bodyText body
            | h <- hits
            ]
              === [True | word `T.isInfixOf` foldText (bodyText body)]

  describe "folding" $ do
    prop "folds as each character's foldLetter, joined" $
      forAll genFoldable $
        \t -> foldText t === T.concatMap foldLetter t

    prop "gives each character of the fold the character it came from" $
      forAll genFoldable $ \t ->
        let f = folded t
         in [(c, foldedOrigin f j) | (j, c) <- zip [0 ..] (T.unpack (foldedText f))] === reference t

    it "traces folds to several characters and to none back to theirs" $ do
      let f = folded "aße\x301x\x130y"
      foldedText f `shouldBe` "assex" <> "i\x307y"
      map (foldedOrigin f) [0 .. 7] `shouldBe` [0, 1, 1, 2, 4, 5, 5, 6]

-- | The fold as it was first written, a character at a time, with the index
-- of the character each of its characters came from: what 'folded' must
-- agree with.
reference :: Text -> [(Char, Int)]
reference t = [(f, i) | (i, c) <- zip [0 ..] (T.unpack t), f <- T.unpack (foldLetter c)]

-- | Text of every kind, with plenty of what does not fold to one character:
-- letters that fold to two (@ß@, @æ@, @ĳ@), combining marks that fold to
-- none, a capital whose lowercase is two characters (@İ@), next to ASCII,
-- capitals and Polish letters, and any character at all.
genFoldable :: Gen Text
genFoldable =
  T.pack
    <$> listOf
      ( frequency
          [ (4, elements "abcXYZ 09-.")
          , (3, elements "ąćęłńóśźżĄĆĘŁŃÓŚŹŻ")
          , (3, elements "ßæœĳþÆŒĲÞ\x130")
          , (3, elements "\x300\x301\x308\x328\x20dd")
          , (3, arbitrary)
          ]
      )

-- | The one hit expected.
single :: [SearchHit] -> IO SearchHit
single = \case
  [h] -> pure h
  hits -> panic ("expected one hit, got " <> show hits)

vocabulary :: [Text]
vocabulary = ["needle", "hay", "stack", "straw", "barn"]

genBody :: Gen Text
genBody = do
  n <- chooseInt (1, 120)
  ws <- vectorOf n (elements (vocabulary <> ["Needle", "HAY", "Straße", "żółw"]))
  extra <- listOf1 (elements ["", "\n\n", " **x** "])
  pure (T.unwords ws <> mconcat extra)
