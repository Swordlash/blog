-- | The live channel's messages ("Wiki.Api.Events"), on every target: the
-- browser reads the server's and writes its own. Their JSON is pinned by
-- the golden files of @wiki-api-server-test@; here, that they read back,
-- that an event of a type this program does not know is read and changes
-- nothing, and that an event applied twice counts once.
module Test.Events (spec) where

import Data.Aeson (decode, eitherDecode, encode)
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.Events
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Version (Author (..))

time :: UTCTime
time = UTCTime (fromGregorian 2026 10 25) 0

comment :: Text -> Text -> Comment
comment i body = Comment {id = CommentId i, thread = CommentThreadId "t", author = Author {id = UserId "u", name = "U"}, body, createdAt = time, editedAt = Nothing}

thread :: Thread
thread = Thread {id = CommentThreadId "t", page = PageId "p", anchor = Nothing, resolved = False, createdAt = time, comments = [comment "c1" "First."]}

spec :: Spec
spec = describe "Events" $ do
  it "reads back every message it writes" $ do
    let messages =
          [ Subscribed (PageId "p") [thread]
          , Refused (PageId "p")
          , Event (PageId "p") (ThreadOpened thread)
          , Event (PageId "p") (CommentAdded (comment "c2" "Reply."))
          , Event (PageId "p") (CommentEdited (comment "c2" "Edited."))
          , Event (PageId "p") (CommentDeleted (CommentThreadId "t") (CommentId "c2"))
          , Event (PageId "p") (ThreadResolved (CommentThreadId "t") True)
          , Event (PageId "p") (ThreadDeleted (CommentThreadId "t"))
          ]
    decode (encode messages) `shouldBe` Just messages
    decode (encode [Subscribe (PageId "p"), Unsubscribe (PageId "p")]) `shouldBe` Just [Subscribe (PageId "p"), Unsubscribe (PageId "p")]

  it "reads an event of a type it does not know, which changes nothing" $ do
    let later = "{\"page\": \"p\", \"event\": {\"type\": \"page-changed\", \"by\": \"u\"}}"
    eitherDecode later `shouldBe` Right (Event (PageId "p") (Unknown "page-changed"))
    applyEvent (Unknown "page-changed") [thread] `shouldBe` [thread]

  it "refuses a message of the tab's that says neither or both" $ do
    (decode "{}" :: Maybe ClientMessage) `shouldBe` Nothing
    (decode "{\"subscribe\": \"p\", \"unsubscribe\": \"p\"}" :: Maybe ClientMessage) `shouldBe` Nothing

  it "applies each event to a page's threads, and the same event twice once" $ do
    let reply = comment "c2" "Reply."
        replied = applyEvent (CommentAdded reply) [thread]
    map (\c -> c.body) (concatMap (\t -> t.comments) replied) `shouldBe` ["First.", "Reply."]
    applyEvent (CommentAdded reply) replied `shouldBe` replied
    applyEvent (ThreadOpened thread) [thread] `shouldBe` [thread]
    applyEvent (CommentEdited reply {body = "Edited."}) replied `shouldBe` applyEvent (CommentAdded reply {body = "Edited."}) replied
    applyEvent (CommentDeleted (CommentThreadId "t") (CommentId "c2")) replied `shouldBe` [thread]
    map (\t -> t.resolved) (applyEvent (ThreadResolved (CommentThreadId "t") True) [thread]) `shouldBe` [True]
    applyEvent (ThreadDeleted (CommentThreadId "t")) replied `shouldBe` []
