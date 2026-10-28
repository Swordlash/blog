-- | The audit log, as the storage writes it (WP4.10 of docs/PLAN.md): one
-- row for each write to the wiki's administration, in its transaction, as
-- whoever made it, from where they asked, with what changed and never a
-- secret; none for a write refused. The "Activity" reads it newest first,
-- by actor and a page at a time; an export carries it and an import brings
-- it back, each entry once.
module Test.Storage.Audit (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Only (..), execute, query_)
import Protolude
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Account (NewAccount (..))
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize, firstPage)
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), WikiSettings (..))
import Wiki.Api.Backups (BackupSettingsOf (..), DestinationOf (..), defaultBackupSettings)
import Wiki.Api.Import (importEverything)
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), noServerSettings)
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Id
import Wiki.Core.Page (PageSummary (..))
import Wiki.Core.Permission (SpacePermission (..))
import Wiki.Core.Permission qualified as P
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.User (Group (..), User (..))
import Wiki.Server.Accounts qualified as Accounts
import Wiki.Server.Import (applyImport)
import Wiki.Server.Storage
import Wiki.Server.Storage.Audit (loadAuditLog, operator)
import Wiki.Server.Storage.Rows (Stamp (..), insertIdentity)

spec :: Spec
spec = describe "the audit log" $ do
  eachWrite
  secrets
  refused
  reading
  moving

-- | Where the tests' requests come from.
origin :: Text
origin = "100.64.0.9"

-- | Run as one of the demo's users, from 'origin'.
as :: Storage -> Text -> SqliteWiki IO a -> IO a
as st login program = do
  who <- whoFor st (As login)
  runSqliteWikiFrom st who origin program

-- | The log, the oldest first.
logged :: Storage -> IO [AuditEntry]
logged st = withDatabase st loadAuditLog

-- | What a write added to the log: exactly one entry, which is given back.
recordsOne :: (HasCallStack, Show e) => Storage -> IO (Either e a) -> IO AuditEntry
recordsOne st write = do
  already <- length <$> logged st
  _ <- write >>= ok
  added <- drop already <$> logged st
  case added of
    [e] -> pure e
    _ -> assertFailure ("expected one entry, got " <> show added)

-- | An entry's action, subject and detail, as the tests compare them.
summary :: AuditEntry -> (Text, Text, Text, [(Text, Text)])
summary e = (e.action, e.subject.kind, e.subject.name, Map.toList e.detail)

spaceNamed :: Storage -> Text -> IO Space
spaceNamed st name = as st "admin" listSpaces >>= maybe (assertFailure ("no space " <> toS name)) pure . find (\s -> s.name == name)

userNamed :: Storage -> Text -> IO User
userNamed st login = userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) pure

