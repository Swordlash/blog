-- | The demo's export and import: the in-memory wiki as an archive
-- ("Wiki.Core.Export") in a zip file and back, natively through
-- @zip-archive@ ("Wiki.Core.Export.Zip"), what an import refuses, and the
-- archives of versions 1 and 2 checked in under @test/data@, which every
-- later version must still import.
module Test.Export (spec, goldenArchive, goldenPath) where

import Data.Aeson (Value (..), decodeStrict', toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Protolude
import Test.HUnit (assertFailure)
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.ServerSettings (noServerSettings)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Mem
import Wiki.App.Backend.Mem.Archive (fromArchive, nextCounter, toArchive)
import Wiki.App.Backend.Mem.Persist (memDatabase, spacesStore)
import Wiki.App.Backend.Mem.State (MemState (..), Saved (..), completeVersions)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Attachment (Attachment (..), FileName (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor)
import Wiki.Core.Export (Archive, encodeJson, readArchive, writeArchive)
-- Qualified, for the fields of an archive, which the in-memory wiki has too.
import Wiki.Core.Export qualified as Export
import Wiki.Core.Export.Zip (unzipFiles, zipFiles)
import Wiki.Core.HomePage (HomeDocument (..), HomePage (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (parsePath)
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.User (Login (..), User (..))
import Wiki.Core.Version (Author (..))

-- | The golden archive of version 1: the demo as it was when version 1 of
-- the format was made, written once by the export of that version and
-- checked in. It is never written again.
goldenV1Path :: FilePath
goldenV1Path = "test/data/wiki-export-v1.zip"

-- | The golden archive of version 2, written once by 'goldenArchive' below
-- (in GHCi: @goldenArchive >>= Data.ByteString.writeFile goldenPath@) and
-- checked in. A version 3 adds a file of its own beside it.
goldenPath :: FilePath
goldenPath = "test/data/wiki-export-v2.zip"

-- | When the golden archives say they were written.
goldenTime :: UTCTime
goldenTime = UTCTime (fromGregorian 2026 10 22) 0

-- | What the golden archive of version 2 holds: the demo, with a file
-- uploaded that is not text and comments with a reply, as the demo's
-- export at version 2 writes it.
goldenArchive :: IO ByteString
goldenArchive = do
  st <- edited
  pure (zipFiles goldenTime (writeArchive (toArchive goldenTime "wiki-app 0.1.0.0" st)))

-- | The demo with some of everything changed: a space and a page made, a
-- page saved, a file of every byte uploaded, a thread of comments with a
-- reply by another user.
edited :: IO MemState
edited = do
  ref <- newMemWiki (demoState demoNow)
  runMemWiki ref $ do
    switchUser (Just (UserId "user-admin"))
    docs <- ok' =<< getSpace (path "docs")
    tour <- ok' =<< getPage docs.id (path "tour")
    _ <- ok' =<< uploadAttachment tour.id "bytes.bin" "application/octet-stream" (BS.pack [0 .. 255])
    space <- ok' =<< createSpace (Just docs.id) "Exported"
    -- Profiles: a description and an emoji, and an image.
    _ <- ok' =<< setSpaceProfile docs.id SpaceProfile {description = "How to use it.", icon = Just (IconEmoji "📘"), homePage = docs.homePage, blog = False}
    _ <- ok' =<< uploadSpaceIcon space.id "image/png" (BS.pack [0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    page <- ok' =<< createPage space.id Nothing "Exported page" "# Exported\n\nWith *Markdown*."
    _ <- ok' =<< savePage page.id page.updatedAt "Exported page" "# Exported, then saved"
    thread <- ok' =<< openThread tour.id Nothing "Is the tour up to date?"
    switchUser (Just (UserId "user-editor"))
    _ <- ok' =<< reply tour.id thread.id "It is now."
    pass
  st <- readIORef ref
  pure (withoutHistory st {current = Nothing, objectUrls = mempty})
  where
    ok' :: (MonadIO m) => Either WikiError a -> m a
    ok' = either (\e -> liftIO (assertFailure ("expected success, got " <> show e))) pure

-- | 'edited', with the orders of its spaces changed and its children moved
-- by hand: Team lists its subspaces newest first and its pages by hand,
-- with a page moved, and has a subspace with no pages.
ordered :: IO MemState
ordered = do
  st <- edited
  ref <- newMemWiki st {current = Just (UserId "user-admin")}
  runMemWiki ref $ do
    team <- either (panic . show) pure =<< getSpace (path "team")
    hollow <- either (panic . show) pure =<< createSpace (Just team.id) "Empty"
    -- A space with no page at all, which a new one is not: its home page
    -- goes.
    for_ hollow.homePage $ \h -> either (panic . show) pure =<< deletePage h
    _ <- either (panic . show) pure =<< setSpaceOrder team.id ChildSpaces NewestFirst
    _ <- either (panic . show) pure =<< setSpaceOrder team.id ChildPages ByHand
    made <- either (panic . show) pure =<< createPage team.id Nothing "Second" ""
    either (panic . show) (const pass) =<< shiftPage made.id ShiftToTop
  (\x -> withoutHistory x {current = Nothing}) <$> readIORef ref

-- | The wiki with each page's history as an import starts it (the page as
-- it is, saved by nobody known), with nobody notified of anything or
-- watching anything, no server settings, and each comment's author named
-- as the users name them. An archive has no history, no notifications and
-- no settings, and an import
-- names the authors from the users, so this is the wiki an archive of it
-- reads back as. (The demo's own comments keep an author's id as their
-- name, which nothing shows: the comments are listed with the users'
-- names.) The counter for new ids is the one an import starts: the ids of
-- the notifications left out do not count.
withoutHistory :: MemState -> MemState
withoutHistory st = imported {counter = nextCounter imported}
  where
    imported =
      completeVersions
        st
          { versions = mempty
          , notices = mempty
          , watches = mempty
          , choices = mempty
          , server = noServerSettings {SS.homePage = st.server.homePage}
          , threads = map (map (\t -> t {comments = map named t.comments})) st.threads
          }
    named c =
      Comment
        { id = c.id
        , thread = c.thread
        , author = maybe (absentAuthor c.author.id) (\u -> Author {id = u.id, name = u.displayName}) (Map.lookup c.author.id st.users)
        , body = c.body
        , createdAt = c.createdAt
        , editedAt = c.editedAt
        }

-- | The files every archive has, besides its tree of spaces and pages.
recordFiles :: [Text]
recordFiles = ["manifest.json", "users.json", "groups.json", "grants.json", "settings.json", "home-versions.json"]

-- | A wiki with its space grants in an order of their own: the store keeps
-- them by space.
normal :: MemState -> MemState
normal st = st {grants = Grants {global = st.grants.global, spaces = sort st.grants.spaces, access = st.grants.access}}

path :: Text -> [Slug]
path t = either (panic . show) identity (parsePath t)

-- | What an archive's files read back as.
readBack :: ByteString -> Either Text Archive
readBack zipped = unzipFiles zipped >>= readArchive

-- | The archive's files, by path.
filesOf :: Archive -> Map Text ByteString
filesOf = Map.fromList . writeArchive

-- | The records of every file whose name ends so (@space.json@,
-- @page.json@), each changed.
editRecords :: Text -> (KeyMap.KeyMap Value -> KeyMap.KeyMap Value) -> Map Text ByteString -> Map Text ByteString
editRecords name f = Map.mapWithKey change
  where
    change file bytes
      | not (name `T.isSuffixOf` file) = bytes
      | otherwise = case decodeStrict' bytes of
          Just (Object o) -> encodeJson (Object (f o))
          _ -> bytes

-- | The records of every file whose name ends so.
recordsIn :: Text -> Map Text ByteString -> [KeyMap.KeyMap Value]
recordsIn name files = [o | (file, bytes) <- Map.toList files, name `T.isSuffixOf` file, Just (Object o) <- [decodeStrict' bytes]]

refused :: (HasCallStack) => Text -> Either Text a -> Expectation
refused saying = \case
  Left why -> (saying, saying `T.isInfixOf` why) `shouldBe` (saying, True)
  Right _ -> expectationFailure ("expected a refusal saying " <> show saying)

spec :: Spec
spec = describe "Wiki.Core.Export, with the in-memory wiki" $ do
  it "exports and restores the public home page with a whole demo wiki" $ do
    st <- edited
    let previous = st.server.homePage
        home = previous {title = "Welcome", body = "Shared.", showSpaces = False}
        reference = fromMaybe (panic "no root document") previous.document
        rootPage = fromMaybe (panic "no root page") (Map.lookup reference.page st.pages)
        page = rootPage {P.title = home.title, P.body = home.body}
        custom = withoutHistory st {server = st.server {SS.homePage = home}, pages = Map.insert page.id page st.pages}
    archive <- either (assertFailure . toS) pure (readArchive (filesOf (toArchive goldenTime "test" custom)))
    archive.homePage `shouldBe` Just home
    (fromArchive archive).server.homePage `shouldBe` home

  it "reads a wiki back from its zip file as it was, attachments' bytes and comments included" $ do
    st <- edited
    let zipped = zipFiles goldenTime (writeArchive (toArchive goldenTime "test" st))
    case readBack zipped of
      Left why -> expectationFailure (toS why)
      Right archive -> do
        fromArchive archive `shouldBe` st
        archive.createdAt `shouldBe` goldenTime
        Map.elems archive.blobs `shouldContain` [BS.pack [0 .. 255]]
        [c.body | ts <- Map.elems archive.threads, t <- ts, c <- t.comments] `shouldContain` ["Is the tour up to date?", "It is now."]

  it "keeps an attachment's name outside ASCII through the zip file, and escapes what a file system refuses" $ do
    ref <- newMemWiki (demoState demoNow)
    runMemWiki ref $ do
      switchUser (Just (UserId "user-admin"))
      docs <- either (panic . show) pure =<< getSpace (path "docs")
      tour <- either (panic . show) pure =<< getPage docs.id (path "tour")
      for_ ["żółw.png", "x: c?*.txt"] $ \name ->
        either (panic . show) (const pass) =<< uploadAttachment tour.id name "application/octet-stream" (encodeUtf8 name)
    st <- readIORef ref
    let zipped = zipFiles goldenTime (writeArchive (toArchive goldenTime "test" st))
    unzipped <- either (assertFailure . toS) pure (unzipFiles zipped)
    Map.lookup "spaces/docs/pages/tour/attachments/żółw.png" unzipped `shouldBe` Just (encodeUtf8 "żółw.png")
    Map.lookup "spaces/docs/pages/tour/attachments/x%3A c%3F%2A.txt" unzipped `shouldBe` Just "x: c?*.txt"
    archive <- either (assertFailure . toS) pure (readArchive unzipped)
    [(x.name.text, Map.lookup b archive.blobs) | p <- archive.pages, x <- p.attachments, SourceBlob b <- [x.source], x.name.text /= "tree.png"]
      `shouldMatchList` [("żółw.png", Just (encodeUtf8 "żółw.png")), ("x: c?*.txt", Just "x: c?*.txt")]

  it "writes the manifest, the people, and a directory per space and page with each attachment's bytes as a file" $ do
    st <- edited
    let files = filesOf (toArchive goldenTime "test" st)
    filter (`Map.member` files) (filter (/= "home-versions.json") recordFiles) `shouldBe` filter (/= "home-versions.json") recordFiles
    -- The images spaces are pictured with have files of their own.
    [p | p <- Map.keys files, "/attachments/" `T.isInfixOf` p || "/icon." `T.isInfixOf` p] `shouldSatisfy` (\ps -> length ps == Map.size st.blobs)
    length (recordsIn "/page.json" files) `shouldBe` Map.size st.pages
    length (recordsIn "/space.json" files) `shouldBe` Map.size st.spaces
    Map.lookup "spaces/docs/pages/tour/attachments/bytes.bin" files `shouldBe` Just (BS.pack [0 .. 255])
    (decodeStrict' =<< Map.lookup "manifest.json" files) `shouldSatisfy` \case
      Just (Object o) -> KeyMap.lookup "format" o == Just (String "wiki-export") && KeyMap.lookup "formatVersion" o == Just (toJSON (2 :: Int))
      _ -> False

  it "carries a space's description, icon and home page, an icon's image as a file of its own" $ do
    st <- edited
    let files = filesOf (toArchive goldenTime "test" st)
        exported = [x | x <- Map.elems st.spaces, x.name == "Exported"]
    for_ exported $ \x -> do
      Map.lookup "spaces/docs/spaces/exported/icon.png" files `shouldBe` Just (BS.pack [0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
      case readArchive files of
        Left why -> expectationFailure (toS why)
        Right archive -> do
          [(y.icon, y.homePage) | y <- archive.spaces, y.id == x.id] `shouldBe` [(x.icon, x.homePage)]
          [y.description | y <- archive.spaces, y.name == "Docs"] `shouldBe` ["How to use it."]
    length exported `shouldBe` 1
    -- An icon whose file is missing is refused, and so is a home page that
    -- is not one of its space's pages.
    refused "icon" (readArchive (Map.delete "spaces/docs/spaces/exported/icon.png" files))
    let elsewhere = editRecords "/space.json" (\o -> if KeyMap.lookup "name" o == Just (String "Blog") then KeyMap.insert "homePage" (toJSON ("page-no-such" :: Text)) o else o) files
    refused "home page" (readArchive elsewhere)

  it "carries the comments' authors by login, and shows one no user has as not a user here" $ do
    st <- edited
    let files = filesOf (toArchive goldenTime "test" st)
        comments = "spaces/docs/pages/tour/comments.json"
        -- The reply's author, as another wiki's user whose login this one
        -- does not have.
        stranger = T.replace "\"login\":\"editor\"" "\"login\":\"stranger\"" . T.replace "\"displayName\":\"Edgar Editor\"" "\"displayName\":\"Stan\""
    archive <- either (assertFailure . toS) pure (readArchive (Map.adjust (encodeUtf8 . stranger . decodeUtf8) comments files))
    ref <- newMemWiki (fromArchive archive) {current = Just (UserId "user-admin")}
    threads <- runMemWiki ref $ do
      docs <- either (panic . show) pure =<< getSpace (path "docs")
      tour <- either (panic . show) pure =<< getPage docs.id (path "tour")
      either (panic . show) pure =<< listThreads tour.id
    [(c.author.id, c.author.name) | t <- threads, c <- t.comments]
      `shouldBe` [(UserId "user-admin", "Ada Admin"), (UserId "~former:Stan", "Stan (not a user here)")]

  describe "the archive of version 1" $ do
    it "still imports, with everything it held" $ do
      golden <- BS.readFile goldenV1Path
      case readBack golden of
        Left why -> expectationFailure (toS why)
        Right archive -> do
          map (\u -> u.login.text) archive.users `shouldBe` ["admin", "editor", "reader"]
          sort (map (\s -> s.name) archive.spaces) `shouldBe` ["Blog", "Docs", "Exported", "Projects", "Team"]
          map (\p -> p.body) archive.pages `shouldContain` ["# Exported, then saved"]
          let bytes = [x | p <- archive.pages, x <- p.attachments, x.name.text == "bytes.bin"]
          case bytes of
            [Attachment {source = SourceBlob blob}] -> Map.lookup blob archive.blobs `shouldBe` Just (BS.pack [0 .. 255])
            other -> expectationFailure ("expected bytes.bin, kept as bytes, got " <> show other)
          length (Map.toList archive.membership) `shouldBe` 1
          archive.threads `shouldBe` mempty

    it "imports with every space listing its children by name, made with its first page, and no positions" $ do
      golden <- BS.readFile goldenV1Path
      case readBack golden of
        Left why -> expectationFailure (toS why)
        Right archive -> do
          [(s.name, s.subspaceOrder, s.pageOrder, s.position) | s <- archive.spaces, s.subspaceOrder /= ByName || s.pageOrder /= ByName || s.position /= 0] `shouldBe` []
          [p.title | p <- archive.pages, p.position /= 0] `shouldBe` []
          let firstPage s = minimumMay [p.createdAt | p <- archive.pages, p.space == s.id]
          for_ archive.spaces $ \s -> Just s.createdAt `shouldBe` (firstPage s <|> Just archive.createdAt)

    it "imports with no math macros, which version 1 was first written without" $ do
      golden <- BS.readFile goldenV1Path
      case readBack golden of
        Left why -> expectationFailure (toS why)
        Right archive -> map (\s -> (s.name, s.mathMacros)) archive.spaces `shouldSatisfy` all ((== "") . snd)

  describe "the archive of version 2" $
    it "still imports, with everything it held, comments included" $ do
      golden <- BS.readFile goldenPath
      case readBack golden of
        Left why -> expectationFailure (toS why)
        Right archive -> do
          (archive.app, archive.createdAt) `shouldBe` ("wiki-app 0.1.0.0", goldenTime)
          map (\u -> u.login.text) archive.users `shouldBe` ["admin", "editor", "reader"]
          sort (map (\s -> s.name) archive.spaces) `shouldBe` ["Blog", "Docs", "Exported", "Projects", "Team"]
          [s.name | s <- archive.spaces, Just parent <- [s.parent], Just above <- [find (\x -> x.id == parent) archive.spaces], above.name == "Docs"] `shouldBe` ["Exported"]
          map (\p -> p.body) archive.pages `shouldContain` ["# Exported, then saved"]
          case [x | p <- archive.pages, x <- p.attachments, x.name.text == "bytes.bin"] of
            [Attachment {source = SourceBlob blob}] -> Map.lookup blob archive.blobs `shouldBe` Just (BS.pack [0 .. 255])
            other -> expectationFailure ("expected bytes.bin, kept as bytes, got " <> show other)
          [x.icon | x <- archive.spaces, x.name == "Docs"] `shouldBe` [Just (IconEmoji "📘")]
          let tour = [p.id | p <- archive.pages, p.title == "Tour"]
              said = [(c.author.name, c.body) | p <- tour, t <- Map.findWithDefault [] p (Export.threadsAmong archive.users archive), c <- t.comments]
          said `shouldBe` [("Ada Admin", "Is the tour up to date?"), ("Edgar Editor", "It is now.")]

  describe "compatibility" $ do
    it "reads a file with fields it does not know, ignoring them" $ do
      st <- edited
      let files = filesOf (toArchive goldenTime "test" st)
          extra = Map.insert "notes.json" "[]" (editRecords "/space.json" (KeyMap.insert "colour" (String "teal")) (editRecords "manifest.json" (KeyMap.insert "producer" (String "a later wiki")) files))
      fromArchive <$> readArchive extra `shouldBe` Right st

    it "keeps a space's math macros, written only for a space that has them" $ do
      st <- edited
      let macros = "\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\def\\x{1}"
      ref <- newMemWiki st {current = Just (UserId "user-admin")}
      _ <- runMemWiki ref $ do
        exported <- getSpace (path "docs/exported") >>= either (panic . show) pure
        setSpaceMathMacros exported.id macros
      withMacros <- (\x -> x {current = Nothing}) <$> readIORef ref
      let files = filesOf (toArchive goldenTime "test" withMacros)
          written = [(KeyMap.lookup "name" o, KeyMap.lookup "mathMacros" o) | o <- recordsIn "/space.json" files]
      [m | (Just (String "Exported"), m) <- written] `shouldBe` [Just (String macros)]
      [m | (Just (String "Blog"), m) <- written] `shouldBe` [Nothing]
      fromArchive <$> readArchive files `shouldBe` Right withMacros

    it "keeps the order of a space's children, and their positions, written only when not the default" $ do
      st <- ordered
      let files = filesOf (toArchive goldenTime "test" st)
          field name o = KeyMap.lookup name o
      [(field "subspaceOrder" o, field "pageOrder" o) | o <- recordsIn "/space.json" files, field "name" o == Just (String "Team")]
        `shouldBe` [(Just (String "newest-first"), Just (String "by-hand"))]
      [(field "subspaceOrder" o, field "pageOrder" o) | o <- recordsIn "/space.json" files, field "name" o == Just (String "Blog")] `shouldBe` [(Nothing, Nothing)]
      [field "position" o | o <- recordsIn "/page.json" files, field "title" o == Just (String "Team handbook")] `shouldBe` [Just (toJSON (1 :: Int))]
      [field "position" o | o <- recordsIn "/page.json" files, field "title" o == Just (String "Second")] `shouldBe` [Nothing]
      fromArchive <$> readArchive files `shouldBe` Right st

    it "reads an order it does not know as by name" $ do
      st <- ordered
      let files = editRecords "/space.json" (\o -> if KeyMap.member "pageOrder" o then KeyMap.insert "pageOrder" (String "by-colour") o else o) (filesOf (toArchive goldenTime "test" st))
      case readArchive files of
        Left why -> expectationFailure (toS why)
        Right archive -> [(s.name, s.pageOrder) | s <- archive.spaces, s.name == "Team"] `shouldBe` [("Team", ByName)]

    it "defaults the fields that may be missing" $ do
      st <- ordered
      let files = filesOf (Export.withoutHomeDocument (toArchive goldenTime "test" st)) {Export.homePage = Nothing, Export.homeVersions = []}
          thin =
            editRecords "/page.json" (KeyMap.delete "position") $
              editRecords
                "/space.json"
                (KeyMap.delete "public" . KeyMap.delete "mathMacros" . KeyMap.delete "createdAt" . KeyMap.delete "position" . KeyMap.delete "subspaceOrder" . KeyMap.delete "pageOrder" . KeyMap.delete "homePage" . KeyMap.delete "icon" . KeyMap.delete "description")
                files
      case readArchive thin of
        Left why -> expectationFailure (toS why)
        Right archive -> do
          all (\s -> not s.public && s.mathMacros == "" && s.position == 0 && s.subspaceOrder == ByName && s.pageOrder == ByName) archive.spaces `shouldBe` True
          all (\s -> isNothing s.homePage && isNothing s.icon && s.description == "") archive.spaces `shouldBe` True
          all (\p -> p.position == 0) archive.pages `shouldBe` True
          -- A space is taken to have been made with its first page, and
          -- one without pages when the archive was.
          let made name = [s.createdAt | s <- archive.spaces, s.name == name]
              firstPage name = [minimum [p.createdAt | p <- archive.pages, p.space == s.id] | s <- archive.spaces, s.name == name]
          made "Team" `shouldBe` firstPage "Team"
          made "Exported" `shouldBe` firstPage "Exported"
          made "Empty" `shouldBe` [goldenTime]

    it "refuses an archive of a newer version, saying so" $ do
      st <- edited
      let files = editRecords "manifest.json" (KeyMap.insert "formatVersion" (toJSON (3 :: Int))) (filesOf (toArchive goldenTime "test" st))
      refused "newer version of the wiki" (readArchive files)

  describe "refusing" $ do
    it "a file that is not a zip file" $
      refused "" (unzipFiles "not a zip file at all" >> pure ())

    it "an archive without one of its record files" $ do
      st <- edited
      refused "It has no users.json." (readArchive (Map.delete "users.json" (filesOf (toArchive goldenTime "test" st))))

    it "a zip file that is not an export" $
      refused "no manifest.json" (readBack (zipFiles goldenTime [("readme.txt", "hello")]))

    it "an attachment whose file is missing, or of the wrong size" $ do
      st <- edited
      let files = filesOf (toArchive goldenTime "test" st)
          file = fromMaybe (panic "no bytes.bin") (head [p | p <- Map.keys files, "bytes.bin" `T.isSuffixOf` p])
      refused "is not in the archive" (readArchive (Map.delete file files))
      refused "bytes, where spaces/docs/pages/tour/page.json says" (readArchive (Map.insert file "short" files))

    it "a page's directory without its record" $ do
      st <- edited
      let files = filesOf (toArchive goldenTime "test" st)
      refused "It has no spaces/docs/pages/tour/page.json." (readArchive (Map.delete "spaces/docs/pages/tour/page.json" files))

    it "a record that does not read" $ do
      st <- edited
      let files = filesOf (toArchive goldenTime "test" st)
      refused "spaces/docs/pages/tour/page.json" (readArchive (Map.insert "spaces/docs/pages/tour/page.json" "{ not json" files))

  it "leaves the pages' histories out, and starts each again with the page as it is" $ do
    ref <- newMemWiki (demoState demoNow)
    saved <- runMemWiki ref $ do
      switchUser (Just (UserId "user-admin"))
      docs <- either (panic . show) pure =<< getSpace (path "docs")
      tour <- either (panic . show) pure =<< getPage docs.id (path "tour")
      either (panic . show) pure =<< savePage tour.id tour.updatedAt "Tour" "Saved once more"
    st <- readIORef ref
    Map.size (Map.findWithDefault mempty saved.id st.versions) `shouldBe` 2
    let files = filesOf (toArchive goldenTime "test" st)
    Map.keys files `shouldSatisfy` all (\f -> f `elem` recordFiles || "spaces/" `T.isPrefixOf` f)
    back <- either (panic . toS) pure (readArchive files)
    let imported = fromArchive back
    Map.map Map.keys imported.versions `shouldBe` Map.map (\p -> [p.updatedAt]) imported.pages
    Map.lookup saved.id imported.versions `shouldBe` Just (Map.singleton saved.updatedAt Saved {title = "Tour", body = "Saved once more", author = Nothing})

  describe "importing into a kept wiki" $ do
    it "replaces the wiki in memory and in the database, staying signed in as before" $ do
      st <- edited
      db <- fresh "import"
      opened <- runMemDOM (openMemWiki db (demoState demoNow))
      archive <- either (panic . toS) pure (readBack (zipFiles goldenTime (writeArchive (toArchive goldenTime "test" st))))
      runMemWikiWith opened.store opened.wiki (importMemWiki archive) `shouldReturn` Right ()
      now <- readIORef opened.wiki
      -- The demo's server settings stay the demo's own.
      normal now `shouldBe` normal st {current = (demoState demoNow).current, server = (demoState demoNow).server}
      reopened <- runMemDOM (openMemWiki db (demoState demoNow))
      -- Loaded again, with the attachments' bytes and the versions read.
      normal <$> runMemWikiWith reopened.store reopened.wiki readWholly `shouldReturn` normal st {current = (demoState demoNow).current, server = (demoState demoNow).server}

    it "changes nothing when the database will not take it" $ do
      st <- edited
      db <- fresh "import-refused"
      opened <- runMemDOM (openMemWiki db (demoState demoNow))
      was <- readIORef opened.wiki
      -- A newer version of the program upgrades the database meanwhile.
      runMemDOM (IDB.put db {version = db.version + 1} spacesStore "space-1" "{}")
      archive <- either (panic . toS) pure (readArchive (filesOf (toArchive goldenTime "test" st)))
      result <- runMemWikiWith opened.store opened.wiki (importMemWiki archive)
      result `shouldSatisfy` isLeft
      readIORef opened.wiki `shouldReturn` was
  where
    fresh name = do
      let db = memDatabase ("wiki-export-test-" <> name)
      runMemDOM (IDB.deleteDatabase db.name)
      pure db
