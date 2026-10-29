-- | Export and import over HTTP: the wiki out as a zip file, and an archive
-- merged into a wiki that has content already, in two steps (a preview,
-- then the import as chosen), as "Wiki.Server.Import" describes.
module Test.Server.Import (spec) where

import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Network.HTTP.Types (methodPost, methodPut)
import Protolude
import Servant.API (toUrlPiece)
import Test.Database (Backing)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), ArchiveApi (..), CommentsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), NewAccount (..))
import Wiki.Api.Admin (ServerStatus (..))
import Wiki.Api.Comments (NewThread (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Import
import Wiki.Api.Links (attachmentUrl, links, spaceIconUrl)
import Wiki.Api.Types
import Wiki.Api.Version (pageVersion)
import Wiki.App.View.Common (pagePathOf)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..), formerAuthor)
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Export.Zip (unzipFiles, zipFiles)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..), withProfile)
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Storage.Blobs (blobOf)

spec :: Backing -> Spec
spec backing = describe "export and import" $ do
  intoAnEmptyWiki backing
  merging backing
  conflicts backing
  choices backing
  roundTrip backing
  profiles backing
  discussions backing
  refusals backing

-- | The admin listener's address of an endpoint.
admin :: Running -> Text -> Text
admin r address = r.admin <> "/admin/" <> address

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

time :: UTCTime
time = UTCTime (fromGregorian 2026 9 1) 0

-- | A space of an archive: its id, its parent's, its slug (and name).
space :: Text -> Maybe Text -> Text -> Space
space i parent s = spaceWith i parent s False "" ByName ByName

-- | A space of an archive, with its settings: public, math macros, and the
-- orders of its subspaces and its pages.
spaceWith :: Text -> Maybe Text -> Text -> Bool -> Text -> ChildOrder -> ChildOrder -> Space
spaceWith i parent s public mathMacros subspaceOrder pageOrder =
  Space
    { id = SpaceId i
    , name = "The " <> s
    , slug = slug s
    , parent = SpaceId <$> parent
    , public
    , mathMacros
    , createdAt = time
    , position = 0
    , subspaceOrder
    , pageOrder
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    }

-- | A page of an archive: its id, its space's, its parent's, its slug, and
-- its body; titled for its slug.
page :: Text -> Text -> Maybe Text -> Text -> Text -> Page
page i s parent sl body = pageWith i s parent sl body 0 []

-- | A page of an archive, with its position and its attachments.
pageWith :: Text -> Text -> Maybe Text -> Text -> Text -> Int -> [Attachment] -> Page
pageWith i s parent sl body position attachments =
  Page
    { id = PageId i
    , space = SpaceId s
    , parent = PageId <$> parent
    , title = "Title of " <> sl
    , slug = slug sl
    , body
    , attachments
    , createdAt = time
    , updatedAt = time
    , position
    , template = False
    }

-- | An attachment kept in an archive, under a blob of the archive's own.
picture :: Attachment
picture = Attachment {id = AttachmentId "a1", name = FileName "pic.png", mediaType = MimeType "image/png", size = 3, source = SourceBlob (BlobId "b1")}

-- | An archive of these spaces and pages, with a user and grants that an
-- import leaves out, and the bytes of 'picture'.
archive :: [Space] -> [Page] -> Archive
archive spaces pages =
  Archive
    { createdAt = time
    , app = "the tests"
    , users = [User {id = UserId "u1", login = Login "alice", displayName = "Alice"}]
    , groups = []
    , membership = mempty
    , grants = Grants {global = [GlobalGrant {subject = SubjectUser (UserId "u1"), permission = Administer}], spaces = [], access = Open}
    , spaces
    , pages
    , threads = mempty
    , commentAuthors = []
    , blobs = Map.fromList [(BlobId "b1", "PNG")]
    , audit = []
    }

zipped :: Archive -> LByteString
zipped a = BSL.fromStrict (zipFiles time (writeArchive a))

preview :: Running -> Archive -> IO ImportPlan
preview r a = multipart r (admin r links.archive.importPreview) [] [("archive", "wiki.zip", "application/zip", zipped a)] >>= jsonAs 200

