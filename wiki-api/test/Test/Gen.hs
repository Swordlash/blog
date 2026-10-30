-- | Generators for the API's types, and for the domain's types they carry.
--
-- The domain's are written again here, smaller, rather than shared with
-- @wiki-core@'s tests: a test suite's modules cannot be imported by another
-- package's. As there, they are plain 'Gen's rather than 'Arbitrary'
-- instances, which would be orphans; properties use them through 'forAll'.
module Test.Gen
  ( genText
  , genSlug
  , genSlugs
  , genUtcTime
  , genSpaceId
  , genPageId
  , genAttachmentId
  , genUser
  , genGrants
  , genApiError
  , genSessionInfo
  , genCredentials
  , genNewAccount
  , genNewPassword
  , genPasswordChange
  , genAccountDisabled
  , genAccount
  , genNewSpace
  , genSpaceName
  , genSpacePublic
  , genSpaceMathMacros
  , genSpaceOrder
  , genSpaceMove
  , genNewPage
  , genPageEdit
  , genPageMove
  , genShiftBy
  , genDraftEdit
  , genDraft
  , genVersionInfo
  , genVersion
  , genImportPlan
  , genImportChoices
  , genImportSummary
  , genBytes
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (Day (ModifiedJulianDay), UTCTime (..), picosecondsToDiffTime)
import Protolude
import Test.QuickCheck
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), NewAccount (..), NewPassword (..), PasswordChange (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Import
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Types
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxKind (..))
import Wiki.Core.Permission (GlobalGrant (..), Grants (..), SpaceGrant (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.User (Login (..), Password (..), SignInProvider (..), Standing (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..))

-- | Any text, Unicode included.
genText :: Gen Text
genText = T.pack <$> listOf arbitrary

-- | A slug of one to three words.
genSlug :: Gen Slug
genSlug = do
  n <- chooseInt (1, 3)
  ws <- vectorOf n (listOf1 (elements (['a' .. 'z'] <> ['0' .. '9'])))
  either (panic . show) pure (mkSlug (T.intercalate "-" (map toS ws)))

-- | A path of up to three slugs.
genSlugs :: Gen [Slug]
genSlugs = do
  n <- chooseInt (0, 3)
  vectorOf n genSlug

-- | A time with as many digits of a second as the clock gives (down to the
-- picosecond), so that a version keeps every one of them.
genUtcTime :: Gen UTCTime
genUtcTime = do
  day <- ModifiedJulianDay <$> choose (40000, 70000)
  picos <- oneof [(* 1000000000) <$> choose (0, 86399999), choose (0, 86399999999999999)]
  pure (UTCTime day (picosecondsToDiffTime picos))

genSpaceId :: Gen SpaceId
genSpaceId = SpaceId <$> genText

genPageId :: Gen PageId
genPageId = PageId <$> genText

genAttachmentId :: Gen AttachmentId
genAttachmentId = AttachmentId <$> genText

genUserId :: Gen UserId
genUserId = UserId <$> genText

genGroupId :: Gen GroupId
genGroupId = GroupId <$> genText

genUser :: Gen User
genUser = do
  id <- genUserId
  login <- Login <$> genText
  displayName <- genText
  pure User {id, login, displayName}

genSubject :: Gen Subject
genSubject = oneof [SubjectUser <$> genUserId, SubjectGroup <$> genGroupId]

genGrants :: Gen Grants
genGrants = do
  global <- resize 2 (listOf (GlobalGrant <$> genSubject <*> arbitraryBoundedEnum))
  spaces <- resize 4 (listOf (SpaceGrant <$> genSpaceId <*> genSubject <*> arbitraryBoundedEnum))
  access <- arbitraryBoundedEnum
  pure Grants {global, spaces, access}

genApiError :: Gen ApiError
genApiError = oneof [pure NotFound, pure Forbidden, Conflict <$> genText, Invalid <$> genText, pure Unauthenticated, TooManyRequests <$> genText]

genSessionInfo :: Gen SessionInfo
genSessionInfo = do
  user <- oneof [pure Nothing, Just <$> genUser]
  groups <- Set.fromList <$> resize 3 (listOf genGroupId)
  grants <- genGrants
  standing <- elements [NotSignedIn, SignedIn, Operator]
  providers <- resize 3 (listOf (SignInProvider <$> genText <*> genText))
  exports <- sublistOf [minBound .. maxBound]
  boxes <- resize 3 (listOf (BoxKind <$> genText <*> genText <*> elements [minBound .. maxBound] <*> elements [minBound .. maxBound]))
  pure SessionInfo {user, groups, grants, standing, providers, exports, boxes, homePage = defaultHomePage}

genCredentials :: Gen Credentials
genCredentials = Credentials <$> genText <*> (Password <$> genText)

genNewAccount :: Gen NewAccount
genNewAccount = NewAccount <$> genText <*> genText <*> (Password <$> genText) <*> oneof [pure Nothing, Just <$> genText]

genNewPassword :: Gen NewPassword
genNewPassword = NewPassword . Password <$> genText

genPasswordChange :: Gen PasswordChange
genPasswordChange = PasswordChange <$> genMaybe (Password <$> genText) <*> (Password <$> genText)

genAccountDisabled :: Gen AccountDisabled
genAccountDisabled = AccountDisabled <$> arbitrary

genAccount :: Gen Account
genAccount = Account <$> genUser <*> arbitrary <*> arbitrary

genNewSpace :: Gen NewSpace
genNewSpace = NewSpace <$> genMaybe genSpaceId <*> genText

genSpaceName :: Gen SpaceName
genSpaceName = SpaceName <$> genText

genSpacePublic :: Gen SpacePublic
genSpacePublic = SpacePublic <$> arbitrary

genSpaceMathMacros :: Gen SpaceMathMacros
genSpaceMathMacros = SpaceMathMacros <$> genText

genSpaceOrder :: Gen SpaceOrder
genSpaceOrder = SpaceOrder <$> arbitraryBoundedEnum <*> arbitraryBoundedEnum

genSpaceMove :: Gen SpaceMove
genSpaceMove = SpaceMove <$> genMaybe genSpaceId

genNewPage :: Gen NewPage
genNewPage = NewPage <$> genMaybe genPageId <*> genText <*> genText

genPageEdit :: Gen PageEdit
genPageEdit = PageEdit <$> genText <*> genText

genPageMove :: Gen PageMove
genPageMove = PageMove <$> genSpaceId <*> genMaybe genPageId

genShiftBy :: Gen ShiftBy
genShiftBy = ShiftBy <$> arbitraryBoundedEnum

genDraftEdit :: Gen DraftEdit
genDraftEdit = DraftEdit <$> genUtcTime <*> genText <*> genText

genAuthor :: Gen Author
genAuthor = Author <$> genUserId <*> genText

genVersionInfo :: Gen VersionInfo
genVersionInfo = VersionInfo <$> genPageId <*> genUtcTime <*> genText <*> oneof [pure Nothing, Just <$> genAuthor] <*> chooseInt (1, 10000)

genVersion :: Gen Version
genVersion = Version <$> genPageId <*> genUtcTime <*> genText <*> genText <*> oneof [pure Nothing, Just <$> genAuthor]

genDraft :: Gen Draft
genDraft = Draft <$> genPageId <*> genUserId <*> genText <*> genText <*> genUtcTime <*> genUtcTime

genPageConflict :: Gen PageConflict
genPageConflict = PageConflict <$> genText <*> genUtcTime <*> arbitrary

genPagePlan :: Gen PagePlan
genPagePlan = PagePlan <$> genSlugs <*> genText <*> chooseInt (0, 5) <*> genMaybe genPageConflict

genSpacePlan :: Gen SpacePlan
genSpacePlan = SpacePlan <$> genSlugs <*> genText <*> arbitraryBoundedEnum <*> resize 4 (listOf genPagePlan)

genImportPlan :: Gen ImportPlan
genImportPlan = ImportPlan <$> resize 4 (listOf genSpacePlan)

genPageRef :: Gen PageRef
genPageRef = PageRef <$> genSlugs <*> genSlugs

genImportChoices :: Gen ImportChoices
genImportChoices = do
  skipSpaces <- resize 3 (listOf genSlugs)
  skipPages <- resize 3 (listOf genPageRef)
  conflicts <- resize 3 (listOf (ConflictChoice <$> genPageRef <*> arbitraryBoundedEnum))
  pure ImportChoices {skipSpaces, skipPages, conflicts}

genImportSummary :: Gen ImportSummary
genImportSummary =
  ImportSummary <$> count <*> count <*> count <*> count <*> count <*> count <*> count
  where
    count = chooseInt (0, 1000)

-- | Bytes of every value, a zip file's or an image's.
genBytes :: Gen LByteString
genBytes = BSL.pack <$> listOf arbitrary

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]
