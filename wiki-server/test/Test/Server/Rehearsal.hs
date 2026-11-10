-- | The upgrade's rehearsal (WP5.75 of docs/PLAN.md, "Wiki.Server.Rehearsal"):
-- the pages check's comparison of the pages read before the migration
-- with those read after, the copy cut off from the outside, and each check
-- run with this program as both the old and the new one, on one database
-- and across a move from SQLite to PostgreSQL (WP5.80b). The rehearsal
-- itself runs two programs, and is tested end to end by
-- toolchain/rehearse-ci.sh in CI.
module Test.Server.Rehearsal (unitSpec, spec) where

import Data.Aeson (encode)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Client (defaultManagerSettings, managerResponseTimeout, newManager, responseTimeoutMicro)
import Network.HTTP.Types (hContentType)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing (..), choiceOf, placeOptionsOf, withConnectionTo, withEmptyPlace)
import Test.Hspec
import Test.Server.Fixture (Reply (status), Running (..), cookie, givePassword, send, signInAs, withDemoMoved, withDemoPlace, withDemoRunning)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Types (PersonalSpaceSwitch (..))
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Server.Accounts (listAccounts)
import Wiki.Server.Console (runUsers, usersParser)
import Wiki.Server.CopyDatabase (CopyOptions (..), CopyOutcome (..), runCopy)
import Wiki.Server.Options (DatabaseChoice (..))
import Wiki.Server.Rehearsal (Check (..), PageAt (..), PageRead (..), PagesRead (..), Seeding (..), Server (..), SpaceRead (..), checks, compareHomes, comparePages, isolateCopy, pathAsBuilt, readPages, readSpaces)
import Wiki.Server.Storage (Place (..), migrateDatabase, withStorageAside)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (settingsLike, storeSetting)

unitSpec :: Spec
unitSpec = do
  pagesUnitSpec
  homesUnitSpec
  pathsUnitSpec

-- | A page's path as a program before step 13 of the schema builds it, and
-- as one after it does: from the top of the space, or from under its home
-- page.
pathsUnitSpec :: Spec
pathsUnitSpec = describe "the upgrade's rehearsal, a page's path as each program builds it" $ do
  let pages =
        [ PageAt {page = "h", parent = Nothing, slug = "home"}
        , PageAt {page = "a", parent = Just "h", slug = "about"}
        , PageAt {page = "d", parent = Just "a", slug = "deep"}
        , PageAt {page = "t", parent = Nothing, slug = "top"}
        ]
  it "has every slug from the top for a program before the step" $ do
    pathAsBuilt False (Just "h") pages "d" `shouldBe` Just ["home", "about", "deep"]
    pathAsBuilt False (Just "h") pages "h" `shouldBe` Just ["home"]
  it "leaves the home page's slug out for a program with the step, the home page's own path empty" $ do
    pathAsBuilt True (Just "h") pages "d" `shouldBe` Just ["about", "deep"]
    pathAsBuilt True (Just "h") pages "h" `shouldBe` Just []
    pathAsBuilt True (Just "h") pages "t" `shouldBe` Just ["top"]
  it "has every slug in a space with no home page, and nothing for a page not there or under itself" $ do
    pathAsBuilt True Nothing pages "d" `shouldBe` Just ["home", "about", "deep"]
    pathAsBuilt True (Just "h") pages "nowhere" `shouldBe` Nothing
    pathAsBuilt True Nothing (PageAt {page = "x", parent = Just "y", slug = "x"} : PageAt {page = "y", parent = Just "x", slug = "y"} : pages) "x" `shouldBe` Nothing

-- | Pages read from spaces s1 and s2, whose home pages are p1 and none.
readOf :: [PageRead] -> PagesRead
readOf pages = PagesRead {pages, homes = Map.fromList [("s1", Just "p1"), ("s2", Nothing)]}

