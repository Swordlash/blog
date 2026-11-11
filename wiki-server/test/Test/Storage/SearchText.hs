-- | The search text the server stores for each page (@search_text@ and
-- @search_fold@, "Wiki.Server.Storage.Rows"), which the search reads: that
-- the program makes it again from every page's source when it opens a
-- database whose text another version of how search text is made
-- ('Wiki.Core.Search.searchVersion') made, or when @wiki-server migrate@
-- runs on it; that a page is then found by what it shows now; and that
-- nothing else of the page changes.
module Test.Storage.SearchText (spec) where

import Database.Beam (all_, filter_, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import Test.Database (Backing (..), withConnectionTo)
import Test.Hspec
import Test.Storage.Fixture (demoArchive, withPlaceIn, withStorageIn)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search (SearchHit (..), bodyText, foldText, searchQuery, searchVersion)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Storage
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (deleteSettingsLike, searchVersionSetting, settingValue)
import Wiki.Server.Storage.Schema (PageVersions (..), Pages (..), WikiDb (..), wikiDb)

spec :: Backing -> Spec
spec backing = describe "the pages' stored search text" $ do
  it "is made again when the program opens a database whose text another version made" $
    withStorageIn backing $ \at st -> do
      page <- framedPage st
      written <- stored st page.id
      rollBack st page
      -- As an earlier program left it: the fence's source is searched, in
      -- which the word the page shows is cut by a tag.
      found st "sunflower" `shouldReturn` []
      withStorageAside at $ \reopened -> do
        found reopened "sunflower" `shouldReturn` [page.id]
        found reopened "tomato" `shouldReturn` []
        stored reopened page.id `shouldReturn` written
        reading reopened (settingValue searchVersionSetting) `shouldReturn` Just (show searchVersion)

  it "is made again by wiki-server migrate, before any storage opens the database" $
    withPlaceIn backing $ \at -> do
      (page, written) <- withStorage defaultConfig at $ \st -> do
        page <- framedPage st
        written <- stored st page.id
        rollBack st page
        pure (page, written)
      _ <- migrateDatabase at
      -- Read straight from the database: opening a storage would make the
      -- text again itself.
      withConnectionTo at $ \c -> do
        runDb c (settingValue searchVersionSetting) `shouldReturn` Just (show searchVersion)
        runDb c (rowOf page.id) `shouldReturn` written

  it "changes no page that is already as this version makes it, and every page of the demo is" $
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= either (\e -> expectationFailure ("the demo does not import: " <> toS e)) (const pass)
      everything <- reading st allRows
      writing st (deleteSettingsLike searchVersionSetting [])
      withStorageAside at $ \reopened -> reading reopened allRows `shouldReturn` everything
  where
    -- The search's hits for a word, as the pages they are.
    found st word = map (\h -> h.page) <$> runStoredWiki st Administrator (searchPages (searchQuery word))

-- | A page of an html fence that shows "sunflower", split by a tag, and
-- has "tomato" in its CSS, made in a new space by the administrator.
framedPage :: Storage -> IO Page
framedPage st = do
  space <- runStoredWiki st Administrator (createSpace Nothing "Garden") >>= either (\e -> expectationFailure (show e) >> panic "no space") pure
  runStoredWiki st Administrator (createPage space.id Nothing "Flowers" "```html\n<style>p { color: tomato }</style>\n<p>sun<b>flower</b></p>\n```\n")
    >>= either (\e -> expectationFailure (show e) >> panic "no page") pure

-- | Store a page's search text as the program before WP5.89 made it, the
-- fence a listing whose text is its source, and take away the stamp of
-- the version that made the stored text, as that program left a database.
rollBack :: Storage -> Page -> IO ()
rollBack st page = writing st $ do
  let source = "<style>p { color: tomato }</style>\n<p>sun<b>flower</b></p>"
      listing = bodyText ("```\n" <> source <> "\n```\n")
  runUpdate (update wikiDb.pages (\p -> mconcat [p.search_text <-. val_ listing, p.search_fold <-. val_ (foldText page.title <> "\n" <> foldText listing)]) (\p -> p.id ==. val_ page.id.text))
  deleteSettingsLike searchVersionSetting []

-- | A page's row and its versions: everything of it the search text must
-- not change, and the search text itself, as stored.
stored :: Storage -> PageId -> IO (Maybe (Pages Identity), [PageVersions Identity])
stored st pid = reading st (rowOf pid)

rowOf :: (Backend be) => PageId -> Db be (Maybe (Pages Identity), [PageVersions Identity])
rowOf pid =
  (,)
    <$> runSelectReturningOne (select (filter_ (\p -> p.id ==. val_ pid.text) (all_ wikiDb.pages)))
    <*> runSelectReturningList (select (filter_ (\v -> v.page_id ==. val_ pid.text) (all_ wikiDb.page_versions)))

-- | Every page's row.
allRows :: (Backend be) => Db be [Pages Identity]
allRows = sortOn (\p -> p.id) <$> runSelectReturningList (select (all_ wikiDb.pages))
