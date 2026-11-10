{-# LANGUAGE MultiWayIf #-}

-- | The backend over HTTP, natively, over a transport the test answers: the
-- requests its client, derived from the API's type, makes (addresses,
-- methods, headers, bodies), how it reads answers and refusals, and what
-- it keeps of what it read. That the
-- server reads those requests as meant is @wiki-server-test@'s
-- (@Test.Server.Http@ runs the whole backend contract over them), and that
-- the browser's @fetch@ carries them is the browser suite's.
module Test.Backend.Http (spec) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.Net.Fetch qualified as Fetch
import Halogen.Subscription qualified as HS
import Protolude
import Servant.Client.Core (Response)
import Test.Backend.Opaque (opaqueServer)
import Test.Browser.Opaque (fakeChallenge, fakeRegistration)
import Test.Hspec
import Test.Opaque (fakeChallengeMade, fakeRegistrationMade)
import Test.Scripted (bodyOf, formOf, headersOf, jsonResponse, methodOf, responseWith)
import Wiki.Api (NotificationsApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (PasswordChange (..), SignInMethods (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Export (ExportFormat (..))
import Wiki.Api.Import (ImportChoices (..), ImportPlan (..), ImportSummary (..), importEverything)
import Wiki.Api.Links (searchUrl)
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Stars (StarredPage)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Vault (StoredVault (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..))
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http
import Wiki.App.Backend.Http.Cache (Cache (..), CachedDraft (..), afterEvent, cachedPage, emptyCache, withDraft, withPageAt, withPageLocation, withPages, withSearch, withSession, withSpaceAt, withSpaces)
import Wiki.App.Backend.Http.Client (endpointUrl, fromSessionInfo)
import Wiki.App.Backend.Http.Preload (decodePreload, encodePreload)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Assistant.Vault (Sealed (..), Vault (..), VaultTag (..), vaultFormat, withSealed)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (AttachmentId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Page (Page (..), summaryOf)
import Wiki.Core.Path (parsePath, pathOf)
import Wiki.Core.Search (SearchHit, SearchQuery (..), searchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Space qualified as S
import Wiki.Core.User (Login (..), Password (..), Standing (..), User (..))
import Wiki.Core.Vault (KeyId (..))
import Wiki.Core.Version (Author)

-- | A transport that answers as the function says, and keeps every request
-- it was given, the latest first.
scripted :: (HttpRequest -> Either Text Response) -> IO (Transport, IORef [HttpRequest])
scripted respond = do
  asked <- newIORef []
  pure (Transport (\r -> atomicModifyIORef' asked (\rs -> (r : rs, ())) $> respond r), asked)

-- | A backend over a scripted transport, and the requests it made.
backend :: (HttpRequest -> Either Text Response) -> IO (HttpEnv, IORef [HttpRequest])
backend respond = do
  (transport, asked) <- scripted respond
  (,asked) <$> newHttpEnv transport

ok :: (ToJSON a) => a -> Either Text Response
ok a = Right (jsonResponse 200 (encode a))

status :: Int -> BSL.ByteString -> Either Text Response
status n body = Right (jsonResponse n body)

demo :: MemState
demo = demoState demoNow

-- | A page of the demo, by path from under its space's home page, with its
-- space's path.
demoPage :: Text -> Text -> Page
demoPage s p =
  fromMaybe (panic ("no page " <> p)) $
    head
      [ page
      | page <- Map.elems demo.pages
      , Just sp <- [pathOf (`Map.lookup` demo.spaces) page.space]
      , sp == slugs s
      , Just space <- [Map.lookup page.space demo.spaces]
      , S.pagePath space (`Map.lookup` demo.pages) page.id == Just (slugs p)
      ]

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

-- | A vault as the server stores it; its contents do not matter here.
demoVault :: Vault
demoVault = withSealed Sealed {nonce = "nonce", ciphertext = "ciphertext"} Vault {format = vaultFormat, salt = "salt", items = mempty, wraps = mempty}

spec :: Spec
spec = describe "Wiki.App.Backend.Http" $ do
  requests
  answers
  browserFetch
  caching
  accounts
  preload
  exports

-- | A page or a space fetched as a document (WP5.56 of docs/PLAN.md): its
-- bytes with the name and the media type the server's answer gives, or the
-- server's refusal with its reason, which the Export menu shows.
exports :: Spec
exports = describe "its exports" $ do
  it "fetches a document at its address, named as the answer's Content-Disposition names it" $ do
    (env, asked) <- backend (const (Right (responseWith 200 [("Content-Type", "application/pdf"), ("Content-Disposition", "inline; filename=\"tour.pdf\"")] "%PDF-1.5")))
    runHttpWiki env (fetchExport (ExportPage (PageId "p1")) Pdf) `shouldReturn` Right Document {fileName = "tour.pdf", mediaType = "application/pdf", bytes = "%PDF-1.5"}
    map (\r -> (methodOf r, requestUrl r)) <$> readIORef asked `shouldReturn` [("GET", "api/v1/pages/p1/export/pdf")]

  it "names a document whose answer names none after its format" $ do
    (env, _) <- backend (const (Right (responseWith 200 [] "PK")))
    runHttpWiki env (fetchExport (ExportSpace (SpaceId "s1")) Docx)
      `shouldReturn` Right Document {fileName = "export.docx", mediaType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document", bytes = "PK"}

  it "gives the server's refusal with its reason, rather than a document" $ do
    (env, _) <- backend (const (status 400 "{\"error\":\"Invalid\",\"message\":\"PDF needs xelatex.\"}"))
    runHttpWiki env (fetchExport (ExportSpace (SpaceId "s1")) Pdf) `shouldReturn` Left (Invalid "PDF needs xelatex.")

  it "waits longer for a document than for any other read, since a PDF takes up to a minute to make" $ do
    (env, asked) <- backend (const (Right (responseWith 200 [] "")))
    _ <- runHttpWiki env (fetchExport (ExportPage (PageId "p1")) BeamerPdf)
    _ <- runHttpWiki env (fetchExport (ExportSpace (SpaceId "s1")) Html)
    _ <- runHttpWiki env (getPage (SpaceId "s1") (slugs "export/pdf"))
    map timeLimit <$> readIORef asked `shouldReturn` [requestTimeout, exportTimeout, exportTimeout]

  it "waits as long for a check of the TeX engine, which may hang until the server stops it" $ do
    (env, asked) <- backend (const (status 403 "{\"error\":\"Forbidden\"}"))
    _ <- runHttpWiki env checkTexEngine
    _ <- runHttpWiki env texEngine
    map (\r -> (requestUrl r, timeLimit r)) <$> readIORef asked `shouldReturn` [("api/v1/admin/tex-engine", requestTimeout), ("api/v1/admin/tex-engine/check", exportTimeout)]

-- | What the browser's transport makes of what @fetch@ did, which natively
-- is only that there is no network.
browserFetch :: Spec
browserFetch = describe "the browser's transport" $ do
  it "says why fetch gave no answer, as the application shows it" $ do
    fetchFailure (Fetch.JSError "TypeError" "Failed to fetch") `shouldBe` "the network or the server is down"
    fetchFailure (Fetch.JSError "AbortError" "signal is aborted without reason") `shouldBe` "the request was cancelled"
    fetchFailure (Fetch.JSError "SecurityError" "Refused.") `shouldBe` "Refused."
    fetchFailure (Fetch.JSError "Mystery" "") `shouldBe` "Mystery"

  it "says how long it waited for an answer that did not come" $ do
    noAnswerIn requestTimeout `shouldBe` "no answer in 30 seconds"
    noAnswerIn uploadTimeout `shouldBe` "no answer in 360 seconds"
    noAnswerIn 300 `shouldBe` "no answer in 300 milliseconds"

  it "gives an upload longer than any other request" $ do
    let hello = demoPage "blog" "hello-world"
    (env, asked) <- backend (const (status 500 ""))
    _ <- runHttpWiki env (uploadAttachment hello.id "f" "text/plain" "bytes")
    _ <- runHttpWiki env (savePage hello.id hello.updatedAt "t" "b")
    _ <- runHttpWiki env (getSpace (slugs "docs"))
    map timeLimit <$> readIORef asked `shouldReturn` [requestTimeout, requestTimeout, uploadTimeout]

  it "has no network natively, which the backend takes for the wiki out of reach" $ do
    env <- newHttpEnv browserTransport
    runHttpWiki env (getSpace (slugs "docs")) `shouldReturn` Left (Unreachable "there is no network natively")

requests :: Spec
requests = describe "its requests" $ do
  let hello = demoPage "blog" "hello-world"
  it "reads at the API's addresses" $ do
    (env, asked) <- backend (const (ok ([] :: [Space])))
    _ <- runHttpWiki env listSpaces
    _ <- runHttpWiki env (getPage hello.space (slugs "a/b"))
    _ <- runHttpWiki env (searchPages (searchQuery "two words"))
    rs <- reverse <$> readIORef asked
    map (\r -> (methodOf r, requestUrl r, bodyOf r)) rs
      `shouldBe` [ ("GET", "api/v1/spaces", Nothing)
                 , ("GET", "api/v1/spaces/" <> hello.space.text <> "/pages/at/a/b", Nothing)
                 , ("GET", "api/v1/search?q=two%20words&limit=50", Nothing)
                 ]

  it "writes a search's query as the server reads it back" $ do
    (env, asked) <- backend (const (ok ([] :: [SearchHit])))
    let q = (searchQuery "x y") {space = Just hello.space, includeSubspaces = False, templates = True}
    _ <- runHttpWiki env (searchPages q)
    map requestUrl <$> readIORef asked `shouldReturn` ["api/v1/search?q=x%20y&space=" <> hello.space.text <> "&only&limit=50&templates"]
    map requestUrl <$> readIORef asked `shouldReturn` [searchUrl q]

  it "asks for a list in the query a parameter at a time, and names that address without asking" $ do
    (env, asked) <- backend (const (ok (mempty :: Map Text Author)))
    _ <- runHttpWiki env (mentionable ["ada", "edgar"])
    let people = endpointUrl (\e -> e.notifications.people ["ada", "edgar"])
    people `shouldBe` "api/v1/notifications/people?login=ada&login=edgar"
    map requestUrl <$> readIORef asked `shouldReturn` [people]

  it "saves against the version it started from, in If-Match, with the edit as JSON" $ do
    (env, asked) <- backend (const (ok hello))
    _ <- runHttpWiki env (savePage hello.id hello.updatedAt "New title" "New body")
    [r] <- readIORef asked
    methodOf r `shouldBe` "PUT"
    requestUrl r `shouldBe` "api/v1/pages/" <> hello.id.text
    headersOf r
      `shouldBe` [ ("If-Match", "\"2026-09-01T12:00:00Z\"")
                 , ("X-Wiki-Request", "1")
                 , ("Accept", "application/json;charset=utf-8,application/json")
                 , ("Content-Type", "application/json;charset=utf-8")
                 ]
    bodyOf r `shouldBe` Just ("application/json;charset=utf-8", "{\"body\":\"New body\",\"title\":\"New title\"}")

  it "sends no plain write or search for a space the server says is encrypted now, though the cached list says it is plain" $ do
    let blog = fromMaybe (panic "no blog") (Map.lookup hello.space demo.spaces)
        nowEncrypted = blog {encryption = Just (KeyId "a-key")}
    (transport, asked) <- scripted $ \r ->
      if
        | requestUrl r == "api/v1/spaces" -> ok [nowEncrypted]
        | requestUrl r == endpointUrl (\e -> e.spaces.pageAt hello.space (slugs "hello-world")) -> ok hello
        | otherwise -> status 500 ""
    env <- newHttpEnvWith transport (withSpaces [blog] emptyCache)
    -- Read while the cached list says the space is plain.
    runHttpWiki env (getPage hello.space (slugs "hello-world")) `shouldReturn` Right hello
    -- Every write that would carry the page's text asks for the list first,
    -- and sends nothing once it says the space is encrypted. (Natively the
    -- encrypted way then stops: there is no WebCrypto.)
    runHttpWiki env (savePage hello.id hello.updatedAt "Hello" "Edited") >>= (`shouldSatisfy` isLeft)
    runHttpWiki env (saveDraft hello.id hello.updatedAt "Hello" "Edited") >>= (`shouldSatisfy` isLeft)
    runHttpWiki env (uploadAttachment hello.id "a.txt" "text/plain" "bytes") >>= (`shouldSatisfy` isLeft)
    runHttpWiki env (openThread hello.id Nothing "A comment") >>= (`shouldSatisfy` isLeft)
    runHttpWiki env (createPage hello.space Nothing "New" "Text") >>= (`shouldSatisfy` isLeft)
    -- A search limited to the space is not sent.
    runHttpWiki env (searchPages (searchQuery "words") {space = Just hello.space, includeSubspaces = True}) `shouldReturn` []
    sent <- readIORef asked
    [(methodOf r, requestUrl r) | r <- sent, methodOf r /= "GET" || "api/v1/search" `T.isPrefixOf` requestUrl r] `shouldBe` []

  it "keeps a draft with the version it started from in the body" $ do
    (env, asked) <- backend (const (ok Draft {page = hello.id, author = UserId "admin", title = "t", body = "b", base = hello.updatedAt, savedAt = hello.updatedAt}))
    _ <- runHttpWiki env (saveDraft hello.id hello.updatedAt "t" "b")
    [r] <- readIORef asked
    (methodOf r, requestUrl r) `shouldBe` ("PUT", "api/v1/pages/" <> hello.id.text <> "/draft")
    snd <$> bodyOf r `shouldBe` Just "{\"base\":\"2026-09-01T12:00:00Z\",\"body\":\"b\",\"title\":\"t\"}"

  it "deletes with DELETE, and takes a 204 for done" $ do
    (env, asked) <- backend (const (status 204 ""))
    runHttpWiki env (deleteAttachment (AttachmentId "a 1")) `shouldReturn` Right ()
    map (\r -> (methodOf r, requestUrl r)) <$> readIORef asked `shouldReturn` [("DELETE", "api/v1/attachments/a%201")]

  it "uploads a file as a multipart form, its name quoted" $ do
    (env, asked) <- backend (const (status 500 ""))
    _ <- runHttpWiki env (uploadAttachment hello.id "say \"hi\" ü.txt" "text/plain" "the bytes")
    [r] <- readIORef asked
    (methodOf r, requestUrl r) `shouldBe` ("POST", "api/v1/pages/" <> hello.id.text <> "/attachments")
    fst <$> bodyOf r `shouldSatisfy` maybe False ("multipart/form-data;boundary=" `T.isPrefixOf`)
    case formOf r of
      Just (boundary, form) ->
        form
          `shouldBe` mconcat
            [ "--" <> boundary <> "\r\n"
            , "Content-Disposition: form-data; name=\"file\"; filename=\"say \\\"hi\\\" "
            , encodeUtf8 "ü"
            , ".txt\"\r\nContent-Type: text/plain\r\n\r\nthe bytes\r\n--" <> boundary <> "--"
            ]
      Nothing -> expectationFailure "no form"

  it "writes each form with a boundary of its own, too long for a file to hold by chance" $ do
    (env, asked) <- backend (const (status 500 ""))
    _ <- runHttpWiki env (uploadAttachment hello.id "a.txt" "text/plain" "a")
    _ <- runHttpWiki env (uploadAttachment hello.id "b.txt" "text/plain" "b")
    boundaries <- mapMaybe (fmap fst . formOf) <$> readIORef asked
    length boundaries `shouldBe` 2
    ordNub boundaries `shouldBe` boundaries
    map BS.length boundaries `shouldBe` [55, 55]

  it "asks for an import's preview with the archive as the form's file" $ do
    (env, asked) <- backend (const (ok (ImportPlan [])))
    runHttpWiki env (previewImport "PK zipped") `shouldReturn` Right (ImportPlan [])
    [r] <- readIORef asked
    (methodOf r, requestUrl r) `shouldBe` ("POST", "api/v1/import/preview")
    case formOf r of
      Just (boundary, form) ->
        form
          `shouldBe` ( "--"
                         <> boundary
                         <> "\r\nContent-Disposition: form-data; name=\"archive\"; filename=\"wiki.zip\"\r\nContent-Type: application/zip\r\n\r\nPK zipped\r\n--"
                         <> boundary
                         <> "--"
                     )
      Nothing -> expectationFailure "no form"

  it "applies an import with the archive again and the choices as a field that is not a file" $ do
    let summary = ImportSummary {spacesCreated = 1, spacesMerged = 0, pagesCreated = 2, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}
        choices = importEverything {skipSpaces = [slugs "docs/notes"]}
    (env, asked) <- backend (const (ok summary))
    runHttpWiki env (applyImport "PK zipped" choices) `shouldReturn` Right summary
    [r] <- readIORef asked
    (methodOf r, requestUrl r) `shouldBe` ("POST", "api/v1/import/apply")
    case formOf r of
      Just (boundary, form) ->
        form
          `shouldBe` mconcat
            [ "--" <> boundary <> "\r\nContent-Disposition: form-data; name=\"choices\"\r\nContent-Type: text/plain\r\n\r\n"
            , toS (encode choices)
            , "\r\n--" <> boundary <> "\r\nContent-Disposition: form-data; name=\"archive\"; filename=\"wiki.zip\"\r\nContent-Type: application/zip\r\n\r\nPK zipped\r\n"
            , "--" <> boundary <> "--"
            ]
      Nothing -> expectationFailure "no form"

  it "forgets what it read once an import has been applied" $ do
    let summary = ImportSummary {spacesCreated = 0, spacesMerged = 0, pagesCreated = 0, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}
    (env, _) <- backend $ \r ->
      if requestUrl r == "api/v1/spaces" then ok ([] :: [Space]) else ok summary
    _ <- runHttpWiki env listSpaces
    ((\c -> c.spaces) <$> cacheOf env) `shouldReturn` Just []
    _ <- runHttpWiki env (applyImport "PK" importEverything)
    ((\c -> c.spaces) <$> cacheOf env) `shouldReturn` Nothing

  it "gives an attachment's address without asking" $ do
    (env, asked) <- backend (const (Left "not asked"))
    for_ (head hello.attachments) $ \a -> do
      url <- runHttpWiki env (attachmentUrl a)
      url `shouldSatisfy` (\u -> "api/v1/attachments/" `T.isPrefixOf` u || "https://" `T.isPrefixOf` u)
    readIORef asked `shouldReturn` []

answers :: Spec
answers = describe "its answers" $ do
  let read' :: Either Text Response -> IO (Either WikiError Space)
      read' answered = do
        (env, _) <- backend (const answered)
        runHttpWiki env (getSpace (slugs "docs"))
  it "reads a refusal by the error its body names" $ do
    read' (status 404 "{\"error\":\"NotFound\"}") `shouldReturn` Left NotFound
    read' (status 403 "{\"error\":\"Forbidden\"}") `shouldReturn` Left Forbidden
    read' (status 409 "{\"error\":\"Conflict\",\"message\":\"Saved since.\"}") `shouldReturn` Left (Conflict "Saved since.")
    read' (status 400 "{\"error\":\"Invalid\",\"message\":\"A title, please.\"}") `shouldReturn` Left (Invalid "A title, please.")

  it "reads a refusal without such a body by its status" $ do
    read' (status 404 "") `shouldReturn` Left NotFound
    read' (status 401 "") `shouldReturn` Left Forbidden
    read' (status 413 "Too large") `shouldReturn` Left (Invalid "Too large")
    read' (status 405 "<html>a proxy's page</html>") `shouldReturn` Left (Invalid "The request was refused (405).")

  it "takes a failing server, a broken answer and no answer for out of reach" $ do
    read' (status 500 "") `shouldReturn` Left (Unreachable "the server failed, with status 500")
    read' (status 502 "<html>Bad gateway</html>") `shouldReturn` Left (Unreachable "the server failed, with status 502")
    read' (Left "the network or the server is down") `shouldReturn` Left (Unreachable "the network or the server is down")
    let outOfReach = \case
          Left (Unreachable _) -> True
          _ -> False
    -- A captive portal's page, which is no JSON.
    read' (Right (responseWith 200 [("Content-Type", "text/html")] "<html>a captive portal</html>")) >>= (`shouldSatisfy` outOfReach)
    -- JSON, but not the space the API declares.
    read' (status 200 "<html>a captive portal</html>") >>= (`shouldSatisfy` outOfReach)
    read' (status 200 "{\"spaces\": 3}") >>= (`shouldSatisfy` outOfReach)
    -- A success, but not the one the API declares for a read.
    read' (status 201 "{}") `shouldReturn` Left (Unreachable "its answer was not one the wiki can read: status 201")

  it "throws from a read without an Either, for attempt to catch" $ do
    (env, _) <- backend (const (Left "down"))
    runHttpWiki env (attempt listSpaces) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env (attempt session) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env (attempt (searchPages (searchQuery "x"))) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env listSpaces `shouldThrow` (== Unreachable "down")

  it "returns a refusal from a read with an Either" $ do
    (env, _) <- backend (const (status 403 "{\"error\":\"Forbidden\"}"))
    runHttpWiki env (getSpace (slugs "team")) `shouldReturn` Left Forbidden

  it "fetches the vault against the version it has, and takes a 304 for that version and a 404 for none" $ do
    let stored = StoredVault {tag = VaultTag "v2", vault = demoVault}
        vaultAnswer = \case
          Just (VaultTag "v2") -> status 304 ""
          Just _ -> ok stored
          Nothing -> status 404 (encode ApiError.NotFound)
    (env, asked) <- backend $ \r -> vaultAnswer (VaultTag <$> lookup "If-None-Match" (headersOf r))
    runHttpWiki env (fetchVault (Just (VaultTag "v2"))) `shouldReturn` Right Unchanged
    runHttpWiki env (fetchVault (Just (VaultTag "v1"))) `shouldReturn` Right (Fetched stored)
    runHttpWiki env (fetchVault Nothing) `shouldReturn` Right NoVault
    map (\r -> (methodOf r, requestUrl r, lookup "If-None-Match" (headersOf r))) . reverse <$> readIORef asked
      `shouldReturn` [ ("GET", "api/v1/assistant/vault", Just "v2")
                     , ("GET", "api/v1/assistant/vault", Just "v1")
                     , ("GET", "api/v1/assistant/vault", Nothing)
                     ]

caching :: Spec
caching = describe "what it keeps" $ do
  let hello = demoPage "blog" "hello-world"
      blogPages = [p | p <- Map.elems demo.pages, p.space == hello.space]
      answering r
        | methodOf r /= "GET" = status 204 ""
        | "/draft" `T.isSuffixOf` requestUrl r = ok (Nothing :: Maybe Draft)
        | "/pages" `T.isSuffixOf` requestUrl r = ok (map summaryOf blogPages)
        | "/pages/at/" `T.isInfixOf` requestUrl r = ok hello
        | "api/v1/search" `T.isPrefixOf` requestUrl r = ok ([] :: [SearchHit])
        | otherwise = ok (Map.elems demo.spaces)
  it "answers at once only what it has read, and asks nothing meanwhile" $ do
    (env, asked) <- backend answering
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Nothing
    readIORef asked `shouldReturn` []
    spaces <- runHttpWiki env listSpaces
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Just spaces
    length <$> readIORef asked `shouldReturn` 1

  it "reads a page by itself, since its space's list of pages has no bodies" $ do
    (env, asked) <- backend answering
    _ <- runHttpWiki env (listPages hello.space)
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Nothing
    runHttpWiki env (getPage hello.space (slugs "hello-world")) `shouldReturn` Right hello
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Just (Right hello)
    length <$> readIORef asked `shouldReturn` 2

  it "caches page content until the route changes, and fetches it on every read after that" $ do
    (env, asked) <- backend answering
    spaces <- runHttpWiki env listSpaces
    _ <- runHttpWiki env (listPages hello.space)
    _ <- runHttpWiki env (getPage hello.space (slugs "hello-world"))
    _ <- runHttpWiki env (getDraft hello.id)
    _ <- runHttpWiki env (searchPages (searchQuery "hello"))
    old <- cacheOf env
    runHttpWiki env endPreload
    left <- cacheOf env
    -- The page content goes; the spaces and this user's draft stay.
    (Map.null left.pages, Map.null left.pageAt, left.searches) `shouldBe` (True, True, [])
    (left.spaces, left.drafts, left.session) `shouldBe` (Just spaces, old.drafts, old.session)
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Just spaces
    runHttpWiki env (atOnce (getDraft hello.id)) `shouldReturn` Just (Right Nothing)
    -- Page content is no longer answered at once, and every read asks the
    -- server, keeping nothing.
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Nothing
    runHttpWiki env (atOnce (listPages hello.space)) `shouldReturn` Nothing
    asked' <- length <$> readIORef asked
    runHttpWiki env (getPage hello.space (slugs "hello-world")) `shouldReturn` Right hello
    runHttpWiki env (getPage hello.space (slugs "hello-world")) `shouldReturn` Right hello
    runHttpWiki env (listPages hello.space) `shouldReturn` Right (map summaryOf blogPages)
    runHttpWiki env (searchPages (searchQuery "hello")) `shouldReturn` []
    length <$> readIORef asked `shouldReturn` asked' + 4
    (\c -> (Map.null c.pageAt, Map.null c.pages, c.searches)) <$> cacheOf env `shouldReturn` (True, True, [])

  it "caches the starred pages as page content, and keeps the list when a star is refused" $ do
    (env, asked) <- backend $ \r ->
      if methodOf r == "GET" then ok ([] :: [StarredPage]) else status 404 "{\"error\":\"NotFound\"}"
    runHttpWiki env starred `shouldReturn` Right []
    -- A star refused for one page leaves the list as it was read.
    runHttpWiki env (setStarred (PageId "gone") True) `shouldReturn` Left NotFound
    runHttpWiki env (atOnce starred) `shouldReturn` Just (Right [])
    -- A page saved anywhere, and the route left, drop the list: its pages'
    -- titles and places may have changed.
    read' <- cacheOf env
    (afterEvent hello.id (PageChanged demoNow) read').stars `shouldBe` Nothing
    runHttpWiki env endPreload
    runHttpWiki env (atOnce starred) `shouldReturn` Nothing
    sofar <- length <$> readIORef asked
    runHttpWiki env starred `shouldReturn` Right []
    runHttpWiki env starred `shouldReturn` Right []
    length <$> readIORef asked `shouldReturn` sofar + 2

  it "lets everything go after a write" $ do
    (env, _) <- backend answering
    _ <- runHttpWiki env listSpaces
    _ <- runHttpWiki env (listPages hello.space)
    _ <- runHttpWiki env (deletePage (PageId "x"))
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Nothing
    (\c -> Map.null c.pages) <$> cacheOf env `shouldReturn` True

  it "keeps the rest after a draft's write, which puts the draft in its place" $ do
    (env, asked) <- backend answering
    _ <- runHttpWiki env (listPages hello.space)
    runHttpWiki env (getDraft hello.id) `shouldReturn` Right Nothing
    runHttpWiki env (discardDraft hello.id) `shouldReturn` Right ()
    runHttpWiki env (atOnce ((,) <$> getDraft hello.id <*> listPages hello.space)) `shouldReturn` Just (Right Nothing, Right (map summaryOf blogPages))
    length <$> readIORef asked `shouldReturn` 3

  it "lets the pages read go when the live channel tells of a save, and keeps the rest" $ do
    (env, _) <- backend answering
    spaces <- runHttpWiki env listSpaces
    _ <- runHttpWiki env (listPages hello.space)
    _ <- runHttpWiki env (getDraft hello.id)
    read' <- cacheOf env
    let saved = afterEvent hello.id (PageChanged demoNow) read'
    Map.null saved.pages `shouldBe` True
    cachedPage hello.space (slugs "hello-world") saved `shouldBe` Nothing
    saved.spaces `shouldBe` Just spaces
    saved.drafts `shouldBe` read'.drafts
    saved.session `shouldBe` read'.session
    -- Who is editing changes nothing kept.
    afterEvent hello.id (Editing []) read' `shouldBe` read'

  it "keeps a refusal the wiki decided, and asks again after one it did not" $ do
    (env, asked) <- backend $ \r ->
      if "/team" `T.isSuffixOf` requestUrl r then status 403 "{\"error\":\"Forbidden\"}" else status 503 ""
    runHttpWiki env (getSpace (slugs "team")) `shouldReturn` Left Forbidden
    runHttpWiki env (atOnce (getSpace (slugs "team"))) `shouldReturn` Just (Left Forbidden)
    runHttpWiki env (getSpace (slugs "docs")) `shouldReturn` Left (Unreachable "the server failed, with status 503")
    runHttpWiki env (atOnce (getSpace (slugs "docs"))) `shouldReturn` Nothing
    length <$> readIORef asked `shouldReturn` 2

  it "keeps a search's hits by its query, until a write" $ do
    (env, asked) <- backend (\r -> if methodOf r == "GET" then ok ([] :: [SearchHit]) else status 204 "")
    runHttpWiki env (searchPages (searchQuery "tour")) `shouldReturn` []
    runHttpWiki env (atOnce (searchPages (searchQuery "tour"))) `shouldReturn` Just []
    runHttpWiki env (atOnce (searchPages (searchQuery "other"))) `shouldReturn` Nothing
    _ <- runHttpWiki env (deletePage (PageId "x"))
    runHttpWiki env (atOnce (searchPages (searchQuery "tour"))) `shouldReturn` Nothing
    length <$> readIORef asked `shouldReturn` 2

  it "starts from what it is given, and asks nothing for it" $ do
    (env, asked) <- backend (const (Left "not asked"))
    let spaces = Map.elems demo.spaces
    seeded <- newHttpEnvWith (Transport (\_ -> panic "asked")) . withSpaces spaces =<< cacheOf env
    runHttpWiki seeded (atOnce listSpaces) `shouldReturn` Just spaces
    readIORef asked `shouldReturn` []

  it "asks a transport that answers at once from within atOnce" $ do
    (transport, asked) <- scripted answering
    env <- newImmediateHttpEnv transport
    runHttpWiki env (atOnce (listPages hello.space)) `shouldReturn` Just (Right (map summaryOf blogPages))
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Just (Right hello)
    length <$> readIORef asked `shouldReturn` 2
    -- The server's prerender caches page content whatever the route, since
    -- the page it writes carries the cache.
    runHttpWiki env endPreload
    _ <- runHttpWiki env (atOnce (listPages hello.space))
    (\c -> Map.member hello.space c.pages) <$> cacheOf env `shouldReturn` True

-- | Who is asking: the demo's admin, signed in, or nobody, as the server
-- sends them.
-- | That no request's body holds a password.
noPassword :: (HasCallStack) => [HttpRequest] -> Text -> Expectation
noPassword rs password = [r | r <- rs, maybe False ((encodeUtf8 password `BS.isInfixOf`) . snd) (bodyOf r)] `shouldSatisfy` null

signedIn, nobody :: SessionInfo
signedIn =
  SessionInfo
    { user = Just User {id = UserId "user-admin", login = Login "admin", displayName = "Ada Admin", avatar = Nothing}
    , groups = mempty
    , grants = mempty
    , standing = SignedIn
    , providers = []
    , exports = []
    , boxes = []
    , homePage = defaultHomePage
    , mathMacros = Nothing
    , assistantServices = []
    , whatsNew = Nothing
    }
nobody = SessionInfo {user = Nothing, groups = mempty, grants = mempty, standing = NotSignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Nothing}

accounts :: Spec
accounts = describe "signing in and out" $ do
  it "marks every request as the application's own" $ do
    (env, asked) <- backend (const (status 204 ""))
    _ <- runHttpWiki env (deletePage (PageId "x"))
    _ <- runHttpWiki env (attempt listSpaces)
    rs <- readIORef asked
    map (\r -> lookup "X-Wiki-Request" (headersOf r)) rs `shouldBe` [Just "1", Just "1"]

  it "is answered in the browser tests with what the server's functions make" $
    -- The browser suite cannot use the opaque-hs package, so it carries the
    -- answers as fixed bytes (Test.Browser.Opaque).
    (fakeChallenge, fakeRegistration) `shouldBe` (fakeChallengeMade, fakeRegistrationMade)

  it "signs in through OPAQUE, sending no password, and starts over with the session it answers" $ do
    (env, asked) <- backend (opaqueServer False signedIn (const (ok (Map.elems demo.spaces))))
    _ <- runHttpWiki env listSpaces
    s <- runHttpWiki env (signIn "admin" (Password "correct horse"))
    (\x -> (x.user, x.standing)) <$> s `shouldBe` Right (signedIn.user, SignedIn)
    rs <- reverse <$> readIORef asked
    map (\r -> (methodOf r, requestUrl r)) rs `shouldBe` [("GET", "api/v1/spaces"), ("POST", "api/v1/session/password"), ("PUT", "api/v1/session/password")]
    noPassword rs "correct horse"
    -- What was read as nobody is gone; who is asking is known.
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Nothing
    runHttpWiki env (atOnce session) `shouldReturn` Just (fromSessionInfo signedIn)

  it "answers a wrong password without sending it, once no account from before OPAQUE is left" $ do
    (env, asked) <- backend (opaqueServer False signedIn (const (status 500 "")))
    runHttpWiki env (signIn "admin" (Password "battery staple")) `shouldReturn` Left WrongCredentials
    runHttpWiki env (signIn "nobody" (Password "correct horse")) `shouldReturn` Left WrongCredentials
    rs <- readIORef asked
    map (\r -> (methodOf r, requestUrl r)) rs `shouldBe` replicate 2 ("POST", "api/v1/session/password")
    noPassword rs "battery staple"

  it "signs an account from before OPAQUE in the old way, with the password once, and registers its record at once" $ do
    let old r
          | requestUrl r == "api/v1/session" = ok signedIn
          | otherwise = status 500 ""
    (env, asked) <- backend (opaqueServer True signedIn old)
    s <- runHttpWiki env (signIn "olga" (Password "olga's old password"))
    (\x -> x.standing) <$> s `shouldBe` Right SignedIn
    rs <- reverse <$> readIORef asked
    map (\r -> (methodOf r, requestUrl r)) rs
      `shouldBe` [("POST", "api/v1/session/password"), ("POST", "api/v1/session"), ("POST", "api/v1/password-registration"), ("PUT", "api/v1/account/password")]
    -- The old sign-in names the attempt that failed, and is the one
    -- request with the password.
    [_, legacy, _, record] <- pure rs
    fmap snd (bodyOf legacy) `shouldSatisfy` maybe False (\b -> "\"attempt\":\"olga " `BS.isInfixOf` b && "olga's old password" `BS.isInfixOf` b)
    noPassword [r | r <- rs, requestUrl r /= "api/v1/session"] "olga's old password"
    fmap snd (bodyOf record) `shouldSatisfy` maybe False ("\"current\":null" `BS.isInfixOf`)

  it "says why signing in failed" $ do
    let failing n body = backend (const (status n body)) >>= \(env, _) -> runHttpWiki env (signIn "admin" (Password "nope"))
    failing 401 "{\"error\":\"Unauthenticated\"}" `shouldReturn` Left WrongCredentials
    failing 429 "{\"error\":\"TooManyRequests\",\"message\":\"Wait 15 minutes.\"}" `shouldReturn` Left (TooManyAttempts "Wait 15 minutes.")
    failing 403 "{\"error\":\"Forbidden\"}" `shouldReturn` Left (SignInFailed Forbidden)
    failing 503 "" `shouldReturn` Left (SignInFailed (Unreachable "the server failed, with status 503"))

  it "changes the password with PUT, the current one proved and the new one registered, keeps what it has read, and says why it could not" $ do
    (env, asked) <- backend (opaqueServer False signedIn (const (ok (Map.elems demo.spaces))))
    _ <- runHttpWiki env listSpaces
    runHttpWiki env (changePassword PasswordChange {current = Just (Password "correct horse"), new = Password "a new one"}) `shouldReturn` Right SignInMethods {password = True, identities = []}
    rs <- reverse <$> readIORef asked
    map (\r -> (methodOf r, requestUrl r)) rs
      `shouldBe` [("GET", "api/v1/spaces"), ("POST", "api/v1/account/password/proof"), ("PUT", "api/v1/account/password/proof"), ("POST", "api/v1/password-registration"), ("PUT", "api/v1/account/password")]
    noPassword rs "correct horse"
    noPassword rs "a new one"
    -- The rules for a new password are the backend's to apply, since the
    -- server never sees it.
    runHttpWiki env (changePassword PasswordChange {current = Just (Password "correct horse"), new = Password "short"}) >>= (`shouldSatisfy` \case Left (SignInFailed (Invalid _)) -> True; _ -> False)
    -- Who is asking is the same: what was read stays.
    isJust <$> runHttpWiki env (atOnce listSpaces) `shouldReturn` True
    let failing n body = backend (const (status n body)) >>= \(e, _) -> runHttpWiki e (changePassword PasswordChange {current = Just (Password "wrong"), new = Password "a new one"})
    failing 401 "{\"error\":\"Unauthenticated\"}" `shouldReturn` Left WrongCredentials
    failing 429 "{\"error\":\"TooManyRequests\",\"message\":\"Wait 15 minutes.\"}" `shouldReturn` Left (TooManyAttempts "Wait 15 minutes.")
    failing 400 "{\"error\":\"Invalid\",\"message\":\"Too short.\"}" `shouldReturn` Left (SignInFailed (Invalid "Too short."))

  it "keeps the session after a wrong current password, which is no session's end" $ do
    changed <- newIORef False
    (transport, asked) <- scripted $ \r ->
      if
        | requestUrl r == "api/v1/session" -> ok signedIn
        | otherwise -> status 401 "{\"error\":\"Unauthenticated\"}"
    env' <- newHttpEnvWith transport (withSession (fromSessionInfo signedIn) emptyCache)
    changes <- runHttpWiki env' sessionChanges
    _ <- HS.subscribe changes (const (writeIORef changed True))
    runHttpWiki env' (changePassword PasswordChange {current = Just (Password "wrong"), new = Password "a new one"}) `shouldReturn` Left WrongCredentials
    readIORef changed `shouldReturn` False
    runHttpWiki env' (atOnce session) `shouldReturn` Just (fromSessionInfo signedIn)
    map requestUrl <$> readIORef asked `shouldReturn` ["api/v1/session", "api/v1/account/password/proof"]

  it "signs out with DELETE, and starts over as nobody" $ do
    (env, asked) <- backend (const (ok nobody))
    runHttpWiki env signOut `shouldReturn` Right (fromSessionInfo nobody)
    map (\r -> (methodOf r, requestUrl r)) <$> readIORef asked `shouldReturn` [("DELETE", "api/v1/session")]
    runHttpWiki env (atOnce session) `shouldReturn` Just anonymous

  it "asks who is asking after a refusal while someone is signed in, and says when that has changed" $ do
    ended <- newIORef False
    (transport, asked) <- scripted $ \r ->
      if
        | requestUrl r == "api/v1/session" -> ok nobody
        | otherwise -> status 403 "{\"error\":\"Forbidden\"}"
    env' <- newHttpEnvWith transport (withSession (fromSessionInfo signedIn) emptyCache)
    changes <- runHttpWiki env' sessionChanges
    _ <- HS.subscribe changes (\s -> when (isNothing s.user) (writeIORef ended True))
    runHttpWiki env' (getSpace (slugs "team")) `shouldReturn` Left Forbidden
    readIORef ended `shouldReturn` True
    runHttpWiki env' (atOnce session) `shouldReturn` Just anonymous
    map requestUrl <$> readIORef asked `shouldReturn` ["api/v1/session", "api/v1/spaces/at/team"]
    -- Nobody is signed in now: another refusal asks nothing more.
    _ <- runHttpWiki env' (getSpace (slugs "docs"))
    length <$> readIORef asked `shouldReturn` 3

  it "asks who is asking once after a refusal, even when that question is refused too" $ do
    -- The question goes through the same client as every request; were it
    -- to ask again after its own refusal, it would never stop.
    (transport, asked) <- scripted (const (status 403 "{\"error\":\"Forbidden\"}"))
    env' <- newHttpEnvWith transport (withSession (fromSessionInfo signedIn) emptyCache)
    runHttpWiki env' (getSpace (slugs "team")) `shouldReturn` Left Forbidden
    map requestUrl <$> readIORef asked `shouldReturn` ["api/v1/session", "api/v1/spaces/at/team"]
    -- What the backend knew of the session stays.
    runHttpWiki env' (atOnce session) `shouldReturn` Just (fromSessionInfo signedIn)

preload :: Spec
preload = describe "what a page it is rendered into carries" $ do
  let hello = demoPage "blog" "hello-world"
      blogPages = [p | p <- Map.elems demo.pages, p.space == hello.space]
      draft = Draft {page = hello.id, author = UserId "admin", title = "t", body = "b <script>", base = hello.updatedAt, savedAt = hello.updatedAt}
      cache =
        withSpaces (Map.elems demo.spaces)
          . withSpaceAt (slugs "blog") (Right (fromMaybe (panic "blog") (Map.lookup hello.space demo.spaces)))
          . withSpaceAt (slugs "team") (Left Forbidden)
          . withPages hello.space (Right (map summaryOf blogPages))
          . withPages (SpaceId "gone") (Left NotFound)
          . withPageAt hello.space (slugs "nowhere") (Left NotFound)
          . withDraft hello.id (HasDraft draft)
          . withDraft (PageId "other") NoDraft
          . withSearch (searchQuery "hello") []
          . withPageLocation (PageId "gone") (Left NotFound)
          . withPageLocation hello.id (Right PageLocation {space = slugs "blog", page = slugs "hello-world"})
          $ emptyCache
  it "reads back as the cache it was written from" $
    decodePreload (encodePreload cache) `shouldBe` Right cache

  it "carries the page shown by itself, beside its space's list of summaries" $ do
    let withPage = withPageAt hello.space (slugs "hello-world") (Right hello) cache
    decodePreload (encodePreload withPage) `shouldBe` Right withPage
    (cachedPage hello.space (slugs "hello-world") <$> decodePreload (encodePreload withPage)) `shouldBe` Right (Just (Right hello))

  it "writes a refusal as the API's error" $
    encodePreload cache `shouldSatisfy` T.isInfixOf "{\"error\":{\"error\":\"Forbidden\"},\"path\":[\"team\"]}"

  it "reads a payload written before the later reads were carried as without them" $
    decodePreload "{\"session\":null,\"spaces\":null,\"spacesAt\":[],\"pages\":[],\"pagesAt\":[],\"drafts\":[],\"searches\":[],\"versionLists\":[],\"versions\":[]}"
      `shouldBe` Right emptyCache

  it "writes what is not kept as nothing, and nothing as null" $
    encodePreload (withSpaceAt (slugs "away") (Left (Unreachable "offline")) emptyCache)
      `shouldBe` "{\"activity\":null,\"backups\":null,\"directory\":null,\"drafts\":[],\"homeDocument\":null,\"invitations\":null,\"invitationsAt\":null,\"notices\":null,\"pageCounts\":null,\"pageLocations\":null,\"pages\":[],\"pagesAt\":[],\"people\":null,\"postDetails\":null,\"searches\":[],\"server\":null,\"session\":null,\"settings\":null,\"spaces\":null,\"spacesAt\":[],\"stars\":null,\"status\":null,\"texEngine\":null,\"threads\":null,\"userPages\":null,\"versionLists\":[],\"versions\":[],\"watches\":null,\"whatsNew\":null}"

  it "says why a payload cannot be read" $
    decodePreload "{\"spaces\": 3}" `shouldSatisfy` isLeft
