-- | The upgrade's rehearsal (WP5.75 of docs/PLAN.md, "Wiki.Server.Rehearsal"):
-- the pages check's comparison of the pages read before the migration
-- with those read after, the copy cut off from the outside, and each check
-- run with this program as both the old and the new one. The rehearsal
-- itself runs two programs, and is tested end to end by
-- toolchain/rehearse-ci.sh in CI.
module Test.Server.Rehearsal (unitSpec, spec) where

import Data.Aeson (encode)
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, managerResponseTimeout, newManager, responseTimeoutMicro)
import Network.HTTP.Types (hContentType)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing, choiceOf, withConnectionTo, withEmptyPlace)
import Test.Hspec
import Test.Server.Fixture (Reply (status), Running (..), cookie, givePassword, send, signInAs, withDemoPlace, withDemoRunning)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Types (PersonalSpaceSwitch (..))
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Server.Accounts (listAccounts)
import Wiki.Server.Console (runUsers, usersParser)
import Wiki.Server.Options (DatabaseChoice (..))
import Wiki.Server.Rehearsal (Check (..), PageRead (..), Seeding (..), Server (..), checks, comparePages, isolateCopy, readPages)
import Wiki.Server.Storage (Place (..), migrateDatabase, withStorageAside)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (settingsLike, storeSetting)

unitSpec :: Spec
unitSpec = describe "the upgrade's rehearsal, the pages check" $ do
  let first' = PageRead {space = "s1", page = "p1", title = "First", body = "# First\n\nText."}
      second' = PageRead {space = "s1", page = "p2", title = "Second", body = "More."}
  it "passes when every page reads the same, in whatever order" $
    comparePages [first', second'] [second', first'] `shouldBe` Right ()
  it "names a page whose source changed, one whose title changed, one gone and one new" $ do
    let changed = first' {body = "# First\n\nOther text."}
        renamed = second' {title = "Second, renamed"}
        third = PageRead {space = "s2", page = "p3", title = "Third", body = ""}
        why = either identity (const "") (comparePages [first', second'] [changed, renamed, third])
    why `shouldSatisfy` T.isInfixOf "page p1 (First) has another source"
    why `shouldSatisfy` T.isInfixOf "page p2 (Second) has another title: Second, renamed"
    why `shouldSatisfy` T.isInfixOf "page p3 (Third) is new"
    comparePages [first', second'] [first'] `shouldSatisfy` isLeft
  it "tells the same page id in two spaces apart" $
    comparePages [first'] [first' {space = "s2"}] `shouldSatisfy` isLeft
  it "names five differences and counts the rest" $ do
    let pages = [PageRead {space = "s", page = show i, title = "t", body = "b"} | i <- [1 .. 8 :: Int]]
        why = either identity (const "") (comparePages pages [])
    why `shouldSatisfy` T.isInfixOf "and 3 more"

-- | The copy is cut off from the outside before a server starts on it: no
-- scheduled backup to the running wiki's destination, no notification
-- mail through its mail server.
spec :: Backing -> Spec
spec backing = do
  copySpec backing
  checksSpec backing

copySpec :: Backing -> Spec
copySpec backing = describe "the upgrade's rehearsal, its copy of the wiki" $ do
  it "reads every page an administrator may read, and leaves out the spaces nobody may" $ withDemoRunning backing identity $ \r -> do
    manager <- newManager defaultManagerSettings
    let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public}
    withoutPersonal <- readPages manager server
    withoutPersonal `shouldSatisfy` isRight
    -- The editor's personal space makes the container of personal spaces,
    -- which the list of spaces names and nobody may read.
    givePassword r "user-editor" "editor's password"
    token <- signInAs r "editor" "editor's password"
    turnedOn <- send r "PUT" (r.public <> "/api/v1/account/personal-space") [(hContentType, "application/json"), cookie token] (encode PersonalSpaceSwitch {enabled = True})
    turnedOn.status `shouldBe` 200
    withPersonal <- readPages manager server
    withPersonal `shouldSatisfy` isRight
  it "loses its backup and mail settings, and keeps the rest" $
    withSystemTempDirectory "wiki-rehearsal" $ \dir -> withEmptyPlace backing dir $ \place -> do
      _ <- migrateDatabase place
      withConnectionTo place $ \c ->
        runDb c $
          traverse_
            (uncurry storeSetting)
            [ ("backup-enabled", "1")
            , ("backup-schedule", "every 1")
            , ("backup-directory", "/mnt/backup/wiki")
            , ("backup-last", "{}")
            , ("mail-host", "smtp.example.org")
            , ("mail-from", "wiki@example.org")
            , ("access", "closed")
            ]
      isolateCopy place
      left <- withConnectionTo place $ \c -> runDb c (concat <$> traverse settingsLike ["backup-", "mail-", "access"])
      sort left `shouldBe` [("access", "closed"), ("backup-last", "{}")]

