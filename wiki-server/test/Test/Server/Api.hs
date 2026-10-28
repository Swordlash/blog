-- | The API over HTTP, against a running server and its storage: what each
-- listener answers and as whom, the round trips of every kind of record,
-- versions and conflicts, uploads and their limit, attachments' bytes, the
-- administration's people, and every refusal as an 'ApiError'.
module Test.Server.Api (spec) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Network.HTTP.Types (hContentType, methodDelete, methodPost, methodPut)
import Protolude
import Servant.API (toUrlPiece)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), AttachmentsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), AccountDisabled (..), NewAccount (..), NewPassword (..))
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), Directory (..), GroupName (..), ServerStatus (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Api.Links (attachmentUrl, links, searchUrl, spaceIconUrl)
import Wiki.Api.Types
import Wiki.Api.Version (pageVersion)
import Wiki.App.Backend (maxAttachmentSize)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (AttachmentId (..), BlobId (..), GroupId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Order (ChildOrder (..), Children (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), searchQuery)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.User (Group (..), User (..))
import Wiki.Server.Storage (administratorUser)

spec :: Spec
spec = describe "the API over HTTP" $ do
  whoIsAsking
  spacesAndPages
  templates
  versions
  draftsAndSearch
  attachments
  refusals
  status
  people
  permissions
  profiles

-- | An address of the API on a listener: the public one's root, or the
-- admin one's @\/admin\/@.
at :: Text -> Text -> Text
at root address = root <> "/" <> address

onPublic, onAdmin :: Running -> Text -> Text
onPublic r = at r.public
onAdmin r = at (r.admin <> "/admin")

whoIsAsking :: Spec
whoIsAsking = describe "who is asking" $ do
  it "describes the server on both listeners" $ withRunning $ \r -> do
    ok200 (getUrl r (onPublic r links.info)) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}
    ok200 (getUrl r (onAdmin r links.info)) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}

  it "is nobody on the public listener and the administrator on the admin one" $ withRunning $ \r -> do
    anonymous <- ok200 (getUrl r (onPublic r links.session))
    (anonymous :: SessionInfo).user `shouldBe` Nothing
    operator <- ok200 (getUrl r (onAdmin r links.session))
    (operator :: SessionInfo).user `shouldBe` Just administratorUser
    map (\g -> g.permission) operator.grants.global `shouldBe` [Administer]

  it "logs each request with its listener, principal, route, status and time, but not its query" $ withRunning $ \r -> do
    _ <- getUrl r (onPublic r (searchUrl (searchQuery "secret words")))
    -- The line is written once the response has been sent, which the client
    -- can see before the server gets to it: wait for it, a little at a time.
    logged <- eventually (filter ("path=/api/v1/search" `T.isInfixOf`) <$> readIORef r.logged)
    case logged of
      [line] -> do
        line `shouldSatisfy` T.isInfixOf "listener=public principal=anonymous"
        line `shouldSatisfy` T.isInfixOf "method=GET path=/api/v1/search route=/api/v1/search status=200 ms="
        line `shouldNotSatisfy` T.isInfixOf "secret"
      other -> expectationFailure ("expected one line, got " <> show other)

-- | Wait, a little at a time, for a list to have something in it, and give
-- it: a log line written after the answer. Gives the last, empty, reading
-- when it never comes, so the test says what it expected.
eventually :: IO [a] -> IO [a]
eventually read = go (100 :: Int)
  where
    go 0 = read
    go n = read >>= \found -> if null found then threadDelay 50_000 >> go (n - 1) else pure found

-- | A space made by the administrator, public or not, with a page in it.
withSpace :: Running -> Bool -> IO (Space, Page)
withSpace r public = do
  space <- sendJson r methodPost (onAdmin r links.spaces.create) NewSpace {parent = Nothing, name = "Team notes"} >>= jsonAs 201
  _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public})
  page <- sendJson r methodPost (onAdmin r (links.spaces.createPage space.id)) NewPage {parent = Nothing, title = "Welcome", body = "# Welcome\n\nThe first page."} >>= jsonAs 201
  pure (space, page)

