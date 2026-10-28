-- | The JSON of every body a client depends on, checked against files kept
-- in @test-server\/golden\/@: a change to a type that changes its JSON (a field renamed,
-- a constructor written differently) fails here, rather than unnoticed in a
-- browser that still expects the old shape.
--
-- Each file is compared as JSON, not as text, both ways: what the value is
-- written as is the file, and the file reads as the value. To write the
-- files again after a deliberate change, run the suite with
-- @WIKI_API_GOLDEN=accept@ and read the diff before committing it.
module Test.Golden (spec) where

import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeFileStrict', toJSON)
import Data.Aeson.Encode.Pretty (Config (..), Indent (..), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Protolude
import System.Environment (lookupEnv)
import Test.Hspec
import Test.Sample qualified as Sample
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount (..), NewPassword (..), PasswordChange (..))
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..))
import Wiki.Api.Backups (BackupRecord (..), Backups (..), Trigger (..))
import Wiki.Api.Comments (CommentText (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Events (ClientMessage (..), PageEvent (..), ServerMessage (..))
import Wiki.Api.Info (Health (..), ServerInfo (..))
import Wiki.Api.Notifications (NotificationSettingsChange (..), ReadMark (..), Watching (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), NewPasswordByMail (..), OneTimeCode (..), RecoveryCodes (..), ResetRequest (..))
import Wiki.Api.ServerSettings (MailTest (..), MailTestResult (..), ProviderCheck (..), SecretState (..), ServerSettingsChange, noServerSettings)
import Wiki.Api.Types
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Blog (PostDetails (..))
import Wiki.Core.Id (BlobId (..), CommentId (..), CommentThreadId (..), GroupId (..), NotificationId (..), PageId (..), SpaceId (..))
import Wiki.Core.Notification (MailMode (..), Watch (..), WatchReason (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (summaryOf)
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Space (Icon (..), SpaceProfile (..))
import Wiki.Core.User (Password (..))
import Wiki.Core.Version (VersionInfo (..))

-- | A golden file: its name, and the value it holds.
golden :: forall a. (Eq a, Show a, ToJSON a, FromJSON a) => FilePath -> a -> Spec
golden name value = it name $ do
  let path = "test-server/golden/" <> name <> ".json"
  accept <- (== Just "accept") <$> lookupEnv "WIKI_API_GOLDEN"
  when accept $ BSL.writeFile path (encodePretty' config value <> "\n")
  json <- either (panic . toS) identity <$> eitherDecodeFileStrict' path
  (json :: Value) `shouldBe` toJSON value
  eitherDecodeFileStrict' path `shouldReturn` Right value
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare}

spec :: Spec
spec = describe "golden JSON" $ do
  describe "responses" $ do
    golden "server-info" ServerInfo {name = "Wiki", apiVersion = 1}
    golden "health" Health {status = "ok", schemaVersion = 9, lastBackupAgeSeconds = Just 3600}
    golden "activity" Sample.activity
    golden "session" Sample.sessionInfo
    golden "space" Sample.space
    golden "page-counts" (Map.fromList [(SpaceId "s1", 5 :: Int), (SpaceId "s2", 0)])
    golden "post-details" (Map.fromList [(PageId "p1", Sample.postDetails), (PageId "p2", PostDetails {author = Nothing, comments = 0, excerpt = ""})])
    golden "page" Sample.page
    golden "page-summaries" [summaryOf Sample.page]
    golden "attachment" Sample.attachment
    golden "draft" Sample.draft
    golden "versions" [Sample.versionInfo, Sample.versionInfo {updatedAt = Sample.later, title = "A tour", author = Nothing}]
    golden "version" Sample.version
    golden "search-hits" [Sample.hit]
    golden "import-plan" Sample.importPlan
    golden "import-summary" Sample.importSummary
    golden "server-status" Sample.serverStatus
    golden "directory" Sample.directory
    golden "account" Sample.account
    golden "space-access" Sample.spaceAccess
    golden "settings" Sample.settings
    golden "invitations" Sample.invitations
    golden "invited" Sample.invited
    golden "invitation-info" Sample.invitationInfo
    golden "sign-in-methods" Sample.signInMethods
    golden "sessions" Sample.sessions
    golden "second-factor" Sample.secondFactor
    golden "totp-enrolment" Sample.enrolment
    golden "recovery-codes" RecoveryCodes {codes = ["abcd-efgh-ijkl-mnop", "qrst-uvwx-yz23-4567"]}
    golden "email-state" Sample.emailState
    golden "server-settings" Sample.serverSettings
    golden "provider-check" Sample.providerCheck
    golden "provider-check-failed" ProviderCheck {redirectUri = Nothing, clientSecret = NotSet, discovered = Nothing, problem = Just "Corp could not be reached at https://id.example.org/realms/corp/.well-known/openid-configuration."}
    golden "mail-test-result" MailTestResult {failure = Just "The mail server at mail.example.org:587 did not answer in time."}
    golden "backups" Sample.backups
    golden "backups-failed" Sample.backups {last = (\r -> r {file = Nothing, size = Nothing, failure = Just "The disk is full.", offSite = Nothing, trigger = Manual}) <$> Sample.backups.last, running = True}
    golden "threads" [Sample.inlineThread, Sample.pageThread]
    golden "comment" Sample.reply
    golden "notifications" Sample.notifications
    golden "notification-settings" Sample.notificationSettings
    golden "watch" [Watch True Chosen, Watch True (FromSpace (SpaceId "s1")), Watch True OwnPage, Watch False Unchosen]
    golden "people" (Map.fromList [("bea" :: Text, Sample.author)])
  describe "the live channel's messages" $ do
    golden "client-messages" [Subscribe (PageId "p1"), Unsubscribe (PageId "p1"), StartEditing (PageId "p1"), StopEditing (PageId "p1")]
    golden
      "server-messages"
      [ Subscribed (PageId "p1") [Sample.inlineThread, Sample.pageThread] [Sample.author]
      , Refused (PageId "p2")
      , Event (PageId "p1") (ThreadOpened Sample.pageThread)
      , Event (PageId "p1") (CommentAdded Sample.reply)
      , Event (PageId "p1") (CommentEdited Sample.reply)
      , Event (PageId "p1") (CommentDeleted (CommentThreadId "t1") (CommentId "c2"))
      , Event (PageId "p1") (ThreadResolved (CommentThreadId "t1") True)
      , Event (PageId "p1") (ThreadDeleted (CommentThreadId "t2"))
      , Event (PageId "p1") (Editing [Sample.author])
      , Event (PageId "p1") (PageChanged Sample.later)
      , Notified Sample.notification
      ]
  describe "errors" $ do
    golden "error-not-found" NotFound
    golden "error-forbidden" Forbidden
    golden "error-conflict" (Conflict "The page has been saved since you began editing it.")
    golden "error-invalid" (Invalid "A page needs a title.")
    golden "error-unauthenticated" Unauthenticated
    golden "error-too-many-requests" (TooManyRequests "Too many failed attempts to sign in as ada: try again in 15 minutes.")
    golden "error-second-factor-required" SecondFactorRequired
  describe "requests" $ do
    golden "new-space" NewSpace {parent = Just (SpaceId "s1"), name = "Guides"}
    golden "space-name" SpaceName {name = "Guides"}
    golden "space-public" SpacePublic {public = True}
    golden "space-math-macros" SpaceMathMacros {mathMacros = "\\R: \\mathbb{R}"}
    golden "space-profile" SpaceProfile {description = "Guides for writers.", icon = Just (IconImage (BlobId "b1") "image/png"), homePage = Just (PageId "p1"), blog = False}
    golden "space-profile-colour" SpaceProfile {description = "", icon = Just (IconColour "teal"), homePage = Nothing, blog = True}
    golden "space-order" SpaceOrder {children = ChildPages, order = NewestFirst}
    golden "space-move" SpaceMove {parent = Nothing}
    golden "new-page" NewPage {parent = Nothing, title = "Tour", body = "# Tour"}
    golden "page-edit" PageEdit {title = "Tour", body = "# Tour, again"}
    golden "page-move" PageMove {space = SpaceId "s2", parent = Just (PageId "p9")}
    golden "page-template" PageTemplate {template = True}
    golden "new-thread" NewThread {anchor = Just Anchor {exact = "a diagram", prefix = "Here is ", suffix = " of the wiki."}, body = "Which **diagram**?"}
    golden "new-page-thread" NewThread {anchor = Nothing, body = "A good tour."}
    golden "comment-text" CommentText {body = "Agreed."}
    golden "thread-resolution" ThreadResolution {resolved = True}
    golden "read-mark" ReadMark {ids = [NotificationId "n1"], everything = False}
    golden "notification-settings-change" NotificationSettingsChange {mail = MailOff, watchOwn = False}
    golden "watching" Watching {watching = True}
    golden "shift" ShiftBy {shift = ShiftToTop}
    golden "draft-edit" DraftEdit {base = Sample.time, title = "Tour", body = "# Tour, unsaved"}
    golden "import-choices" Sample.importChoices
    golden "administrator-flag" AdministratorFlag {administrator = True}
    golden "create-spaces-flag" CreateSpacesFlag {createSpaces = False}
    golden "space-grant-change" SpaceGrantChange {subject = SubjectGroup (GroupId "g1"), permission = View, granted = True}
    golden "group-name" GroupName {name = "writers"}
    golden "credentials" Credentials {login = "ada", password = Password "correct horse battery staple"}
    golden "new-account" NewAccount {login = "ada", displayName = "Ada", password = Password "correct horse battery staple", email = Just "ada@example.org"}
    golden "one-time-code" OneTimeCode {code = "287082"}
    golden "email-change" EmailChange {email = "ada@example.org", password = Just (Password "correct horse battery staple")}
    golden "current-password" CurrentPassword {password = Just (Password "correct horse battery staple")}
    golden "reset-request" ResetRequest {login = "ada"}
    golden "new-password-by-mail" NewPasswordByMail {password = Password "correct horse battery staple"}
    golden "new-password" NewPassword {password = Password "correct horse battery staple"}
    golden "password-change" PasswordChange {current = Just (Password "correct horse battery staple"), new = Password "a longer passphrase than that"}
    golden "account-disabled" AccountDisabled {disabled = True}
    golden "new-invitation" NewInvitation {email = "bea@example.org"}
    golden "server-settings-change" Sample.serverChange
    golden "server-settings-clear" (noServerSettings :: ServerSettingsChange)
    golden "backup-settings-change" Sample.backupChange
    golden "backup-settings-rclone" Sample.backupRcloneChange
    golden "mail-test" MailTest {to = "ada@example.org"}
