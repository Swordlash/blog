-- | A page's comments over real HTTP (WP4.5 of docs/PLAN.md), each rule by
-- itself: someone not signed in reads the threads of a public page and
-- may not comment; someone who may only read it comments; an author edits
-- only their own; the space's administrator deletes anyone's; anyone who
-- may comment resolves an inline thread. Then the live channel, over a
-- real WebSocket: two tabs on a page, one comments and both hear of it; a
-- page one may not read is refused, and nothing of it is heard; a closed
-- wiki refuses someone not signed in before the upgrade; another site's
-- page is refused; a request that is no WebSocket's is told so.
--
-- The demo's wiki is the server's, as in "Test.Server.Access": the
-- reader may read the blog, the editor edit it, and the administrator
-- (holding the global administer) administers every space.
module Test.Server.Comments (spec) where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.Text qualified as T
import Network.HTTP.Types (Header, Method, hContentType, methodDelete, methodPost, methodPut)
import Network.WebSockets qualified as WS
import Protolude
import System.Timeout (timeout)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), CommentsApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.Comments (CommentText (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Events (ClientMessage (..), PageEvent (..), ServerMessage (..), eventsPath)
import Wiki.Api.Links (links)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))

spec :: Spec
spec = describe "comments, over HTTP" $ do
  rules
  live

onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | The demo's users, signed in on the public listener with passwords the
-- operator gave them: their cookies.
data People = People
  { admin :: Header
  , editor :: Header
  , reader :: Header
  }

signedIn :: (HasCallStack) => Running -> IO People
signedIn r = People <$> as "admin" <*> as "editor" <*> as "reader"
  where
    as login = do
      givePassword r ("user-" <> login) (login <> "'s password")
      cookie <$> signInAs r login (login <> "'s password")

-- | The id of the page at a path in the space at a path, as the operator
-- finds it.
pageAt :: (HasCallStack) => Running -> Text -> Text -> IO PageId
pageAt r space page = do
  s :: Space <- ok200 (getUrl r (onAdmin r (links.spaces.atPath [slug space])))
  p :: Page <- ok200 (getUrl r (onAdmin r (links.spaces.pageAt s.id [slug page])))
  pure p.id
  where
    slug t = either (panic . show) identity (mkSlug t)

-- | The blog's page nobody has commented on, which anyone may read.
notesOf :: (HasCallStack) => Running -> IO PageId
notesOf r = pageAt r "blog" "notes-on-haskell"

-- | A request to the public listener as someone (nobody, without a
-- cookie), with a JSON body.
asWith :: (ToJSON a) => Running -> Maybe Header -> Method -> Text -> a -> IO Reply
asWith r who m address body = send r m (onPublic r address) ((hContentType, "application/json") : toList who) (encode body)

-- | A request without a body.
asWithout :: Running -> Maybe Header -> Method -> Text -> IO Reply
asWithout r who m address = send r m (onPublic r address) (toList who) ""

-- | That a reply is this refusal.
refusedWith :: (HasCallStack) => Int -> ApiError -> Reply -> IO ()
refusedWith code e reply = (reply.status, eitherDecode reply.body) `shouldBe` (code, Right e)

quote :: Anchor
quote = Anchor {exact = "Haskell", prefix = "Notes on ", suffix = ""}

