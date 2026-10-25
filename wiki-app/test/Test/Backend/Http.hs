{-# LANGUAGE MultiWayIf #-}

-- | The backend over HTTP, natively, over a transport the test answers: the
-- requests it makes (addresses, methods, headers, bodies), how it reads
-- answers and refusals, and what it keeps of what it read. That the
-- server reads those requests as meant is @wiki-server-test@'s
-- (@Test.Server.Http@ runs the whole backend contract over them), and that
-- the browser's @fetch@ carries them is the browser suite's.
module Test.Backend.Http (spec) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.Net.Fetch qualified as Fetch
import Halogen.Subscription qualified as HS
import Protolude
import Test.Hspec
import Wiki.Api.Account (PasswordChange (..), SignInMethods (..))
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportChoices (..), ImportPlan (..), ImportSummary (..), importEverything)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Backend
import Wiki.App.Backend.Http
import Wiki.App.Backend.Http.Cache (Cache (..), afterEvent, cachedPage, emptyCache, withDraft, withPageAt, withPages, withSearch, withSession, withSpaceAt, withSpaces)
import Wiki.App.Backend.Http.Preload (decodePreload, encodePreload)
import Wiki.App.Backend.Http.Request
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (AttachmentId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath, pathOf)
import Wiki.Core.Search (SearchHit, searchQuery)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Standing (..), User (..))

