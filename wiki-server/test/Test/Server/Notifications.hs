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
import Database.Beam (all_, filter_, runSelectReturningOne, runUpdate, select, update, val_, (<-.), (==.))
import Network.HTTP.Types (Header, Method, hContentType, methodGet, methodPost, methodPut)
import Network.WebSockets qualified as WS
import Protolude
import System.Timeout (timeout)
import Test.Database (Backing)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (countWhere, ok, path, whoFor, withDemo)
import Web.HttpApiData (toUrlPiece)
import Wiki.Api (CommentsApi (..), NotificationsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Comments (NewThread (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Events (ClientMessage (..), ServerMessage (..), eventsPath)
import Wiki.Api.Links (links)
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark (..), Watching (..))
import Wiki.Api.Security (UnsubscribeToken (..))
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
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Login (..), User (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Mail (Message (..))
import Wiki.Server.Notifier (mailRound, newNotifier, newWake)
import Wiki.Server.Storage (Storage, StoredWiki, Who (..), runStoredWiki, withStorageAside, writing)
import Wiki.Server.Storage qualified as Storage
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Notifications (unsubscribeToken, unsubscribeUser)
import Wiki.Server.Storage.Rows (insertUsers, updateDisabled)
import Wiki.Server.Storage.Schema (Users (..), WikiDb (..), wikiDb)
import Wiki.Server.Storage.Schema qualified as Schema

spec :: Backing -> Spec
spec backing = describe "notifications" $ do
  overHttp backing
  overTheChannel backing
  byMail backing
  inTheStorage backing

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

overHttp :: Backing -> Spec
overHttp backing = describe "over HTTP" $ do
  it "tells whom a save and a comment mention, lists it, and marks it read" $ withDemoRunning backing identity $ \r -> do
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

  it "names the users among the logins asked for to someone signed in, and nobody to anyone else" $ withDemoRunning backing identity $ \r -> do
    people <- signedIn r
    -- The brackets of servant's list parameter, as a browser's fetch
    -- writes them.
    let encoded = T.replace "[]" "%5B%5D"
    named :: Map Text Value <- asWithout r (Just people.reader) methodGet (encoded (links.notifications.people ["editor", "nobody"])) >>= jsonAs 200
    Map.keys named `shouldBe` ["editor"]
    nobody :: Map Text Value <- asWithout r Nothing methodGet (encoded (links.notifications.people ["editor"])) >>= jsonAs 200
    Map.keys nobody `shouldBe` []

  it "finds the users whose login or display name starts with some letters, ten at most, for someone signed in" $ withDemoRunning backing identity $ \r -> do
    people <- signedIn r
    let user login name = User {id = UserId ("user-" <> login), login = Login login, displayName = name}
        fillers = [user ("fill" <> n) ("Filler " <> n) | i <- [1 .. 12 :: Int], let n = T.justifyRight 2 '0' (show i)]
    withStorageAside r.place $ \st -> writing st $ do
      insertUsers ([user "anna" "Anna Nowak", user "jsmith" "Annabel Smith", user "annex" "Zed Annex", user "anne" "Anne Gone", user "j.doe" "Jo Dot", user "jdoe" "Jay Doe"] <> fillers)
      updateDisabled (UserId "user-anne") True
    let found who letters = map (\u -> u.login.text) <$> (asWithout r who methodGet (links.notifications.searchPeople letters) >>= jsonAs @[User] 200)
    -- By login (anna, annex) and by display name (Annabel Smith), ordered
    -- by display name, the letters folded; a disabled login left out.
    found (Just people.reader) "AN" `shouldReturn` ["anna", "jsmith", "annex"]
    found (Just people.reader) "annA" `shouldReturn` ["anna", "jsmith"]
    -- Punctuation is a character like any other: "j." is not "jd".
    found (Just people.reader) "j." `shouldReturn` ["j.doe"]
    found (Just people.reader) "jd" `shouldReturn` ["jdoe"]
    found (Just people.reader) "fil" `shouldReturn` ["fill" <> T.justifyRight 2 '0' (show i) | i <- [1 .. 10 :: Int]]
    found (Just people.reader) "" `shouldReturn` []
    -- Nobody to a visitor, as with the people asked for by login.
    found Nothing "an" `shouldReturn` []

  it "reads and sets a watch, refusing a page one may not read as one that is not there" $ withDemoRunning backing identity $ \r -> do
    people <- signedIn r
    notes <- pageNamed r "blog" "notes-on-haskell"
    handbook <- pageNamed r "team" "team-handbook"
    (asWithout r (Just people.reader) methodGet (links.notifications.pageWatch notes.id) >>= jsonAs 200) `shouldReturn` Watch False Unchosen
    (asWith r (Just people.reader) methodPut (links.notifications.setPageWatch notes.id) Watching {watching = True} >>= jsonAs 200) `shouldReturn` Watch True Chosen
    (asWithout r (Just people.reader) methodGet (links.notifications.pageWatch handbook.id) >>= jsonAs 404) `shouldReturn` NotFound
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

overTheChannel :: Backing -> Spec
overTheChannel backing = describe "over the live channel" $
  it "tells the user's tabs of their notification, subscribed to nothing, and nobody else's" $
    withDemoRunning backing identity $ \r -> do
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
      { publicUrl = Just (Url "https://wiki.example.org/")
      , mail = Just MailSettings {host = "mail.test", port = 587, security = StartTls, user = Nothing, password = Nothing, from = "Wiki <wiki@example.org>"}
      }

-- | Give a user a verified address, beside the running server.
verified :: Running -> Text -> Text -> IO ()
verified r user email = withStorageAside r.place $ \st -> writing st (verify user email)

-- | Give a user a verified address, as a statement.
verify :: (Backend be) => Text -> Text -> Db be ()
verify user email =
  runUpdate (update wikiDb.users (\u -> (u.email <-. val_ (Just email)) <> (u.email_verified_at <-. val_ (Just (UTCTime (fromGregorian 2026 10 1) 0)))) (\u -> u.id ==. val_ user))

-- | Wait, a little at a time, for something to hold.
eventually :: (HasCallStack) => IO Bool -> IO ()
eventually condition = go (100 :: Int)
  where
    go 0 = expectationFailure "it did not happen in time"
    go n = condition >>= \held -> unless held (threadDelay 50_000 >> go (n - 1))

mailsTo :: Running -> Text -> IO [Message]
mailsTo r address = filter (\m -> m.to.text == address) <$> readIORef r.outbox

byMail :: Backing -> Spec
byMail backing = describe "by mail" $
  it "mails at once to a verified address only, with a link that turns mail off without signing in" $
    withDemoRunning backing identity $ \r -> do
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
      (asWithout r Nothing methodPost (links.unsubscribe (UnsubscribeToken (token <> "0"))) >>= jsonAs 404) `shouldReturn` NotFound
      (.status) <$> asWithout r Nothing methodPost (links.unsubscribe (UnsubscribeToken token)) `shouldReturn` 204
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
  runStoredWiki st Administrator (setServerSettings noServerSettings {publicUrl = Just (Url "https://wiki.example.org/"), mail = Just MailSettings {host = "mail.test", port = 587, security = StartTls, user = Nothing, password = Nothing, from = "wiki@example.org"}})
    >>= void
    . ok

-- | Run something as one of the demo's users.
as' :: Storage -> Text -> StoredWiki IO a -> IO a
as' st login program = whoFor st (As login) >>= \who -> runStoredWiki st who program

-- | A day at an hour, UTC.
at :: Integer -> Int -> UTCTime
at day hour = addUTCTime (fromIntegral (hour * 3600)) (UTCTime (fromGregorian 2026 11 (fromIntegral day)) 0)

inTheStorage :: Backing -> Spec
inTheStorage backing = describe "in the storage" $ do
  it "mails a daily digest once a day from its hour, the pages' notifications together" $ withDemo backing $ \st -> do
    mailOn st
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    writing st (verify "user-reader" "rita@example.org")
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
    map (\m -> m.to.text) digests `shouldBe` ["rita@example.org"]
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

  it "asks again before mailing, and mails nothing of a page the user may no longer read" $ withDemo backing $ \st -> do
    mailOn st
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    writing st (verify "user-reader" "rita@example.org")
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    _ <- as' st "admin" (setSpacePublic blog.id False) >>= ok
    now <- getCurrentTime
    mailRound notifier now
    readIORef sent `shouldReturn` []
    Storage.reading st (countWhere wikiDb.notifications (\n -> n.mail)) `shouldReturn` 0

  it "mails nothing to a user who may not sign in, and takes their notifications out of the mail queue" $ withDemo backing $ \st -> do
    mailOn st
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    writing st (verify "user-reader" "rita@example.org")
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    writing st (updateDisabled (UserId "user-reader") True)
    now <- getCurrentTime
    mailRound notifier now
    readIORef sent `shouldReturn` []
    Storage.reading st (countWhere wikiDb.notifications (\n -> n.mail)) `shouldReturn` 0
    -- Enabled again, they are not mailed what was queued while they were not.
    writing st (updateDisabled (UserId "user-reader") False)
    mailRound notifier now
    readIORef sent `shouldReturn` []

  it "signs the unsubscribe link, which turns off only its user's mail" $ withDemo backing $ \st -> do
    let mailOf user = Storage.reading st (runSelectReturningOne (select ((\u -> u.notification_mail) <$> filter_ (\u -> u.id ==. val_ user) (all_ wikiDb.users))))
    token <- writing st (unsubscribeToken (UserId "user-reader"))
    writing st (unsubscribeToken (UserId "user-reader")) `shouldReturn` token
    other <- writing st (unsubscribeToken (UserId "user-editor"))
    other `shouldNotBe` token
    writing st (unsubscribeUser (UnsubscribeToken (T.replace "user-reader" "user-editor" token.text))) `shouldReturn` False
    writing st (unsubscribeUser (UnsubscribeToken "nothing")) `shouldReturn` False
    writing st (unsubscribeUser token) `shouldReturn` True
    mailOf "user-reader" `shouldReturn` Just (Just "off")
    mailOf "user-editor" `shouldReturn` Just Nothing

  it "deletes what is older than kept with the day's digest" $ withDemo backing $ \st -> do
    sent <- newIORef []
    wake <- newWake
    let notifier = newNotifier (silentLogger (const pass)) (\_ _ m -> Right <$> modifyIORef' sent (m :)) wake st
    blog <- as' st "admin" (getSpace (path "blog")) >>= ok
    notes <- as' st "admin" (getPage blog.id (path "notes-on-haskell")) >>= ok
    _ <- as' st "editor" (savePage notes.id notes.updatedAt notes.title "For @reader.") >>= ok
    writing st (runUpdate (update wikiDb.notifications (\n -> n.created_at <-. val_ (UTCTime (fromGregorian 2026 1 1) 0)) (const (val_ True))))
    mailRound notifier (at 2 8)
    Storage.reading st (countWhere wikiDb.notifications (const (val_ True))) `shouldReturn` 0
  where
    findIndex' p xs = fromMaybe (-1 :: Int) (head [i | (i, x) <- zip [0 ..] xs, p x])