rules :: Spec
rules = describe "who may" $ do
  it "lets someone not signed in read a public page's threads, and not comment" $ withDemoRunning identity $ \r -> do
    p <- notesOf r
    ok200 (getUrl r (onPublic r (links.comments p).list)) `shouldReturn` ([] :: [Thread])
    asWith r Nothing methodPost (links.comments p).open NewThread {anchor = Nothing, body = "Hello."} >>= refusedWith 403 Forbidden

  it "lets someone who may only read the page comment on it, which everyone then reads" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    t :: Thread <- asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Just quote, body = "Which Haskell?"} >>= jsonAs 201
    map (\c -> (c.author.name, c.body)) t.comments `shouldBe` [("Rita Reader", "Which Haskell?")]
    ok200 (getUrl r (onPublic r (links.comments p).list)) `shouldReturn` [t]

  it "refuses a page one may not read, even its threads, and one that is not there" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    handbook <- pageAt r "team" "team-handbook"
    asWithout r (Just people.reader) "GET" (links.comments handbook).list >>= refusedWith 403 Forbidden
    asWith r (Just people.reader) methodPost (links.comments handbook).open NewThread {anchor = Nothing, body = "Hi."} >>= refusedWith 403 Forbidden
    asWithout r (Just people.reader) "GET" (links.comments (PageId "no-such-page")).list >>= refusedWith 404 NotFound

  it "lets an author edit their own comment, and nobody else" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    t :: Thread <- asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Nothing, body = "First."} >>= jsonAs 201
    c :: Comment <- asWith r (Just people.editor) methodPost ((links.comments p).reply t.id) CommentText {body = "Second."} >>= jsonAs 201
    asWith r (Just people.reader) methodPut ((links.comments p).edit t.id c.id) CommentText {body = "Mine."} >>= refusedWith 403 Forbidden
    asWith r (Just people.admin) methodPut ((links.comments p).edit t.id c.id) CommentText {body = "Mine."} >>= refusedWith 403 Forbidden
    edited :: Comment <- asWith r (Just people.editor) methodPut ((links.comments p).edit t.id c.id) CommentText {body = "Second, edited."} >>= jsonAs 200
    (edited.body, isJust edited.editedAt) `shouldBe` ("Second, edited.", True)

  it "lets the space's administrator delete anyone's comment, and another reader not" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    t :: Thread <- asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Nothing, body = "First."} >>= jsonAs 201
    c :: Comment <- asWith r (Just people.editor) methodPost ((links.comments p).reply t.id) CommentText {body = "Second."} >>= jsonAs 201
    asWithout r (Just people.reader) methodDelete ((links.comments p).deleteComment t.id c.id) >>= refusedWith 403 Forbidden
    gone <- asWithout r (Just people.admin) methodDelete ((links.comments p).deleteComment t.id c.id)
    gone.status `shouldBe` 204
    deleted <- asWithout r (Just people.admin) methodDelete ((links.comments p).delete t.id)
    deleted.status `shouldBe` 204
    ok200 (getUrl r (onPublic r (links.comments p).list)) `shouldReturn` ([] :: [Thread])

  it "lets anyone who may comment resolve an inline thread and reopen it, and nobody signed out" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    t :: Thread <- asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Just quote, body = "Which?"} >>= jsonAs 201
    asWith r Nothing methodPut ((links.comments p).resolve t.id) ThreadResolution {resolved = True} >>= refusedWith 403 Forbidden
    resolved :: Thread <- asWith r (Just people.editor) methodPut ((links.comments p).resolve t.id) ThreadResolution {resolved = True} >>= jsonAs 200
    resolved.resolved `shouldBe` True
    reopened :: Thread <- asWith r (Just people.reader) methodPut ((links.comments p).resolve t.id) ThreadResolution {resolved = False} >>= jsonAs 200
    reopened.resolved `shouldBe` False

  it "lets the operator on the admin listener comment, named as the administrator" $ withDemoRunning identity $ \r -> do
    p <- notesOf r
    t :: Thread <- sendJson r methodPost (onAdmin r (links.comments p).open) NewThread {anchor = Nothing, body = "From the console."} >>= jsonAs 201
    map (\c -> c.author.name) t.comments `shouldBe` ["Administrator"]

  it "refuses a comment a page of another site sends, without the application's header" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    reply <- sendBare r methodPost (onPublic r (links.comments p).open) [(hContentType, "application/json"), people.reader] (encode NewThread {anchor = Nothing, body = "Forged."})
    reply.status `shouldBe` 403
    ok200 (getUrl r (onPublic r (links.comments p).list)) `shouldReturn` ([] :: [Thread])

--------------------------------------------------------------------------------
-- The live channel

-- | The port of a listener's root, @http:\/\/127.0.0.1:\<port>@.
portOf :: Text -> Int
portOf root = fromMaybe (panic ("no port in " <> root)) (readMaybe (T.takeWhileEnd (/= ':') root))

-- | A WebSocket to the public listener's channel, with these headers.
channel :: Running -> [Header] -> (WS.Connection -> IO a) -> IO a
channel r headers = WS.runClientWith "127.0.0.1" (portOf r.public) ("/" <> toS eventsPath) WS.defaultConnectionOptions headers

say :: WS.Connection -> ClientMessage -> IO ()
say c = WS.sendTextData c . encode