-- | Each check, run as the rehearsal runs it, with this program as both the
-- old program and the new one: an upgrade that changes nothing, which every
-- check must pass. The accounts check must also fail, and say why, when the
-- canary's password no longer signs in.
checksSpec :: Backing -> Spec
checksSpec backing = describe "the upgrade's rehearsal, its checks" $ do
  for_ [name | Check {name} <- checks] $ \name ->
    it ("passes the " <> toS name <> " check when the program is upgraded to itself") $ withDemoPlace backing $ \at serve ->
      rehearseCheck name at serve pass `shouldReturn` Right ()
  it "fails the accounts check, naming the password's sign-in, when the canary's password changed after the old program made it" $ withDemoPlace backing $ \at serve -> do
    let changePassword = do
          accounts <- withStorageAside at listAccounts
          case [a.user.login.text | (a, _) <- accounts, "rehearsal-" `T.isPrefixOf` a.user.login.text, a.hasPassword] of
            [login] -> consoleOn at ["users", "password", login] "not the canary's password\n" >>= (`shouldSatisfy` isRight)
            logins -> expectationFailure ("expected one canary account with a password, found " <> show logins)
    verdict <- rehearseCheck "accounts" at serve changePassword
    verdict `shouldSatisfy` either (T.isPrefixOf "the password's first sign-in: not signed in") (const False)

-- | Run the check of this name as the rehearsal does: what it holds around
-- the whole run, its seed on the place, its before on a server over the
-- place, the action given, and its after on a second server over the same
-- place. The result is the after's verdict; a seed or a before that fails
-- fails the test.
rehearseCheck :: Text -> Place -> (forall a. (Running -> IO a) -> IO a) -> IO () -> IO (Either Text ())
rehearseCheck wanted at serve between = do
  manager <- newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 120_000_000}
  let serverOf r = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public}
      orFail :: Text -> Either Text x -> IO x
      orFail what = either (\why -> panic (what <> " of the " <> wanted <> " check failed: " <> why)) pure
  case [c | c@Check {name} <- checks, name == wanted] of
    [Check {holding, seed, before = beforeIt, after = afterIt}] -> holding $ \held -> do
      seeded <- seed held Seeding {copy = at, console = consoleOn at} >>= orFail "the seed"
      fixture <- serve (\r -> beforeIt held seeded manager (serverOf r)) >>= orFail "the before"
      between
      serve (\r -> afterIt held fixture manager (serverOf r))
    _ -> panic ("no check is named " <> wanted)

-- | The console as the rehearsal runs the old program's ('Seeding'), here
-- this program's, in the test: a @users@ command, parsed as the program
-- parses it, with the place's options after it and the input's first line
-- as the password.
consoleOn :: Place -> [Text] -> Text -> IO (Either Text Text)
consoleOn at args input = case args of
  "users" : rest -> case execParserPure defaultPrefs (info usersParser mempty) (map toS (rest <> placeArgs)) of
    Success command -> fmap T.unlines <$> runUsers (\_ -> pure (Right (Password (T.takeWhile (/= '\n') input)))) command
    _ -> pure (Left ("the console does not take " <> T.unwords args))
  _ -> pure (Left ("the test's console runs only users commands, not " <> T.unwords args))
  where
    placeArgs =
      ["--data", toS at.dataDir] <> case choiceOf at.database of
        SqliteChosen file -> ["--sqlite", toS file]
        PostgresChosen url _ -> ["--database", url]
        InDataDirectory -> []
