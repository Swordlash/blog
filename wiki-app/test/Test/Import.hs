-- | The dialog "What to migrate" as pure data ("Wiki.App.Import"): the
-- plan of an import as a tree, its boxes, and the choices they send.
module Test.Import (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.Import
import Wiki.App.Import
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

ref :: Text -> Text -> PageRef
ref s p = PageRef {space = slugs s, page = slugs p}

conflict :: Bool -> Maybe PageConflict
conflict same = Just PageConflict {title = "The server's", updatedAt = UTCTime (fromGregorian 2026 10 1) 0, sameContent = same}

newPage :: Text -> Text -> PagePlan
newPage p title = PagePlan {path = slugs p, title, attachments = 0, conflict = Nothing}

-- | Docs is on both sides, with a page in conflict, one new under it and
-- one the same on both; Notes, under Docs, and Blog are new.
plan :: ImportPlan
plan =
  ImportPlan
    [ SpacePlan
        { path = slugs "docs"
        , name = "Docs"
        , status = SpaceMerged
        , pages =
            [ (newPage "tour" "Tour") {conflict = conflict False, attachments = 2}
            , newPage "tour/more" "More"
            , (newPage "guide" "Guide") {conflict = conflict True}
            ]
        }
    , SpacePlan {path = slugs "docs/notes", name = "Notes", status = SpaceNew, pages = [newPage "n1" "N1", newPage "n1/sub" "Sub"]}
    , SpacePlan {path = slugs "blog", name = "Blog", status = SpaceNew, pages = [newPage "hello" "Hello"]}
    ]

-- | The tree as names, for reading.
data Shape = Shape Text [Shape] [Shape]
  deriving stock (Eq, Show)

shape :: SpaceNode -> Shape
shape n = Shape n.plan.name (map pageShape n.pages) (map shape n.subspaces)
  where
    pageShape p = Shape p.plan.title (map pageShape p.children) []

on', off', fixed :: Mark
on' = Mark {checked = True, enabled = True}
off' = Mark {checked = False, enabled = True}
fixed = Mark {checked = False, enabled = False}

spec :: Spec
spec = describe "Wiki.App.Import" $ do
  it "shows the plan as the tree its paths make, in its order" $
    map shape (planTree plan)
      `shouldBe` [ Shape "Docs" [Shape "Tour" [Shape "More" [] []] [], Shape "Guide" [] []] [Shape "Notes" [Shape "N1" [Shape "Sub" [] []] []] []]
                 , Shape "Blog" [Shape "Hello" [] []] []
                 ]

  it "names each page with its space's path" $
    [p.space | n <- planTree plan, p <- n.pages] `shouldBe` [slugs "docs", slugs "docs", slugs "blog"]

  it "opens with everything checked and sends no choice" $ do
    spaceMark everything (slugs "docs/notes") `shouldBe` on'
    pageMark everything (ref "docs" "tour/more") `shouldBe` on'
    resolutionOf everything (ref "docs" "tour") `shouldBe` KeepServer
    choicesOf plan everything `shouldBe` importEverything

  it "leaves out a space unchecked, with its pages and its subspaces, which cannot be checked meanwhile" $ do
    let sel = setSpace (slugs "docs") False everything
    spaceMark sel (slugs "docs") `shouldBe` off'
    spaceMark sel (slugs "docs/notes") `shouldBe` fixed
    pageMark sel (ref "docs" "tour") `shouldBe` fixed
    pageMark sel (ref "docs/notes" "n1/sub") `shouldBe` fixed
    spaceMark sel (slugs "blog") `shouldBe` on'
    choicesOf plan sel `shouldBe` importEverything {skipSpaces = [slugs "docs"]}

  it "sends only the uppermost box unchecked, as the server leaves out what is under it" $ do
    let sel =
          everything
            & setPage (ref "docs/notes" "n1/sub") False
            & setSpace (slugs "docs/notes") False
            & setResolution (ref "docs" "tour") TakeImported
            & setSpace (slugs "docs") False
    choicesOf plan sel `shouldBe` importEverything {skipSpaces = [slugs "docs"]}

  it "brings back the boxes under a space as they were when it is checked again" $ do
    let sel = everything & setPage (ref "docs/notes" "n1") False & setSpace (slugs "docs") False & setSpace (slugs "docs") True
    spaceMark sel (slugs "docs/notes") `shouldBe` on'
    pageMark sel (ref "docs/notes" "n1") `shouldBe` off'
    pageMark sel (ref "docs/notes" "n1/sub") `shouldBe` fixed
    choicesOf plan sel `shouldBe` importEverything {skipPages = [ref "docs/notes" "n1"]}

  it "leaves out a page unchecked with the pages under it" $ do
    let sel = everything & setPage (ref "docs" "tour/more") False & setPage (ref "docs" "tour") False
    pageMark sel (ref "docs" "tour") `shouldBe` off'
    pageMark sel (ref "docs" "tour/more") `shouldBe` fixed
    pageMark sel (ref "docs" "guide") `shouldBe` on'
    choicesOf plan sel `shouldBe` importEverything {skipPages = [ref "docs" "tour"]}

  it "sends a conflict that takes the imported page, while that page is imported" $ do
    let taking = setResolution (ref "docs" "tour") TakeImported everything
        takeTour = ConflictChoice {page = ref "docs" "tour", resolution = TakeImported}
    resolutionOf taking (ref "docs" "tour") `shouldBe` TakeImported
    choicesOf plan taking `shouldBe` importEverything {conflicts = [takeTour]}
    choicesOf plan (setPage (ref "docs" "tour") False taking) `shouldBe` importEverything {skipPages = [ref "docs" "tour"]}
    -- Kept as chosen while the page is left out, and sent again once it is
    -- checked.
    choicesOf plan (taking & setPage (ref "docs" "tour") False & setPage (ref "docs" "tour") True) `shouldBe` importEverything {conflicts = [takeTour]}
    choicesOf plan (setResolution (ref "docs" "tour") KeepServer taking) `shouldBe` importEverything

  it "checks nothing, then everything, keeping the conflicts as chosen" $ do
    let taking = setResolution (ref "docs" "tour") TakeImported everything
        none = selectNone plan taking
    map (spaceMark none . (\s -> s.path)) plan.spaces `shouldBe` [off', fixed, off']
    (choicesOf plan none).skipSpaces `shouldBe` [slugs "docs", slugs "blog"]
    selectionSummary plan none `shouldBe` "Nothing is checked: the import would bring in nothing."
    -- One space checked again brings in that space alone.
    (choicesOf plan (setSpace (slugs "blog") True none)).skipSpaces `shouldBe` [slugs "docs"]
    choicesOf plan (selectAll none) `shouldBe` choicesOf plan taking

  it "counts what a plan holds, and what is checked of it" $ do
    planSummary plan `shouldBe` "3 spaces (2 new, 1 already here) and 6 pages (4 new, 1 in conflict, 1 the same on both sides)"
    selectionSummary plan (setSpace (slugs "docs/notes") False everything)
      `shouldBe` "Checked: 2 spaces (1 new, 1 already here) and 4 pages (2 new, 1 in conflict, 1 the same on both sides)."
    selectionSummary plan (setResolution (ref "docs" "tour") TakeImported everything)
      `shouldBe` "Checked: 3 spaces (2 new, 1 already here) and 6 pages (4 new, 1 in conflict, 1 the same on both sides); 1 conflict takes the imported page."
    tally plan everything `shouldBe` Tally {spacesNew = 2, spacesMerged = 1, pagesNew = 4, pagesConflicting = 1, pagesSame = 1}

  it "says what an import did, a line for each thing it did" $
    importSummary ImportSummary {spacesCreated = 1, spacesMerged = 2, pagesCreated = 5, pagesReplaced = 1, pagesKept = 0, pagesSkipped = 3, attachments = 1}
      `shouldBe` [ "1 space created"
                 , "2 spaces merged with the server's"
                 , "5 pages created"
                 , "1 page replaced by the imported one"
                 , "3 pages left out"
                 , "1 attachment brought in"
                 ]