apply :: Running -> Archive -> ImportChoices -> IO ImportSummary
apply r a cs =
  multipart r (admin r links.archive.importApply) [("choices", decodeUtf8 (BSL.toStrict (encode cs)))] [("archive", "wiki.zip", "application/zip", zipped a)] >>= jsonAs 200

summary :: ImportSummary
summary = ImportSummary {spacesCreated = 0, spacesMerged = 0, pagesCreated = 0, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}

-- | The server's space at a path.
spaceAt :: Running -> [Text] -> IO Space
spaceAt r path = ok200 (getUrl r (admin r (links.spaces.atPath (map slug path))))

-- | The server's page at a path of a space at a path.
pageAt :: Running -> [Text] -> [Text] -> IO Page
pageAt r s p = spaceAt r s >>= \x -> ok200 (getUrl r (admin r (links.spaces.pageAt x.id (map slug p))))

-- | A space made on the server, at the top level, named so that its slug
-- is the one given.
makeSpace :: Running -> Text -> IO Space
makeSpace r s = sendJson r methodPost (admin r links.spaces.create) NewSpace {parent = Nothing, name = s} >>= jsonAs 201

makePage :: Running -> Space -> Text -> Text -> IO Page
makePage r s title body = sendJson r methodPost (admin r (links.spaces.createPage s.id)) NewPage {parent = Nothing, title, body} >>= jsonAs 201

-- | The docs of the tests: a space with a subspace, a page with one under
-- it, the first with a picture.
docs :: Archive
docs =
  archive
    [space "s1" Nothing "docs", space "s2" (Just "s1") "notes"]
    [ pageWith "p1" "s1" Nothing "tour" "# Tour" 0 [picture]
    , page "p2" "s1" (Just "p1") "more" "More."
    , page "p3" "s2" Nothing "n1" "A note."
    ]

intoAnEmptyWiki :: Backing -> Spec
intoAnEmptyWiki backing = describe "into an empty wiki" $ do
  it "plans every space and page as new" $ withRunning backing $ \r -> do
    plan <- preview r docs
    [(s.path, s.status, [(p.path, p.attachments, p.conflict) | p <- s.pages]) | s <- plan.spaces]
      `shouldBe` [ ([slug "docs"], SpaceNew, [([slug "tour"], 1, Nothing), ([slug "tour", slug "more"], 0, Nothing)])
                 , ([slug "docs", slug "notes"], SpaceNew, [([slug "n1"], 0, Nothing)])
                 ]

  it "imports it all, attachments' bytes kept by their hash, and none of its people" $ withRunning backing $ \r -> do
    apply r docs importEverything `shouldReturn` summary {spacesCreated = 2, pagesCreated = 3, attachments = 1}
    tour <- pageAt r ["docs"] ["tour"]
    (tour.title, tour.body, tour.createdAt, tour.updatedAt) `shouldBe` ("Title of tour", "# Tour", time, time)
    (tour.id == PageId "p1") `shouldBe` False
    case tour.attachments of
      [a] -> do
        a.source `shouldBe` SourceBlob (blobOf "PNG")
        ((.body) <$> getUrl r (r.admin <> "/admin/" <> attachmentUrl a)) `shouldReturn` "PNG"
      other -> expectationFailure ("not one attachment: " <> show other)
    more <- pageAt r ["docs"] ["tour", "more"]
    more.parent `shouldBe` Just tour.id
    s <- ok200 (getUrl r (admin r links.admin.status))
    ((s :: ServerStatus).users, s.spaces, s.pages, s.attachments) `shouldBe` (0, 2, 3, 1)

