-- | The program's first render is the page the prerender wrote, at every
-- route the build writes a page for: the program adopts that page
-- ('Halogen.VDom.Driver.hydrateUI'), and where its first render differs it
-- repairs the page, rebuilding what differs, which shows as a flash of the
-- page changing and loses the reader's place.
--
-- Natively there is no HTML parser, so what is adopted is the tree the
-- prerender rendered, given up (its listeners taken off, as a page that
-- arrives has none) and adopted by a fresh application over the same demo:
-- what this finds is a difference of state, a first render that is not the
-- prerendered one. What the parser makes of the page differently (comments,
-- empty texts, elements it moves) is the smoke test's to find, in the built
-- page.
--
-- The pages a server renders for each request are checked the same way:
-- rendered as @wiki-server@ renders them ('renderServed'), over a
-- transport that answers as the API does, from the demo's wiki as someone
-- sees it; then adopted by a fresh application whose backend starts from
-- what the page carries, written as JSON and read back as the program reads
-- it ("Wiki.App.Backend.Http.Preload"), over a transport it must never ask.
module Test.Hydrate (spec, storageSpec) where

import Data.Aeson (ToJSON, encode)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Halogen.HTML.Core (ElemName (..))
import Halogen.Router.Duplex (decodeComponent)
import Halogen.VDom.DOM.Monad (appendChild, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Protolude
import Servant.Client.Core (Response)
import Test.Hspec
import Test.Scripted (jsonResponse, methodOf)
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Api (AdminApi (..), InvitationsApi (..), NotificationsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (InvitationInfo (..), InvitationToken (..))
import Wiki.Api.Activity (firstPage)
import Wiki.Api.Admin (LoggedError (..), ServerStatus (..), UserQuery (..))
import Wiki.Api.Error (ApiError, errorStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Links (searchQueryOf)
import Wiki.Api.Security (ResetToken (..), UnsubscribeToken (..), VerificationToken (..))
import Wiki.Api.ServerSettings (HomePage (..), defaultHomePage)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Version (VersionTime (..))
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http (Transport (..), cacheOf, newHttpEnvWith, newImmediateHttpEnv, requestUrl)
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Http.Preload (decodePreload, encodePreload)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..), savePageIn)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (AdminSection (..), Against (..), Route (..), UserFilter (..), UserListing (..), adminSections)
import Wiki.App.Static (Rendered (..), Start (..), prerenderedRoutes, renderLoading, startLoading, startRoute, startServed)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Users (pageSizeKey)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.HomePage (HomeDocument (page))
import Wiki.Core.Id (SpaceId (..), UserId (..))
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (parsePath, pathOf)
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.Space qualified as S
import Wiki.Core.User (Email (..), SignInProvider (..))
import Wiki.Core.Version (Author, latestVersions)

spec :: Spec
spec = do
  demoPages
  serverPage
  servedPages
  savedHomePage

-- | Saved front page Markdown and switches agree with embedded session data.
savedHomePage :: Spec
savedHomePage = describe "the saved front page, adopted" $
  for_ ["/", "/wiki/"] $ \base ->
    it ("keeps every node and base-path link under " <> toS base) $ do
      let home = defaultHomePage {title = "Knowledge", body = "Shared **welcome**.\n\n[[/docs]]", showSpaces = False, showRecent = False, document = Nothing}
          seed = demoState demoNow
          custom =
            seed
              { M.server = seed.server {SS.homePage = home {document = seed.server.homePage.document}}
              , M.pages = Map.map (\p -> if maybe False (\d -> d.page == p.id) seed.server.homePage.document then p {P.title = home.title, P.body = home.body} else p) seed.pages
              }
      transport <- apiOver [] custom
      rendering <- newImmediateHttpEnv transport
      container <- detached (fmap snd . startServed Build rendering base Home)
      original <- nodesOf container
      html <- markup container
      html `shouldSatisfy` T.isInfixOf "Shared <strong>welcome</strong>."
      html `shouldSatisfy` T.isInfixOf ("href=\"" <> base <> "s/docs/\"")
      html `shouldNotSatisfy` T.isInfixOf "space-cards"
      carried <- either (panic . ("the preload: " <>)) pure . decodePreload . encodePreload =<< cacheOf rendering
      adopting <- newHttpEnvWith (Transport (\_ -> expectationFailure "hydration asked the network" $> Left "no network")) carried
      (_, dispose) <- startServed Adopt adopting base Home container
      markup container >>= (`shouldBe` html)
      adopted <- nodesOf container
      map fst adopted `shouldBe` map fst original
      dispose

-- At the root, and under the base path GitHub Pages serves the demo at
-- (@\/blog\/@, the repository's name), which is in every link the page has:
-- a link the prerender wrote one way and the program another would be a
-- repair.
demoPages :: Spec
demoPages = for_ ["/", "/blog/"] $ \base -> describe ("Wiki.App.Static, adopted, under " <> toS base) $
  for_ (prerenderedRoutes (demoState demoNow)) $ \at ->
    it ("keeps every node of the prerendered page at " <> show at) $ do
      container <- prerendered base at
      original <- nodesOf container
      html <- markup container
      (_, dispose) <- startRoute Adopt (demoState demoNow) base at container
      adopted <- nodesOf container
      markup container >>= (`shouldBe` html)
      dispose
      let kept = Set.fromList (map fst adopted)
          lost = [what | (ident, what) <- original, not (ident `Set.member` kept)]
          had = Set.fromList (map fst original)
          built = [what | (ident, what) <- adopted, not (ident `Set.member` had)]
      (lost, built) `shouldBe` ([], [])

-- | The server's build has one page for every address: the application as
-- it shows before it has loaded anything. The program adopts it at any
-- route with nothing to repair, before the server has answered.
serverPage :: Spec
serverPage = describe "Wiki.App.Static, the server's page adopted" $ do
  it "is the frame, loading, with nothing that names a route" $ do
    Rendered {html, title} <- renderLoading "/"
    title `shouldBe` "Wiki"
    html `shouldSatisfy` T.isInfixOf "<p class=\"loading\">Loading…</p>"
    html `shouldSatisfy` T.isInfixOf "<ol></ol>"
    html `shouldSatisfy` T.isInfixOf "<footer class=\"wiki-footer\">"
  for_ routes $ \at ->
    it ("keeps every node of it at " <> show at) $ do
      container <- detached (startLoading Build "/" Home)
      original <- nodesOf container
      html <- markup container
      dispose <- startLoading Adopt "/" at container
      adopted <- nodesOf container
      markup container >>= (`shouldBe` html)
      dispose
      map fst adopted `shouldBe` map fst original
  where
    path = either (panic . show) identity . parsePath
    routes =
      [ Home
      , Space (path "docs")
      , SpacePages (path "docs")
      , Space (path "team/projects")
      , Page (path "docs") (path "tour")
      , EditPage (path "blog") (path "hello-world")
      , PageSource (path "docs") (path "tour")
      , PageHistory (path "docs") (path "tour") Nothing AgainstPrevious
      , PageSlides (path "docs") (path "markdown-guide/presentations") 1 1
      , NewSpace Nothing
      , Search (Just "words") Nothing True
      , Unknown
      , Invite (InvitationToken "valid")
      , ResetPassword (ResetToken "secret")
      , VerifyEmail (VerificationToken "secret")
      , Unsubscribe (UnsubscribeToken "secret")
      , AssistantSettings
      ]
        <> map Admin adminSections

-- | The pages a server renders, adopted by the program that starts from
-- what they carry: every route the demo's build has a page for, an editor,
-- a search, a space and a page that are not there, a page's history at an
-- older version compared both ways and at one it does not have, and an
-- address that is none, as someone not signed in (to whom the team's space
-- is private) and as the administrator. The demo's first post has been
-- saved once, so that it has a history.
servedPages :: Spec
servedPages = describe "Wiki.App.Static, the pages a server renders, adopted" $
  for_ principals $ \(whom, wiki, providers) ->
    describe ("as " <> whom) $
      for_ routes $ \at ->
        it ("keeps every node at " <> show at <> ", and asks nothing") $ do
          transport <- apiOver providers wiki
          rendering <- newImmediateHttpEnv transport
          container <- detached (fmap snd . startServed Build rendering "/" at)
          original <- nodesOf container
          html <- markup container
          html `shouldNotSatisfy` T.isInfixOf "Loading…"
          carried <- either (panic . ("the preload: " <>)) pure . decodePreload . encodePreload =<< cacheOf rendering
          asked <- newIORef (0 :: Int)
          adopting <- newHttpEnvWith (Transport (\_ -> atomicModifyIORef' asked (\n -> (n + 1, ())) $> Left "no network")) carried
          (_, dispose) <- startServed Adopt adopting "/" at container
          adopted <- nodesOf container
          markup container >>= (`shouldBe` html)
          dispose
          readIORef asked `shouldReturn` 0
          map fst adopted `shouldBe` map fst original
  where
    path = either (panic . show) identity . parsePath
    -- Someone not signed in, in the open wiki and in the wiki closed (to
    -- whom every route is the way to sign in, but for a mailed link's), and
    -- the administrator, in the wiki closed (which changes nothing for them
    -- but the administration's section on it).
    -- And, where the server signs in with providers, which the forms,
    -- the invitation's page and the signed-in user's name offer, someone
    -- not signed in in the wiki closed and the administrator in it open.
    principals =
      [ ("someone not signed in", savedOnce {current = Nothing}, [])
      , ("someone not signed in, the wiki closed", closed savedOnce {current = Nothing}, [])
      , ("the administrator", savedOnce {current = Just (UserId "user-admin")}, [])
      , ("the administrator, the wiki closed", closed savedOnce {current = Just (UserId "user-admin")}, [])
      , ("someone not signed in, the wiki closed, with providers", closed savedOnce {current = Nothing}, withProviders)
      , ("the administrator, with providers", savedOnce {current = Just (UserId "user-admin")}, withProviders)
      ]
    withProviders = [SignInProvider {name = "google", label = "Google"}, SignInProvider {name = "hub", label = "GitHub"}]
    closed st = st {M.grants = Grants {global = st.grants.global, spaces = st.grants.spaces, access = Closed}}
    routes =
      prerenderedRoutes (demoState demoNow)
        <> [ PageHistory (path "blog") (path "hello-world") (Just helloMade) AgainstPrevious
           , PageHistory (path "blog") (path "hello-world") (Just helloMade) AgainstCurrent
           , PageHistory (path "blog") (path "hello-world") (Just demoNow) AgainstPrevious
           , EditPage (path "blog") (path "hello-world")
           , PageSlides (path "docs") (path "markdown-guide/presentations") 4 1
           , PageSlides (path "docs") (path "markdown-guide/presentations") 7 2
           , PageSlides (path "docs") (path "markdown-guide/presentations") 8 2
           , PageSlides (path "blog") (path "hello-world") 1 1
           , Search (Just "haskell") Nothing True
           , Search (Just "tour") (Just (path "docs")) False
           , Posts (path "blog") 2
           , Posts (path "docs") 3
           , Space (path "nowhere")
           , Page (path "docs") (path "nowhere")
           , NewPage (path "docs") Nothing
           , NewSpace Nothing
           , Unknown
           , Invite (InvitationToken "valid")
           , Invite (InvitationToken "used")
           , ResetPassword (ResetToken "secret")
           , VerifyEmail (VerificationToken "secret")
           , Unsubscribe (UnsubscribeToken "secret")
           , AssistantSettings
           , Admin (Users (UserListing "ed" 1 Everyone))
           ]
        <> map Admin adminSections

-- | The users at the page size this browser keeps (50), which the server
-- does not know: the program adopts the page the server rendered at 25
-- users, every node kept, and then asks once for the page at 50.
storageSpec :: Spec
storageSpec = describe "Wiki.App.Static, the users at the page size the browser keeps" $
  it "adopts the page rendered at the first size, and then asks once for the kept size" $ do
    let wiki = savedOnce {current = Just (UserId "user-admin")}
        at = Admin (Users (UserListing "" 1 Everyone))
    transport <- apiOver [] wiki
    rendering <- newImmediateHttpEnv transport
    container <- detached (fmap snd . startServed Build rendering "/" at)
    original <- nodesOf container
    carried <- either (panic . ("the preload: " <>)) pure . decodePreload . encodePreload =<< cacheOf rendering
    asked <- newIORef []
    adopting <- newHttpEnvWith (Transport (\r -> atomicModifyIORef' asked (\rs -> (requestUrl r : rs, ())) >> (case transport of Transport t -> t r))) carried
    flip finally (runMemDOM (Storage.removeItem LocalStorage pageSizeKey)) $ do
      runMemDOM (Storage.setItem LocalStorage pageSizeKey (50 :: Int))
      (_, dispose) <- startServed Adopt adopting "/" at container
      adopted <- nodesOf container
      html <- markup container
      dispose
      map fst adopted `shouldBe` map fst original
      readIORef asked `shouldReturn` [endpointUrl (\e -> e.admin.users (Just 0) (Just 50) Nothing False False)]
      html `shouldSatisfy` T.isInfixOf "<option selected>50</option>"

-- | The users section's query for everyone: from an offset, at a page
-- size, with the words searched for.
usersFrom :: Int -> Int -> Text -> UserQuery
usersFrom offset limit search = UserQuery {offset, limit, search, administrators = False, disabled = False}

-- | The demo with its first post saved once by the editor.
savedOnce :: MemState
savedOnce =
  case savePageIn hello.id hello.updatedAt "Hello, again" (hello.body <> "\nOne more line.\n") demoNow (demo {current = Just (UserId "user-editor")}) of
    Right (st, _) -> st {current = demo.current}
    Left e -> panic ("the demo's first post could not be saved: " <> show e)
  where
    demo = demoState demoNow
    hello = fromMaybe (panic "the demo has no first post") (find (\p -> p.updatedAt == helloMade) (Map.elems demo.pages))

-- | When the demo's first post was made: the time of its first version.
helloMade :: UTCTime
helloMade = addUTCTime (negate (30 * 86400)) demoNow

-- | A transport that answers the reads of the backend over HTTP as the API
-- does, from a wiki in memory as its current user sees it: the API's
-- answers, its refusals with their status, and a 404 for an address it does
-- not have.
apiOver :: [SignInProvider] -> MemState -> IO Transport
apiOver providers seed = do
  wiki <- newMemWiki seed
  st <- readIORef wiki
  let spacePath s = fromMaybe [] (pathOf (`Map.lookup` st.spaces) s)
      pagePath p = fromMaybe [] (pathOf (`Map.lookup` st.pages) p)
  now <- getCurrentTime
  table <- runMemWiki wiki $ do
    me <- session
    people <- directory
    usersPages <- for [usersFrom 0 25 "", usersFrom 0 25 "ed", usersFrom 0 50 ""] $ \q ->
      (endpointUrl (\e -> e.admin.users (Just q.offset) (Just q.limit) (mfilter (/= "") (Just q.search)) q.administrators q.disabled),) . answerOf <$> userPage q
    settings <- wikiSettings
    invited <- invitations
    server <- serverSettings
    kept <- backups
    logged <- activity firstPage
    home <- getHomeDocument
    spaces <- listSpaces
    counts <- pageCounts
    perSpace <- for (Map.elems st.spaces) $ \s -> do
      space <- getSpace (spacePath s.id)
      pages <- listPages s.id
      details <- postDetails s.id
      perPage <- for [p | p <- Map.elems st.pages, p.space == s.id] $ \p -> do
        page <- getPage s.id (pagePath p.id)
        draft <- getDraft p.id
        versions <- listVersions p.id latestVersions
        each <- for (Map.keys (Map.findWithDefault mempty p.id st.versions)) $ \at ->
          (endpointUrl (\e -> e.pages.version p.id (VersionTime at)),) . answerOf <$> getVersion p.id at
        threads <- fromRight [] <$> listThreads p.id
        watch <- watching (WatchPage p.id)
        let logins = Body.unasked Body.noPeople (p.body : [c.body | t <- threads, c <- t.comments])
        named <- Body.askPeople logins
        pure
          ( [(endpointUrl (\e -> e.spaces.pageAt s.id (pagePath p.id)), answerOf page), (endpointUrl (\e -> e.pages.draft p.id), answerOf draft), (endpointUrl (\e -> e.pages.versions p.id Nothing Nothing), answerOf versions)]
              <> [(endpointUrl (\e -> e.notifications.pageWatch p.id), answerOf watch)]
              <> [(endpointUrl (\e -> e.notifications.people logins), answerOf (Right named :: Either WikiError (Map Text Author))) | not (null logins)]
              <> each
          )
      spaceWatch <- watching (WatchSpace s.id)
      pure ([(endpointUrl (\e -> e.spaces.atPath (spacePath s.id)), answerOf space), (endpointUrl (\e -> e.spaces.listPages s.id), answerOf pages), (endpointUrl (\e -> e.spaces.postDetails s.id), answerOf details), (endpointUrl (\e -> e.notifications.spaceWatch s.id), answerOf spaceWatch)] <> concat perPage)
    told <- notifications
    pure
      ( Map.fromList
          ( (endpointUrl (\e -> e.session), answerOf (Right SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing, providers, exports = me.exports, boxes = [], homePage = me.homePage} :: Either WikiError SessionInfo))
              : (endpointUrl (\e -> e.homeDocument), answerOf home)
              : (endpointUrl (\e -> e.spaces.list), answerOf (Right spaces :: Either WikiError [S.Space]))
              : (endpointUrl (\e -> e.spaces.pageCounts), answerOf (Right counts :: Either WikiError (Map SpaceId Int)))
              : (endpointUrl (\e -> e.admin.directory), answerOf people)
              : (endpointUrl (\e -> e.admin.settings), answerOf settings)
              : (endpointUrl (\e -> e.admin.invitations), answerOf invited)
              : (endpointUrl (\e -> e.admin.server), answerOf server)
              : (endpointUrl (\e -> e.admin.backups), answerOf kept)
              : (endpointUrl (\e -> e.admin.activity Nothing Nothing Nothing), answerOf logged)
              : (endpointUrl (\e -> e.admin.status), answerOf (Right status :: Either WikiError ServerStatus))
              : (endpointUrl (\e -> e.notifications.list), answerOf told)
              : (endpointUrl (\e -> e.invitations.details (InvitationToken "valid")), answerOf (Right InvitationInfo {email = Email "bea@example.org", expiresAt = now} :: Either WikiError InvitationInfo))
              : usersPages
                <> concat perSpace
          )
      )
  pure . Transport $ \r -> case (methodOf r, Map.lookup (requestUrl r) table, searchOf (requestUrl r)) of
    ("GET", Just answered, _) -> pure (Right answered)
    ("GET", _, Just q) -> Right . answerOf . Right @WikiError <$> runMemWiki wiki (searchPages q)
    _ -> pure (Right (refusal ApiError.NotFound))
  where
    -- A server's status, with an error it logged: the demo has no
    -- server to say it.
    status =
      ServerStatus
        { version = "wiki-server test"
        , startedAt = demoNow
        , dataDir = "/data"
        , spaces = Map.size seed.spaces
        , pages = Map.size seed.pages
        , attachments = 0
        , users = Map.size seed.users
        , backups = 1
        , schemaVersion = 9
        , lastBackup = Just demoNow
        , connections = 0
        , errors = [LoggedError {at = demoNow, route = "/api/v1/spaces", message = "the disk is full"}]
        , guideInstallable = False
        }
    answerOf :: (ToJSON a) => Either WikiError a -> Response
    answerOf = \case
      Right a -> jsonResponse 200 (encode a)
      Left e -> refusal (apiError e)
    refusal :: ApiError -> Response
    refusal e = jsonResponse (errorStatus e) (encode e)
    apiError = \case
      NotFound -> ApiError.NotFound
      Forbidden -> ApiError.Forbidden
      Conflict t -> ApiError.Conflict t
      Invalid t -> ApiError.Invalid t
      Unreachable t -> ApiError.Invalid t
    -- A search's address, read back into its query.
    searchOf url = do
      query <- T.stripPrefix "api/v1/search?" url
      let params = [(k, decodeComponent (T.drop 1 v)) | pair <- T.splitOn "&" query, let (k, v) = T.breakOn "=" pair]
          param k = snd <$> find ((== k) . fst) params
      pure (searchQueryOf (param "q") (SpaceId <$> param "space") (isJust (param "only")) (readMaybe . T.unpack =<< param "limit") (isJust (param "templates")))

-- | A container holding the page the prerender writes for the route, as the
-- browser has it before the program has loaded: the application that
-- rendered it disposed of, and its nodes put back without their listeners.
prerendered :: Text -> Route -> IO N.NativeNode
prerendered base at = detached (fmap snd . startRoute Build (demoState demoNow) base at)

-- | A container holding what an application started in it rendered, as
-- the browser has it before the program has loaded: the application
-- disposed of, and its nodes put back without their listeners.
detached :: (N.NativeNode -> IO (IO ())) -> IO N.NativeNode
detached start = do
  container <- N.newElement Nothing (ElemName "div")
  dispose <- start container
  rendered <- N.childNodes container
  dispose
  for_ rendered $ \node -> do
    stripListeners node
    runMemDOM (appendChild (N.fromNative node) (N.fromNative container))
  pure container
  where
    stripListeners node = do
      writeIORef node.listeners []
      traverse_ stripListeners =<< N.childNodes node

markup :: N.NativeNode -> IO Text
markup container = mconcat <$> (traverse N.renderToText =<< N.childNodes container)

-- | Every node under the container, by its identity, with its markup to say
-- which it is; but not what is inside an island, which its library fills
-- (natively, with its source) after every render, adopted or not.
nodesOf :: N.NativeNode -> IO [(Int, Text)]
nodesOf node = do
  children <- N.childNodes node
  concat
    <$> for
      children
      ( \c -> do
          here <- (c.ident,) . T.take 120 <$> N.renderToText c
          island <- isIsland c
          (here :) <$> if island then pure [] else nodesOf c
      )

isIsland :: N.NativeNode -> IO Bool
isIsland node = do
  attributes <- N.attributeList node
  properties <- N.propertyList node
  let classes = concatMap T.words ([v | ((_, "class"), v) <- attributes] <> [v | ("className", v) <- properties])
  pure (any (`elem` ["wiki-math", "wiki-mermaid", "wiki-tikz", "wiki-code", "wiki-time"]) classes)