pagesUnitSpec :: Spec
pagesUnitSpec = describe "the upgrade's rehearsal, the pages check" $ do
  let first' = PageRead {space = "s1", page = "p1", title = "First", body = "# First\n\nText."}
      second' = PageRead {space = "s1", page = "p2", title = "Second", body = "More."}
  it "passes when every page reads the same, in whatever order" $
    comparePages (readOf [first', second']) (readOf [second', first']) `shouldBe` Right ()
  it "names a page whose source changed, one whose title changed, one gone and one new" $ do
    let changed = first' {body = "# First\n\nOther text."}
        renamed = second' {title = "Second, renamed"}
        third = PageRead {space = "s2", page = "p3", title = "Third", body = ""}
        why = either identity (const "") (comparePages (readOf [first', second']) (readOf [changed, renamed, third]))
    why `shouldSatisfy` T.isInfixOf "page p1 (First) has another source"
    why `shouldSatisfy` T.isInfixOf "page p2 (Second) has another title: Second, renamed"
    why `shouldSatisfy` T.isInfixOf "page p3 (Third) is new"
    comparePages (readOf [first', second']) (readOf [first']) `shouldSatisfy` isLeft
  it "tells the same page id in two spaces apart" $
    comparePages (readOf [first']) (readOf [PageRead {space = "s2", page = first'.page, title = first'.title, body = first'.body}]) `shouldSatisfy` isLeft
  it "names five differences and counts the rest" $ do
    let pages = [PageRead {space = "s", page = show i, title = "t", body = "b"} | i <- [1 .. 8 :: Int]]
        why = either identity (const "") (comparePages (readOf pages) (readOf []))
    why `shouldSatisfy` T.isInfixOf "and 3 more"
  it "takes a new page only as the home page given to a space that had none" $ do
    let home = PageRead {space = "s2", page = "p9", title = "Home", body = "Welcome to **Two**.\n"}
        given = PagesRead {pages = [first', home], homes = Map.fromList [("s1", Just "p1"), ("s2", Just "p9")]}
    comparePages (readOf [first']) given `shouldBe` Right ()
    -- Not a page that is not the space's home page, nor a new home page
    -- of a space that had one.
    comparePages (readOf [first']) given {homes = Map.fromList [("s1", Just "p1"), ("s2", Just "p8")]} `shouldSatisfy` isLeft
    let elsewhere = PageRead {space = "s1", page = home.page, title = home.title, body = home.body}
    comparePages (readOf [first']) PagesRead {pages = [first', elsewhere], homes = Map.fromList [("s1", Just "p9"), ("s2", Nothing)]} `shouldSatisfy` isLeft

homesUnitSpec :: Spec
homesUnitSpec = describe "the upgrade's rehearsal, the home pages check" $ do
  let space i home = SpaceRead {space = i, name = "Space " <> i, homePage = home, withoutHome = False}
      container = (space "c" Nothing) {withoutHome = True}
  it "passes when every space has a home page, the one it had if it had one, but the two kinds" $
    compareHomes [space "a" (Just "p1"), space "b" Nothing, container] [space "a" (Just "p1"), space "b" (Just "p2"), container] `shouldBe` Right ()
  it "names a space with no home page, and one whose home page changed" $ do
    let why = either identity (const "") (compareHomes [space "a" (Just "p1"), space "b" Nothing] [space "a" (Just "p3"), space "b" Nothing])
    why `shouldSatisfy` T.isInfixOf "space b (Space b) has no home page"
    why `shouldSatisfy` T.isInfixOf "space a (Space a) has another home page"

-- | The copy is cut off from the outside before a server starts on it: no
-- scheduled backup to the running wiki's destination, no notification
-- mail through its mail server.
spec :: Backing -> Spec
spec backing = do
  copySpec backing
  checksSpec backing
  moveSpec backing

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
  it "leaves out an encrypted space, whose pages answer 409, and reads the rest" $ withDemoPlace backing $ \at serve -> do
    -- An encrypted space as the server knows one: its key's id set. Its
    -- pages are then not listed as plain text.
    withConnectionTo at $ \c -> do
      begin True c
      runScript c "UPDATE spaces SET key_id = 'k1' WHERE slug = 'team';"
      commitTransaction c
    manager <- newManager defaultManagerSettings
    serve $ \r -> do
      let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public}
      read' <- readPages manager server >>= either (\why -> panic ("not read: " <> why)) pure
      spaces <- readSpaces manager server >>= either (\why -> panic ("not read: " <> why)) pure
      let team = [s.space | s <- spaces, s.name == "Team"]
          blog = [s.space | s <- spaces, s.name == "Blog"]
      length team `shouldBe` 1
      [p | p <- read'.pages, p.space `elem` team] `shouldBe` []
      [p | p <- read'.pages, p.space `elem` blog] `shouldNotBe` []
      (\s -> s.withoutHome) <$> find (\s -> s.name == "Team") spaces `shouldBe` Just True
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
  it "fails the roots check, naming the space, when a space no longer answers at its address" $ withDemoPlace backing $ \at serve -> do
    let moveBlog = withConnectionTo at $ \c -> do
          begin True c
          runScript c "UPDATE spaces SET slug = 'elsewhere' WHERE slug = 'blog';"
          commitTransaction c
    verdict <- rehearseCheck "roots" at serve moveBlog
    verdict `shouldSatisfy` either (T.isInfixOf "does not answer at /blog") (const False)

-- | Each check across a move from SQLite to PostgreSQL, as the rehearsal
-- of a move runs it (@--move-to-database@): this program serves the demo's
-- wiki in SQLite for the before, the wiki is copied into an empty
-- PostgreSQL database as @wiki-server copy-database@ copies it, and this
-- program serves that database for the after. Every check must pass. On
-- SQLite there is no move to rehearse.
moveSpec :: Backing -> Spec
moveSpec = \case
  OnSqlite -> pass
  backing -> describe "the rehearsal of a move to PostgreSQL, its checks" $
    for_ [name | Check {name} <- checks] $ \name ->
      it ("passes the " <> toS name <> " check when the wiki moves from SQLite to PostgreSQL") $ withDemoMoved backing $ \inSqlite serveSqlite moved serveMoved -> do
        let copy =
              runCopy CopyOptions {place = placeOptionsOf inSqlite, target = choiceOf moved.database} >>= \case
                Copied _ -> pass
                other -> expectationFailure ("the wiki was not copied: " <> show other)
        rehearseAcross name inSqlite serveSqlite copy serveMoved `shouldReturn` Right ()

-- | Run the check of this name as the rehearsal does: what it holds around
-- the whole run, its seed on the place, its before on a server over the
-- place, the action given, and its after on a second server over the same
-- place. The result is the after's verdict; a seed or a before that fails
-- fails the test.
rehearseCheck :: Text -> Place -> (forall a. (Running -> IO a) -> IO a) -> IO () -> IO (Either Text ())
rehearseCheck wanted at serve between = rehearseAcross wanted at serve between serve

-- | 'rehearseCheck' with the after on a server of its own, which serves
-- what the action between made: the moved wiki, for a move.
rehearseAcross :: Text -> Place -> (forall a. (Running -> IO a) -> IO a) -> IO () -> (forall a. (Running -> IO a) -> IO a) -> IO (Either Text ())
rehearseAcross wanted at serve between serveAfter = do
  manager <- newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 120_000_000}
  let serverOf r = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public}
      orFail :: Text -> Either Text x -> IO x
      orFail what = either (\why -> panic (what <> " of the " <> wanted <> " check failed: " <> why)) pure
  case [c | c@Check {name} <- checks, name == wanted] of
    [Check {holding, seed, before = beforeIt, after = afterIt}] -> holding $ \held -> do
      seeded <- seed held Seeding {copy = at, console = consoleOn at} >>= orFail "the seed"
      fixture <- serve (\r -> beforeIt held seeded manager (serverOf r)) >>= orFail "the before"
      between
      serveAfter (\r -> afterIt held fixture manager (serverOf r))
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
