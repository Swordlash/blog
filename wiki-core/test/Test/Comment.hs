-- | Comments' rules (who may comment, edit and delete), what a comment's
-- body may be, and keeping a page's threads up to date with what happens
-- to them, which the application does with its own writes and with what
-- the server tells it.
module Test.Comment (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Permission
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))

time :: UTCTime
time = UTCTime (fromGregorian 2026 10 25) 0

blog :: Space
blog =
  Space
    { id = SpaceId "blog"
    , name = "Blog"
    , slug = either (panic . show) identity (mkSlug "blog")
    , parent = Nothing
    , public = True
    , mathMacros = ""
    , createdAt = time
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    }

ada, eve, rita :: Principal
ada = Principal {user = UserId "ada", groups = mempty}
eve = Principal {user = UserId "eve", groups = mempty}
rita = Principal {user = UserId "rita", groups = mempty}

-- | Ada administers the blog; nobody else holds anything on it, and it is
-- public.
grants :: Grants
grants = Grants {global = [], spaces = [SpaceGrant {space = blog.id, subject = SubjectUser ada.user, permission = AdministerSpace}], access = Open}

comment :: Text -> Principal -> Text -> Comment
comment i who body = Comment {id = CommentId i, thread = CommentThreadId "t", author = Author {id = who.user, name = who.user.text}, body, createdAt = time, editedAt = Nothing}

thread :: Text -> [Comment] -> Thread
thread i cs = Thread {id = CommentThreadId i, page = PageId "p", anchor = Nothing, resolved = False, createdAt = time, comments = map (\c -> c {thread = CommentThreadId i}) cs}

spec :: Spec
spec = describe "Comment" $ do
  describe "rules" $ do
    it "lets whoever is signed in and may read the page comment, and nobody else" $ do
      mayComment (Just rita) grants [blog] `shouldBe` True
      mayComment Nothing grants [blog] `shouldBe` False
      mayComment (Just rita) grants [blog {public = False}] `shouldBe` False
      mayComment (Just rita) grants {access = Closed} [blog] `shouldBe` True

    it "lets a comment's author alone edit it" $ do
      let c = comment "c" rita "Mine."
      mayEditComment (Just rita) c `shouldBe` True
      mayEditComment (Just ada) c `shouldBe` False
      mayEditComment Nothing c `shouldBe` False

    it "lets a comment's author, or whoever administers the space, delete it" $ do
      let c = comment "c" rita "Mine."
      mayDeleteComment (Just rita) grants [blog] c `shouldBe` True
      mayDeleteComment (Just ada) grants [blog] c `shouldBe` True
      mayDeleteComment (Just eve) grants [blog] c `shouldBe` False
      mayDeleteComment Nothing grants [blog] c `shouldBe` False

    it "lets whoever administers the space delete a thread, or its opener while all of it is theirs" $ do
      let alone = thread "t" [comment "a" rita "One.", comment "b" rita "Two."]
          answered = thread "t" [comment "a" rita "One.", comment "b" eve "Two."]
      mayDeleteThread (Just rita) grants [blog] alone `shouldBe` True
      mayDeleteThread (Just rita) grants [blog] answered `shouldBe` False
      mayDeleteThread (Just ada) grants [blog] answered `shouldBe` True
      mayDeleteThread (Just eve) grants [blog] alone `shouldBe` False

  describe "checkCommentBody" $ do
    it "refuses a blank comment" $ do
      isLeft (checkCommentBody "") `shouldBe` True
      isLeft (checkCommentBody " \n\t ") `shouldBe` True
    it "refuses one longer than the limit" $
      isLeft (checkCommentBody (toS (replicate (maxCommentLength + 1) 'x'))) `shouldBe` True
    it "keeps the Markdown, without the blank lines around it, and a first line's indent" $
      checkCommentBody "\n  \n    code\n\nText.  \n\n" `shouldBe` Right "    code\n\nText."

  describe "keeping threads up to date" $ do
    let opened = thread "one" [comment "a" rita "First."]
        two = thread "two" [comment "b" eve "Second."]
    it "adds a new thread last, and replaces one it has" $ do
      withThread two [opened] `shouldBe` [opened, two]
      withThread opened {resolved = True} [opened, two] `shouldBe` [opened {resolved = True}, two]
      withThread opened [opened] `shouldBe` [opened]

    it "adds a reply to its thread, and replaces a comment edited" $ do
      let reply = (comment "r" eve "Reply.") {thread = CommentThreadId "one"}
          added = withComment reply [opened, two]
      map (map (\c -> c.body) . (\t -> t.comments)) added `shouldBe` [["First.", "Reply."], ["Second."]]
      withComment reply added `shouldBe` added
      map (map (\c -> c.body) . (\t -> t.comments)) (withComment reply {body = "Edited."} added)
        `shouldBe` [["First.", "Edited."], ["Second."]]

    it "takes a comment away, and a thread with it when it was its last" $ do
      let reply = (comment "r" eve "Reply.") {thread = CommentThreadId "one"}
      withoutComment (CommentThreadId "one") (CommentId "r") (withComment reply [opened, two]) `shouldBe` [opened, two]
      withoutComment (CommentThreadId "one") (CommentId "a") [opened, two] `shouldBe` [two]

    it "resolves and reopens a thread, and takes one away" $ do
      let inline = opened {anchor = Just (Anchor "q" "" "")}
      resolvedAs (CommentThreadId "one") True [inline, two] `shouldBe` [inline {resolved = True}, two]
      withoutThread (CommentThreadId "two") [inline, two] `shouldBe` [inline]
      isInline inline `shouldBe` True
      opener inline `shouldBe` Just (UserId "rita")