-- | The next message, within five seconds.
hear :: (HasCallStack) => WS.Connection -> IO ServerMessage
hear c =
  timeout 5_000_000 (WS.receiveData c) >>= \case
    Nothing -> assertFailure "nothing heard in five seconds"
    Just bytes -> either (\e -> assertFailure ("not a message of the server's: " <> e)) pure (eitherDecode bytes)

subscribe :: (HasCallStack) => WS.Connection -> PageId -> IO ()
subscribe c p = do
  say c (Subscribe p)
  hear c `shouldReturn` Subscribed p

-- | How a handshake the server refused ended: its status.
refusedUpgrade :: Running -> [Header] -> IO (Either Int ())
refusedUpgrade r headers =
  try (channel r headers (\_ -> pass)) <&> \case
    Left (WS.MalformedResponse response _) -> Left (WS.responseCode response)
    Left other -> panic ("another refusal: " <> show other)
    Right () -> Right ()

created :: (FromJSON a, HasCallStack) => IO Reply -> IO a
created act = act >>= jsonAs 201

live :: Spec
live = describe "the live channel" $ do
  it "tells two tabs on a page, one signed in and one not, of what happens to its comments" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    channel r [people.reader] $ \reading -> channel r [] $ \watching -> do
      subscribe reading p
      subscribe watching p
      t :: Thread <- created (asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Just quote, body = "Which Haskell?"})
      hear reading `shouldReturn` Event p (ThreadOpened t)
      hear watching `shouldReturn` Event p (ThreadOpened t)
      c :: Comment <- created (asWith r (Just people.editor) methodPost ((links.comments p).reply t.id) CommentText {body = "GHC's."})
      hear watching `shouldReturn` Event p (CommentAdded c)
      _ :: Thread <- asWith r (Just people.editor) methodPut ((links.comments p).resolve t.id) ThreadResolution {resolved = True} >>= jsonAs 200
      hear watching `shouldReturn` Event p (ThreadResolved t.id True)
      gone <- asWithout r (Just people.admin) methodDelete ((links.comments p).delete t.id)
      gone.status `shouldBe` 204
      hear watching `shouldReturn` Event p (ThreadDeleted t.id)
      -- And the tab that comments hears of its own, too.
      replicateM_ 2 (void (hear reading))
      hear reading `shouldReturn` Event p (ThreadDeleted t.id)

  it "refuses a page one may not read, and tells nothing of it" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    handbook <- pageAt r "team" "team-handbook"
    p <- notesOf r
    channel r [people.reader] $ \c -> do
      say c (Subscribe handbook)
      hear c `shouldReturn` Refused handbook
      say c (Subscribe (PageId "no-such-page"))
      hear c `shouldReturn` Refused (PageId "no-such-page")
      _ :: Thread <- created (asWith r (Just people.admin) methodPost (links.comments handbook).open NewThread {anchor = Nothing, body = "Internal."})
      -- The next thing heard is the answer to this, not the handbook's.
      subscribe c p

  it "stops telling a tab of a page it unsubscribed from" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    p <- notesOf r
    other <- pageAt r "blog" "hello-world"
    channel r [] $ \c -> do
      subscribe c p
      say c (Unsubscribe p)
      subscribe c other
      _ :: Thread <- created (asWith r (Just people.reader) methodPost (links.comments p).open NewThread {anchor = Nothing, body = "Unheard."})
      t :: Thread <- created (asWith r (Just people.reader) methodPost (links.comments other).open NewThread {anchor = Nothing, body = "Heard."})
      hear c `shouldReturn` Event other (ThreadOpened t)

  it "is closed to someone not signed in in a closed wiki, before the upgrade, and open to who signed in" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    _ :: WikiSettings <- sendJson r methodPut (onAdmin r links.admin.setSettings) WikiSettings {access = Closed, newAccountsCreateSpaces = False} >>= jsonAs 200
    refusedUpgrade r [] `shouldReturn` Left 401
    p <- notesOf r
    channel r [people.reader] (`subscribe` p)

  it "refuses an upgrade a page of another site asks for, and takes one from this one" $ withDemoRunning identity $ \r -> do
    refusedUpgrade r [("Origin", "http://elsewhere.example")] `shouldReturn` Left 403
    refusedUpgrade r [("Origin", encodeUtf8 r.public)] `shouldReturn` Right ()

  it "tells a request that is no WebSocket's that it is one's address" $ withDemoRunning identity $ \r -> do
    reply <- getUrl r (onPublic r eventsPath)
    reply.status `shouldBe` 426
