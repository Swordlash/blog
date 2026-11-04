-- | The addresses "Wiki.Api.Links" makes: what the browser's backend over
-- HTTP will request, written out here once so that a change to the API's
-- type that moves an endpoint shows up as a failing test rather than as a
-- client and a server that no longer meet. The server's own test
-- (@wiki-api-server-test@) requests these addresses from a server of the
-- type and checks each reaches its handler.
module Test.Links (spec) where

import Protolude
import Test.Hspec
import Wiki.Api (AccountApi (..), ArchiveApi (..), AttachmentsApi (..), PagesApi (..), SpacesApi (..), UsersApi (..), WikiApi (..))
import Wiki.Api.Export (ExportFormat (..), dispositionFileName, documentDisposition, opensInline)
import Wiki.Api.Links
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Id
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Avatar (..))

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

spec :: Spec
spec = describe "Wiki.Api.Links" $ do
  let s = SpaceId "s1"
      p = PageId "p1"

  it "makes each endpoint's address, relative to the application's base" $ do
    links.info `shouldBe` "api/v1/info"
    links.session `shouldBe` "api/v1/session"
    links.spaces.list `shouldBe` "api/v1/spaces"
    links.spaces.atPath [slug "docs", slug "guides"] `shouldBe` "api/v1/spaces/at/docs/guides"
    links.spaces.create `shouldBe` "api/v1/spaces"
    links.spaces.rename s `shouldBe` "api/v1/spaces/s1/name"
    links.spaces.setPublic s `shouldBe` "api/v1/spaces/s1/public"
    links.spaces.setMathMacros s `shouldBe` "api/v1/spaces/s1/math-macros"
    links.spaces.setOrder s `shouldBe` "api/v1/spaces/s1/order"
    links.spaces.move s `shouldBe` "api/v1/spaces/s1/move"
    links.spaces.shift s `shouldBe` "api/v1/spaces/s1/shift"
    links.spaces.delete s `shouldBe` "api/v1/spaces/s1"
    links.spaces.listPages s `shouldBe` "api/v1/spaces/s1/pages"
    links.spaces.pageAt s [slug "tour", slug "intro"] `shouldBe` "api/v1/spaces/s1/pages/at/tour/intro"
    links.spaces.createPage s `shouldBe` "api/v1/spaces/s1/pages"
    links.pages.save p `shouldBe` "api/v1/pages/p1"
    links.pages.move p `shouldBe` "api/v1/pages/p1/move"
    links.pages.shift p `shouldBe` "api/v1/pages/p1/shift"
    links.pages.delete p `shouldBe` "api/v1/pages/p1"
    links.pages.upload p `shouldBe` "api/v1/pages/p1/attachments"
    links.pages.draft p `shouldBe` "api/v1/pages/p1/draft"
    links.attachments.delete (AttachmentId "a1") `shouldBe` "api/v1/attachments/a1"
    links.archive.export `shouldBe` "api/v1/export"
    links.archive.importPreview `shouldBe` "api/v1/import/preview"
    links.archive.importApply `shouldBe` "api/v1/import/apply"
    links.account.setAvatar `shouldBe` "api/v1/account/avatar"
    links.users.avatar (UserId "u1") (BlobId "b1") `shouldBe` "api/v1/users/u1/avatar/b1"

  it "gives a user's avatar an address with its picture's blob in it" $
    avatarUrl (UserId "u1") Avatar {blob = BlobId "b2", mediaType = MimeType "image/png"} `shouldBe` "api/v1/users/u1/avatar/b2"

  it "opens the PDFs in a tab, and downloads every other export" $ do
    filter opensInline [minBound .. maxBound] `shouldBe` [Pdf, BeamerPdf]

  it "names an exported document in its Content-Disposition, and reads the name back" $ do
    documentDisposition Pdf "tour.pdf" `shouldBe` "inline; filename=\"tour.pdf\""
    documentDisposition Docx "tour.docx" `shouldBe` "attachment; filename=\"tour.docx\""
    for_ [minBound .. maxBound] $ \f -> dispositionFileName (documentDisposition f "a-b.x") `shouldBe` Just "a-b.x"
    dispositionFileName "attachment; filename=plain.txt; size=3" `shouldBe` Just "plain.txt"
    dispositionFileName "attachment" `shouldBe` Nothing

  it "escapes what an id or a name holds that an address cannot" $ do
    links.spaces.rename (SpaceId "a b/c?") `shouldBe` "api/v1/spaces/a%20b%2Fc%3F/name"
    attachmentUrl (attachment (SourceBlob (BlobId "b1")) "photo of us.png")
      `shouldBe` "api/v1/attachments/a1/photo%20of%20us.png"

  it "gives an attachment that lives on the web its own address" $
    attachmentUrl (attachment (SourceUrl (Url "https://example.org/x.png")) "x.png")
      `shouldBe` "https://example.org/x.png"

  it "writes every field of a search into its address" $ do
    searchUrl (searchQuery "mermaid diagrams") `shouldBe` "api/v1/search?q=mermaid%20diagrams&limit=50"
    searchUrl (narrow "x")
      `shouldBe` "api/v1/search?q=x&space=s1&only&limit=10"
    searchUrl (searchQuery "agenda") {templates = True}
      `shouldBe` "api/v1/search?q=agenda&limit=50&templates"

  it "reads a search's parameters as the query they came from" $ do
    searchQueryOf (Just "x") (Just s) True (Just 10) False `shouldBe` narrow "x"
    searchQueryOf Nothing Nothing False Nothing False `shouldBe` searchQuery ""
    searchQueryOf (Just "agenda") Nothing False Nothing True `shouldBe` (searchQuery "agenda") {templates = True}
  where
    -- A search of one space alone, for ten hits at most.
    narrow text = SearchQuery {text, space = Just (SpaceId "s1"), includeSubspaces = False, limit = 10, templates = False}
    attachment source name =
      Attachment {id = AttachmentId "a1", name = FileName name, mediaType = MimeType "image/png", size = 1, source}