merging :: Backing -> Spec
merging backing = describe "a space at the same path" $ do
  it "is merged: its pages added after the server's, its settings the server's but empty math macros" $ withRunning backing $ \r -> do
    ours <- makeSpace r "docs"
    _ :: Space <- ok200 (sendJson r methodPut (admin r (links.spaces.setPublic ours.id)) SpacePublic {public = True})
    _ :: Space <- ok200 (sendJson r methodPut (admin r (links.spaces.setOrder ours.id)) SpaceOrder {children = ChildPages, order = ByHand})
    intro <- makePage r ours "Intro" "Ours."
    let theirs =
          archive
            [spaceWith "s1" Nothing "docs" False "\\R: \\mathbb{R}" NewestFirst ByHand]
            [pageWith "p1" "s1" Nothing "tour" "Tour." 1 [], pageWith "p2" "s1" Nothing "guide" "Guide." 0 []]
    plan <- preview r theirs
    [(s.status, map (\p -> p.conflict) s.pages) | s <- plan.spaces] `shouldBe` [(SpaceMerged, [Nothing, Nothing])]
    apply r theirs importEverything `shouldReturn` summary {spacesMerged = 1, pagesCreated = 2}
    merged <- spaceAt r ["docs"]
    (merged.id, merged.public, merged.subspaceOrder, merged.mathMacros) `shouldBe` (ours.id, True, ByName, "\\R: \\mathbb{R}")
    pages <- ok200 (getUrl r (admin r (links.spaces.listPages ours.id)))
    -- The space's home page first, made with it.
    [(p.title, p.position) | (p :: PageSummary) <- pages] `shouldBe` [("Home", 0), ("Intro", intro.position), ("Title of guide", intro.position + 1), ("Title of tour", intro.position + 2)]

  it "keeps the server's math macros when it has some" $ withRunning backing $ \r -> do
    ours <- makeSpace r "docs"
    _ :: Space <- ok200 (sendJson r methodPut (admin r (links.spaces.setMathMacros ours.id)) SpaceMathMacros {mathMacros = "ours"})
    _ <- apply r (archive [spaceWith "s1" Nothing "docs" False "theirs" ByName ByName] []) importEverything
    (.mathMacros) <$> spaceAt r ["docs"] `shouldReturn` "ours"

conflicts :: Backing -> Spec
conflicts backing = describe "a page at the same path" $ do
  let theirs =
        archive
          [space "s1" Nothing "docs"]
          [pageWith "p1" "s1" Nothing "tour" "Imported." 0 [picture], page "p2" "s1" (Just "p1") "more" "More."]
      setUp r = do
        ours <- makeSpace r "docs"
        mine <- makePage r ours "Tour" "Ours."
        pure (ours, mine)

  it "is a conflict, with the server's page beside it" $ withRunning backing $ \r -> do
    (_, mine) <- setUp r
    plan <- preview r theirs
    [map (\p -> p.conflict) s.pages | s <- plan.spaces]
      `shouldBe` [[Just PageConflict {title = "Tour", updatedAt = mine.updatedAt, sameContent = False}, Nothing]]

  it "keeps the server's page unless told otherwise, and brings in the pages under it" $ withRunning backing $ \r -> do
    (_, mine) <- setUp r
    apply r theirs importEverything `shouldReturn` summary {spacesMerged = 1, pagesKept = 1, pagesCreated = 1}
    pageAt r ["docs"] ["tour"] `shouldReturn` mine
    more <- pageAt r ["docs"] ["tour", "more"]
    more.parent `shouldBe` Just mine.id

  it "takes the imported page when chosen: its title, body and attachments, as a new version in the same place" $ withRunning backing $ \r -> do
    (_, mine) <- setUp r
    let taken = importEverything {conflicts = [ConflictChoice {page = PageRef {space = [slug "docs"], page = [slug "tour"]}, resolution = TakeImported}]}
    apply r theirs taken `shouldReturn` summary {spacesMerged = 1, pagesReplaced = 1, pagesCreated = 1, attachments = 1}
    now <- pageAt r ["docs"] ["tour"]
    (now.id, now.slug, now.position, now.title, now.body, map (\a -> a.name.text) now.attachments)
      `shouldBe` (mine.id, mine.slug, mine.position, "Title of tour", "Imported.", ["pic.png"])
    (now.updatedAt > mine.updatedAt) `shouldBe` True
    -- An editor open on the server's page saves against its old version,
    -- which is now a conflict.
    stale <- send r methodPut (admin r (links.pages.save mine.id)) [("Content-Type", "application/json"), ("If-Match", encodeUtf8 (toUrlPiece (pageVersion mine)))] (encode PageEdit {title = "Tour", body = "Late."})
    stale.status `shouldBe` 409

  it "is the same content when nothing differs, attachments compared by their bytes" $ withRunning backing $ \r -> do
    apply r theirs importEverything `shouldReturn` summary {spacesCreated = 1, pagesCreated = 2, attachments = 1}
    plan <- preview r theirs
    [map (\p -> (.sameContent) <$> p.conflict) s.pages | s <- plan.spaces] `shouldBe` [[Just True, Just True]]
    apply r theirs importEverything `shouldReturn` summary {spacesMerged = 1, pagesKept = 2}

