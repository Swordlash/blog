-- | One value of each type the API sends, as a client would see it: what
-- the golden files hold, and what the stub server answers with.
module Test.Sample
  ( time
  , later
  , slug
  , space
  , page
  , attachment
  , draft
  , versionInfo
  , version
  , hit
  , sessionInfo
  , account
  , importPlan
  , inlineThread
  , pageThread
  , reply
  , author
  , postDetails
  , importChoices
  , importSummary
  , serverStatus
  , activity
  , directory
  , spaceAccess
  , settings
  , invitation
  , invitations
  , invited
  , invitationInfo
  , signInMethods
  , sessions
  , secondFactor
  , enrolment
  , emailState
  , serverSettings
  , serverChange
  , providerCheck
  , backups
  , backupChange
  , backupsAfter
  , backupRcloneChange
  , notification
  , notifications
  , notificationSettings
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Protolude
import Wiki.Api.Account (Account (..), InvitationInfo (..), LinkedIdentity (..), SignInMethods (..))
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), LoggedError (..), ServerStatus (..), WikiSettings (..))
import Wiki.Api.Backups (BackupRecord (..), BackupSettingsChange, BackupSettingsOf (..), Backups (..), DestinationOf (..), OffSite (..), Retention (..), Schedule (..), Trigger (..))
import Wiki.Api.Export (ExportFormat (..))
import Wiki.Api.Import
import Wiki.Api.Notifications (NotificationSettings (..), Notifications (..))
import Wiki.Api.Security (AccountEmail (..), EmailState (..), SecondFactorState (..), SessionRef (..), SessionSummary (..), TotpEnrolment (..))
import Wiki.Api.ServerSettings (Discovered (..), MailSettingsOf (..), ProviderCheck (..), ProviderKind (..), ProviderSettingsOf (..), SecretState (..), Security (..), ServerSettings, ServerSettingsChange, ServerSettingsOf (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Audit (Actor (..), AuditEntry (..))
import Wiki.Core.Audit qualified as Audit
import Wiki.Core.Blog (PostDetails (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), MailMode (..), Notification (..), PageLocation (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (Piece (..), SearchHit (..), Snippet (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (Group (..), SignInProvider (..), Standing (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..))

-- | A time with a fraction of a second, as a page's version has.
time :: UTCTime
time = UTCTime (fromGregorian 2026 10 24) (picosecondsToDiffTime 34212345678000000)

-- | A time after 'time'.
later :: UTCTime
later = UTCTime (fromGregorian 2026 10 25) 0

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

space :: Space
space =
  Space
    { id = SpaceId "s1"
    , name = "Docs"
    , slug = slug "docs"
    , parent = Nothing
    , public = True
    , mathMacros = "\\R: \\mathbb{R}"
    , createdAt = time
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByHand
    , homePage = Just (PageId "p1")
    , icon = Just (IconEmoji "📘")
    , description = "How to write here."
    , blog = False
    }

attachment :: Attachment
attachment =
  Attachment
    { id = AttachmentId "a1"
    , name = "diagram.png"
    , mediaType = "image/png"
    , size = 1024
    , source = SourceBlob (BlobId "sha256-0f1e")
    }

page :: Page
page =
  Page
    { id = PageId "p1"
    , space = SpaceId "s1"
    , parent = Nothing
    , title = "Tour"
    , slug = slug "tour"
    , body = "# Tour\n\n![A diagram](diagram.png)"
    , attachments = [attachment]
    , createdAt = time
    , updatedAt = time
    , position = 2
    }

draft :: Draft
draft =
  Draft
    { page = PageId "p1"
    , author = UserId "u1"
    , title = "Tour"
    , body = "# Tour, unsaved"
    , base = time
    , savedAt = later
    }

-- | The version 'page' is, as its history lists it.
versionInfo :: VersionInfo
versionInfo =
  VersionInfo
    { page = PageId "p1"
    , updatedAt = time
    , title = "Tour"
    , author = Just Author {id = UserId "u1", name = "Ada"}
    }

-- | The same version, whole.
version :: Version
version =
  Version
    { page = PageId "p1"
    , updatedAt = time
    , title = "Tour"
    , body = "# Tour\n\n![A diagram](diagram.png)"
    , author = Just Author {id = UserId "u1", name = "Ada"}
    }

hit :: SearchHit
hit =
  SearchHit
    { page = PageId "p1"
    , space = SpaceId "s1"
    , title = Snippet [Piece "Tour" True]
    , spacePath = [slug "docs"]
    , pagePath = [slug "tour"]
    , snippet = Snippet [Piece "… a " False, Piece "tour" True, Piece " of the wiki …" False]
    }

sessionInfo :: SessionInfo
sessionInfo =
  SessionInfo
    { user = Just User {id = UserId "u1", login = "ada", displayName = "Ada"}
    , groups = Set.fromList [GroupId "g1"]
    , grants =
        Grants
          { global = [GlobalGrant {subject = SubjectUser (UserId "u1"), permission = CreateSpaces}]
          , spaces = [SpaceGrant {space = SpaceId "s1", subject = SubjectGroup (GroupId "g1"), permission = Edit}]
          , access = Open
          }
    , standing = SignedIn
    , providers = [SignInProvider {name = "github", label = "GitHub"}]
    , exports = [Docx, Html, Pdf]
    }

-- | A user's account, as the administration sees it.
account :: Account
account =
  Account
    { user = User {id = UserId "u1", login = "ada", displayName = "Ada"}
    , hasPassword = True
    , disabled = False
    }

importPlan :: ImportPlan
importPlan =
  ImportPlan
    { spaces =
        [ SpacePlan
            { path = [slug "docs"]
            , name = "Docs"
            , status = SpaceMerged
            , pages =
                [ PagePlan
                    { path = [slug "tour"]
                    , title = "Tour"
                    , attachments = 1
                    , conflict = Just PageConflict {title = "Tour", updatedAt = time, sameContent = False}
                    }
                , PagePlan {path = [slug "tour", slug "more"], title = "More", attachments = 0, conflict = Nothing}
                ]
            }
        , SpacePlan {path = [slug "docs", slug "notes"], name = "Notes", status = SpaceNew, pages = []}
        ]
    }

importChoices :: ImportChoices
importChoices =
  ImportChoices
    { skipSpaces = [[slug "docs", slug "notes"]]
    , skipPages = []
    , conflicts = [ConflictChoice {page = PageRef {space = [slug "docs"], page = [slug "tour"]}, resolution = TakeImported}]
    }

importSummary :: ImportSummary
importSummary =
  ImportSummary
    { spacesCreated = 0
    , spacesMerged = 1
    , pagesCreated = 1
    , pagesReplaced = 1
    , pagesKept = 0
    , pagesSkipped = 0
    , attachments = 1
    }

-- | A server's status, as its operator reads it.
serverStatus :: ServerStatus
serverStatus =
  ServerStatus
    { version = "wiki-server 0.1.0.0"
    , startedAt = time
    , dataDir = "/home/owner/wiki-demo/data"
    , spaces = 3
    , pages = 12
    , attachments = 4
    , users = 2
    , backups = 1
    , schemaVersion = 9
    , lastBackup = Just time
    , connections = 2
    , errors = [LoggedError {at = later, route = "/api/v1/pages/:page", message = "SQLite3 returned ErrorIO"}]
    }

-- | A page of the audit log, as the administration's Activity reads it.
activity :: Activity
activity =
  Activity
    { available = True
    , entries =
        [ AuditEntry
            { id = "e2"
            , at = later
            , actor = Actor {id = UserId "u1", login = "ada"}
            , action = "space.grant"
            , subject = Audit.Subject {kind = "space", id = Just "s1", name = "Docs"}
            , detail = Map.fromList [("to", "group writers"), ("permission", "edit")]
            , address = "100.64.0.7"
            }
        , AuditEntry
            { id = "e1"
            , at = time
            , actor = Actor {id = UserId "~administrator", login = "administrator"}
            , action = "user.create"
            , subject = Audit.Subject {kind = "user", id = Just "u1", name = "ada"}
            , detail = Map.fromList [("login", "ada"), ("name", "Ada")]
            , address = "console"
            }
        ]
    , more = True
    , actors = [Actor {id = UserId "u1", login = "ada"}, Actor {id = UserId "~administrator", login = "administrator"}]
    }

-- | The wiki's people, as the administration reads them: two users, one of
-- them an administrator who may create spaces, the other disabled and
-- without a password, and a group with the other in it.
directory :: Directory
directory =
  Directory
    { users =
        [ User {id = UserId "u1", login = "ada", displayName = "Ada"}
        , User {id = UserId "u2", login = "edgar", displayName = "Edgar"}
        ]
    , administrators = Set.fromList [UserId "u1"]
    , creators = Set.fromList [UserId "u1"]
    , disabled = Set.fromList [UserId "u2"]
    , withPassword = Set.fromList [UserId "u1"]
    , identities = Map.fromList [(UserId "u2", ["github", "google"])]
    , secondFactor = Set.fromList [UserId "u1"]
    , emails = Map.fromList [(UserId "u1", AccountEmail {email = "ada@example.org", verified = True}), (UserId "u2", AccountEmail {email = "edgar@example.org", verified = False})]
    , mailing = True
    , groups = [Group {id = GroupId "g1", name = "writers"}]
    , membership = Map.fromList [(GroupId "g1", Set.fromList [UserId "u2"])]
    }

-- | Who may do what on a space, as its administrator reads it: a grant on
-- the space itself, to a group, and one inherited from its parent, to a
-- user; and whom a grant may be given to.
spaceAccess :: SpaceAccess
spaceAccess =
  SpaceAccess
    { grants =
        [ SpaceGrant {space = SpaceId "s2", subject = SubjectGroup (GroupId "g1"), permission = Edit}
        , SpaceGrant {space = SpaceId "s1", subject = SubjectUser (UserId "u1"), permission = AdministerSpace}
        ]
    , users = directory.users
    , groups = directory.groups
    }

-- | The wiki's settings: closed, and new accounts may create spaces.
settings :: WikiSettings
settings = WikiSettings {access = Closed, newAccountsCreateSpaces = True}

-- | An invitation, not expired.
invitation :: Invitation
invitation = Invitation {id = InvitationId "i1", email = "bea@example.org", createdAt = time, expiresAt = later, expired = False}

-- | The invitations, of a server that mails none.
invitations :: Invitations
invitations =
  Invitations
    { mailing = False
    , invitations = [invitation, Invitation {id = InvitationId "i0", email = "cy@example.org", createdAt = time, expiresAt = time, expired = True}]
    }

-- | An invitation just made and not mailed, with its link's secret.
invited :: Invited
invited = Invited {invitation, token = Just "c2VjcmV0IG9mIGFuIGludml0YXRpb24gZm9yIGJlYQ", mailError = Just "the mail server answered RCPT TO with 550 no such mailbox"}

-- | An invitation as its link shows it.
invitationInfo :: InvitationInfo
invitationInfo = InvitationInfo {email = "bea@example.org", expiresAt = later}

-- | How a user signs in: with a password, and an account at GitHub.
signInMethods :: SignInMethods
signInMethods =
  SignInMethods
    { password = True
    , identities = [LinkedIdentity {provider = "github", email = Just "ada@example.org", name = Just "Ada Lovelace", linkedAt = time}]
    }

-- | A user's sessions: this one, and one elsewhere.
sessions :: [SessionSummary]
sessions =
  [ SessionSummary {id = SessionRef "0a1b2c3d", createdAt = time, lastSeenAt = later, address = "100.64.0.7", current = True}
  , SessionSummary {id = SessionRef "4e5f6a7b", createdAt = time, lastSeenAt = time, address = "", current = False}
  ]

-- | A second factor that is on, with most recovery codes left.
secondFactor :: SecondFactorState
secondFactor = SecondFactorState {enabled = True, recoveryCodesLeft = 9, asksPassword = True}

-- | A second factor being set up: RFC 6238's own test secret.
enrolment :: TotpEnrolment
enrolment =
  TotpEnrolment
    { secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    , uri = "otpauth://totp/Wiki:ada?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Wiki&algorithm=SHA1&digits=6&period=30"
    , qr = ["1110111", "1000001", "1011101"]
    }

-- | An address given and not yet verified, where mail is sent.
emailState :: EmailState
emailState = EmailState {email = Just "ada@example.org", verified = False, mailing = True, mailError = Nothing, asksPassword = True}

-- | The server's settings as they are read: an address, a mail server whose
-- password is set, and two providers, one of them without its secret.
serverSettings :: ServerSettings
serverSettings =
  ServerSettings
    { publicUrl = Just "https://wiki.example.org/"
    , mail = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user = Just "wiki", password = Set, from = "Wiki <wiki@example.org>"}
    , providers =
        [ ProviderSettings {name = "google", kind = Google, clientId = "id.apps.example", issuer = Nothing, secret = Set}
        , ProviderSettings {name = "corp", kind = Generic, clientId = "wiki", issuer = Just "https://id.example.org/realms/corp", secret = NotSet}
        ]
    }

-- | A change of them: the mail's password kept (left out), one provider's
-- secret replaced, another's cleared.
serverChange :: ServerSettingsChange
serverChange =
  ServerSettings
    { publicUrl = Just "https://wiki.example.org/"
    , mail = Just MailSettings {host = "mail.example.org", port = 465, security = ImplicitTls, user = Just "wiki", password = Nothing, from = "wiki@example.org"}
    , providers =
        [ ProviderSettings {name = "google", kind = Google, clientId = "id.apps.example", issuer = Nothing, secret = Just "a new secret"}
        , ProviderSettings {name = "hub", kind = GitHub, clientId = "Iv1.abc", issuer = Nothing, secret = Just ""}
        ]
    }

-- | The backups of a server that makes them every six hours, keeping a
-- week of days and four weeks, and copies them with rclone, whose
-- configuration is set; the last one made on schedule and copied.
backups :: Backups
backups =
  Backups
    { available = True
    , settings =
        BackupSettings
          { enabled = True
          , schedule = EveryHours 6
          , keep = Retention {daily = 7, weekly = 4}
          , destination = Just (ToRclone "b2:wiki-backups/wiki" Set)
          }
    , last =
        Just
          BackupRecord
            { startedAt = time
            , finishedAt = later
            , trigger = OnSchedule
            , file = Just "20261024T153000.000Z.sqlite"
            , size = Just 1253376
            , failure = Nothing
            , offSite = Just OffSite {to = "b2:wiki-backups/wiki", problem = Nothing}
            }
    , running = False
    , next = Just later
    , kept = 9
    }

-- | The backups as a server answers a change of their settings: the
-- configuration said to be set if it was given.
backupsAfter :: BackupSettingsChange -> Backups
backupsAfter change = Backups {available = True, settings = maybe NotSet (const Set) <$> change, last = backups.last, running = False, next = backups.next, kept = backups.kept}

-- | A change of them: every day at 03:30, to a directory.
backupChange :: BackupSettingsChange
backupChange =
  BackupSettings
    { enabled = True
    , schedule = DailyAt 3 30
    , keep = Retention {daily = 14, weekly = 8}
    , destination = Just (ToDirectory "/mnt/backup/wiki")
    }

-- | A change that keeps the rclone configuration (left out) of another
-- remote.
backupRcloneChange :: BackupSettingsChange
backupRcloneChange = backupChange {destination = Just (ToRclone "b2:other" Nothing)}

-- | What checking a provider found.
providerCheck :: ProviderCheck
providerCheck =
  ProviderCheck
    { redirectUri = Just "https://wiki.example.org/auth/corp/callback"
    , clientSecret = Set
    , discovered =
        Just
          Discovered
            { issuer = "https://id.example.org/realms/corp"
            , authorization = "https://id.example.org/realms/corp/auth"
            , token = "https://id.example.org/realms/corp/token"
            , userinfo = Just "https://id.example.org/realms/corp/userinfo"
            }
    , problem = Nothing
    }

-- | A reply to 'inlineThread', edited since.
-- | Someone as a comment and the live channel name them.
author :: Author
author = Author {id = UserId "u2", name = "Bea"}

-- | What a post is listed with: its first author and its comments.
postDetails :: PostDetails
postDetails = PostDetails {author = Just author, comments = 3}

reply :: Comment
reply =
  Comment
    { id = CommentId "c2"
    , thread = CommentThreadId "t1"
    , author = Author {id = UserId "u2", name = "Bea"}
    , body = "Agreed, *and* the next one."
    , createdAt = later
    , editedAt = Just later
    }

-- | A thread about a quote of 'page', with its first comment and a reply.
inlineThread :: Thread
inlineThread =
  Thread
    { id = CommentThreadId "t1"
    , page = PageId "p1"
    , anchor = Just Anchor {exact = "a diagram", prefix = "Here is ", suffix = " of the wiki."}
    , resolved = False
    , createdAt = time
    , comments =
        [ Comment {id = CommentId "c1", thread = CommentThreadId "t1", author = Author {id = UserId "u1", name = "Ada"}, body = "Which **diagram**?", createdAt = time, editedAt = Nothing}
        , reply
        ]
    }

-- | A thread about the whole of 'page', resolved never.
pageThread :: Thread
pageThread =
  Thread
    { id = CommentThreadId "t2"
    , page = PageId "p1"
    , anchor = Nothing
    , resolved = False
    , createdAt = later
    , comments = [Comment {id = CommentId "c3", thread = CommentThreadId "t2", author = Author {id = UserId "u1", name = "Ada"}, body = "A good tour.", createdAt = later, editedAt = Nothing}]
    }

-- | Bea's reply, as the notification its thread's opener is told of it.
notification :: Notification
notification =
  Notification
    { id = NotificationId "n1"
    , kind = Replied
    , page = page.id
    , thread = Just inlineThread.id
    , actor = author
    , title = "Tour"
    , excerpt = "Agreed, and @ada should see this."
    , createdAt = later
    , read = False
    , location = Just PageLocation {space = [slug "docs"], page = [slug "tour"]}
    }

notifications :: Notifications
notifications =
  Notifications
    { unread = 1
    , items = [notification, notification {id = NotificationId "n0", kind = Changed, thread = Nothing, excerpt = "", createdAt = time, read = True, location = Nothing}]
    }

notificationSettings :: NotificationSettings
notificationSettings = NotificationSettings {mail = MailDaily, watchOwn = True, verifiedEmail = True, mailing = True}
