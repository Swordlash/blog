-- | Generators for the domain's types. They are plain 'Gen's rather than
-- 'Arbitrary' instances, which would be orphans here; properties use them
-- through 'forAll'.
module Test.Gen
  ( genText
  , genSlug
  , genSlugs
  , genUtcTime
  , genSpaceId
  , genPageId
  , genAttachmentId
  , genBlobId
  , genUserId
  , genGroupId
  , genSource
  , genAttachment
  , genSpace
  , genIcon
  , genPage
  , genUser
  , genGroup
  , genMembership
  , genSubject
  , genGlobalGrant
  , genSpaceGrant
  , genGrants
  , genPrincipal
  , genMaybePrincipal
  , genChain
  , genSearchQuery
  , genSearchHit
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (Day (ModifiedJulianDay), UTCTime (..), picosecondsToDiffTime)
import Protolude
import Test.QuickCheck
import Wiki.Core.Attachment
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page
import Wiki.Core.Permission
import Wiki.Core.Search
import Wiki.Core.Slug
import Wiki.Core.Space
import Wiki.Core.Url (Url (..))
import Wiki.Core.User

-- | Any text, Unicode included.
genText :: Gen Text
genText = T.pack <$> listOf arbitrary

-- | A slug of one to four words.
genSlug :: Gen Slug
genSlug = do
  n <- chooseInt (1, 4)
  ws <- vectorOf n (listOf1 (elements (['a' .. 'z'] <> ['0' .. '9'])))
  either (panic . show) pure (mkSlug (T.intercalate "-" (map toS ws)))

-- | A path of up to four slugs.
genSlugs :: Gen [Slug]
genSlugs = do
  n <- chooseInt (0, 4)
  vectorOf n genSlug

-- | A time with milliseconds, so that JSON has fractions of a second to keep.
genUtcTime :: Gen UTCTime
genUtcTime = do
  day <- ModifiedJulianDay <$> choose (40000, 70000)
  millis <- choose (0, 86399999)
  pure (UTCTime day (picosecondsToDiffTime (millis * 1000000000)))

-- | Identifiers drawn from a small pool, so that grants and the spaces they
-- are on, or users and the groups they are in, meet often.
genSmallId :: Text -> Gen Text
genSmallId prefix = (\n -> prefix <> show n) <$> chooseInt (1, 3)

genSpaceId :: Gen SpaceId
genSpaceId = SpaceId <$> oneof [genSmallId "s", genText]

genPageId :: Gen PageId
genPageId = PageId <$> genText

genAttachmentId :: Gen AttachmentId
genAttachmentId = AttachmentId <$> genText

genBlobId :: Gen BlobId
genBlobId = BlobId <$> genText

genUserId :: Gen UserId
genUserId = UserId <$> genSmallId "u"

genGroupId :: Gen GroupId
genGroupId = GroupId <$> genSmallId "g"

genSource :: Gen Source
genSource = oneof [SourceUrl . Url <$> genText, SourceBlob <$> genBlobId]

genAttachment :: Gen Attachment
genAttachment = do
  id <- genAttachmentId
  name <- genText
  mediaType <- elements ["image/png", "video/mp4", "audio/ogg", "application/pdf", ""]
  size <- fromIntegral <$> chooseInteger (0, 2 ^ (40 :: Int))
  source <- genSource
  pure Attachment {id, name, mediaType, size, source}

genSpace :: Gen Space
genSpace = do
  id <- genSpaceId
  name <- genText
  slug <- genSlug
  parent <- oneof [pure Nothing, Just <$> genSpaceId]
  public <- arbitrary
  mathMacros <- oneof [pure "", genText]
  createdAt <- genUtcTime
  position <- arbitrary
  subspaceOrder <- arbitraryBoundedEnum
  pageOrder <- arbitraryBoundedEnum
  homePage <- oneof [pure Nothing, Just <$> genPageId]
  icon <- oneof [pure Nothing, Just <$> genIcon]
  description <- oneof [pure "", genText]
  blog <- arbitrary
  pure Space {id, name, slug, parent, public, mathMacros, createdAt, position, subspaceOrder, pageOrder, homePage, icon, description, blog}

genIcon :: Gen Icon
genIcon =
  oneof
    [ IconEmoji <$> genText
    , IconColour <$> elements iconColours
    , IconImage <$> genBlobId <*> elements iconMediaTypes
    ]

genPage :: Gen Page
genPage = do
  id <- genPageId
  space <- genSpaceId
  parent <- oneof [pure Nothing, Just <$> genPageId]
  title <- genText
  slug <- genSlug
  body <- genText
  attachments <- resize 3 (listOf genAttachment)
  createdAt <- genUtcTime
  updatedAt <- genUtcTime
  position <- arbitrary
  template <- arbitrary
  pure Page {id, space, parent, title, slug, body, attachments, createdAt, updatedAt, position, template}

genUser :: Gen User
genUser = do
  id <- genUserId
  login <- Login <$> genText
  displayName <- genText
  pure User {id, login, displayName}

genGroup :: Gen Group
genGroup = do
  id <- genGroupId
  name <- genText
  pure Group {id, name}

genMembership :: Gen Membership
genMembership = Map.fromList <$> listOf ((,) <$> genGroupId <*> (Set.fromList <$> listOf genUserId))

genSubject :: Gen Subject
genSubject = oneof [SubjectUser <$> genUserId, SubjectGroup <$> genGroupId]

genGlobalGrant :: Gen GlobalGrant
genGlobalGrant = do
  subject <- genSubject
  permission <- arbitraryBoundedEnum
  pure GlobalGrant {subject, permission}

genSpaceGrant :: Gen SpaceGrant
genSpaceGrant = do
  space <- SpaceId <$> genSmallId "s"
  subject <- genSubject
  permission <- arbitraryBoundedEnum
  pure SpaceGrant {space, subject, permission}

-- | Grants with global ones rarer than space ones, since a global
-- 'Administer' makes every other grant moot.
genGrants :: Gen Grants
genGrants = do
  global <- resize 2 (listOf genGlobalGrant)
  spaces <- listOf genSpaceGrant
  access <- arbitraryBoundedEnum
  pure Grants {global, spaces, access}

genPrincipal :: Gen Principal
genPrincipal = do
  user <- genUserId
  groups <- Set.fromList <$> listOf genGroupId
  pure Principal {user, groups}

-- | Someone signed in, or not.
genMaybePrincipal :: Gen (Maybe Principal)
genMaybePrincipal = frequency [(1, pure Nothing), (4, Just <$> genPrincipal)]

-- | A chain of spaces from a top-level one down, each the parent of the
-- next, with ids from the pool the grants use.
genChain :: Gen [Space]
genChain = do
  n <- chooseInt (0, 3)
  ids <- shuffle ["s1", "s2", "s3"]
  let chainIds = map SpaceId (take n ids)
  for (zip chainIds (Nothing : map Just chainIds)) $ \(id, parent) -> do
    slug <- genSlug
    public <- frequency [(1, pure True), (3, pure False)]
    pure Space {id, name = "", slug, parent, public, mathMacros = "", createdAt = UTCTime (ModifiedJulianDay 60000) 0, position = 0, subspaceOrder = ByName, pageOrder = ByName, homePage = Nothing, icon = Nothing, description = "", blog = False}

genSearchQuery :: Gen SearchQuery
genSearchQuery = do
  text <- genText
  space <- oneof [pure Nothing, Just <$> genSpaceId]
  includeSubspaces <- arbitrary
  limit <- arbitrary
  templates <- arbitrary
  pure SearchQuery {text, space, includeSubspaces, limit, templates}

genSnippet :: Gen Snippet
genSnippet = Snippet <$> listOf (Piece <$> genText <*> arbitrary)

genSearchHit :: Gen SearchHit
genSearchHit = do
  page <- genPageId
  space <- genSpaceId
  title <- genSnippet
  spacePath <- genSlugs
  pagePath <- genSlugs
  snippet <- genSnippet
  pure SearchHit {page, space, title, spacePath, pagePath, snippet}
