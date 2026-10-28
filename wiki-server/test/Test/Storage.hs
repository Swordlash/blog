-- | What only the storage does, besides the contracts: who is asking (the
-- administrator, the wiki's people included), the
-- versions and the search text it keeps beside each page, attachments on
-- disk, and whole wikis in and out.
module Test.Storage (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Database.SQLite.Simple (Only (..), execute, query, query_)
import Protolude
import System.Directory (doesFileExist)
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Admin (Directory (..))
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.Core.Attachment (Attachment (..), MimeType (..), Source (..), findAttachment)
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Export.Zip (ZipSource (..), unzipFile, writeZipFile, zipFiles)
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), Subject (..))
import Wiki.Core.Search (SearchHit (..), bodyText, foldText, searchQuery)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Login (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..), VersionsQuery (..), latestVersions)
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

  it "administers the wiki's people, of whom they are not one" $
    withDemo $ \st -> do
      d <- runSqliteWiki st Administrator directory >>= ok
      map (\u -> u.login.text) d.users `shouldBe` ["admin", "editor", "reader"]
      runSqliteWiki st Administrator (setAdministrator administratorId False) `shouldReturn` Left NotFound
      -- Every user's administer may go, the last one's included: the
      -- operator gives it back.
      admin <- maybe (panic "no admin") (\u -> u.id) <$> userByLogin st "admin"
      runSqliteWiki st Administrator (setAdministrator admin False) >>= ok
      none <- runSqliteWiki st Administrator directory >>= ok
      none.administrators `shouldBe` mempty
      runSqliteWiki st Administrator (setAdministrator admin True) >>= ok
      rows <- withDatabase st $ \c -> query c "SELECT count(*) FROM global_grants WHERE subject_kind = 'user' AND subject_id = ?" (Only admin.text)
      rows `shouldBe` [Only (1 :: Int)]

  it "deletes a group with the rows that grant it anything" $
    withDemo $ \st -> do
      d <- runSqliteWiki st Administrator directory >>= ok
      let writers = maybe (panic "no writers") (\g -> g.id) (head d.groups)
      let grantsTo = withDatabase st $ \c ->
            (,)
              <$> query c "SELECT count(*) FROM space_grants WHERE subject_kind = 'group' AND subject_id = ?" (Only writers.text)
              <*> query c "SELECT count(*) FROM group_members WHERE group_id = ?" (Only writers.text)
      grantsTo `shouldReturn` ([Only (1 :: Int)], [Only (1 :: Int)])
      runSqliteWiki st Administrator (deleteGroup writers) >>= ok
      grantsTo `shouldReturn` ([Only 0], [Only 0])

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

  it "name each version's author: a user by their name, the administrator, someone gone by their id, nobody for an import" $
    withDemo $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      editor <- whoFor st (As "editor")
      byEditor <- runSqliteWiki st editor (savePage hello.id hello.updatedAt "Hello" "By the editor") >>= ok
      byAdministrator <- runSqliteWiki st Administrator (savePage hello.id byEditor.updatedAt "Hello" "By the administrator") >>= ok
      -- A version whose author is no longer one of the users.
      withDatabase st $ \c ->
        execute c "UPDATE page_versions SET author = 'user-gone' WHERE page_id = ? AND updated_at = ?" (hello.id.text, Stamp byEditor.updatedAt)
      versions <- asAdmin st (listVersions hello.id latestVersions) >>= ok
      map (\v -> (v.updatedAt, (\a -> (a.id, a.name)) <$> v.author)) versions
        `shouldBe` [ (byAdministrator.updatedAt, Just (administratorId, "Administrator"))
                   , (byEditor.updatedAt, Just (UserId "user-gone", "user-gone"))
                   , (hello.updatedAt, Nothing)
                   ]
      edgar <- runSqliteWiki st editor (savePage hello.id byAdministrator.updatedAt "Hello" "By the editor again") >>= ok
      v <- asAdmin st (getVersion hello.id edgar.updatedAt) >>= ok
      ((\a -> a.name) <$> v.author, v.body) `shouldBe` (Just "Edgar Editor", "By the editor again")

  it "list the versions by time, though times written with and without a fraction sort otherwise as text" $
    withDemo $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      let whole = UTCTime (utctDay hello.updatedAt) 50000
          fraction = UTCTime (utctDay hello.updatedAt) (picosecondsToDiffTime 50000500000000000)
      withDatabase st $ \c -> for_ [whole, fraction] $ \t ->
        execute c "INSERT INTO page_versions (page_id, updated_at, title, body, author) VALUES (?, ?, 'Hello', '', NULL)" (hello.id.text, Stamp t)
      listed <- map (\x -> x.updatedAt) <$> (asAdmin st (listVersions hello.id latestVersions) >>= ok)
      listed `shouldBe` sortOn Down listed
      sort listed `shouldBe` sort [hello.updatedAt, whole, fraction]
      -- And a page of one version at a time goes through them in the same
      -- order, each numbered.
      let oneBefore at = asAdmin st (listVersions hello.id VersionsQuery {before = at, limit = 1}) >>= ok
          walk at =
            oneBefore at >>= \case
              [v] -> ((v.number, v.updatedAt) :) <$> walk (Just v.updatedAt)
              _ -> pure []
      walk Nothing `shouldReturn` zip [3, 2, 1] listed

  it "keep the search text in step with every page's body, through imports, saves and moves" $
    withDemo $ \st -> do
      let inStep = do
            rows <- withDatabase st $ \c -> query_ c "SELECT title, body, search_text, search_fold FROM pages"
            length rows `shouldSatisfy` (> 0)
            for_ rows $ \(title, body, text, stored) -> do
              text `shouldBe` bodyText body
              stored `shouldBe` (foldText title <> "\n" <> foldText text)
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
      (a.mediaType.text, b.mediaType.text) `shouldBe` ("application/octet-stream", "application/x-thing")
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
      runSqliteWiki st Anonymous (attachmentFile a.id) >>= (`shouldBe` Left NotFound) . fmap (const ())
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
    withSystemTempDirectory "wiki-server-test" $ \dir -> do
      let shard = attachmentsDir dir </> "ab"
      file <- withStorage defaultConfig dir $ \st -> do
        importArchive st demoArchive >>= ok
        hello <- pageIn st "blog" "hello-world"
        a <- asAdmin st (uploadAttachment hello.id "gone.txt" "text/plain" "soon gone") >>= ok
        _ <- asAdmin st (uploadAttachment hello.id "kept.txt" "text/plain" "kept") >>= ok
        _ <- asAdmin st (deleteAttachment a.id) >>= ok
        file <- maybe (panic "not a hash") pure (blobFile (attachmentsDir dir) (blobOf "soon gone"))
        doesFileExist file `shouldReturn` True
        -- A write that never finished leaves a file behind, which goes too.
        Directory.createDirectoryIfMissing True shard
        writeFile (shard </> "incoming123") "half"
        -- Nobody else may open the directory meanwhile: a second storage
        -- would delete what this one may still be writing.
        (withStorage defaultConfig dir (const pass) >> pure False) `catch` (\(_ :: DataDirInUse) -> pure True) `shouldReturn` True
        doesFileExist file `shouldReturn` True
        pure file
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

  it "carry the pages' comments into another storage, with their ids, authors, times and edits" $
    withDemo $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      opened <- runSqliteWiki st Administrator (openThread hello.id Nothing "From the administrator.") >>= ok
      editor <- whoFor st (As "editor")
      answer <- runSqliteWiki st editor (reply hello.id opened.id "From the editor.") >>= ok
      _ <- runSqliteWiki st editor (editComment hello.id opened.id answer.id "Edited by the editor.") >>= ok
      exported <- exportArchive st "wiki-server-test" >>= ok
      -- The administrator has no row among the users, so the archive
      -- names them among its comment authors, by login.
      exported.commentAuthors `shouldBe` [administratorUser]
      [(c.author.name, c.body, isJust c.editedAt) | t <- Map.findWithDefault [] hello.id exported.threads, t.id == opened.id, c <- t.comments]
        `shouldBe` [("Administrator", "From the administrator.", False), ("Edgar Editor", "Edited by the editor.", True)]
      -- The files of the archive read back as the same comments.
      (\a -> (a.threads, a.commentAuthors)) <$> readArchive (Map.fromList (writeArchive exported)) `shouldBe` Right (exported.threads, exported.commentAuthors)
      withStorageIn $ \_ fresh -> do
        importArchive fresh exported >>= ok
        again <- exportArchive fresh "wiki-server-test" >>= ok
        again.threads `shouldBe` exported.threads

  it "write the export as a zip file on disk that holds exportArchive's files, and that imports back as the same wiki" $
    withDemo $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      -- Bytes that do not compress, bytes that do, none, and a name
      -- outside ASCII.
      let noise = BS.pack (take 300_000 (iterate (\b -> b * 31 + 7) 1))
      for_ [("noise.bin", noise), ("lines.txt", encodeUtf8 (mconcat (replicate 5000 "a line of text\n"))), ("empty", ""), ("żółw.txt", "turtle")] $ \(name, bytes) ->
        asAdmin st (uploadAttachment hello.id name "application/octet-stream" bytes) >>= ok
      exported <- exportArchive st "wiki-server-test" >>= ok
      withSystemTempDirectory "export" $ \dir -> do
        let file = dir </> "wiki.zip"
        at <- writeExport st "wiki-server-test" file >>= ok
        files <- unzipFile file >>= ok
        -- The same files, but for the manifest's time.
        Map.delete "manifest.json" files `shouldBe` Map.delete "manifest.json" (Map.fromList (writeArchive exported))
        readBack <- either (panic . show) pure (readArchive files)
        readBack.createdAt `shouldBe` at
        contents readBack `shouldBe` contents exported
        withStorageIn $ \_ fresh -> do
          importArchive fresh readBack >>= ok
          again <- exportArchive fresh "wiki-server-test" >>= ok
          contents (byHash again) `shouldBe` contents (byHash exported)

  it "write a zip file one file at a time that is zip-archive's zip file of the same files, byte for byte" $
    withSystemTempDirectory "zip" $ \dir -> do
      let at = UTCTime (fromGregorian 2026 10 28) 45296.7
          noise = BS.pack (take 70_000 (iterate (\b -> b * 31 + 7) 1))
          files =
            Map.toList (Map.fromList (writeArchive demoArchive))
              <> [ ("noise.bin", noise)
                 , ("empty", "")
                 , ("spaces/żółw/page.md", encodeUtf8 "# Żółw\n")
                 , ("repeated.txt", encodeUtf8 (mconcat (replicate 10000 "the same line\n")))
                 ]
      -- Every other file read from disk rather than memory.
      sources <- for (zip [0 :: Int ..] files) $ \(i, (name, bytes)) ->
        if even i
          then pure (name, ZipBytes bytes)
          else do
            let source = dir </> ("source-" <> show i)
            BS.writeFile source bytes
            pure (name, ZipFile source)
      writeZipFile (dir </> "written.zip") at sources
      BS.readFile (dir </> "written.zip") `shouldReturn` zipFiles at files
      unzipFile (dir </> "written.zip") `shouldReturn` Right (Map.fromList files)

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
        , template = p.template
        }
    rehash x = case x.source of
      SourceBlob b | Just bytes <- Map.lookup b a.blobs -> x {source = SourceBlob (blobOf bytes)}
      _ -> x