choices :: Backing -> Spec
choices backing = describe "what is left unchecked" $ do
  it "is not imported: a space with its subspaces, a page with the pages under it" $ withRunning backing $ \r -> do
    let skipped = importEverything {skipSpaces = [[slug "docs", slug "notes"]], skipPages = [PageRef {space = [slug "docs"], page = [slug "tour"]}]}
    apply r docs skipped `shouldReturn` summary {spacesCreated = 1, pagesSkipped = 3}
    (.status) <$> getUrl r (admin r (links.spaces.atPath [slug "docs", slug "notes"])) `shouldReturn` 404
    kept <- spaceAt r ["docs"]
    ok200 (getUrl r (admin r (links.spaces.listPages kept.id))) `shouldReturn` ([] :: [PageSummary])

  it "of a whole archive is nothing" $ withRunning backing $ \r -> do
    apply r docs importEverything {skipSpaces = [[slug "docs"]]} `shouldReturn` summary {pagesSkipped = 3}
    ok200 (getUrl r (admin r links.spaces.list)) `shouldReturn` ([] :: [Space])

roundTrip :: Backing -> Spec
roundTrip backing = describe "an export" $ do
  it "is a zip file of the whole wiki, which imports into another server as it was" $
    withRunning backing $ \origin -> withRunning backing $ \copy -> do
      _ <- apply origin docs importEverything
      reply <- getUrl origin (admin origin links.archive.export)
      (reply.status, header "Content-Type" reply) `shouldBe` (200, Just "application/zip")
      header "Content-Disposition" reply `shouldSatisfy` maybe False (BS.isPrefixOf "attachment; filename=\"wiki-")
      exported <- either (assertFailure . toS) pure (unzipFiles (BSL.toStrict reply.body) >>= readArchive)
      exported.app `shouldSatisfy` T.isPrefixOf "wiki-server "
      apply copy exported importEverything `shouldReturn` summary {spacesCreated = 2, pagesCreated = 3, attachments = 1}
      let shape :: Running -> IO [(Text, Slug, [(Text, Slug, Text, [(Text, Source)])])]
          shape r = do
            spaces <- ok200 (getUrl r (admin r links.spaces.list))
            for spaces $ \(s :: Space) -> do
              listed <- ok200 (getUrl r (admin r (links.spaces.listPages s.id)))
              -- The list has no bodies: each page is read by itself.
              pages <- for listed $ \(l :: PageSummary) -> ok200 (getUrl r (admin r (links.spaces.pageAt s.id (pagePathOf listed l.id))))
              pure (s.name, s.slug, [(p.title, p.slug, p.body, map (\a -> (a.name.text, a.source)) p.attachments) | (p :: Page) <- pages])
      expected <- shape origin
      shape copy `shouldReturn` expected

-- | The docs of the tests with a profile: a description, an image for its
-- icon, the tour for its home page, and shown as a blog.
profiled :: Archive
profiled =
  docs
    { spaces = [if s.id == SpaceId "s1" then withProfile SpaceProfile {description = "Guides.", icon = Just (IconImage (BlobId "b2") (MimeType "image/png")), homePage = Just (PageId "p1"), blog = True} s else s | s <- docs.spaces]
    , blobs = docs.blobs <> Map.fromList [(BlobId "b2", "ICON")]
    }