spacesAndPages :: Spec
spacesAndPages = describe "spaces and pages" $ do
  it "are made, changed and read back through the storage" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    ok200 (getUrl r (onAdmin r links.spaces.list)) `shouldReturn` [space]
    ok200 (getUrl r (onAdmin r (links.spaces.atPath [space.slug]))) `shouldReturn` space
    renamed <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.rename space.id)) SpaceName {name = "Notes"})
    (renamed :: Space).name `shouldBe` "Notes"
    ordered <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setOrder space.id)) SpaceOrder {children = ChildPages, order = NewestFirst})
    (ordered :: Space).pageOrder `shouldBe` NewestFirst
    pages <- ok200 (getUrl r (onAdmin r (links.spaces.listPages space.id)))
    -- Newest first: the page made after the space's home page, then it.
    map (\(p :: PageSummary) -> p.title) pages `shouldBe` ["Welcome", "Home"]
    reply <- getUrl r (onAdmin r (links.spaces.pageAt space.id [page.slug]))
    jsonAs 200 reply `shouldReturn` page
    header "ETag" reply `shouldBe` Just (encodeUtf8 (toUrlPiece (pageVersion page)))
    (.status) <$> send r methodDelete (onAdmin r (links.pages.delete page.id)) [] "" `shouldReturn` 204
    (.status) <$> getUrl r (onAdmin r (links.spaces.pageAt space.id [page.slug])) `shouldReturn` 404

  it "are hidden from an anonymous reader unless public, and never changed by one" $ withRunning $ \r -> do
    (private, _) <- withSpace r False
    ok200 (getUrl r (onPublic r links.spaces.list)) `shouldReturn` ([] :: [Space])
    getUrl r (onPublic r (links.spaces.listPages private.id)) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic private.id)) SpacePublic {public = True})
    map (\(s :: Space) -> s.id) <$> ok200 (getUrl r (onPublic r links.spaces.list)) `shouldReturn` [private.id]
    sendJson r methodPost (onPublic r links.spaces.create) NewSpace {parent = Nothing, name = "Mine"} >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    sendJson r methodPut (onPublic r (links.spaces.rename private.id)) SpaceName {name = "Ours"} >>= jsonAs 403 >>= (`shouldBe` Forbidden)

templates :: Spec
templates = describe "templates" $ do
  it "makes a page a template, which a search then finds only when asked to, and an anonymous reader may not" $ withRunning $ \r -> do
    (space, page) <- withSpace r True
    let search q = map (\(h :: SearchHit) -> h.page) <$> ok200 (getUrl r (onPublic r (searchUrl q)))
    search (searchQuery "first page") `shouldReturn` [page.id]
    sendJson r methodPut (onPublic r (links.pages.template page.id)) PageTemplate {template = True} >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    made <- ok200 (sendJson r methodPut (onAdmin r (links.pages.template page.id)) PageTemplate {template = True})
    ((made :: Page).template, made.updatedAt, made.body) `shouldBe` (True, page.updatedAt, page.body)
    (\(p :: Page) -> p.template) <$> ok200 (getUrl r (onPublic r (links.spaces.pageAt space.id [page.slug]))) `shouldReturn` True
    search (searchQuery "first page") `shouldReturn` []
    search (searchQuery "first page") {templates = True} `shouldReturn` [page.id]
    getUrl r (onPublic r "api/v1/search?q=first&templates") >>= jsonAs 200 >>= (`shouldBe` [page.id]) . map (\(h :: SearchHit) -> h.page)
    -- Not counted among the space's pages: its home page is.
    counts <- ok200 (getUrl r (onPublic r links.spaces.pageCounts))
    Map.lookup space.id counts `shouldBe` Just (1 :: Int)
    back <- ok200 (sendJson r methodPut (onAdmin r (links.pages.template page.id)) PageTemplate {template = False})
    (back :: Page).template `shouldBe` False
    search (searchQuery "first page") `shouldReturn` [page.id]

  it "refuses a space's home page, and what is not there" $ withRunning $ \r -> do
    (space, _) <- withSpace r False
    home <- maybe (panic "no home page") pure space.homePage
    sendJson r methodPut (onAdmin r (links.pages.template home)) PageTemplate {template = True} >>= jsonAs 400 >>= (`shouldSatisfy` isInvalid)
    sendJson r methodPut (onAdmin r (links.pages.template (PageId "no-such-page"))) PageTemplate {template = True} >>= jsonAs 404 >>= (`shouldBe` NotFound)
  where
    isInvalid = \case
      Invalid _ -> True
      _ -> False

versions :: Spec
versions = describe "versions" $ do
  let save r page tag = send r methodPut (onAdmin r (links.pages.save page.id)) ([(hContentType, "application/json")] <> [("If-Match", t) | Just t <- [tag]]) (encode PageEdit {title = "Welcome", body = "Saved."})
      etag = encodeUtf8 . toUrlPiece . pageVersion

  it "saves a page against its ETag, answering with the new one" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    reply <- save r page (Just (etag page))
    saved <- jsonAs 200 reply
    (saved :: Page).body `shouldBe` "Saved."
    header "ETag" reply `shouldBe` Just (etag saved)
    (saved.updatedAt > page.updatedAt) `shouldBe` True

  it "refuses a save against an older version as a conflict" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    _ :: Page <- save r page (Just (etag page)) >>= jsonAs 200
    save r page (Just (etag page)) >>= jsonAs 409 >>= \case
      Conflict _ -> pass
      other -> expectationFailure ("not a conflict: " <> show other)

  it "refuses a save without If-Match, or with one that is weak or not a version, as invalid" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    for_ [Nothing, Just ("W/" <> etag page), Just "*", Just "\"yesterday\""] $ \tag ->
      save r page tag >>= jsonAs 400 >>= \case
        Invalid _ -> pass
        other -> expectationFailure ("not invalid: " <> show other)