eachWrite :: Spec
eachWrite = describe "has one entry for each write of the administration" $ do
  it "a grant on a space, given and taken away, and a space made public" $ withDemo $ \st -> do
    docs <- spaceNamed st "Docs"
    rita <- userNamed st "reader"
    granted <- recordsOne st (as st "admin" (setSpaceGrant docs.id (P.SubjectUser rita.id) Edit True))
    summary granted `shouldBe` ("space.grant", "space", "Docs", [("permission", "edit"), ("to", "user reader")])
    granted.actor.login `shouldBe` "admin"
    granted.address `shouldBe` origin
    granted.subject.id `shouldBe` Just docs.id.text
    revoked <- recordsOne st (as st "admin" (setSpaceGrant docs.id (P.SubjectUser rita.id) Edit False))
    summary revoked `shouldBe` ("space.revoke", "space", "Docs", [("permission", "edit"), ("to", "user reader")])
    public <- recordsOne st (as st "admin" (setSpacePublic docs.id False))
    summary public `shouldBe` ("space.public", "space", "Docs", [("public", "no")])

  it "a space's profile changed in its settings, and an icon uploaded; a save that changes nothing, none" $ withDemo $ \st -> do
    docs <- spaceNamed st "Docs"
    pages <- as st "admin" (listPages docs.id) >>= ok
    guide <- maybe (assertFailure "the docs have no Markdown guide") pure (find (\p -> slugText p.slug == "markdown-guide") pages)
    let profile b = SpaceProfile {description = "How to write here, and why.", icon = Just (IconColour "teal"), homePage = Just guide.id, blog = b}
    changed <- recordsOne st (as st "admin" (setSpaceProfile docs.id (profile docs.blog)))
    summary changed `shouldBe` ("space.profile", "space", "Docs", [("description", "How to write here, and why."), ("home page", guide.title), ("icon", "colour teal")])
    blog <- recordsOne st (as st "admin" (setSpaceProfile docs.id (profile (not docs.blog))))
    summary blog `shouldBe` ("space.profile", "space", "Docs", [("blog", if docs.blog then "no" else "yes")])
    already <- length <$> logged st
    _ <- as st "admin" (setSpaceProfile docs.id (profile (not docs.blog))) >>= ok
    length <$> logged st `shouldReturn` already
    uploaded <- recordsOne st (as st "admin" (uploadSpaceIcon docs.id "image/png" "not really a picture"))
    summary uploaded `shouldBe` ("space.profile", "space", "Docs", [("icon", "an uploaded image")])

  it "a space deleted, with what went with it, and a page deleted" $ withDemo $ \st -> do
    blog <- spaceNamed st "Blog"
    pages <- as st "admin" (listPages blog.id) >>= ok
    let leaves = [p | p <- pages, isNothing p.parent, not (any (\q -> q.parent == Just p.id) pages)]
    victim <- maybe (assertFailure "the blog has no page without pages under it") pure (head leaves)
    deletedPage <- recordsOne st (as st "editor" (deletePage victim.id))
    summary deletedPage `shouldBe` ("page.delete", "page", victim.title, [("path", slugText victim.slug), ("space", "blog")])
    deletedPage.actor.login `shouldBe` "editor"
    team <- spaceNamed st "Team"
    deletedSpace <- recordsOne st (as st "admin" (deleteSpace team.id))
    (\(a, k, n, _) -> (a, k, n)) (summary deletedSpace) `shouldBe` ("space.delete", "space", "Team")
    Map.lookup "path" deletedSpace.detail `shouldBe` Just "team"
    Map.lookup "subspaces" deletedSpace.detail `shouldBe` Just "1"

  it "a user's grants of the wiki, account, password, login and second factor, and an identity" $ withDemo $ \st -> do
    rita <- userNamed st "reader"
    made <- recordsOne st (as st "admin" (setAdministrator rita.id True))
    summary made `shouldBe` ("user.administrator", "user", "reader", [("administrator", "yes")])
    creates <- recordsOne st (as st "admin" (setCreateSpaces rita.id True))
    summary creates `shouldBe` ("user.create-spaces", "user", "reader", [("creates spaces", "yes")])
    password <- recordsOne st (as st "admin" (setPassword rita.id "a new password of hers"))
    summary password `shouldBe` ("user.password", "user", "reader", [])
    disabled <- recordsOne st (as st "admin" (setDisabled rita.id True))
    summary disabled `shouldBe` ("user.disable", "user", "reader", [])
    enabled <- recordsOne st (as st "admin" (setDisabled rita.id False))
    summary enabled `shouldBe` ("user.enable", "user", "reader", [])
    now <- getCurrentTime
    withDatabase st $ \c -> do
      execute c "INSERT INTO totp (user_id, secret, created_at, enabled_at) VALUES (?, 'JBSWY3DPEHPK3PXP', ?, ?)" (rita.id.text, Stamp now, Stamp now)
      insertIdentity c now rita.id "github" "1234" Nothing Nothing
    factor <- recordsOne st (as st "admin" (removeSecondFactor rita.id))
    summary factor `shouldBe` ("user.second-factor-remove", "user", "reader", [])
    unlinked <- recordsOne st (as st "admin" (unlinkUserIdentity rita.id "github"))
    summary unlinked `shouldBe` ("user.identity-remove", "user", "reader", [("provider", "github")])
    created <- recordsOne st (as st "admin" (createUser (newAccount "bea" "Bea")))
    summary created `shouldBe` ("user.create", "user", "bea", [("login", "bea"), ("name", "Bea")])

  it "a group made, renamed, given and losing a member, and deleted" $ withDemo $ \st -> do
    rita <- userNamed st "reader"
    made <- recordsOne st (as st "admin" (createGroup "Readers"))
    g <- as st "admin" directory >>= ok >>= \d -> maybe (assertFailure "no group") pure (find (\(x :: Group) -> x.name == "Readers") d.groups)
    summary made `shouldBe` ("group.create", "group", "Readers", [])
    renamed <- recordsOne st (as st "admin" (renameGroup g.id "Proofreaders"))
    summary renamed `shouldBe` ("group.rename", "group", "Proofreaders", [("was", "Readers")])
    added <- recordsOne st (as st "admin" (addMember g.id rita.id))
    summary added `shouldBe` ("group.member-add", "group", "Proofreaders", [("user", "reader")])
    removed <- recordsOne st (as st "admin" (removeMember g.id rita.id))
    summary removed `shouldBe` ("group.member-remove", "group", "Proofreaders", [("user", "reader")])
    deleted <- recordsOne st (as st "admin" (deleteGroup g.id))
    summary deleted `shouldBe` ("group.delete", "group", "Proofreaders", [])

  it "the wiki's settings, and invitations made and revoked" $ withDemo $ \st -> do
    settings <- recordsOne st (as st "admin" (setWikiSettings WikiSettings {access = Closed, newAccountsCreateSpaces = True}))
    summary settings `shouldBe` ("settings.wiki", "settings", "whom the wiki lets in", [("access", "closed"), ("new accounts create spaces", "yes")])
    invited <- recordsOne st (as st "admin" (invite "bea@example.org"))
    summary invited `shouldBe` ("invitation.create", "invitation", "bea@example.org", [])
    i <- as st "admin" invitations >>= ok >>= \is -> maybe (assertFailure "no invitation") pure (head is.invitations)
    revoked <- recordsOne st (as st "admin" (revokeInvitation i.id))
    summary revoked `shouldBe` ("invitation.revoke", "invitation", "bea@example.org", [])
    revoked.subject.id `shouldBe` Just i.id.text

  it "the console's writes, as the operator's from the console, and an account someone makes, with a password or a provider" $ withDemo $ \st -> do
    made <- recordsOne st (Accounts.createAccount st "cleo" "Cleo" (Just "a password of hers"))
    summary made `shouldBe` ("user.create", "user", "cleo", [("login", "cleo"), ("name", "Cleo")])
    made.actor `shouldBe` operator
    made.address `shouldBe` "console"
    cleo <- userNamed st "cleo"
    admin <- recordsOne st (Accounts.setAdministrator st cleo.id True)
    summary admin `shouldBe` ("user.administrator", "user", "cleo", [("administrator", "yes")])
    now <- getCurrentTime
    registered <- recordsOne st (Accounts.register st now "100.64.0.10" (newAccount "dora" "Dora"))
    summary registered `shouldBe` ("user.register", "user", "dora", [])
    registered.actor.login `shouldBe` "dora"
    registered.address `shouldBe` "100.64.0.10"
    -- One a provider's sign-in makes, with the provider.
    landed <- recordsOne st (Accounts.landWith st now "100.64.0.11" Accounts.SignInOnly Accounts.Claimed {provider = "github", subject = "42", email = Nothing, name = Just "Eve", login = Just "eve"})
    summary landed `shouldBe` ("user.register", "user", "eve", [("provider", "github")])
    landed.actor.login `shouldBe` "eve"
    landed.address `shouldBe` "100.64.0.11"

  it "an import, with what it did, as the administrator" $ withDemo $ \st -> do
    actor <- actorOf st Administrator
    imported <- recordsOne st (Right . const () <$> applyImport st actor "127.0.0.1" demoArchive importEverything :: IO (Either Text ()))
    (\(a, k, _, _) -> (a, k)) (summary imported) `shouldBe` ("wiki.import", "wiki")
    imported.actor `shouldBe` operator
    imported.address `shouldBe` "127.0.0.1"
    Map.lookup "pages kept" imported.detail `shouldSatisfy` isJust
  where
    newAccount login displayName = NewAccount {login, displayName, password = "a password of theirs", email = Nothing}

