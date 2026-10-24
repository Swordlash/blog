-- | What only the storage does, besides the contract: who is asking, the
-- versions and the search text it keeps beside each page, attachments on
-- disk, and whole wikis in and out.
module Test.Storage (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Database.SQLite.Simple (Only (..), query, query_)
import Protolude
import System.Directory (doesFileExist)
import System.Directory qualified as Directory
import System.FilePath ((</>))
import Test.Hspec
import Test.Storage.Fixture
import Wiki.App.Backend
import Wiki.App.Backend.Contract (As (As))
import Wiki.Core.Attachment (Attachment (..), Source (..), findAttachment)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), Subject (..))
import Wiki.Core.Search (SearchHit (..), bodyText, searchQuery)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Storage
import Wiki.Server.Storage.Blobs (blobFile, blobOf, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Rows (Stamp (..))

spec :: Spec
spec = describe "SqliteWiki, besides the contract" $ do
  times
  administrator
  versionsAndSearchText
  attachmentsOnDisk
  wholeWikis

-- | Run as the demo's administrator user.
asAdmin :: Storage -> SqliteWiki IO a -> IO a
asAdmin st program = whoFor st (As "admin") >>= \who -> runSqliteWiki st who program

-- | The page at a path of the space at a path.
pageIn :: Storage -> Text -> Text -> IO Page
pageIn st s p = asAdmin st (getSpace (path s) >>= either (pure . Left) (\space -> getPage space.id (path p))) >>= ok

times :: Spec
times = describe "times" $
  it "come back from the database exactly as they went in, to the picosecond" $
    withStorageIn $ \_ st -> do
      let day = fromGregorian 2026 10 24
          ts =
            [ UTCTime day 0
            , UTCTime day (picosecondsToDiffTime 43200123456789012)
            , UTCTime day (picosecondsToDiffTime 86399999999999999)
            , UTCTime day (picosecondsToDiffTime 1000000)
            ]
      back <- withDatabase st $ \c -> for ts $ \t -> query c "SELECT ?" (Only (Stamp t))
      [t | [Only (Stamp t)] <- back] `shouldBe` ts

administrator :: Spec
administrator = describe "the administrator" $ do
  it "is signed in as no user of the wiki, holding Administer" $
    withDemo $ \st -> do
      s <- runSqliteWiki st Administrator session
      s.user `shouldBe` Just administratorUser
      s.grants.global `shouldBe` [GlobalGrant {subject = SubjectUser administratorId, permission = Administer}]
      users <- withDatabase st $ \c -> query_ c "SELECT count(*) FROM users WHERE id = '~administrator'"
      users `shouldBe` [Only (0 :: Int)]

  it "sees every space and may do everything, without a grant of their own" $
    withDemo $ \st -> do
      names <- map (\s -> s.name) <$> runSqliteWiki st Administrator listSpaces
      names `shouldBe` ["Blog", "Docs", "Team", "Projects"]
      team <- runSqliteWiki st Administrator (getSpace (path "team")) >>= ok
      mine <- runSqliteWiki st Administrator (createSpace (Just team.id) "Mine") >>= ok
      _ <- runSqliteWiki st Administrator (setSpacePublic mine.id True) >>= ok
      grants <- withDatabase st $ \c -> query c "SELECT count(*) FROM space_grants WHERE space_id = ?" (Only mine.id.text)
      grants `shouldBe` [Only (0 :: Int)]
      runSqliteWiki st Administrator (deleteSpace team.id) >>= ok

  it "keeps drafts of their own, and saves versions under their id" $
    withDemo $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      d <- runSqliteWiki st Administrator (saveDraft hello.id hello.updatedAt "Hello" "The administrator's") >>= ok
      d.author `shouldBe` administratorId
      runSqliteWiki st Administrator (getDraft hello.id) `shouldReturn` Right (Just d)
      asAdmin st (getDraft hello.id) `shouldReturn` Right Nothing
      saved <- runSqliteWiki st Administrator (savePage hello.id hello.updatedAt "Hello" "Saved") >>= ok
      runSqliteWiki st Administrator (getDraft hello.id) `shouldReturn` Right Nothing
      authors <- withDatabase st $ \c -> query c "SELECT author FROM page_versions WHERE page_id = ? AND updated_at = ?" (hello.id.text, Stamp saved.updatedAt)
      authors `shouldBe` [Only (Just administratorId.text)]

  it "is told apart from a user who is not there, who is nobody" $
    withDemo $ \st -> do
      runSqliteWiki st (AsUser (UserId "no-such-user")) session `shouldReturn` anonymous
      names <- map (\s -> s.name) <$> runSqliteWiki st (AsUser (UserId "no-such-user")) listSpaces
      names `shouldBe` ["Blog", "Docs"]

versionsAndSearchText :: Spec
versionsAndSearchText = describe "each page's versions and search text" $ do
  it "keep a version for the page as made and one for every save, by its updatedAt" $
    withDemo $ \st -> do
      blog <- asAdmin st (getSpace (path "blog")) >>= ok
      editor <- whoFor st (As "editor")
      made <- runSqliteWiki st editor (createPage blog.id Nothing "Marsupials" "A wombat.") >>= ok
      saved <- runSqliteWiki st editor (savePage made.id made.updatedAt "Marsupials" "A quokka.") >>= ok
      again <- runSqliteWiki st editor (savePage made.id saved.updatedAt "Marsupials, again" "A numbat.") >>= ok
      versions <- withDatabase st $ \c -> query c "SELECT updated_at, title, body, author FROM page_versions WHERE page_id = ? ORDER BY updated_at" (Only made.id.text)
      let editorId = case editor of
            AsUser u -> Just u.text
            _ -> Nothing
      [(t, title, body, author) | (Stamp t, title :: Text, body :: Text, author) <- versions]
        `shouldBe` [ (made.updatedAt, "Marsupials", "A wombat.", editorId)
                   , (saved.updatedAt, "Marsupials", "A quokka.", editorId)
                   , (again.updatedAt, "Marsupials, again", "A numbat.", editorId)
                   ]
      _ <- runSqliteWiki st editor (deletePage made.id) >>= ok
      gone <- withDatabase st $ \c -> query c "SELECT count(*) FROM page_versions WHERE page_id = ?" (Only made.id.text)
      gone `shouldBe` [Only (0 :: Int)]

  it "keep the search text in step with every page's body, through imports, saves and moves" $
    withDemo $ \st -> do
      let inStep = do
            rows <- withDatabase st $ \c -> query_ c "SELECT body, search_text FROM pages"
            length rows `shouldSatisfy` (> 0)
            for_ rows $ \(body, text) -> text `shouldBe` bodyText body
      inStep
      docs <- asAdmin st (getSpace (path "docs")) >>= ok
      blog <- asAdmin st (getSpace (path "blog")) >>= ok
      p <- asAdmin st (createPage docs.id Nothing "Marsupials" "**A** `wombat` digs.\n\n$$x^2$$") >>= ok
      inStep
      saved <- asAdmin st (savePage p.id p.updatedAt "Marsupials" "A *quokka* smiles.") >>= ok
      inStep
      _ <- asAdmin st (movePage saved.id blog.id Nothing) >>= ok
      inStep
      found <- asAdmin st (searchPages (searchQuery "quokka"))
      map (\h -> h.page) found `shouldBe` [p.id]
      asAdmin st (searchPages (searchQuery "wombat")) `shouldReturn` []

attachmentsOnDisk :: Spec
attachmentsOnDisk = describe "attachments" $ do
  it "keep their bytes in a file named by their hash, one file for the same bytes" $
    withStorageIn $ \dir st -> do
      importArchive st demoArchive >>= ok
      hello <- pageIn st "blog" "hello-world"
      notes <- pageIn st "blog" "notes-on-haskell"
      a <- asAdmin st (uploadAttachment hello.id "a.bin" "" "the same bytes") >>= ok
      b <- asAdmin st (uploadAttachment notes.id "b.bin" "application/x-thing" "the same bytes") >>= ok
      (a.mediaType, b.mediaType) `shouldBe` ("application/octet-stream", "application/x-thing")
      a.source `shouldBe` SourceBlob (blobOf "the same bytes")
      b.source `shouldBe` a.source
      file <- maybe (panic "not a hash") pure (blobFile (attachmentsDir dir) (blobOf "the same bytes"))
      BS.readFile file `shouldReturn` "the same bytes"

  it "are served from their file to those who may view their page, at the address configured" $
    withDemo $ \st -> do
      wiki <- pageIn st "team/projects" "the-wiki"
      a <- asAdmin st (uploadAttachment wiki.id "plan.txt" "text/plain" "The plan.") >>= ok
      rita <- whoFor st (As "reader")
      (found, file) <- runSqliteWiki st rita (attachmentFile a.id) >>= ok
      found `shouldBe` a
      maybe (pure "") BS.readFile file `shouldReturn` "The plan."
      runSqliteWiki st Anonymous (attachmentFile a.id) >>= (`shouldBe` Left Forbidden) . fmap (const ())
      runSqliteWiki st rita (attachmentFile (AttachmentId "no-such-attachment")) >>= (`shouldBe` Left NotFound) . fmap (const ())
      runSqliteWiki st rita (attachmentUrl a) `shouldReturn` ("/api/v1/attachments/" <> a.id.text)
      -- One on the web is there, not here.
      guide <- pageIn st "docs" "markdown-guide"
      earth <- maybe (panic "no earth.jpg") pure (findAttachment "earth.jpg" guide.attachments)
      (_, none) <- runSqliteWiki st Anonymous (attachmentFile earth.id) >>= ok
      none `shouldBe` Nothing

  it "over 50 MB is refused before anything is written" $
    withStorageIn $ \dir st -> do
      importArchive st demoArchive >>= ok
      hello <- pageIn st "blog" "hello-world"
      already <- storedBlobs (attachmentsDir dir)
      let tooLarge = BS.replicate (fromIntegral maxAttachmentSize + 1) 7
      asAdmin st (uploadAttachment hello.id "big.bin" "application/octet-stream" tooLarge) >>= \case
        Left (Invalid _) -> pass
        other -> expectationFailure ("expected Invalid, got " <> show (fmap (\x -> x.size) other))
      storedBlobs (attachmentsDir dir) `shouldReturn` already
      found <- pageIn st "blog" "hello-world"
      findAttachment "big.bin" found.attachments `shouldBe` Nothing
      -- 50 MB exactly is not too large.
      let largest = BS.replicate (fromIntegral maxAttachmentSize) 7
      kept <- asAdmin st (uploadAttachment hello.id "big.bin" "application/octet-stream" largest) >>= ok
      kept.size `shouldBe` maxAttachmentSize

  it "whose files nothing refers to any more are deleted when the storage is next opened, and only then" $
    withStorageIn $ \dir st -> do
      importArchive st demoArchive >>= ok
      hello <- pageIn st "blog" "hello-world"
      a <- asAdmin st (uploadAttachment hello.id "gone.txt" "text/plain" "soon gone") >>= ok
      _ <- asAdmin st (uploadAttachment hello.id "kept.txt" "text/plain" "kept") >>= ok
      _ <- asAdmin st (deleteAttachment a.id) >>= ok
      file <- maybe (panic "not a hash") pure (blobFile (attachmentsDir dir) (blobOf "soon gone"))
      doesFileExist file `shouldReturn` True
      -- A write that never finished leaves a file behind, which goes too.
      let shard = attachmentsDir dir </> "ab"
      Directory.createDirectoryIfMissing True shard
      writeFile (shard </> "incoming123") "half"
      withStorage defaultConfig dir (const pass)
      doesFileExist file `shouldReturn` False
      doesFileExist (shard </> "incoming123") `shouldReturn` False
      storedBlobs (attachmentsDir dir) `shouldReturn` Set.fromList [blobOf "kept", blobOf treePng]
  where
    treePng = fromMaybe "" (head (Map.elems demoArchive.blobs))

wholeWikis :: Spec
wholeWikis = describe "importArchive and exportArchive" $ do
  it "give back the wiki that was put in, its attachments under their hashes" $
    withDemo $ \st -> do
      exported <- exportArchive st "wiki-server-test" >>= ok
      contents (byHash exported) `shouldBe` contents (byHash demoArchive)
      exported.app `shouldBe` "wiki-server-test"

  it "refuse to import into a storage with a wiki in it, changing nothing" $
    withDemo $ \st -> do
      original <- withDatabase st tableRows
      importArchive st demoArchive >>= (`shouldSatisfy` isLeft)
      withDatabase st tableRows `shouldReturn` original

  it "refuse an archive without the bytes of an attachment, writing nothing" $
    withStorageIn $ \_ st -> do
      original <- withDatabase st tableRows
      importArchive st demoArchive {blobs = mempty} >>= (`shouldSatisfy` isLeft)
      withDatabase st tableRows `shouldReturn` original

-- | What an archive holds, but for when and by what it was written.
contents :: Archive -> _
contents a = (a.users, a.groups, a.membership, a.grants, a.spaces, a.pages, a.blobs)

-- | An archive with its blobs named by their hashes, as the storage names
-- them: two archives of the same wiki are then equal.
byHash :: Archive -> Archive
byHash a =
  a
    { pages = map rehashPage a.pages
    , blobs = Map.fromList [(blobOf bytes, bytes) | bytes <- Map.elems a.blobs]
    }
  where
    rehashPage p =
      Page
        { id = p.id
        , space = p.space
        , parent = p.parent
        , title = p.title
        , slug = p.slug
        , body = p.body
        , attachments = map rehash p.attachments
        , createdAt = p.createdAt
        , updatedAt = p.updatedAt
        , position = p.position
        }
    rehash x = case x.source of
      SourceBlob b | Just bytes <- Map.lookup b a.blobs -> x {source = SourceBlob (blobOf bytes)}
      _ -> x