-- | A transport that answers as the function says, and keeps every request
-- it was given, the latest first.
scripted :: (Request -> Either Text Response) -> IO (Transport, IORef [Request])
scripted respond = do
  asked <- newIORef []
  pure (Transport (\r -> atomicModifyIORef' asked (\rs -> (r : rs, ())) $> respond r), asked)

-- | A backend over a scripted transport, and the requests it made.
backend :: (Request -> Either Text Response) -> IO (HttpEnv, IORef [Request])
backend respond = do
  (transport, asked) <- scripted respond
  (,asked) <$> newHttpEnv transport

ok :: (ToJSON a) => a -> Either Text Response
ok a = Right (Response 200 (toS (encode a)))

status :: Int -> ByteString -> Either Text Response
status n body = Right (Response n body)

demo :: MemState
demo = demoState demoNow

-- | A page of the demo, by path, with its space's path.
demoPage :: Text -> Text -> Page
demoPage s p =
  fromMaybe (panic ("no page " <> p)) $
    head
      [ page
      | page <- Map.elems demo.pages
      , Just sp <- [pathOf (`Map.lookup` demo.spaces) page.space]
      , sp == slugs s
      , pathOf (`Map.lookup` demo.pages) page.id == Just (slugs p)
      ]

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

spec :: Spec
spec = describe "Wiki.App.Backend.Http" $ do
  requests
  answers
  browserFetch
  caching
  accounts
  preload

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
    timeLimit (multipart "u" "file" "f" "text/plain" "bytes") `shouldBe` uploadTimeout
    timeLimit (withJson "PUT" "u" ()) `shouldBe` requestTimeout
    timeLimit (ifMatch hello.updatedAt (Request {method = "GET", url = "u", headers = [], body = NoBody})) `shouldBe` requestTimeout

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
    map (\r -> (r.method, r.url, r.body)) rs
      `shouldBe` [ ("GET", "api/v1/spaces", NoBody)
                 , ("GET", "api/v1/spaces/" <> hello.space.text <> "/pages/at/a/b", NoBody)
                 , ("GET", "api/v1/search?q=two%20words&limit=50", NoBody)
                 ]

  it "saves against the version it started from, in If-Match, with the edit as JSON" $ do
    (env, asked) <- backend (const (ok hello))
    _ <- runHttpWiki env (savePage hello.id hello.updatedAt "New title" "New body")
    [r] <- readIORef asked
    r.method `shouldBe` "PUT"
    r.url `shouldBe` "api/v1/pages/" <> hello.id.text
    r.headers `shouldBe` [("If-Match", "\"2026-09-01T12:00:00Z\""), ("X-Wiki-Request", "1")]
    r.body `shouldBe` Body "application/json" "{\"body\":\"New body\",\"title\":\"New title\"}"

  it "keeps a draft with the version it started from in the body" $ do
    (env, asked) <- backend (const (ok Draft {page = hello.id, author = UserId "admin", title = "t", body = "b", base = hello.updatedAt, savedAt = hello.updatedAt}))
    _ <- runHttpWiki env (saveDraft hello.id hello.updatedAt "t" "b")
    [r] <- readIORef asked
    (r.method, r.url) `shouldBe` ("PUT", "api/v1/pages/" <> hello.id.text <> "/draft")
    r.body `shouldBe` Body "application/json" "{\"base\":\"2026-09-01T12:00:00Z\",\"body\":\"b\",\"title\":\"t\"}"

  it "deletes with DELETE, and takes a 204 for done" $ do
    (env, asked) <- backend (const (status 204 ""))
    runHttpWiki env (deleteAttachment (AttachmentId "a 1")) `shouldReturn` Right ()
    map (\r -> (r.method, r.url)) <$> readIORef asked `shouldReturn` [("DELETE", "api/v1/attachments/a%201")]

  it "uploads a file as a multipart form, its name quoted" $ do
    (env, asked) <- backend (const (status 500 ""))
    _ <- runHttpWiki env (uploadAttachment hello.id "say \"hi\" ü.txt" "text/plain" "the bytes")
    [r] <- readIORef asked
    (r.method, r.url) `shouldBe` ("POST", "api/v1/pages/" <> hello.id.text <> "/attachments")
    case r.body of
      Body mediaType form -> do
        mediaType `shouldBe` "multipart/form-data; boundary=wiki-form-boundary-0"
        form
          `shouldBe` mconcat
            [ "--wiki-form-boundary-0\r\n"
            , "Content-Disposition: form-data; name=\"file\"; filename=\"say \\\"hi\\\" "
            , encodeUtf8 "ü"
            , ".txt\"\r\nContent-Type: text/plain\r\n\r\nthe bytes\r\n--wiki-form-boundary-0--\r\n"
            ]
      NoBody -> expectationFailure "no form"

  it "chooses a boundary the file does not hold" $ do
    let r = multipart "u" "file" "f" "text/plain" "--wiki-form-boundary-0 and --wiki-form-boundary-1"
    case r.body of
      Body mediaType form -> do
        mediaType `shouldBe` "multipart/form-data; boundary=wiki-form-boundary-2"
        BS.length form `shouldSatisfy` (> 0)
      NoBody -> expectationFailure "no form"

  it "asks for an import's preview with the archive as the form's file" $ do
    (env, asked) <- backend (const (ok (ImportPlan [])))
    runHttpWiki env (previewImport "PK zipped") `shouldReturn` Right (ImportPlan [])
    [r] <- readIORef asked
    (r.method, r.url) `shouldBe` ("POST", "api/v1/import/preview")
    r.body
      `shouldBe` Body
        "multipart/form-data; boundary=wiki-form-boundary-0"
        "--wiki-form-boundary-0\r\nContent-Disposition: form-data; name=\"archive\"; filename=\"wiki.zip\"\r\nContent-Type: application/zip\r\n\r\nPK zipped\r\n--wiki-form-boundary-0--\r\n"

  it "applies an import with the archive again and the choices as a field that is not a file" $ do
    let summary = ImportSummary {spacesCreated = 1, spacesMerged = 0, pagesCreated = 2, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}
        choices = importEverything {skipSpaces = [slugs "docs/notes"]}
    (env, asked) <- backend (const (ok summary))
    runHttpWiki env (applyImport "PK zipped" choices) `shouldReturn` Right summary
    [r] <- readIORef asked
    (r.method, r.url) `shouldBe` ("POST", "api/v1/import/apply")
    r.body
      `shouldBe` Body
        "multipart/form-data; boundary=wiki-form-boundary-0"
        ( mconcat
            [ "--wiki-form-boundary-0\r\nContent-Disposition: form-data; name=\"archive\"; filename=\"wiki.zip\"\r\nContent-Type: application/zip\r\n\r\nPK zipped\r\n"
            , "--wiki-form-boundary-0\r\nContent-Disposition: form-data; name=\"choices\"\r\n\r\n"
            , toS (encode choices)
            , "\r\n--wiki-form-boundary-0--\r\n"
            ]
        )

  it "chooses a boundary that no part of a form holds" $ do
    let r = multipartForm "u" [FilePart {part = "a", name = "f", mediaType = "text/plain", bytes = "--wiki-form-boundary-0"}, TextPart {part = "b", value = "--wiki-form-boundary-1"}]
    case r.body of
      Body mediaType _ -> mediaType `shouldBe` "multipart/form-data; boundary=wiki-form-boundary-2"
      NoBody -> expectationFailure "no form"

  it "forgets what it read once an import has been applied" $ do
    let summary = ImportSummary {spacesCreated = 0, spacesMerged = 0, pagesCreated = 0, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}
    (env, _) <- backend $ \r ->
      if r.url == "api/v1/spaces" then ok ([] :: [Space]) else ok summary
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
  let read' :: Either Text Response -> Either WikiError Space
      read' = answer
  it "reads a refusal by the error its body names" $ do
    read' (status 404 "{\"error\":\"NotFound\"}") `shouldBe` Left NotFound
    read' (status 403 "{\"error\":\"Forbidden\"}") `shouldBe` Left Forbidden
    read' (status 409 "{\"error\":\"Conflict\",\"message\":\"Saved since.\"}") `shouldBe` Left (Conflict "Saved since.")
    read' (status 400 "{\"error\":\"Invalid\",\"message\":\"A title, please.\"}") `shouldBe` Left (Invalid "A title, please.")

  it "reads a refusal without such a body by its status" $ do
    read' (status 404 "") `shouldBe` Left NotFound
    read' (status 401 "") `shouldBe` Left Forbidden
    read' (status 413 "Too large") `shouldBe` Left (Invalid "Too large")
    read' (status 405 "<html>a proxy's page</html>") `shouldBe` Left (Invalid "The request was refused (405).")

  it "takes a failing server, a broken answer and no answer for out of reach" $ do
    read' (status 500 "") `shouldBe` Left (Unreachable "the server failed, with status 500")
    read' (status 502 "<html>Bad gateway</html>") `shouldBe` Left (Unreachable "the server failed, with status 502")
    read' (Left "the network or the server is down") `shouldBe` Left (Unreachable "the network or the server is down")
    read' (status 200 "<html>a captive portal</html>") `shouldSatisfy` \case
      Left (Unreachable _) -> True
      _ -> False

  it "throws from a read without an Either, for attempt to catch" $ do
    (env, _) <- backend (const (Left "down"))
    runHttpWiki env (attempt listSpaces) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env (attempt session) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env (attempt (searchPages (searchQuery "x"))) `shouldReturn` Left (Unreachable "down")
    runHttpWiki env listSpaces `shouldThrow` (== Unreachable "down")

  it "returns a refusal from a read with an Either" $ do
    (env, _) <- backend (const (status 403 "{\"error\":\"Forbidden\"}"))
    runHttpWiki env (getSpace (slugs "team")) `shouldReturn` Left Forbidden

caching :: Spec
caching = describe "what it keeps" $ do
  let hello = demoPage "blog" "hello-world"
      blogPages = [p | p <- Map.elems demo.pages, p.space == hello.space]
      answering r
        | r.method /= "GET" = status 204 ""
        | "/draft" `T.isSuffixOf` r.url = ok (Nothing :: Maybe Draft)
        | "/pages" `T.isSuffixOf` r.url = ok blogPages
        | otherwise = ok (Map.elems demo.spaces)
  it "answers at once only what it has read, and asks nothing meanwhile" $ do
    (env, asked) <- backend answering
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Nothing
    readIORef asked `shouldReturn` []
    spaces <- runHttpWiki env listSpaces
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Just spaces
    length <$> readIORef asked `shouldReturn` 1

  it "gives a page of a space whose pages it has read, at once" $ do
    (env, asked) <- backend answering
    _ <- runHttpWiki env (listPages hello.space)
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Just (Right hello)
    cachedPage hello.space (slugs "no-such-page") <$> cacheOf env `shouldReturn` Nothing
    length <$> readIORef asked `shouldReturn` 1

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
    runHttpWiki env (atOnce ((,) <$> getDraft hello.id <*> listPages hello.space)) `shouldReturn` Just (Right Nothing, Right blogPages)
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
      if "/team" `T.isSuffixOf` r.url then status 403 "{\"error\":\"Forbidden\"}" else status 503 ""
    runHttpWiki env (getSpace (slugs "team")) `shouldReturn` Left Forbidden
    runHttpWiki env (atOnce (getSpace (slugs "team"))) `shouldReturn` Just (Left Forbidden)
    runHttpWiki env (getSpace (slugs "docs")) `shouldReturn` Left (Unreachable "the server failed, with status 503")
    runHttpWiki env (atOnce (getSpace (slugs "docs"))) `shouldReturn` Nothing
    length <$> readIORef asked `shouldReturn` 2

  it "keeps a search's hits by its query, until a write" $ do
    (env, asked) <- backend (\r -> if r.method == "GET" then ok ([] :: [SearchHit]) else status 204 "")
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
    runHttpWiki env (atOnce (listPages hello.space)) `shouldReturn` Just (Right blogPages)
    runHttpWiki env (atOnce (getPage hello.space (slugs "hello-world"))) `shouldReturn` Just (Right hello)
    length <$> readIORef asked `shouldReturn` 1

-- | Who is asking: the demo's admin, signed in, or nobody, as the server
-- sends them.
signedIn, nobody :: SessionInfo
signedIn =
  SessionInfo
    { user = Just User {id = UserId "user-admin", login = "admin", displayName = "Ada Admin"}
    , groups = mempty
    , grants = mempty
    , standing = SignedIn
    , providers = []
    , exports = []
    }
nobody = SessionInfo {user = Nothing, groups = mempty, grants = mempty, standing = NotSignedIn, providers = [], exports = []}

accounts :: Spec
accounts = describe "signing in and out" $ do
  it "marks every request as the application's own" $ do
    (env, asked) <- backend (const (status 204 ""))
    _ <- runHttpWiki env (deletePage (PageId "x"))
    _ <- runHttpWiki env (attempt listSpaces)
    rs <- readIORef asked
    map (\r -> lookup "X-Wiki-Request" r.headers) rs `shouldBe` [Just "1", Just "1"]

  it "signs in with the credentials as JSON, and starts over with the session it answers" $ do
    (env, asked) <- backend $ \r ->
      if
        | r.method == "POST" -> ok signedIn
        | otherwise -> ok (Map.elems demo.spaces)
    _ <- runHttpWiki env listSpaces
    s <- runHttpWiki env (signIn "admin" "correct horse")
    (\x -> (x.user, x.standing)) <$> s `shouldBe` Right (signedIn.user, SignedIn)
    [r, _] <- readIORef asked
    (r.method, r.url, r.body) `shouldBe` ("POST", "api/v1/session", Body "application/json" "{\"login\":\"admin\",\"password\":\"correct horse\"}")
    -- What was read as nobody is gone; who is asking is known.
    runHttpWiki env (atOnce listSpaces) `shouldReturn` Nothing
    runHttpWiki env (atOnce session) `shouldReturn` Just (fromSessionInfo signedIn)

  it "says why signing in failed" $ do
    let failing n body = backend (const (status n body)) >>= \(env, _) -> runHttpWiki env (signIn "admin" "nope")
    failing 401 "{\"error\":\"Unauthenticated\"}" `shouldReturn` Left WrongCredentials
    failing 429 "{\"error\":\"TooManyRequests\",\"message\":\"Wait 15 minutes.\"}" `shouldReturn` Left (TooManyAttempts "Wait 15 minutes.")
    failing 403 "{\"error\":\"Forbidden\"}" `shouldReturn` Left (SignInFailed Forbidden)
    failing 503 "" `shouldReturn` Left (SignInFailed (Unreachable "the server failed, with status 503"))

  it "changes the password with PUT, keeps what it has read, and says why it could not" $ do
    (env, asked) <- backend $ \r ->
      if
        | r.method == "PUT" -> ok SignInMethods {password = True, identities = []}
        | otherwise -> ok (Map.elems demo.spaces)
    _ <- runHttpWiki env listSpaces
    runHttpWiki env (changePassword PasswordChange {current = Just "old one", new = "a new one"}) `shouldReturn` Right SignInMethods {password = True, identities = []}
    (r : _) <- readIORef asked
    (r.method, r.url, r.body) `shouldBe` ("PUT", "api/v1/account/password", Body "application/json" "{\"current\":\"old one\",\"new\":\"a new one\"}")
    -- Who is asking is the same: what was read stays.
    isJust <$> runHttpWiki env (atOnce listSpaces) `shouldReturn` True
    let failing n body = backend (const (status n body)) >>= \(e, _) -> runHttpWiki e (changePassword PasswordChange {current = Just "wrong", new = "a new one"})
    failing 401 "{\"error\":\"Unauthenticated\"}" `shouldReturn` Left WrongCredentials
    failing 429 "{\"error\":\"TooManyRequests\",\"message\":\"Wait 15 minutes.\"}" `shouldReturn` Left (TooManyAttempts "Wait 15 minutes.")
    failing 400 "{\"error\":\"Invalid\",\"message\":\"Too short.\"}" `shouldReturn` Left (SignInFailed (Invalid "Too short."))

  it "keeps the session after a wrong current password, which is no session's end" $ do
    changed <- newIORef False
    (transport, asked) <- scripted $ \r ->
      if
        | r.url == "api/v1/session" -> ok signedIn
        | otherwise -> status 401 "{\"error\":\"Unauthenticated\"}"
    env' <- newHttpEnvWith transport (withSession (fromSessionInfo signedIn) emptyCache)
    changes <- runHttpWiki env' sessionChanges
    _ <- HS.subscribe changes (const (writeIORef changed True))
    runHttpWiki env' (changePassword PasswordChange {current = Just "wrong", new = "a new one"}) `shouldReturn` Left WrongCredentials
    readIORef changed `shouldReturn` False
    runHttpWiki env' (atOnce session) `shouldReturn` Just (fromSessionInfo signedIn)
    map (\r -> r.url) <$> readIORef asked `shouldReturn` ["api/v1/session", "api/v1/account/password"]

  it "signs out with DELETE, and starts over as nobody" $ do
    (env, asked) <- backend (const (ok nobody))
    runHttpWiki env signOut `shouldReturn` Right (fromSessionInfo nobody)
    map (\r -> (r.method, r.url)) <$> readIORef asked `shouldReturn` [("DELETE", "api/v1/session")]
    runHttpWiki env (atOnce session) `shouldReturn` Just anonymous

  it "asks who is asking after a refusal while someone is signed in, and says when that has changed" $ do
    ended <- newIORef False
    (transport, asked) <- scripted $ \r ->
      if
        | r.url == "api/v1/session" -> ok nobody
        | otherwise -> status 403 "{\"error\":\"Forbidden\"}"
    env' <- newHttpEnvWith transport (withSession (fromSessionInfo signedIn) emptyCache)
    changes <- runHttpWiki env' sessionChanges
    _ <- HS.subscribe changes (\s -> when (isNothing s.user) (writeIORef ended True))
    runHttpWiki env' (getSpace (slugs "team")) `shouldReturn` Left Forbidden
    readIORef ended `shouldReturn` True
    runHttpWiki env' (atOnce session) `shouldReturn` Just anonymous
    map (\r -> r.url) <$> readIORef asked `shouldReturn` ["api/v1/session", "api/v1/spaces/at/team"]
    -- Nobody is signed in now: another refusal asks nothing more.
    _ <- runHttpWiki env' (getSpace (slugs "docs"))
    length <$> readIORef asked `shouldReturn` 3

preload :: Spec
preload = describe "what a page it is rendered into carries" $ do
  let hello = demoPage "blog" "hello-world"
      blogPages = [p | p <- Map.elems demo.pages, p.space == hello.space]
      draft = Draft {page = hello.id, author = UserId "admin", title = "t", body = "b <script>", base = hello.updatedAt, savedAt = hello.updatedAt}
      cache =
        withSpaces (Map.elems demo.spaces)
          . withSpaceAt (slugs "blog") (Right (fromMaybe (panic "blog") (Map.lookup hello.space demo.spaces)))
          . withSpaceAt (slugs "team") (Left Forbidden)
          . withPages hello.space (Right blogPages)
          . withPages (SpaceId "gone") (Left NotFound)
          . withPageAt hello.space (slugs "nowhere") (Left NotFound)
          . withDraft hello.id (Just (Right (Just draft)))
          . withDraft (PageId "other") (Just (Right Nothing))
          . withSearch (searchQuery "hello") []
          $ emptyCache
  it "reads back as the cache it was written from" $
    decodePreload (encodePreload cache) `shouldBe` Right cache

  it "carries a page in its space's list only once, and finds it there" $ do
    let withPage = withPageAt hello.space (slugs "hello-world") (Right hello) cache
    decodePreload (encodePreload withPage) `shouldBe` Right cache
    (cachedPage hello.space (slugs "hello-world") <$> decodePreload (encodePreload withPage)) `shouldBe` Right (Just (Right hello))

  it "writes a refusal as the API's error" $
    encodePreload cache `shouldSatisfy` T.isInfixOf "{\"error\":{\"error\":\"Forbidden\"},\"path\":[\"team\"]}"

  it "says why a payload cannot be read" $
    decodePreload "{\"spaces\": 3}" `shouldSatisfy` isLeft