secrets :: Spec
secrets = describe "never holds a secret" $ do
  it "says a mail password and an rclone configuration changed, not what they are" $ withDemo $ \st -> do
    let mailWith password = MailSettings {host = "mail.example.org", port = 587, security = StartTls, user = Just "wiki", password, from = "wiki@example.org"}
        mail = mailWith (Just "hunter2-mail-secret")
    server <- recordsOne st (as st "admin" (setServerSettings noServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just mail}))
    summary server
      `shouldBe` ( "settings.server"
                 , "settings"
                 , "the server"
                 , [("mail", "mail.example.org:587 (starttls), from wiki@example.org"), ("mail password", "changed"), ("public address", "https://wiki.example.org/")]
                 )
    kept <- recordsOne st (as st "admin" (setServerSettings noServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just (mailWith Nothing)}))
    summary kept `shouldBe` ("settings.server", "settings", "the server", [])
    backed <- recordsOne st (as st "admin" (setBackupSettings defaultBackupSettings {enabled = True, destination = Just (ToRclone "b2:wiki" (Just "[b2]\naccount = rclone-secret"))}))
    summary backed `shouldBe` ("settings.backups", "settings", "backups", [("copied to", "b2:wiki"), ("on", "yes"), ("rclone configuration", "changed")])
    everything <- withDatabase st $ \c -> query_ c "SELECT detail || subject_name || action FROM audit_log" :: IO [Only Text]
    for_ everything $ \(Only row) -> do
      row `shouldSatisfy` (not . T.isInfixOf "hunter2")
      row `shouldSatisfy` (not . T.isInfixOf "rclone-secret")