draftsAndSearch :: Spec
draftsAndSearch = describe "drafts and search" $ do
  it "keeps the administrator's draft of a page, and discards it" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` (Nothing :: Maybe Draft)
    draft <- ok200 (sendJson r methodPut (onAdmin r (links.pages.saveDraft page.id)) DraftEdit {base = page.updatedAt, title = "Welcome", body = "Unsaved."})
    (draft :: Draft).body `shouldBe` "Unsaved."
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` Just draft
    (.status) <$> send r methodDelete (onAdmin r (links.pages.discardDraft page.id)) [] "" `shouldReturn` 204
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` (Nothing :: Maybe Draft)

  it "finds the pages the asker may view, and no others" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    hits <- ok200 (getUrl r (onAdmin r (searchUrl (searchQuery "first"))))
    map (\(h :: SearchHit) -> h.page) hits `shouldBe` [page.id]
    ok200 (getUrl r (onPublic r (searchUrl (searchQuery "first")))) `shouldReturn` ([] :: [SearchHit])
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public = True})
    map (\(h :: SearchHit) -> h.page) <$> ok200 (getUrl r (onPublic r (searchUrl (searchQuery "first")))) `shouldReturn` [page.id]

  it "answers a limit beyond its own with at most its own" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    map (\(h :: SearchHit) -> h.page) <$> ok200 (getUrl r (onAdmin r "api/v1/search?q=first&limit=100000")) `shouldReturn` [page.id]
    ok200 (getUrl r (onAdmin r "api/v1/search?q=first&limit=-3")) `shouldReturn` ([] :: [SearchHit])

attachments :: Spec
attachments = describe "attachments" $ do
  let upload r page name mediaType content = multipart r (onAdmin r (links.pages.upload page.id)) [] [("file", name, mediaType, content)]
      bytes = BSL.pack [0 .. 99]

  it "are uploaded as a form and downloaded from their address, with their type, as data" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    a <- upload r page "chart.png" "image/png" bytes >>= jsonAs 201
    (a :: Attachment).size `shouldBe` 100
    reply <- getUrl r (onAdmin r (attachmentUrl a))
    (reply.status, reply.body) `shouldBe` (200, bytes)
    header "Content-Type" reply `shouldBe` Just "image/png"
    header "X-Content-Type-Options" reply `shouldBe` Just "nosniff"
    header "Content-Disposition" reply `shouldBe` Just "inline; filename=\"chart.png\"; filename*=UTF-8''chart.png"
    header "Content-Security-Policy" reply `shouldSatisfy` maybe False (BS.isSuffixOf "sandbox")
    -- Kept by this browser for five minutes: the bytes never change
    -- under their address.
    header "Cache-Control" reply `shouldBe` Just "private, max-age=300"
    revalidated <- getUrlWith r (onAdmin r (attachmentUrl a)) [("If-None-Match", fromMaybe "" (header "ETag" reply))]
    revalidated.status `shouldBe` 304

  it "are downloaded, not shown, when they could run as a page" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    for_ [("page.html", "text/html"), ("drawing.svg", "image/svg+xml"), ("notes día.pdf", "application/pdf")] $ \(name, mediaType) -> do
      a <- upload r page name mediaType bytes >>= jsonAs 201
      reply <- getUrl r (onAdmin r (attachmentUrl a))
      header "Content-Disposition" reply `shouldSatisfy` maybe False (BS.isPrefixOf "attachment; ")
      header "Content-Type" reply `shouldBe` Just (encodeUtf8 mediaType)
    a <- upload r page "notes día.pdf" "application/pdf" bytes >>= jsonAs 201
    reply <- getUrl r (onAdmin r (attachmentUrl a))
    header "Content-Disposition" reply `shouldBe` Just "attachment; filename=\"notes d_a.pdf\"; filename*=UTF-8''notes%20d%C3%ADa.pdf"

  it "answer a range of their bytes, as a video seeking asks" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    a <- upload r page "clip.mp4" "video/mp4" bytes >>= jsonAs 201
    reply <- getUrlWith r (onAdmin r (attachmentUrl a)) [("Range", "bytes=10-19")]
    (reply.status, reply.body) `shouldBe` (206, BSL.pack [10 .. 19])
    header "Content-Range" reply `shouldBe` Just "bytes 10-19/100"
    header "Content-Type" reply `shouldBe` Just "video/mp4"

  it "are not there under another name, nor for whoever may not view their page" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    a <- upload r page "chart.png" "image/png" bytes >>= jsonAs 201
    getUrl r (onAdmin r ("api/v1/attachments/" <> (a :: Attachment).id.text <> "/other.png")) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    getUrl r (onPublic r (attachmentUrl a)) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public = True})
    (.status) <$> getUrl r (onPublic r (attachmentUrl a)) `shouldReturn` 200
    (.status) <$> send r methodDelete (onAdmin r (links.attachments.delete a.id)) [] "" `shouldReturn` 204
    (.status) <$> getUrl r (onAdmin r (attachmentUrl a)) `shouldReturn` 404

  it "over 50 MB are refused with a 413, as an ApiError, before the handler" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    reply <- upload r page "big.bin" "application/octet-stream" (BSL.replicate (fromIntegral maxAttachmentSize + 1) 0)
    reply.status `shouldBe` 413
    json reply >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    ok200 (getUrl r (onAdmin r (links.spaces.pageAt page.space [page.slug]))) >>= \(p :: Page) -> p.attachments `shouldBe` []

refusals :: Spec
refusals = describe "refusals servant makes itself" $ do
  it "are ApiErrors too: a body that does not parse, an address with no endpoint, a method, a media type" $ withRunning $ \r -> do
    malformed <- send r methodPost (onAdmin r links.spaces.create) [(hContentType, "application/json")] "{\"name\": "
    malformed.status `shouldBe` 400
    json malformed >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    getUrl r (onAdmin r "api/v1/nothing-here") >>= jsonAs 404 >>= (`shouldBe` NotFound)
    getUrl r (onAdmin r "api/v1/spaces/at/Not%20A%20Slug") >>= jsonAs 400 >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    wrongMethod <- send r methodDelete (onAdmin r links.info) [] ""
    wrongMethod.status `shouldBe` 405
    json wrongMethod >>= (`shouldBe` Invalid "Method Not Allowed")
    wrongType <- send r methodPost (onAdmin r links.spaces.create) [(hContentType, "text/plain")] "Team"
    wrongType.status `shouldBe` 415
    (json wrongType :: IO ApiError) >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)

status :: Spec
status = describe "the server's status" $ do
  it "is given to the administrator, with the server's counts" $ withRunning $ \r -> do
    (_, _) <- withSpace r False
    s <- ok200 (getUrl r (onAdmin r links.admin.status))
    -- The space's home page, and the page made in it.
    ((s :: ServerStatus).spaces, s.pages, s.users, s.dataDir) `shouldBe` (1, 2, 0, toS r.dataDir)
    s.version `shouldSatisfy` T.isPrefixOf "wiki-server "

  it "is refused to an anonymous reader" $ withRunning $ \r ->
    getUrl r (onPublic r links.admin.status) >>= jsonAs 403 >>= (`shouldBe` Forbidden)

-- | The administration's users, accounts and groups over HTTP: answered on
-- the admin listener with no session, and on the public one to an
-- administrator's session; refused to an anonymous reader and to a user
-- signed in who is not an administrator, before anything they name is
-- looked for.
people :: Spec
people = describe "the wiki's people" $ do
  it "are the operator's on the admin listener, without a session" $ withDemoRunning identity $ \r -> do
    d <- ok200 (getUrl r (onAdmin r links.admin.directory))
    map (\u -> u.login) (d :: Directory).users `shouldBe` ["admin", "editor", "reader"]
    map (\g -> g.name) d.groups `shouldBe` ["writers"]
    let editor = loginId d "editor"
    marked <- sendJson r methodPut (onAdmin r (links.admin.setAdministrator editor)) AdministratorFlag {administrator = True}
    marked.status `shouldBe` 204
    made <- sendJson r methodPost (onAdmin r links.admin.createGroup) GroupName {name = "Reviewers"} >>= jsonAs 201
    added <- send r methodPut (onAdmin r (links.admin.addMember (made :: Group).id editor)) [] ""
    added.status `shouldBe` 204
    changed <- ok200 (getUrl r (onAdmin r links.admin.directory))
    (editor `Set.member` (changed :: Directory).administrators) `shouldBe` True
    map (\g -> g.name) changed.groups `shouldBe` ["Reviewers", "writers"]
    Map.lookup made.id changed.membership `shouldBe` Just (Set.singleton editor)
    -- Taken back, and the group gone.
    unmarked <- sendJson r methodPut (onAdmin r (links.admin.setAdministrator editor)) AdministratorFlag {administrator = False}
    unmarked.status `shouldBe` 204
    gone <- send r methodDelete (onAdmin r (links.admin.deleteGroup made.id)) [] ""
    gone.status `shouldBe` 204
    final <- ok200 (getUrl r (onAdmin r links.admin.directory))
    (editor `Set.member` (final :: Directory).administrators) `shouldBe` False
    map (\g -> g.name) final.groups `shouldBe` ["writers"]

  it "are an administrator's on the public listener, through their session" $ withAdminSession identity $ \r session -> do
    let get' address = getUrlWith r (onPublic r address) [session]
        put' :: (ToJSON b) => Text -> b -> IO Reply
        put' address body = send r methodPut (onPublic r address) [session, (hContentType, "application/json")] (encode body)
        post' :: (ToJSON b) => Text -> b -> IO Reply
        post' address body = send r methodPost (onPublic r address) [session, (hContentType, "application/json")] (encode body)
    d <- ok200 (get' links.admin.directory)
    map (\u -> u.login) (d :: Directory).users `shouldBe` ["admin", "editor", "reader"]
    (d.administrators, d.withPassword, d.disabled, d.creators) `shouldBe` (Set.singleton (loginId d "admin"), Set.singleton (loginId d "admin"), mempty, Set.singleton (loginId d "editor"))
    _ :: ServerStatus <- ok200 (get' links.admin.status)
    made <- post' links.admin.createGroup GroupName {name = "Reviewers"} >>= jsonAs 201
    (made :: Group).name `shouldBe` "Reviewers"
    renamed <- put' (links.admin.renameGroup made.id) GroupName {name = "Editors"} >>= jsonAs 200
    renamed `shouldBe` Group {id = made.id, name = "Editors"}
    -- The accounts' operations too.
    bea :: Account <- post' links.admin.createUser NewAccount {login = "bea", displayName = "Bea", password = "bea's password", email = Nothing} >>= jsonAs 201
    (bea.hasPassword, bea.disabled) `shouldBe` (True, False)
    reset :: Account <- put' (links.admin.setPassword bea.user.id) NewPassword {password = "another password"} >>= jsonAs 200
    reset.hasPassword `shouldBe` True
    off :: Account <- put' (links.admin.setDisabled bea.user.id) AccountDisabled {disabled = True} >>= jsonAs 200
    off.disabled `shouldBe` True
    (.status) <$> put' (links.admin.setCreateSpaces (loginId d "reader")) CreateSpacesFlag {createSpaces = True} `shouldReturn` 204
    changed <- ok200 (get' links.admin.directory)
    ((changed :: Directory).disabled, changed.creators, bea.user.id `Set.member` changed.withPassword)
      `shouldBe` (Set.singleton bea.user.id, Set.fromList [loginId d "editor", loginId d "reader"], True)

  it "are refused to a user signed in who is not an administrator" $ withAdminSession identity $ \r _ -> do
    givePassword r "user-editor" "editor's password"
    editor <- cookie <$> signInAs r "editor" "editor's password"
    d <- ok200 (getUrl r (onAdmin r links.admin.directory))
    let rita = loginId d "reader"
        forbidden reply = jsonAs 403 reply >>= (`shouldBe` Forbidden)
        put' :: (ToJSON b) => Text -> b -> IO Reply
        put' address body = send r methodPut (onPublic r address) [editor, (hContentType, "application/json")] (encode body)
    getUrlWith r (onPublic r links.admin.directory) [editor] >>= forbidden
    getUrlWith r (onPublic r links.admin.status) [editor] >>= forbidden
    put' (links.admin.setAdministrator (loginId d "editor")) AdministratorFlag {administrator = True} >>= forbidden
    put' (links.admin.setCreateSpaces (loginId d "editor")) CreateSpacesFlag {createSpaces = True} >>= forbidden
    put' (links.admin.setPassword rita) NewPassword {password = "a password of mine"} >>= forbidden
    put' (links.admin.setDisabled rita) AccountDisabled {disabled = True} >>= forbidden
    send r methodPost (onPublic r links.admin.createUser) [editor, (hContentType, "application/json")] (encode NewAccount {login = "mine", displayName = "", password = "a password of mine", email = Nothing}) >>= forbidden
    send r methodPost (onPublic r links.admin.createGroup) [editor, (hContentType, "application/json")] (encode GroupName {name = "Mine"}) >>= forbidden
    ok200 (getUrl r (onAdmin r links.admin.directory)) `shouldReturn` d

  it "are refused to an anonymous reader, who learns nothing of what they name" $ withDemoRunning identity $ \r -> do
    d <- ok200 (getUrl r (onAdmin r links.admin.directory))
    let rita = loginId d "reader"
        writers = maybe (panic "no writers") (\g -> g.id) (head (d :: Directory).groups)
        nobody = UserId "user-nobody"
        forbidden reply = jsonAs 403 reply >>= (`shouldBe` Forbidden)
    getUrl r (onPublic r links.admin.directory) >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.setAdministrator rita)) AdministratorFlag {administrator = True} >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.setAdministrator nobody)) AdministratorFlag {administrator = True} >>= forbidden
    sendJson r methodPost (onPublic r links.admin.createGroup) GroupName {name = "Mine"} >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.renameGroup writers)) GroupName {name = "Mine"} >>= forbidden
    send r methodDelete (onPublic r (links.admin.deleteGroup writers)) [] "" >>= forbidden
    send r methodPut (onPublic r (links.admin.addMember writers rita)) [] "" >>= forbidden
    send r methodDelete (onPublic r (links.admin.removeMember writers rita)) [] "" >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.setCreateSpaces rita)) CreateSpacesFlag {createSpaces = True} >>= forbidden
    sendJson r methodPost (onPublic r links.admin.createUser) NewAccount {login = "mine", displayName = "", password = "a password of mine", email = Nothing} >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.setPassword rita)) NewPassword {password = "a password of mine"} >>= forbidden
    sendJson r methodPut (onPublic r (links.admin.setDisabled nobody)) AccountDisabled {disabled = True} >>= forbidden
    -- Nothing changed.
    ok200 (getUrl r (onAdmin r links.admin.directory)) `shouldReturn` d
  where
    loginId :: Directory -> Text -> UserId
    loginId d login = maybe (panic ("no user " <> login)) (\u -> u.id) (find (\u -> u.login == login) d.users)

-- | Who may do what, given over HTTP by an administrator's session on the
-- public listener, and kept to by the server for each user's own: the
-- global create-spaces, and grants on a private space, which its subspace
-- inherits, until they are revoked. The demo's wiki: the editor may create
-- spaces; Team is private, its subspace Projects viewable by the reader;
-- the editor sees neither.
permissions :: Spec
permissions = describe "permissions given over HTTP" $ do
  it "lets whoever holds create-spaces make a top-level space, and nobody else" $ withAdminSession identity $ \r session -> do
    givePassword r "user-editor" "editor's password"
    givePassword r "user-reader" "reader's password"
    editor <- cookie <$> signInAs r "editor" "editor's password"
    rita <- cookie <$> signInAs r "reader" "reader's password"
    let create hs name = send r methodPost (onPublic r links.spaces.create) ((hContentType, "application/json") : hs) (encode NewSpace {parent = Nothing, name})
    (.status) <$> create [rita] "Rita's" `shouldReturn` 403
    (.status) <$> create [] "Nobody's" `shouldReturn` 403
    granted <- send r methodPut (onPublic r (links.admin.setCreateSpaces (UserId "user-reader"))) [session, (hContentType, "application/json")] (encode CreateSpacesFlag {createSpaces = True})
    granted.status `shouldBe` 204
    made <- create [rita] "Rita's" >>= jsonAs 201
    (made :: Space).parent `shouldBe` Nothing
    -- Her session says so, and she administers what she made.
    me <- ok200 (getUrlWith r (onPublic r links.session) [rita])
    map (\g -> g.permission) (me :: SessionInfo).grants.global `shouldBe` [CreateSpaces]
    (.status) <$> getUrlWith r (onPublic r (links.spaces.access made.id)) [rita] `shouldReturn` 200
    -- The demo's editor holds it already; taken from him, he may not.
    (.status) <$> create [editor] "Edgar's" `shouldReturn` 201
    _ <- send r methodPut (onPublic r (links.admin.setCreateSpaces (UserId "user-editor"))) [session, (hContentType, "application/json")] (encode CreateSpacesFlag {createSpaces = False})
    (.status) <$> create [editor] "Edgar's again" `shouldReturn` 403
    (.status) <$> create [] "Nobody's" `shouldReturn` 403
    (.status) <$> create [rita] "Rita's again" `shouldReturn` 201

  it "answers a space one may not view, and everything in it, as one that is not there: 404, not 403" $ withAdminSession identity $ \r session -> do
    givePassword r "user-reader" "reader's password"
    rita <- cookie <$> signInAs r "reader" "reader's password"
    let at' hs path = getUrlWith r (onPublic r (links.spaces.atPath (either (panic . show) identity (parsePath path)))) hs
        pageIn hs sid path = getUrlWith r (onPublic r (links.spaces.pageAt sid (either (panic . show) identity (parsePath path)))) hs
        save hs page = send r methodPut (onPublic r (links.pages.save page.id)) ([(hContentType, "application/json"), ("If-Match", encodeUtf8 (toUrlPiece (pageVersion page)))] <> hs) (encode PageEdit {title = page.title, body = "Mine."})
        hits hs sid = ok200 (getUrlWith r (onPublic r (searchUrl (searchQuery "handbook") {space = Just sid, includeSubspaces = False})) hs)
    team :: Space <- at' [session] "team" >>= jsonAs 200
    projects :: Space <- at' [session] "team/projects" >>= jsonAs 200
    handbook :: Page <- pageIn [session] team.id "team-handbook" >>= jsonAs 200
    map (\h -> h.page) <$> hits [session] team.id `shouldReturn` [handbook.id]
    -- Rita may view Projects, under Team, but not Team; nobody signed in
    -- may view neither.
    for_ [[rita], []] $ \hs -> do
      (at' hs "team" >>= jsonAs 404) `shouldReturn` NotFound
      (at' hs "no-such-space" >>= jsonAs 404) `shouldReturn` NotFound
      (pageIn hs team.id "team-handbook" >>= jsonAs 404) `shouldReturn` NotFound
      (pageIn hs team.id "no-such-page" >>= jsonAs 404) `shouldReturn` NotFound
      (save hs handbook >>= jsonAs 404) `shouldReturn` NotFound
      (getUrlWith r (onPublic r (links.pages.versions handbook.id)) hs >>= jsonAs 404) `shouldReturn` NotFound
      hits hs team.id `shouldReturn` ([] :: [SearchHit])
      hits hs (SpaceId "no-such-space") `shouldReturn` ([] :: [SearchHit])
    -- A space Rita may view, but not edit: what she may not do there is 403.
    wiki :: Page <- pageIn [rita] projects.id "the-wiki" >>= jsonAs 200
    (save [rita] wiki >>= jsonAs 403) `shouldReturn` Forbidden

  it "grants a user a private space, which its subspace inherits, until it is revoked" $ withAdminSession identity $ \r session -> do
    givePassword r "user-editor" "editor's password"
    editor <- cookie <$> signInAs r "editor" "editor's password"
    let at' hs path = getUrlWith r (onPublic r (links.spaces.atPath (either (panic . show) identity (parsePath path)))) hs
        grant how sid granted =
          send r methodPut (onPublic r (links.spaces.setGrant sid)) [session, (hContentType, "application/json")] (encode SpaceGrantChange {subject = SubjectUser (UserId "user-editor"), permission = how, granted})
        newPage' sid = send r methodPost (onPublic r (links.spaces.createPage sid)) [editor, (hContentType, "application/json")] (encode NewPage {parent = Nothing, title = "Granted", body = "Hello."})
    team :: Space <- at' [session] "team" >>= jsonAs 200
    projects :: Space <- at' [session] "team/projects" >>= jsonAs 200
    (.status) <$> at' [editor] "team" `shouldReturn` 404
    (.status) <$> at' [editor] "team/projects" `shouldReturn` 404
    -- Who may do what on Projects, as its administrator reads it: its own
    -- grants and Team's above it.
    initially <- ok200 (getUrlWith r (onPublic r (links.spaces.access projects.id)) [session])
    [(g.space == projects.id, g.subject, g.permission) | g <- (initially :: SpaceAccess).grants]
      `shouldBe` [(True, SubjectUser (UserId "user-reader"), View)]
    map (\u -> u.login) initially.users `shouldBe` ["admin", "editor", "reader"]
    -- View on Team: both, read only.
    (.status) <$> grant View team.id True `shouldReturn` 204
    (.status) <$> at' [editor] "team" `shouldReturn` 200
    (.status) <$> at' [editor] "team/projects" `shouldReturn` 200
    (.status) <$> newPage' projects.id `shouldReturn` 403
    -- Edit on Team: the subspace's pages too.
    (.status) <$> grant Edit team.id True `shouldReturn` 204
    (.status) <$> newPage' projects.id `shouldReturn` 201
    granted <- ok200 (getUrlWith r (onPublic r (links.spaces.access projects.id)) [session])
    [(g.space == team.id, g.permission) | g <- (granted :: SpaceAccess).grants, g.subject == SubjectUser (UserId "user-editor")]
      `shouldBe` [(True, View), (True, Edit)]
    -- The grants are not the editor's to read or change.
    (.status) <$> getUrlWith r (onPublic r (links.spaces.access team.id)) [editor] `shouldReturn` 403
    (.status) <$> send r methodPut (onPublic r (links.spaces.setGrant team.id)) [editor, (hContentType, "application/json")] (encode SpaceGrantChange {subject = SubjectUser (UserId "user-editor"), permission = AdministerSpace, granted = True})
      `shouldReturn` 403
    -- Revoked, they are gone, from both.
    (.status) <$> grant Edit team.id False `shouldReturn` 204
    (.status) <$> grant View team.id False `shouldReturn` 204
    (.status) <$> at' [editor] "team" `shouldReturn` 404
    (.status) <$> at' [editor] "team/projects" `shouldReturn` 404
    -- Granting to nobody is refused, after the permission.
    (.status) <$> send r methodPut (onPublic r (links.spaces.setGrant team.id)) [session, (hContentType, "application/json")] (encode SpaceGrantChange {subject = SubjectGroup (GroupId "no-such-group"), permission = View, granted = True})
      `shouldReturn` 400

-- | A space's profile and icon over HTTP: set by whoever administers the
-- space, its icon served to whoever may view it, and kept across a
-- restart, which deletes the files nothing refers to.
profiles :: Spec
profiles = describe "a space's profile and icon over HTTP" $ do
  let png = BSL.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]
      spaceNamed r hs path = getUrlWith r (onPublic r (links.spaces.atPath (either (panic . show) identity (parsePath path)))) hs >>= jsonAs 200
      -- Upload icons as the operator, and see them served as images to
      -- whoever may view their spaces and to nobody else: the blog's icon,
      -- as uploaded.
      icons :: Running -> IO Space
      icons r = do
        blog :: Space <- spaceNamed r [] "blog"
        team :: Space <- getUrl r (onAdmin r (links.spaces.atPath (either (panic . show) identity (parsePath "team")))) >>= jsonAs 200
        uploaded :: Space <- multipart r (onAdmin r (links.spaces.uploadIcon blog.id)) [] [("file", "icon.png", "image/png; charset=binary", png)] >>= jsonAs 200
        case uploaded.icon of
          Just (IconImage _ mediaType) -> mediaType `shouldBe` "image/png"
          other -> expectationFailure ("not an image: " <> show other)
        served <- getUrl r (onPublic r (spaceIconUrl uploaded))
        (served.status, served.body) `shouldBe` (200, png)
        lookup hContentType served.headers `shouldBe` Just "image/png"
        lookup "X-Content-Type-Options" served.headers `shouldBe` Just "nosniff"
        lookup "Content-Security-Policy" served.headers `shouldSatisfy` maybe False ("sandbox" `BS.isInfixOf`)
        -- Another blob is not the space's icon; another space's is its own.
        (.status) <$> getUrl r (onPublic r (links.spaces.icon blog.id (BlobId (T.replicate 64 "0")))) `shouldReturn` 404
        teamIcon :: Space <- multipart r (onAdmin r (links.spaces.uploadIcon team.id)) [] [("file", "icon.png", "image/png", png)] >>= jsonAs 200
        (.status) <$> getUrl r (onPublic r (spaceIconUrl teamIcon)) `shouldReturn` 404
        (.status) <$> getUrl r (onAdmin r (spaceIconUrl teamIcon)) `shouldReturn` 200
        -- An SVG, which could run scripts on the wiki's origin, is refused.
        multipart r (onAdmin r (links.spaces.uploadIcon blog.id)) [] [("file", "icon.svg", "image/svg+xml", "<svg/>")] >>= jsonAs 400 >>= \case
          Invalid _ -> pass
          other -> expectationFailure ("not invalid: " <> show other)
        pure uploaded
      setProfile r hs sid p = send r methodPut (onPublic r (links.spaces.setProfile sid)) ((hContentType, "application/json") : hs) (encode p)

  it "is set by whoever administers the space, and by nobody else" $ withAdminSession identity $ \r session -> do
    givePassword r "user-editor" "editor's password"
    editor <- cookie <$> signInAs r "editor" "editor's password"
    blog :: Space <- spaceNamed r [session] "blog"
    let profile = SpaceProfile {description = "Posts.", icon = Just (IconEmoji "📝"), homePage = blog.homePage, blog = blog.blog}
    -- The editor edits the blog, and does not administer it.
    (.status) <$> setProfile r [editor] blog.id profile `shouldReturn` 403
    (.status) <$> setProfile r [] blog.id profile `shouldReturn` 403
    (.status) <$> multipart r (onPublic r (links.spaces.uploadIcon blog.id)) [] [("file", "icon.png", "image/png", png)] `shouldReturn` 403
    set :: Space <- setProfile r [session] blog.id profile >>= jsonAs 200
    (set.description, set.icon) `shouldBe` ("Posts.", Just (IconEmoji "📝"))
    seen :: Space <- spaceNamed r [] "blog"
    (seen.description, seen.icon, seen.homePage) `shouldBe` ("Posts.", Just (IconEmoji "📝"), blog.homePage)
    setProfile r [session] blog.id SpaceProfile {description = "", icon = Nothing, homePage = Just (PageId "elsewhere"), blog = False} >>= jsonAs 400 >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)

  it "serves an uploaded icon to whoever may view the space, as an image and nothing else" $
    withDemoRestarted icons $ \uploaded again -> do
      -- The image stays across a restart, which deletes the files that
      -- nothing refers to.
      kept <- getUrl again (onPublic again (spaceIconUrl uploaded))
      (kept.status, kept.body) `shouldBe` (200, png)

  it "counts the pages of the spaces the asker may view" $ withDemoRunning identity $ \r -> do
    counts <- getUrl r (onPublic r links.spaces.pageCounts) >>= jsonAs 200
    spaces :: [Space] <- getUrl r (onPublic r links.spaces.list) >>= jsonAs 200
    sort [(s.name, n) | s <- spaces, Just n <- [Map.lookup s.id (counts :: Map SpaceId Int)]] `shouldBe` [("Blog", 2), ("Docs", 5)]
    everything :: Map SpaceId Int <- getUrl r (onAdmin r links.spaces.pageCounts) >>= jsonAs 200
    Map.size everything `shouldBe` 4
