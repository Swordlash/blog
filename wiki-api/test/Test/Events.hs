-- | The live channel's messages ("Wiki.Api.Events"), on every target: the
-- browser reads the server's and writes its own. Their JSON is pinned by
-- the golden files of @wiki-api-server-test@; here, that they read back,
-- that an event of a type this program does not know is read and changes
-- nothing, that an older server's answer is read as nobody editing, and
-- that an event applied twice counts once.
module Test.Events (spec) where

import Data.Aeson (decode, eitherDecode, encode)
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.Events
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), Notification (..))
import Wiki.Core.User (Avatar (..))
import Wiki.Core.Version (Author (..))

time :: UTCTime
time = UTCTime (fromGregorian 2026 10 25) 0

comment :: Text -> Text -> Comment
comment i body = Comment {id = CommentId i, thread = CommentThreadId "t", author = Author {id = UserId "u", name = "U", avatar = Nothing}, body, createdAt = time, editedAt = Nothing}

-- | A reader with an avatar.
ada :: Author
ada = Author {id = UserId "ada", name = "Ada", avatar = Just Avatar {blob = BlobId "b", mediaType = MimeType "image/png"}}

thread :: Thread
thread = Thread {id = CommentThreadId "t", page = PageId "p", anchor = Nothing, resolved = False, createdAt = time, comments = [comment "c1" "First."]}

spec :: Spec
spec = describe "Events" $ do
  it "reads back every message it writes" $ do
    let messages =
          [ Subscribed (PageId "p") [thread] [] noReaders
          , Subscribed (PageId "p") [] [Author {id = UserId "u", name = "U", avatar = Nothing}] Readers {some = [ada], total = 20, visitors = 3}
          , Refused (PageId "p")
          , Event (PageId "p") (ThreadOpened thread)
          , Event (PageId "p") (CommentAdded (comment "c2" "Reply."))
          , Event (PageId "p") (CommentEdited (comment "c2" "Edited."))
          , Event (PageId "p") (CommentDeleted (CommentThreadId "t") (CommentId "c2"))
          , Event (PageId "p") (ThreadResolved (CommentThreadId "t") True)
          , Event (PageId "p") (ThreadDeleted (CommentThreadId "t"))
          , Event (PageId "p") (Editing [Author {id = UserId "u", name = "U", avatar = Nothing}, Author {id = UserId "v", name = "V", avatar = Nothing}])
          , Event (PageId "p") (Editing [])
          , Event (PageId "p") (Reading Readers {some = [ada], total = 1, visitors = 0})
          , Event (PageId "p") (Reading noReaders)
          , Event (PageId "p") (PageChanged time)
          , Notified Notification {id = NotificationId "n", kind = Mentioned, page = PageId "p", thread = Nothing, actor = Author {id = UserId "u", name = "U", avatar = Nothing}, title = "P", excerpt = "", createdAt = time, read = False, location = Nothing}
          ]
    decode (encode messages) `shouldBe` Just messages
    let said = [Subscribe (PageId "p"), Unsubscribe (PageId "p"), StartEditing (PageId "p"), StopEditing (PageId "p")]
    decode (encode said) `shouldBe` Just said

  it "reads a server's answer that says nothing of who edits or reads as nobody editing or reading" $ do
    let older = "{\"subscribed\": \"p\", \"threads\": []}"
    eitherDecode older `shouldBe` Right (Subscribed (PageId "p") [] [] noReaders)

  it "reads an author without an avatar, as an older server writes one" $
    eitherDecode "{\"id\": \"u\", \"name\": \"U\"}" `shouldBe` Right Author {id = UserId "u", name = "U", avatar = Nothing}

  it "reads an event of a type it does not know, which changes nothing" $ do
    let later = "{\"page\": \"p\", \"event\": {\"type\": \"page-moved\", \"to\": \"q\"}}"
    eitherDecode later `shouldBe` Right (Event (PageId "p") (Unknown "page-moved"))
    applyEvent (Unknown "page-moved") [thread] `shouldBe` [thread]

  it "changes no thread for who is editing, or for a page saved" $ do
    applyEvent (Editing [Author {id = UserId "u", name = "U", avatar = Nothing}]) [thread] `shouldBe` [thread]
    applyEvent (PageChanged time) [thread] `shouldBe` [thread]

  it "refuses a message of the tab's that says neither or both" $ do
    (decode "{}" :: Maybe ClientMessage) `shouldBe` Nothing
    (decode "{\"subscribe\": \"p\", \"unsubscribe\": \"p\"}" :: Maybe ClientMessage) `shouldBe` Nothing
    (decode "{\"editing\": \"p\", \"stopped\": \"p\"}" :: Maybe ClientMessage) `shouldBe` Nothing

  it "applies each event to a page's threads, and the same event twice once" $ do
    let reply = comment "c2" "Reply."
        replied = applyEvent (CommentAdded reply) [thread]
    map (\c -> c.body) (concatMap (\t -> t.comments) replied) `shouldBe` ["First.", "Reply."]
    applyEvent (CommentAdded reply) replied `shouldBe` replied
    applyEvent (ThreadOpened thread) [thread] `shouldBe` [thread]
    map (\c -> c.body) (concatMap (\t -> t.comments) (applyEvent (CommentEdited reply {body = "Edited."}) replied)) `shouldBe` ["First.", "Edited."]
    -- A reply or a thread the threads hold is kept as they hold it.
    applyEvent (CommentAdded reply {body = "Older."}) replied `shouldBe` replied
    applyEvent (CommentDeleted (CommentThreadId "t") (CommentId "c2")) replied `shouldBe` [thread]
    map (\t -> t.resolved) (applyEvent (ThreadResolved (CommentThreadId "t") True) [thread]) `shouldBe` [True]
    applyEvent (ThreadDeleted (CommentThreadId "t")) replied `shouldBe` []