refused :: Spec
refused = describe "has no entry for a write refused" $
  it "nor for one made by someone who may not" $
    withDemo $ \st -> do
      rita <- userNamed st "reader"
      earlier <- logged st
      as st "editor" (setAdministrator rita.id True) >>= (`shouldBe` Left Forbidden)
      as st "admin" (createGroup "  ") >>= (`shouldSatisfy` isLeft)
      logged st `shouldReturn` earlier

reading :: Spec
reading = describe "is read" $ do
  it "the newest first, a page at a time, everyone's or one actor's, by whoever administers the wiki" $ withDemo $ \st -> do
    for_ [1 .. activityPageSize + 2] $ \n -> as st "admin" (createGroup ("Group " <> show (n :: Int))) >>= ok
    rita <- userNamed st "reader"
    _ <- as st "admin" (setCreateSpaces rita.id True) >>= ok
    _ <- Accounts.setDisabled st rita.id True >>= ok
    page1 <- as st "admin" (activity firstPage) >>= ok
    page1.available `shouldBe` True
    length page1.entries `shouldBe` activityPageSize
    page1.more `shouldBe` True
    map (\e -> e.action) (take 2 page1.entries) `shouldBe` ["user.disable", "user.create-spaces"]
    map (\e -> e.at) page1.entries `shouldBe` sortOn Down (map (\e -> e.at) page1.entries)
    page2 <- as st "admin" (activity firstPage {offset = activityPageSize}) >>= ok
    length page2.entries `shouldBe` 4
    page2.more `shouldBe` False
    map (\a -> a.login) page1.actors `shouldBe` ["admin", "administrator"]
    admin <- userNamed st "admin"
    theirs <- as st "admin" (activity ActivityQuery {actor = Just admin.id, offset = 0}) >>= ok
    all (\e -> e.actor.login == "admin") theirs.entries `shouldBe` True
    console <- as st "admin" (activity ActivityQuery {actor = Just operator.id, offset = 0}) >>= ok
    map (\e -> e.action) console.entries `shouldBe` ["user.disable"]
    as st "editor" (activity firstPage) >>= (`shouldBe` Left Forbidden)

moving :: Spec
moving = describe "moves with the wiki" $ do
  it "in an export, and back into an empty wiki by its import" $ withDemo $ \st -> do
    _ <- as st "admin" (createGroup "Writers too") >>= ok
    written <- logged st
    archive <- exportArchive st "test" >>= ok
    archive.audit `shouldBe` written
    withStorageIn $ \_ fresh -> do
      importArchive fresh archive >>= ok
      logged fresh `shouldReturn` written

  it "merged by the import of a wiki with content, each entry once" $ withDemo $ \st -> do
    _ <- as st "admin" (createGroup "Writers too") >>= ok
    archive <- exportArchive st "test" >>= ok
    withStorageIn $ \_ other -> do
      importArchive other demoArchive >>= ok
      actor <- actorOf other Administrator
      _ <- applyImport other actor "127.0.0.1" archive importEverything
      _ <- applyImport other actor "127.0.0.1" archive importEverything
      merged <- logged other
      length (filter (\e -> e.action == "group.create") merged) `shouldBe` 1
      length (filter (\e -> e.action == "wiki.import") merged) `shouldBe` 2
