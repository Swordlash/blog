-- | The archive of the export decrypted in the browser
-- ("Wiki.App.DecryptedExport"), natively: what the browser decrypted
-- becomes an archive 'readArchive' takes, with no users, groups or grants,
-- and reads back whole. A comment's author who is no user of the archive
-- is kept by their name, and the pages carry no author at all. The walk
-- that decrypts, and the zip file, are the browser's
-- ("Test.Browser.Encrypted").
module Test.DecryptedExport (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Protolude
import Test.Hspec
import Wiki.App.DecryptedExport (ExportedSpace (..), archiveMismatch, decryptedArchive, exportFileName)
import Wiki.App.Demo (demoNow)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..), formerAuthor)
import Wiki.Core.Export (readArchive, writeArchive)
import Wiki.Core.Export qualified as Export
import Wiki.Core.Id (AttachmentId (..), BlobId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.PageKind (PageKind (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Vault (KeyId (..))
import Wiki.Core.Version (Author (..))

spec :: Spec
spec = describe "the export decrypted in the browser" $ do
  it "is an archive readArchive takes and reads back whole, with no users, its authors kept by name" $ do
    let (written, renamed) = decryptedArchive demoNow "wiki-app test" [outer, inner]
    (written.users, renamed) `shouldBe` ([], [])
    back <- either (\why -> panic ("refused: " <> why)) pure (readArchive (Map.fromList (writeArchive written)))
    archiveMismatch written back `shouldBe` Nothing
    -- The space it started from at the top, and plain; the subspace under
    -- it; a personal space's fields gone, since there is no user to own it.
    [(s.name, s.parent, s.encryption, s.owner, s.active) | s <- sortOn (\x -> x.name) back.spaces]
      `shouldBe` [("Inner", Just outerSpace.id, Nothing, Nothing, True), ("Secret", Nothing, Nothing, Nothing, True)]
    [(p.title, p.body) | p <- sortOn (\x -> x.title) back.pages] `shouldBe` [("Home", "Welcome."), ("Inner plans", "Only the inner circle."), ("Plans", "The launch is on *Tuesday*.")]
    [(x.name.text, x.mediaType.text, x.size) | p <- back.pages, x <- p.attachments] `shouldBe` [("plans.txt", "text/plain", 12)]
    Map.elems back.blobs `shouldBe` ["Plain words."]
    [(t.anchor, [(c.body, c.author.name) | c <- t.comments]) | ts <- Map.elems back.threads, t <- ts]
      `shouldBe` [(Just (Anchor "Tuesday" "on *" "*."), [("Moved?", "Ada Admin"), ("Gone since.", "Former Fred (not a user here)")])]

  it "says what an archive read back lacks of the one written" $ do
    let (written, _) = decryptedArchive demoNow "wiki-app test" [outer]
        changed = written {Export.pages = [p {P.body = if p.title == "Plans" then "Something else." else p.body} | p <- written.pages]}
        withoutBytes = written {Export.blobs = mempty}
    archiveMismatch written changed `shouldSatisfy` isJust
    archiveMismatch written withoutBytes `shouldSatisfy` isJust
    archiveMismatch written written `shouldBe` Nothing

  -- Two tabs that upload one name at once each add theirs: the page lists
  -- both, and its text shows the first, which keeps the name.
  it "tells apart two attachments of one name on a page, the first keeping it, and keeps both" $ do
    let twin = attachment {id = AttachmentId "attachment-2", source = SourceBlob (BlobId "attachment-2")}
        third = attachment {id = AttachmentId "attachment-3", source = SourceBlob (BlobId "attachment-3")}
        doubled = outer {pages = [home, plans {attachments = [attachment, twin, third]}], blobs = Map.fromList [(BlobId "attachment-1", "Plain words."), (BlobId "attachment-2", "Other words."), (BlobId "attachment-3", "Third words.")]}
        (written, renamed) = decryptedArchive demoNow "wiki-app test" [doubled]
    back <- either (\why -> panic ("refused: " <> why)) pure (readArchive (Map.fromList (writeArchive written)))
    archiveMismatch written back `shouldBe` Nothing
    [(x.name.text, Map.lookup blob back.blobs) | p <- back.pages, x <- p.attachments, SourceBlob blob <- [x.source]]
      `shouldBe` [("plans.txt", Just "Plain words."), ("plans (2).txt", Just "Other words."), ("plans (3).txt", Just "Third words.")]
    length renamed `shouldBe` 2

  it "names its file after the space and the day" $
    exportFileName outerSpace demoNow `shouldSatisfy` (\n -> "secret-decrypted-" `BS.isPrefixOf` encodeUtf8 n && ".zip" `BS.isSuffixOf` encodeUtf8 n)
  where
    outer = ExportedSpace {space = outerSpace, pages = [home, plans], threads = Map.singleton plans.id [thread], blobs = Map.singleton (BlobId "attachment-1") "Plain words."}
    inner = ExportedSpace {space = innerSpace, pages = [innerPage], threads = mempty, blobs = mempty}
    home = page "page-home" outerSpace.id Nothing "home" "Home" "Welcome."
    plans = (page "page-plans" outerSpace.id (Just home.id) "p-3f2a" "Plans" "The launch is on *Tuesday*.") {attachments = [attachment]}
    innerPage = page "page-inner" innerSpace.id Nothing "p-9c1d" "Inner plans" "Only the inner circle."
    attachment = Attachment {id = AttachmentId "attachment-1", name = FileName "plans.txt", mediaType = MimeType "text/plain", size = 12, source = SourceBlob (BlobId "attachment-1")}
    thread =
      Thread
        { id = CommentThreadId "thread-1"
        , page = plans.id
        , anchor = Just (Anchor "Tuesday" "on *" "*.")
        , resolved = False
        , createdAt = demoNow
        , comments =
            [ comment "comment-1" Author {id = UserId "user-ada", name = "Ada Admin", avatar = Nothing} "Moved?"
            , comment "comment-2" Author {id = formerAuthor "Former Fred", name = "Former Fred", avatar = Nothing} "Gone since."
            ]
        }
    comment i author body = Comment {id = CommentId i, thread = CommentThreadId "thread-1", author, body, createdAt = demoNow, editedAt = Nothing}
    -- An encrypted space under a plain one the export does not hold, made
    -- as if it were someone's personal space.
    outerSpace = (space "space-secret" "Secret" "secret" (Just (SpaceId "space-plain"))) {homePage = Just (PageId "page-home"), owner = Just (UserId "user-ada"), encryption = Just (KeyId "key-1")}
    innerSpace = (space "space-inner" "Inner" "inner" (Just (SpaceId "space-secret"))) {homePage = Just (PageId "page-inner"), encryption = Just (KeyId "key-2")}

page :: Text -> SpaceId -> Maybe PageId -> Text -> Text -> Text -> Page
page i sid parent slug title body =
  Page {id = PageId i, space = sid, parent, title, slug = slugOf slug, body, attachments = [], createdAt = demoNow, updatedAt = demoNow, position = 0, template = False, kind = Document, createdBy = Nothing, updatedBy = Nothing}

space :: Text -> Text -> Text -> Maybe SpaceId -> Space
space i name slug parent =
  Space
    { id = SpaceId i
    , name
    , slug = slugOf slug
    , parent
    , public = False
    , sealed = True
    , encryption = Nothing
    , conversion = Nothing
    , owner = Nothing
    , active = True
    , personalContainer = False
    , mathMacros = ""
    , createdAt = demoNow
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    , boxNumbering = InPage
    }

slugOf :: Text -> Slug
slugOf = either (const (panic "not a slug")) identity . mkSlug