profiles :: Backing -> Spec
profiles backing = describe "a space's profile" $ do
  it "comes in with a new space: its description, its icon's image, and its home page as the page it became" $ withRunning backing $ \r -> do
    _ <- apply r profiled importEverything
    made <- spaceAt r ["docs"]
    tour <- pageAt r ["docs"] ["tour"]
    (made.description, made.homePage, made.blog) `shouldBe` ("Guides.", Just tour.id, True)
    case made.icon of
      Just (IconImage b mediaType) -> (b, mediaType.text) `shouldBe` (blobOf "ICON", "image/png")
      other -> expectationFailure ("not an image: " <> show other)
    served <- getUrl r (admin r (spaceIconUrl made))
    (served.status, served.body) `shouldBe` (200, "ICON")
    -- And goes out again with an export, the image among the files.
    exported <- getUrl r (admin r links.archive.export)
    back <- either (assertFailure . toS) pure (unzipFiles (BSL.toStrict exported.body) >>= readArchive)
    [(s.description, isJust s.homePage, s.blog, Map.lookup (blobOf "ICON") back.blobs) | s <- back.spaces, s.name == made.name] `shouldBe` [("Guides.", True, True, Just "ICON")]

  it "fills in what a merged space has none of, and keeps what it has" $ withRunning backing $ \r -> do
    ours <- makeSpace r "docs"
    _ <- apply r profiled importEverything
    merged <- spaceAt r ["docs"]
    -- Its own home page, made with it; the archive's description and icon,
    -- which it had none of.
    (merged.homePage, merged.description, merged.blog) `shouldBe` (ours.homePage, "Guides.", True)
    (\case Just (IconImage _ _) -> True; _ -> False) merged.icon `shouldBe` True
    _ :: Space <- ok200 (sendJson r methodPut (admin r (links.spaces.setProfile ours.id)) SpaceProfile {description = "Ours.", icon = Just (IconEmoji "🦉"), homePage = Nothing, blog = False})
    _ <- apply r profiled importEverything
    again <- spaceAt r ["docs"]
    tour <- pageAt r ["docs"] ["tour"]
    (again.description, again.icon, again.homePage) `shouldBe` ("Ours.", Just (IconEmoji "🦉"), Just tour.id)

