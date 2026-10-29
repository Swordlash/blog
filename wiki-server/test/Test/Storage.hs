-- | What only the storage does, besides the contracts: who is asking (the
-- administrator, the wiki's people included), the
-- versions and the search text it keeps beside each page, attachments on
-- disk, and whole wikis in and out.
module Test.Storage (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Database.Beam (all_, asc_, filter_, insert, insertValues, orderBy_, runInsert, runSelectReturningList, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Protolude
import System.Directory (doesFileExist)
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Admin (Directory (..))
import Wiki.Api.Info (Capabilities (..), SearchKind (..))
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
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), bodyText, foldText, searchQuery)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Login (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..), VersionsQuery (..), latestVersions)
import Wiki.Server.Storage
import Wiki.Server.Storage.Blobs (blobFile, blobOf, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Schema (GlobalGrants (..), GroupMembers (..), PageVersions (..), Pages (..), SpaceGrants (..), Users (..), WikiDb (..), wikiDb)

spec :: Backing -> Spec
spec backing = describe "StoredWiki, besides the contract" $ do
  times backing
  administrator backing
  versionsAndSearchText backing
  attachmentsOnDisk backing
  wholeWikis backing
  searching backing

-- | Run as the demo's administrator user.
asAdmin :: Storage -> StoredWiki IO a -> IO a
asAdmin st program = whoFor st (As "admin") >>= \who -> runStoredWiki st who program

-- | The page at a path of the space at a path.
pageIn :: Storage -> Text -> Text -> IO Page
pageIn st s p = asAdmin st (getSpace (path s) >>= either (pure . Left) (\space -> getPage space.id (path p))) >>= ok

times :: Backing -> Spec
times backing = describe "times" $
  it "come back from the database exactly as they went in, to the microsecond" $
    withDemo backing $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      let day = fromGregorian 2026 10 24
          ts =
            [ UTCTime day 0
            , UTCTime day (picosecondsToDiffTime 43200123456000000)
            , UTCTime day (picosecondsToDiffTime 86399999999000000)
            , UTCTime day (picosecondsToDiffTime 1000000)
            ]
      writing st (runInsert (insert wikiDb.page_versions (insertValues [VersionRow {page_id = hello.id.text, updated_at = t, title = "Hello", body = "", author = Nothing} | t <- ts])))
      back <- reading st (runSelectReturningList (select (orderBy_ asc_ ((\v -> v.updated_at) <$> filter_ (\v -> v.page_id ==. val_ hello.id.text) (all_ wikiDb.page_versions)))))
      back `shouldBe` sort (hello.updatedAt : ts)

administrator :: Backing -> Spec
administrator backing = describe "the administrator" $ do
  it "is signed in as no user of the wiki, holding Administer" $
    withDemo backing $ \st -> do
      s <- runStoredWiki st Administrator session
      s.user `shouldBe` Just administratorUser
      s.grants.global `shouldBe` [GlobalGrant {subject = SubjectUser administratorId, permission = Administer}]
      reading st (countWhere wikiDb.users (\u -> u.id ==. val_ "~administrator")) `shouldReturn` 0

  it "sees every space and may do everything, without a grant of their own" $
    withDemo backing $ \st -> do
      names <- map (\s -> s.name) <$> runStoredWiki st Administrator listSpaces
      names `shouldBe` ["Blog", "Docs", "Team", "Projects"]
      team <- runStoredWiki st Administrator (getSpace (path "team")) >>= ok
      mine <- runStoredWiki st Administrator (createSpace (Just team.id) "Mine") >>= ok
      _ <- runStoredWiki st Administrator (setSpacePublic mine.id True) >>= ok
      reading st (countWhere wikiDb.space_grants (\g -> g.space_id ==. val_ mine.id.text)) `shouldReturn` 0
      runStoredWiki st Administrator (deleteSpace team.id) >>= ok

  it "keeps drafts of their own, and saves versions under their id" $
    withDemo backing $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      d <- runStoredWiki st Administrator (saveDraft hello.id hello.updatedAt "Hello" "The administrator's") >>= ok
      d.author `shouldBe` administratorId
      runStoredWiki st Administrator (getDraft hello.id) `shouldReturn` Right (Just d)
      asAdmin st (getDraft hello.id) `shouldReturn` Right Nothing
      saved <- runStoredWiki st Administrator (savePage hello.id hello.updatedAt "Hello" "Saved") >>= ok
      runStoredWiki st Administrator (getDraft hello.id) `shouldReturn` Right Nothing
      authors <- reading st (runSelectReturningList (select ((\v -> v.author) <$> filter_ (\v -> v.page_id ==. val_ hello.id.text &&. v.updated_at ==. val_ saved.updatedAt) (all_ wikiDb.page_versions))))
      authors `shouldBe` [Just administratorId.text]

  it "administers the wiki's people, of whom they are not one" $
    withDemo backing $ \st -> do
      d <- runStoredWiki st Administrator directory >>= ok
      map (\u -> u.login.text) d.users `shouldBe` ["admin", "editor", "reader"]
      runStoredWiki st Administrator (setAdministrator administratorId False) `shouldReturn` Left NotFound
      -- Every user's administer may go, the last one's included: the
      -- operator gives it back.
      admin <- maybe (panic "no admin") (\u -> u.id) <$> userByLogin st "admin"
      runStoredWiki st Administrator (setAdministrator admin False) >>= ok
      none <- runStoredWiki st Administrator directory >>= ok
      none.administrators `shouldBe` mempty
      runStoredWiki st Administrator (setAdministrator admin True) >>= ok
      reading st (countWhere wikiDb.global_grants (\g -> g.subject_kind ==. val_ "user" &&. g.subject_id ==. val_ admin.text)) `shouldReturn` 1

  it "deletes a group with the rows that grant it anything" $
    withDemo backing $ \st -> do
      d <- runStoredWiki st Administrator directory >>= ok
      let writers = maybe (panic "no writers") (\g -> g.id) (head d.groups)
      let grantsTo =
            reading st $
              (,)
                <$> countWhere wikiDb.space_grants (\g -> g.subject_kind ==. val_ "group" &&. g.subject_id ==. val_ writers.text)
                <*> countWhere wikiDb.group_members (\m -> m.group_id ==. val_ writers.text)
      grantsTo `shouldReturn` (1, 1)
      runStoredWiki st Administrator (deleteGroup writers) >>= ok
      grantsTo `shouldReturn` (0, 0)

  it "is told apart from a user who is not there, who is nobody" $
    withDemo backing $ \st -> do
      runStoredWiki st (AsUser (UserId "no-such-user")) session `shouldReturn` anonymous
      names <- map (\s -> s.name) <$> runStoredWiki st (AsUser (UserId "no-such-user")) listSpaces
      names `shouldBe` ["Blog", "Docs"]

versionsAndSearchText :: Backing -> Spec
versionsAndSearchText backing = describe "each page's versions and search text" $ do
  it "keep a version for the page as made and one for every save, by its updatedAt" $
    withDemo backing $ \st -> do
      blog <- asAdmin st (getSpace (path "blog")) >>= ok
      editor <- whoFor st (As "editor")
      made <- runStoredWiki st editor (createPage blog.id Nothing "Marsupials" "A wombat.") >>= ok
      saved <- runStoredWiki st editor (savePage made.id made.updatedAt "Marsupials" "A quokka.") >>= ok
      again <- runStoredWiki st editor (savePage made.id saved.updatedAt "Marsupials, again" "A numbat.") >>= ok
      versions <- reading st (runSelectReturningList (select (orderBy_ (\v -> asc_ v.updated_at) (filter_ (\v -> v.page_id ==. val_ made.id.text) (all_ wikiDb.page_versions)))))
      let editorId = case editor of
            AsUser u -> Just u.text
            _ -> Nothing
      [(v.updated_at, v.title, v.body, v.author) | v <- versions]
        `shouldBe` [ (made.updatedAt, "Marsupials", "A wombat.", editorId)
                   , (saved.updatedAt, "Marsupials", "A quokka.", editorId)
                   , (again.updatedAt, "Marsupials, again", "A numbat.", editorId)
                   ]
      _ <- runStoredWiki st editor (deletePage made.id) >>= ok
      reading st (countWhere wikiDb.page_versions (\v -> v.page_id ==. val_ made.id.text)) `shouldReturn` 0

  it "name each version's author: a user by their name, the administrator, someone gone by their id, nobody for an import" $
    withDemo backing $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      editor <- whoFor st (As "editor")
      byEditor <- runStoredWiki st editor (savePage hello.id hello.updatedAt "Hello" "By the editor") >>= ok
      byAdministrator <- runStoredWiki st Administrator (savePage hello.id byEditor.updatedAt "Hello" "By the administrator") >>= ok
      -- A version whose author is no longer one of the users.
      writing st (runUpdate (update wikiDb.page_versions (\v -> v.author <-. val_ (Just "user-gone")) (\v -> v.page_id ==. val_ hello.id.text &&. v.updated_at ==. val_ byEditor.updatedAt)))
      versions <- asAdmin st (listVersions hello.id latestVersions) >>= ok
      map (\v -> (v.updatedAt, (\a -> (a.id, a.name)) <$> v.author)) versions
        `shouldBe` [ (byAdministrator.updatedAt, Just (administratorId, "Administrator"))
                   , (byEditor.updatedAt, Just (UserId "user-gone", "user-gone"))
                   , (hello.updatedAt, Nothing)
                   ]
      edgar <- runStoredWiki st editor (savePage hello.id byAdministrator.updatedAt "Hello" "By the editor again") >>= ok
      v <- asAdmin st (getVersion hello.id edgar.updatedAt) >>= ok
      ((\a -> a.name) <$> v.author, v.body) `shouldBe` (Just "Edgar Editor", "By the editor again")

  it "list the versions by time, though times written with and without a fraction sort otherwise as text" $
    withDemo backing $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      let whole = UTCTime (utctDay hello.updatedAt) 50000
          fraction = UTCTime (utctDay hello.updatedAt) (picosecondsToDiffTime 50000500000000000)
      writing st (runInsert (insert wikiDb.page_versions (insertValues [VersionRow {page_id = hello.id.text, updated_at = t, title = "Hello", body = "", author = Nothing} | t <- [whole, fraction]])))
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
    withDemo backing $ \st -> do
      let inStep = do
            rows <- reading st (runSelectReturningList (select ((\p -> (p.title, p.body, p.search_text, p.search_fold)) <$> all_ wikiDb.pages)))
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

attachmentsOnDisk :: Backing -> Spec
attachmentsOnDisk backing = describe "attachments" $ do
  it "keep their bytes in a file named by their hash, one file for the same bytes" $
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= ok
      hello <- pageIn st "blog" "hello-world"
      notes <- pageIn st "blog" "notes-on-haskell"
      a <- asAdmin st (uploadAttachment hello.id "a.bin" "" "the same bytes") >>= ok
      b <- asAdmin st (uploadAttachment notes.id "b.bin" "application/x-thing" "the same bytes") >>= ok
      (a.mediaType.text, b.mediaType.text) `shouldBe` ("application/octet-stream", "application/x-thing")
      a.source `shouldBe` SourceBlob (blobOf "the same bytes")
      b.source `shouldBe` a.source
      file <- maybe (panic "not a hash") pure (blobFile (attachmentsDir at.dataDir) (blobOf "the same bytes"))
      BS.readFile file `shouldReturn` "the same bytes"

  it "are served from their file to those who may view their page, at the address configured" $
    withDemo backing $ \st -> do
      wiki <- pageIn st "team/projects" "the-wiki"
      a <- asAdmin st (uploadAttachment wiki.id "plan.txt" "text/plain" "The plan.") >>= ok
      rita <- whoFor st (As "reader")
      (found, file) <- runStoredWiki st rita (attachmentFile a.id) >>= ok
      found `shouldBe` a
      maybe (pure "") BS.readFile file `shouldReturn` "The plan."
      runStoredWiki st Anonymous (attachmentFile a.id) >>= (`shouldBe` Left NotFound) . fmap (const ())
      runStoredWiki st rita (attachmentFile (AttachmentId "no-such-attachment")) >>= (`shouldBe` Left NotFound) . fmap (const ())
      runStoredWiki st rita (attachmentUrl a) `shouldReturn` ("/api/v1/attachments/" <> a.id.text)
      -- One on the web is there, not here.
      guide <- pageIn st "docs" "markdown-guide"
      earth <- maybe (panic "no earth.jpg") pure (findAttachment "earth.jpg" guide.attachments)
      (_, none) <- runStoredWiki st Anonymous (attachmentFile earth.id) >>= ok
      none `shouldBe` Nothing

  it "over 50 MB is refused before anything is written" $
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= ok
      hello <- pageIn st "blog" "hello-world"
      already <- storedBlobs (attachmentsDir at.dataDir)
      let tooLarge = BS.replicate (fromIntegral maxAttachmentSize + 1) 7
      asAdmin st (uploadAttachment hello.id "big.bin" "application/octet-stream" tooLarge) >>= \case
        Left (Invalid _) -> pass
        other -> expectationFailure ("expected Invalid, got " <> show (fmap (\x -> x.size) other))
      storedBlobs (attachmentsDir at.dataDir) `shouldReturn` already
      found <- pageIn st "blog" "hello-world"
      findAttachment "big.bin" found.attachments `shouldBe` Nothing
      -- 50 MB exactly is not too large.
      let largest = BS.replicate (fromIntegral maxAttachmentSize) 7
      kept <- asAdmin st (uploadAttachment hello.id "big.bin" "application/octet-stream" largest) >>= ok
      kept.size `shouldBe` maxAttachmentSize

  it "whose files nothing refers to any more are deleted when the storage is next opened, and only then" $
    withPlaceIn backing $ \at -> do
      let dir = at.dataDir
          shard = attachmentsDir dir </> "ab"
      file <- withStorage defaultConfig at $ \st -> do
        importArchive st demoArchive >>= ok
        hello <- pageIn st "blog" "hello-world"
        a <- asAdmin st (uploadAttachment hello.id "gone.txt" "text/plain" "soon gone") >>= ok
        _ <- asAdmin st (uploadAttachment hello.id "kept.txt" "text/plain" "kept") >>= ok
        _ <- asAdmin st (deleteAttachment a.id) >>= ok
        file <- maybe (panic "not a hash") pure (blobFile (attachmentsDir at.dataDir) (blobOf "soon gone"))
        doesFileExist file `shouldReturn` True
        -- A write that never finished leaves a file behind, which goes too.
        Directory.createDirectoryIfMissing True shard
        writeFile (shard </> "incoming123") "half"
        -- Nobody else may open the directory meanwhile: a second storage
        -- would delete what this one may still be writing.
        (withStorage defaultConfig at (const pass) >> pure False) `catch` (\(_ :: DataDirInUse) -> pure True) `shouldReturn` True
        doesFileExist file `shouldReturn` True
        pure file
      withStorage defaultConfig at (const pass)
      doesFileExist file `shouldReturn` False
      doesFileExist (shard </> "incoming123") `shouldReturn` False
      storedBlobs (attachmentsDir at.dataDir) `shouldReturn` Set.fromList [blobOf "kept", blobOf treePng]
  where
    treePng = fromMaybe "" (head (Map.elems demoArchive.blobs))

wholeWikis :: Backing -> Spec
wholeWikis backing = describe "importArchive and exportArchive" $ do
  it "give back the wiki that was put in, its attachments under their hashes" $
    withDemo backing $ \st -> do
      exported <- exportArchive st "wiki-server-test" >>= ok
      contents (byHash exported) `shouldBe` contents (byHash demoArchive)
      exported.app `shouldBe` "wiki-server-test"

  it "carry the pages' comments into another storage, with their ids, authors, times and edits" $
    withDemo backing $ \st -> do
      hello <- pageIn st "blog" "hello-world"
      opened <- runStoredWiki st Administrator (openThread hello.id Nothing "From the administrator.") >>= ok
      editor <- whoFor st (As "editor")
      answer <- runStoredWiki st editor (reply hello.id opened.id "From the editor.") >>= ok
      _ <- runStoredWiki st editor (editComment hello.id opened.id answer.id "Edited by the editor.") >>= ok
      exported <- exportArchive st "wiki-server-test" >>= ok
      -- The administrator has no row among the users, so the archive
      -- names them among its comment authors, by login.
      exported.commentAuthors `shouldBe` [administratorUser]
      [(c.author.name, c.body, isJust c.editedAt) | t <- Map.findWithDefault [] hello.id exported.threads, t.id == opened.id, c <- t.comments]
        `shouldBe` [("Administrator", "From the administrator.", False), ("Edgar Editor", "Edited by the editor.", True)]
      -- The files of the archive read back as the same comments.
      (\a -> (a.threads, a.commentAuthors)) <$> readArchive (Map.fromList (writeArchive exported)) `shouldBe` Right (exported.threads, exported.commentAuthors)
      withStorageIn backing $ \_ fresh -> do
        importArchive fresh exported >>= ok
        again <- exportArchive fresh "wiki-server-test" >>= ok
        again.threads `shouldBe` exported.threads

  it "write the export as a zip file on disk that holds exportArchive's files, and that imports back as the same wiki" $
    withDemo backing $ \st -> do
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
        withStorageIn backing $ \_ fresh -> do
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
    withDemo backing $ \st -> do
      original <- tableRows st
      importArchive st demoArchive >>= (`shouldSatisfy` isLeft)
      tableRows st `shouldReturn` original

  it "refuse an archive without the bytes of an attachment, writing nothing" $
    withStorageIn backing $ \_ st -> do
      original <- tableRows st
      importArchive st demoArchive {blobs = mempty} >>= (`shouldSatisfy` isLeft)
      tableRows st `shouldReturn` original

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

-- | The search, with the same cases on both databases: SQLite's folded
-- text, and PostgreSQL's full-text search ("Wiki.Api.Info"'s
-- 'SearchKind'). Where the two differ by design (a part of a word, the
-- syntax of a web search engine), the case says what each does.
searching :: Backing -> Spec
searching backing = describe "the search" $ do
  -- A space of four pages: one with the word in its title, one with it in
  -- its text alone, one without it, and a template with it.
  let withPages act = withDemo backing $ \st -> do
        kind <- (\c -> c.search) <$> storageCapabilities st
        space <- asAdmin st (createSpace Nothing "Zoo") >>= ok
        let made title body = asAdmin st (createPage space.id Nothing title body) >>= ok
        inTitle <- made "Wombat burrows" "Burrowing animals of Australia."
        inText <- made "Marsupials" "A short note about the wombat and the quokka. Żółw is Polish for a turtle."
        without <- made "Birds" "The emu and the kookaburra."
        template <- made "Wombat form" "A template that names the wombat."
        _ <- asAdmin st (setPageTemplate template.id True) >>= ok
        act st kind space (inTitle, inText, without, template)
      hits st q = map (\h -> h.page) <$> asAdmin st (searchPages q)
      within space text = SearchQuery {text, space = Just space.id, includeSubspaces = True, limit = 50, templates = False}

  it "finds a word in a title or a text, the title first, and nothing for a word nowhere" $ withPages $ \st _ space (inTitle, inText, _, _) -> do
    hits st (within space "wombat") `shouldReturn` [inTitle.id, inText.id]
    hits st (within space "platypus") `shouldReturn` []

  it "ignores case and diacritics, in the query and in the page" $ withPages $ \st _ space (_, inText, _, _) -> do
    hits st (within space "QUOKKA") `shouldReturn` [inText.id]
    hits st (within space "zolw") `shouldReturn` [inText.id]
    hits st (within space "ŻÓŁW") `shouldReturn` [inText.id]

  it "leaves the templates out unless asked, and keeps to the space asked" $ withPages $ \st _ space (inTitle, inText, _, template) -> do
    hits st (within space "wombat") {templates = True} >>= (`shouldMatchList` [inTitle.id, inText.id, template.id])
    blog <- asAdmin st (getSpace (path "blog")) >>= ok
    hits st (within blog "wombat") `shouldReturn` []

  it "finds a part of a word on SQLite only, whose search is the demo's" $ withPages $ \st kind space (inTitle, inText, _, _) ->
    case kind of
      FoldedText -> hits st (within space "womb") `shouldReturn` [inTitle.id, inText.id]
      FullText -> do
        hits st (within space "womb") `shouldReturn` []
        -- Nor another form of the word: PostgreSQL's 'simple' configuration
        -- has no stemming, which is a language's.
        hits st (within space "burrow") `shouldReturn` []

  it "takes a phrase, or and a word to leave out on PostgreSQL, and every word on SQLite" $ withPages $ \st kind space (inTitle, inText, without, _) ->
    case kind of
      FullText -> do
        hits st (within space "\"wombat and the quokka\"") `shouldReturn` [inText.id]
        hits st (within space "\"quokka and the wombat\"") `shouldReturn` []
        hits st (within space "emu or quokka") >>= (`shouldMatchList` [inText.id, without.id])
        hits st (within space "wombat -quokka") `shouldReturn` [inTitle.id]
      FoldedText -> do
        hits st (within space "wombat quokka") `shouldReturn` [inText.id]
        hits st (within space "emu quokka") `shouldReturn` []
