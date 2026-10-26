-- | Mentions, watching and notifications on the server (WP4.13 of
-- docs/PLAN.md). Over real HTTP: a mention in a save and in a comment told
-- to the user mentioned, listed and marked read, the operator refused, a
-- watch read and set; over a real WebSocket, a notification told to the
-- user's tab whatever it subscribed to, and to nobody else's; mail at once
-- to a verified address only, with a link that turns it off without
-- signing in. On the storage, with the thread's look run by hand at chosen
-- times: the daily digest, grouped by page, mailed once a day from its
-- hour; a notification of a page the user may no longer read not mailed;
-- the unsubscribe link's secret; what is kept.
module Test.Server.Notifications (spec) where

import Data.Aeson (ToJSON, Value, eitherDecode, encode)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Database.SQLite.Simple (Only (..), execute, query, query_)
import Network.HTTP.Types (Header, Method, hContentType, methodGet, methodPost, methodPut)
import Network.WebSockets qualified as WS
import Protolude
import System.Timeout (timeout)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (ok, path, whoFor, withDemo)
import Web.HttpApiData (toUrlPiece)
import Wiki.Api (CommentsApi (..), NotificationsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Comments (NewThread (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Events (ClientMessage (..), ServerMessage (..), eventsPath)
import Wiki.Api.Links (links)
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark (..), Watching (..))
import Wiki.Api.Security (MailToken (..))
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), noServerSettings)
import Wiki.Api.Types (PageEdit (..))
import Wiki.Api.Version (pageVersion)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Contract (As (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), MailMode (..), Notification (..), Watch (..), WatchReason (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Mail (Message (..))
import Wiki.Server.Notifier (mailRound, newNotifier, newWake)
import Wiki.Server.Storage (SqliteWiki, Storage, Who (..), runSqliteWiki, withDatabase, withStorageAside)
import Wiki.Server.Storage.Notifications (unsubscribeToken, unsubscribeUser)

spec :: Spec
spec = describe "notifications" $ do
  overHttp
  overTheChannel
  byMail
  inTheStorage

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

-- | The page at a path in the space at a path, as the operator finds it.
pageNamed :: (HasCallStack) => Running -> Text -> Text -> IO Page
pageNamed r space page = do
  s :: Space <- ok200 (getUrl r (onAdmin r (links.spaces.atPath [slug space])))
  ok200 (getUrl r (onAdmin r (links.spaces.pageAt s.id [slug page])))
  where
    slug t = either (panic . show) identity (mkSlug t)

-- | A request to the public listener as someone (nobody, without a
-- cookie), with a JSON body.
asWith :: (ToJSON a) => Running -> Maybe Header -> Method -> Text -> a -> IO Reply
asWith r who m address body = send r m (onPublic r address) ((hContentType, "application/json") : toList who) (encode body)

-- | A request without a body.
asWithout :: Running -> Maybe Header -> Method -> Text -> IO Reply
asWithout r who m address = send r m (onPublic r address) (toList who) ""

-- | Save a page, as someone, with a new body: the page saved.
saveAs :: (HasCallStack) => Running -> Header -> Page -> Text -> IO Page
saveAs r who page body = do
  answered <- send r methodPut (onPublic r (links.pages.save page.id)) [(hContentType, "application/json"), who, ("If-Match", encodeUtf8 (toUrlPiece (pageVersion page)))] (encode PageEdit {title = page.title, body})
  jsonAs 200 answered

-- | Someone's notifications, over HTTP.
toldOver :: (HasCallStack) => Running -> Header -> IO Notifications
toldOver r who = asWithout r (Just who) methodGet links.notifications.list >>= jsonAs 200

--------------------------------------------------------------------------------
-- Over HTTP

overHttp :: Spec
overHttp = describe "over HTTP" $ do
  it "tells whom a save and a comment mention, lists it, and marks it read" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    notes <- pageNamed r "blog" "notes-on-haskell"
    _ <- saveAs r people.editor notes "Ask @reader."
    _ :: Thread <- asWith r (Just people.admin) methodPost (links.comments notes.id).open NewThread {anchor = Nothing, body = "Yes, @reader, do."} >>= jsonAs 201
    told <- toldOver r people.reader
    told.unread `shouldBe` 2
    map (\n -> (n.kind, n.actor.name, n.page)) told.items `shouldBe` [(Mentioned, "Ada Admin", notes.id), (Mentioned, "Edgar Editor", notes.id)]
    (toldOver r people.editor <&> \n -> n.items) `shouldReturn` []
    marked :: Notifications <- asWith r (Just people.reader) methodPost links.notifications.markRead ReadMark {ids = [], everything = True} >>= jsonAs 200
    marked.unread `shouldBe` 0
    -- Nobody not signed in has any, and the operator, who is no user, none.
    (asWithout r Nothing methodGet links.notifications.list >>= jsonAs 403) `shouldReturn` Forbidden
    (getUrl r (onAdmin r links.notifications.list) >>= jsonAs 403) `shouldReturn` Forbidden

  it "names the users among the logins asked for to someone signed in, and nobody to anyone else" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    -- The brackets of servant's list parameter, as a browser's fetch
    -- writes them.
    let encoded = T.replace "[]" "%5B%5D"
    named :: Map Text Value <- asWithout r (Just people.reader) methodGet (encoded (links.notifications.people ["editor", "nobody"])) >>= jsonAs 200
    Map.keys named `shouldBe` ["editor"]
    nobody :: Map Text Value <- asWithout r Nothing methodGet (encoded (links.notifications.people ["editor"])) >>= jsonAs 200
    Map.keys nobody `shouldBe` []

  it "reads and sets a watch, refusing a page one may not read" $ withDemoRunning identity $ \r -> do
    people <- signedIn r
    notes <- pageNamed r "blog" "notes-on-haskell"
    handbook <- pageNamed r "team" "team-handbook"
    (asWithout r (Just people.reader) methodGet (links.notifications.pageWatch notes.id) >>= jsonAs 200) `shouldReturn` Watch False Unchosen
    (asWith r (Just people.reader) methodPut (links.notifications.setPageWatch notes.id) Watching {watching = True} >>= jsonAs 200) `shouldReturn` Watch True Chosen
    (asWithout r (Just people.reader) methodGet (links.notifications.pageWatch handbook.id) >>= jsonAs 403) `shouldReturn` Forbidden
    _ <- saveAs r people.editor notes "Changed."
    (toldOver r people.reader <&> map (\n -> n.kind) . (\n -> n.items)) `shouldReturn` [Changed]

--------------------------------------------------------------------------------
-- Over the live channel

-- | The port of a listener's root, @http:\/\/127.0.0.1:\<port>@.
portOf :: Text -> Int
portOf root = fromMaybe (panic ("no port in " <> root)) (readMaybe (T.takeWhileEnd (/= ':') root))

channel :: Running -> [Header] -> (WS.Connection -> IO a) -> IO a
channel r headers = WS.runClientWith "127.0.0.1" (portOf r.public) ("/" <> toS eventsPath) WS.defaultConnectionOptions headers

-- | The next message, within five seconds; 'Nothing' if none came.
heardWithin :: Int -> WS.Connection -> IO (Maybe ServerMessage)
heardWithin micros c =
  timeout micros (WS.receiveData c) >>= \case
    Nothing -> pure Nothing
    Just bytes -> either (\e -> assertFailure ("not a message of the server's: " <> e)) (pure . Just) (eitherDecode bytes)

overTheChannel :: Spec
overTheChannel = describe "over the live channel" $
  it "tells the user's tabs of their notification, subscribed to nothing, and nobody else's" $
    withDemoRunning identity $ \r -> do
      people <- signedIn r
      notes <- pageNamed r "blog" "notes-on-haskell"
      channel r [people.reader] $ \reading -> channel r [people.editor] $ \editing -> channel r [] $ \anyone -> do
        -- A message the server answers, so that the connections are open
        -- before anything is told.
        for_ [reading, editing, anyone] $ \c -> do
          WS.sendTextData c (encode (Subscribe (PageId "no-such-page")))
          void (heardWithin 5_000_000 c)
        _ :: Thread <- asWith r (Just people.editor) methodPost (links.comments notes.id).open NewThread {anchor = Nothing, body = "For @reader."} >>= jsonAs 201
        heardWithin 5_000_000 reading >>= \case
          Just (Notified n) -> (n.kind, n.actor.name, n.page, n.excerpt) `shouldBe` (Mentioned, "Edgar Editor", notes.id, "For @reader.")
          other -> expectationFailure ("not a notification: " <> show other)
        heardWithin 500_000 editing `shouldReturn` Nothing
        heardWithin 500_000 anyone `shouldReturn` Nothing

--------------------------------------------------------------------------------
-- By mail

-- | The server mailing into the test's outbox, at a public address.
mailing :: Running -> IO ()
mailing r =
  void . setServer r $
    noServerSettings
      { publicUrl = Just "https://wiki.example.org/"
      , mail = Just MailSettings {host = "mail.test", port = 587, security = StartTls, user = Nothing, password = Nothing, from = "Wiki <wiki@example.org>"}
      }

-- | Give a user a verified address, beside the running server.
verified :: Running -> Text -> Text -> IO ()
verified r user email = withStorageAside r.dataDir $ \st -> withDatabase st $ \c ->
  execute c "UPDATE users SET email = ?, email_verified_at = '2026-10-01T00:00:00Z' WHERE id = ?" (email, user)

-- | Wait, a little at a time, for something to hold.
eventually :: (HasCallStack) => IO Bool -> IO ()
eventually condition = go (100 :: Int)
  where
    go 0 = expectationFailure "it did not happen in time"
    go n = condition >>= \held -> unless held (threadDelay 50_000 >> go (n - 1))

mailsTo :: Running -> Text -> IO [Message]
mailsTo r address = filter (\m -> m.to == address) <$> readIORef r.outbox

byMail :: Spec
byMail = describe "by mail" $
  it "mails at once to a verified address only, with a link that turns mail off without signing in" $
    withDemoRunning identity $ \r -> do
      mailing r
      people <- signedIn r
      verified r "user-reader" "rita@example.org"
      notes <- pageNamed r "blog" "notes-on-haskell"
      saved <- saveAs r people.admin notes "For @reader and @editor."
      eventually (not . null <$> mailsTo r "rita@example.org")
      [m] <- mailsTo r "rita@example.org"
      m.subject `shouldSatisfy` T.isInfixOf "Ada Admin mentioned you"
      m.body `shouldSatisfy` T.isInfixOf "https://wiki.example.org/s/blog/p/notes-on-haskell/"
      -- The editor has no verified address: nothing.
      readIORef r.outbox >>= (`shouldBe` 1) . length . filter (\x -> T.isInfixOf "mentioned" x.subject)
      let secret = head [T.dropEnd 1 (T.drop (T.length prefix) w) | w <- T.words m.body, prefix `T.isPrefixOf` w]
          prefix = "https://wiki.example.org/unsubscribe/" :: Text
      token <- maybe (assertFailure "no unsubscribe link") pure secret
      (asWithout r Nothing methodPost (links.unsubscribe (MailToken (token <> "0"))) >>= jsonAs 404) `shouldReturn` NotFound
      (.status) <$> asWithout r Nothing methodPost (links.unsubscribe (MailToken token)) `shouldReturn` 204
      settings :: NotificationSettings <- asWithout r (Just people.reader) methodGet links.notifications.settings >>= jsonAs 200
      (settings.mail, settings.verifiedEmail, settings.mailing) `shouldBe` (MailOff, True, True)
      -- Told under the bell all the same, and mailed nothing more.
      _ :: Thread <- asWith r (Just people.admin) methodPost (links.comments saved.id).open NewThread {anchor = Nothing, body = "Again, @reader."} >>= jsonAs 201
      eventually ((== 2) . length . (\n -> n.items) <$> toldOver r people.reader)
      threadDelay 300_000
      length <$> mailsTo r "rita@example.org" `shouldReturn` 1

--------------------------------------------------------------------------------
-- In the storage

-- | Mail settings on a storage, as the administration sets them.
mailOn :: Storage -> IO ()
mailOn st =
  runSqliteWiki st Administrator (setServerSettings noServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just MailSettings {host = "mail.test", port = 587, security = StartTls, user = Nothing, password = Nothing, from = "wiki@example.org"}})
    >>= void
    . ok

-- | Run something as one of the demo's users.
as' :: Storage -> Text -> SqliteWiki IO a -> IO a
as' st login program = whoFor st (As login) >>= \who -> runSqliteWiki st who program

-- | A day at an hour, UTC.
at :: Integer -> Int -> UTCTime
at day hour = addUTCTime (fromIntegral (hour * 3600)) (UTCTime (fromGregorian 2026 11 (fromIntegral day)) 0)

inTheStorage :: Spec
inTheStorage = describe "in the storage" $ do
  it "mails a daily digest once a day from its hour, the pages' notifications together" $ withDemo $ \st -> do
    mailOn st
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    withDatabase st $ \c -> execute c "UPDATE users SET email = 'rita@example.org', email_verified_at = '2026-10-01T00:00:00Z' WHERE id = ?" (Only ("user-reader" :: Text))
    _ <- as' st "reader" (setNotificationSettings NotificationSettingsChange {mail = MailDaily, watchOwn = True}) >>= ok
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    hello <- as' st "admin" (getPage blog.id (path "hello-world")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    _ <- as' st "editor" (openThread hello.id Nothing "And @reader again.") >>= ok
    _ <- as' st "admin" (openThread notes.id Nothing "Also @reader.") >>= ok
    mailRound notifier (at 2 6)
    readIORef sent `shouldReturn` []
    mailRound notifier (at 2 7)
    digests <- readIORef sent
    map (\m -> m.to) digests `shouldBe` ["rita@example.org"]
    for_ digests $ \m -> do
      m.subject `shouldSatisfy` T.isInfixOf "digest"
      -- The page with the latest notification first, each page's in order.
      let lines' = T.lines m.body
          notesAt = findIndex' ("\"Notes on Haskell\"" `T.isPrefixOf`) lines'
          helloAt = findIndex' ("\"Hello, world\"" `T.isPrefixOf`) lines'
      (notesAt < helloAt) `shouldBe` True
      length (filter ("  - " `T.isPrefixOf`) lines') `shouldBe` 3
    mailRound notifier (at 2 9)
    length <$> readIORef sent `shouldReturn` 1
    -- The next day's, with nothing waiting: none.
    mailRound notifier (at 3 7)
    length <$> readIORef sent `shouldReturn` 1

  it "asks again before mailing, and mails nothing of a page the user may no longer read" $ withDemo $ \st -> do
    mailOn st
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    withDatabase st $ \c -> execute c "UPDATE users SET email = 'rita@example.org', email_verified_at = '2026-10-01T00:00:00Z' WHERE id = ?" (Only ("user-reader" :: Text))
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    _ <- as' st "admin" (setSpacePublic blog.id False) >>= ok
    now <- getCurrentTime
    mailRound notifier now
    readIORef sent `shouldReturn` []
    withDatabase st (\c -> query_ c "SELECT count(*) FROM notifications WHERE mail = 1") `shouldReturn` [Only (0 :: Int)]

  it "signs the unsubscribe link, which turns off only its user's mail" $ withDemo $ \st -> withDatabase st $ \c -> do
    token <- unsubscribeToken c (UserId "user-reader")
    unsubscribeToken c (UserId "user-reader") `shouldReturn` token
    other <- unsubscribeToken c (UserId "user-editor")
    other `shouldNotBe` token
    unsubscribeUser c (T.replace "user-reader" "user-editor" token) `shouldReturn` False
    unsubscribeUser c "nothing" `shouldReturn` False
    unsubscribeUser c token `shouldReturn` True
    query c "SELECT notification_mail FROM users WHERE id = ?" (Only ("user-reader" :: Text)) `shouldReturn` [Only (Just ("off" :: Text))]
    query c "SELECT notification_mail FROM users WHERE id = ?" (Only ("user-editor" :: Text)) `shouldReturn` [Only (Nothing :: Maybe Text)]

  it "deletes what is older than kept with the day's digest" $ withDemo $ \st -> do
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    withDatabase st (\c -> execute c "UPDATE notifications SET created_at = '2026-01-01T00:00:00Z'" ())
    mailRound notifier (at 2 8)
    withDatabase st (\c -> query_ c "SELECT count(*) FROM notifications") `shouldReturn` [Only (0 :: Int)]
  where
    findIndex' p xs = fromMaybe (-1 :: Int) (head [i | (i, x) <- zip [0 ..] xs, p x])