-- | The docs of the tests with comments on the tour: a thread about the
-- whole page, opened by Alice (one of the archive's users) and answered by
-- Bob (not one of them, but named among its comment authors, by login),
-- with his answer edited; and an inline thread, resolved, by Carol, whom
-- the archive names only by her name.
discussed :: Archive
discussed =
  docs
    { threads = Map.fromList [(PageId "p1", [aboutThePage, inline])]
    , commentAuthors = [User {id = UserId "u7", login = Login "bob", displayName = "Bob"}]
    }
  where
    aboutThePage =
      Thread
        { id = CommentThreadId "t1"
        , page = PageId "p1"
        , anchor = Nothing
        , resolved = False
        , createdAt = time
        , comments = [comment "t1" "c1" (UserId "u1") "Is this right?" Nothing, comment "t1" "c2" (UserId "u7") "It is." (Just later)]
        }
    inline =
      Thread
        { id = CommentThreadId "t2"
        , page = PageId "p1"
        , anchor = Just Anchor {exact = "Tour", prefix = "", suffix = ""}
        , resolved = True
        , createdAt = time
        , comments = [comment "t2" "c3" (formerAuthor "Carol") "Fixed." Nothing]
        }
    comment thread i author text editedAt =
      Comment {id = CommentId i, thread = CommentThreadId thread, author = Author {id = author, name = author.text}, body = text, createdAt = time, editedAt}

later :: UTCTime
later = addUTCTime 60 time

-- | The threads of the server's page at a path of a space at a path: each
-- thread's id, whether it is resolved, and its comments' ids, authors,
-- bodies and edit times.
threadsAt :: Running -> [Text] -> [Text] -> IO [(CommentThreadId, Bool, [(CommentId, UserId, Text, Text, Maybe UTCTime)])]
threadsAt r s p = do
  found <- pageAt r s p
  ts <- ok200 (getUrl r (admin r (links.comments found.id).list))
  pure [(t.id, t.resolved, [(c.id, c.author.id, c.author.name, c.body, c.editedAt) | c <- t.comments]) | (t :: Thread) <- ts]

discussions :: Backing -> Spec
discussions backing = describe "a page's comments" $ do
  let expected alice =
        [ (CommentThreadId "t1", False, [(CommentId "c1", alice, "Alice Here", "Is this right?", Nothing), (CommentId "c2", UserId "~former:Bob", "Bob (not a user here)", "It is.", Just later)])
        , (CommentThreadId "t2", True, [(CommentId "c3", UserId "~former:Carol", "Carol (not a user here)", "Fixed.", Nothing)])
        ]
      makeAlice r = do
        made :: Account <- sendJson r methodPost (admin r links.admin.createUser) NewAccount {login = "alice", displayName = "Alice Here", password = Password "alice's password", email = Nothing} >>= jsonAs 201
        pure made.user.id

  it "come with a page the import makes: authors matched by login, anyone else kept by name, ids and times kept" $ withRunning backing $ \r -> do
    alice <- makeAlice r
    apply r discussed importEverything `shouldReturn` summary {spacesCreated = 2, pagesCreated = 3, attachments = 1}
    threadsAt r ["docs"] ["tour"] `shouldReturn` expected alice
    threadsAt r ["docs"] ["tour", "more"] `shouldReturn` []

  it "are not brought twice, whether the server's page is kept or replaced" $ withRunning backing $ \r -> do
    alice <- makeAlice r
    _ <- apply r discussed importEverything
    _ <- apply r discussed importEverything
    let taken = importEverything {conflicts = [ConflictChoice {page = PageRef {space = [slug "docs"], page = [slug "tour"]}, resolution = TakeImported}]}
    _ <- apply r discussed taken
    threadsAt r ["docs"] ["tour"] `shouldReturn` expected alice

  it "come with a page whose content the import replaces, after the page's own, but not with a page the server keeps" $ withRunning backing $ \r -> do
    ours <- makeSpace r "docs"
    mine <- makePage r ours "Tour" "Ours."
    _ :: Thread <- sendJson r methodPost (admin r (links.comments mine.id).open) NewThread {anchor = Nothing, body = "Our own."} >>= jsonAs 201
    _ <- apply r discussed importEverything
    map (\(_, _, cs) -> map (\(_, _, _, b, _) -> b) cs) <$> threadsAt r ["docs"] ["tour"] `shouldReturn` [["Our own."]]
    let taken = importEverything {conflicts = [ConflictChoice {page = PageRef {space = [slug "docs"], page = [slug "tour"]}, resolution = TakeImported}]}
    _ <- apply r discussed taken
    map (\(_, _, cs) -> map (\(_, _, _, b, _) -> b) cs) <$> threadsAt r ["docs"] ["tour"] `shouldReturn` [["Our own."], ["Is this right?", "It is."], ["Fixed."]]

  it "go out with an export, and into another server, kept by name where it has no such user" $
    withRunning backing $ \origin -> withRunning backing $ \copy -> do
      _ <- makeAlice origin
      _ <- apply origin discussed importEverything
      reply <- getUrl origin (admin origin links.archive.export)
      exported <- either (assertFailure . toS) pure (unzipFiles (BSL.toStrict reply.body) >>= readArchive)
      _ <- apply copy exported importEverything
      threadsAt copy ["docs"] ["tour"]
        `shouldReturn` [ (CommentThreadId "t1", False, [(CommentId "c1", UserId "~former:Alice Here", "Alice Here (not a user here)", "Is this right?", Nothing), (CommentId "c2", UserId "~former:Bob", "Bob (not a user here)", "It is.", Just later)])
                       , (CommentThreadId "t2", True, [(CommentId "c3", UserId "~former:Carol", "Carol (not a user here)", "Fixed.", Nothing)])
                       ]

refusals :: Backing -> Spec
refusals backing = describe "export and import" $ do
  it "are the administrator's only" $ withRunning backing $ \r -> do
    getUrl r (r.public <> "/" <> links.archive.export) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    multipart r (r.public <> "/" <> links.archive.importPreview) [] [("archive", "wiki.zip", "application/zip", zipped docs)] >>= jsonAs 403 >>= (`shouldBe` Forbidden)

  it "refuse a file that is not an archive, or choices that are not JSON" $ withRunning backing $ \r -> do
    multipart r (admin r links.archive.importPreview) [] [("archive", "wiki.zip", "application/zip", "not a zip")] >>= jsonAs 400 >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    multipart r (admin r links.archive.importApply) [("choices", "{")] [("archive", "wiki.zip", "application/zip", zipped docs)] >>= jsonAs 400 >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
