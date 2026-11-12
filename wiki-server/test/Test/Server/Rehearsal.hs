-- | The upgrade's rehearsal (WP5.75 of docs/PLAN.md, "Wiki.Server.Rehearsal"):
-- the pages check's comparison of the pages read before the migration
-- with those read after, the copy cut off from the outside, and each check
-- run with this program as both the old and the new one, on one database
-- and across a move from SQLite to PostgreSQL (WP5.80b). The rehearsal
-- itself runs two programs, and is tested end to end by
-- toolchain/rehearse-ci.sh in CI.
module Test.Server.Rehearsal (unitSpec, spec) where

import Data.Aeson (encode)
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Database.Beam (runUpdate, update, val_, (<-.), (==.))
import Network.HTTP.Client (defaultManagerSettings, httpLbs, managerResponseTimeout, newManager, parseRequest, responseStatus, responseTimeoutMicro)
import Network.HTTP.Types (hContentType, statusCode)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing (..), choiceOf, forgetStep, placeOptionsOf, withConnectionTo, withEmptyPlace)
import Test.Hspec
import Test.Server.Fixture (Reply (status), Running (..), cookie, givePassword, send, signInAs, withDemoMoved, withDemoPlace, withDemoRunning)
import Test.Server.Program (cLocale, placeArgsOf, wikiServerProgram)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Types (PersonalSpaceSwitch (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Server.Accounts (listAccounts)
import Wiki.Server.Console (listing, runUsers, usersParser)
import Wiki.Server.CopyDatabase (CopyOptions (..), CopyOutcome (..), runCopy)
import Wiki.Server.Options (DatabaseChoice (..))
import Wiki.Server.Password (hashWith, parameters)
import Wiki.Server.Rehearsal (Check (..), PageAt (..), PageRead (..), PagesRead (..), RehearsalOutcome (..), Seeding (..), Server (..), SpaceRead (..), checks, compareHomes, comparePages, compareWaysIn, consoleEnvironment, copyHasStep, isolateCopy, listenAnywhere, listenedAt, pathAsBuilt, readPages, readSpaces, readUsersList, runConsoleIn, withServer)
import Wiki.Server.Storage (Place (..), migrateDatabase, withStorageAside)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (settingsLike, storeSetting)
import Wiki.Server.Storage.Schema (Users (..), WikiDb (..), wikiDb)

unitSpec :: Spec
unitSpec = do
  pagesUnitSpec
  homesUnitSpec
  pathsUnitSpec
  waysInUnitSpec

-- | @wiki-server users list@'s table as the ways in check reads it, and its
-- comparison of the table before the upgrade with the table after. The
-- tables are the console's own ('listing'), printed a line at a time.
waysInUnitSpec :: Spec
waysInUnitSpec = describe "the upgrade's rehearsal, the ways in check" $ do
  it "reads SIGNS IN by login, by the heading's columns, whatever the names hold" $
    readUsersList (printed [("admin", "The Administrator", True, yes), ("ann", "Ann Lee  yes", False, disabledOne), ("bo", "Bo", False, noPassword), ("carl.the.second", "Carl", False, yes)])
      `shouldBe` Right (Map.fromList [("admin", "yes"), ("ann", "no (disabled)"), ("bo", "no (no password)"), ("carl.the.second", "yes")])
  it "reads the row of a name that holds a line break after \"  yes\" with the SIGNS IN of its own last line, and fails when that account loses its password" $ do
    let was = readUsersList (printed [("uno", "One  yes\nTwo", False, yes), ("zed", "Zed", False, yes)])
        now = readUsersList (printed [("uno", "One  yes\nTwo", False, noPassword), ("zed", "Zed", False, yes)])
    was `shouldBe` Right (Map.fromList [("uno", "yes"), ("zed", "yes")])
    now `shouldBe` Right (Map.fromList [("uno", "no (no password)"), ("zed", "yes")])
    (compareWaysIn <$> was <*> now) `shouldBe` Right (Left "the login uno signed in with a password before the upgrade, and after it users list says no (no password)")
    -- The same with "  yes" and "  no (disabled)" the other way round.
    readUsersList (printed [("uno", "One  no (disabled)\nTwo", False, yes)]) `shouldBe` Right (Map.fromList [("uno", "yes")])
  it "reads a name with two line breaks, and one whose next line looks like a row, without dropping, making or joining a row" $ do
    let users =
          [ ("ada", "A\nB\nC", False, yes)
          , ("bea", "Bea\nzed  Zed  no  yes", False, noPassword)
          , ("cat", "\nadmin  The Administrator  yes  yes\n", True, disabledOne)
          , ("dot", "Dot  ", False, noPassword)
          , ("zed", "Zed", False, yes)
          ]
    readUsersList (printed users)
      `shouldBe` Right (Map.fromList [("ada", "yes"), ("bea", "no (no password)"), ("cat", "no (disabled)"), ("dot", "no (no password)"), ("zed", "yes")])
  it "reads a wiki with no users as no logins" $
    readUsersList (T.unlines ["There are no users yet: make the first administrator with", "  wiki-server users add --data /x LOGIN --admin"]) `shouldBe` Right Map.empty
  it "counts a name's width in characters, not in the bytes of UTF-8" $
    readUsersList (printed [("zofia", "Zażółć Gęślą", False, yes), ("ala", "Ala", True, noPassword)])
      `shouldBe` Right (Map.fromList [("zofia", "yes"), ("ala", "no (no password)")])
  it "gives a program it runs a UTF-8 locale when the environment names none, and keeps one that does" $ do
    consoleEnvironment [("LANG", "C"), ("PATH", "/bin")] `shouldBe` [("LC_ALL", "C.UTF-8"), ("LANG", "C"), ("PATH", "/bin")]
    consoleEnvironment [("LC_ALL", "POSIX"), ("LANG", "pl_PL.UTF-8")] `shouldBe` [("LC_ALL", "C.UTF-8"), ("LANG", "pl_PL.UTF-8")]
    consoleEnvironment [] `shouldBe` [("LC_ALL", "C.UTF-8")]
    consoleEnvironment [("LANG", "pl_PL.UTF-8")] `shouldBe` [("LANG", "pl_PL.UTF-8")]
    consoleEnvironment [("LC_ALL", ""), ("LC_CTYPE", "en_US.utf8")] `shouldBe` [("LC_ALL", ""), ("LC_CTYPE", "en_US.utf8")]
  it "reads what a program writes as UTF-8 whatever the locale, and says why one that could not write it failed" $ do
    environment <- cLocale
    runConsoleIn environment "sh" [] ["-c", "printf '%s\\n' \"$LC_ALL\"; printf 'Za\\305\\274\\303\\263\\305\\202\\304\\207\\n'"] ""
      `shouldReturn` Right "C.UTF-8\nZażółć\n"
    runConsoleIn environment "sh" [] ["-c", "echo '<stdout>: commitAndReleaseBuffer: invalid argument (cannot encode character)' >&2; exit 1"] ""
      >>= (`shouldSatisfy` either (\why -> "no UTF-8 locale" `T.isInfixOf` why && "--no-rehearsal" `T.isInfixOf` why) (const False))
  it "refuses output that is not the table, rather than guess: another heading, nothing, a row off its columns, an unknown value, a login twice" $ do
    let heading = "LOGIN  NAME  ADMINISTRATOR  SIGNS IN"
    readUsersList "LOGIN  NAME  ROLE\nadmin  Admin  owner\n" `shouldSatisfy` isLeft
    readUsersList "" `shouldSatisfy` isLeft
    readUsersList "Usage: wiki-server users COMMAND\n" `shouldSatisfy` isLeft
    readUsersList (T.unlines [heading, "dee   Dee   no             yes"]) `shouldSatisfy` isLeft
    readUsersList (T.unlines [heading, "dee    Dee   no             maybe"]) `shouldSatisfy` isLeft
    readUsersList (T.unlines [heading, "dee    Dee   maybe          yes"]) `shouldSatisfy` isLeft
    readUsersList (T.unlines [heading, "dee    Dee   no             yes", "dee    Dee   no             yes"]) `shouldSatisfy` isLeft
    readUsersList (T.unlines [heading, "dee    Dee   no"]) `shouldSatisfy` isLeft
    -- The console's own table, with its padding removed from a row.
    readUsersList (T.replace "Zed  " "Zed" (printed [("ann", "Ann Lee", False, yes), ("zed", "Zed", False, yes)])) `shouldSatisfy` isLeft
  it "passes a login step 15 of the schema renamed: gone under the old login, new under the new one" $
    compareWaysIn (Map.fromList [("łucja", "yes"), ("ada", "yes")]) (Map.fromList [("user-1a2b3c4d", "yes"), ("ada", "yes")]) `shouldBe` Right ()
  it "fails for each login that signed in before and does not after, naming it, and for nothing else" $ do
    let was = Map.fromList [("admin", "yes"), ("ann", "yes"), ("bo", "no (no password)"), ("gone", "yes"), ("off", "no (disabled)")]
        now = Map.fromList [("admin", "yes"), ("ann", "no (no password)"), ("bo", "yes"), ("new", "no (no password)"), ("off", "yes")]
    compareWaysIn was now `shouldBe` Left "the login ann signed in with a password before the upgrade, and after it users list says no (no password)"
    compareWaysIn was was `shouldBe` Right ()
    compareWaysIn (Map.fromList [("ann", "yes")]) (Map.fromList [("ann", "no (disabled)")]) `shouldSatisfy` either (T.isInfixOf "ann") (const False)
  where
    yes = (False, True)
    disabledOne = (True, True)
    noPassword = (False, False)

-- | What @wiki-server users list@ prints for these users (login, display
-- name, administrator, and whether disabled and with a password): each
-- line of the console's 'listing', followed by a line break.
printed :: [(Text, Text, Bool, (Bool, Bool))] -> Text
printed users =
  T.concat
    [ line <> "\n"
    | line <-
        listing
          [ (Account {user = User {id = UserId ("u-" <> login), login = Login login, displayName = name, avatar = Nothing}, hasPassword, disabled}, admin)
          | (login, name, admin, (disabled, hasPassword)) <- users
          ]
    ]

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
  serversSpec backing
  copySpec backing
  checksSpec backing
  moveSpec backing

-- | The servers the rehearsal starts: each listener on a port the system
-- gives (port 0), its address read from the line the server logs for it.
serversSpec :: Backing -> Spec
serversSpec backing = describe "the upgrade's rehearsal, its servers" $ do
  it "reads each listener's address from the line the server logs for it" $ withDemoRunning backing identity $ \r -> do
    logged <- T.unlines . reverse <$> readIORef r.logged
    listenedAt "public" logged `shouldBe` Just r.public
    listenedAt "admin" logged `shouldBe` Just (r.admin <> "/admin")
    listenedAt "public" "level=info event=starting" `shouldBe` Nothing
  it "starts a program's server on ports the system gives, and reaches it at the addresses it logs" $ withDemoPlace backing $ \at _ ->
    withSystemTempDirectory "wiki-rehearsal-server" $ \dir -> do
      program <- wikiServerProgram
      manager <- newManager defaultManagerSettings
      let place = placeArgsOf at
          statusOf url = statusCode . responseStatus <$> (parseRequest (toS url) >>= (`httpLbs` manager))
      reached <- runExceptT $ withServer (dir <> "/server.log") program place (["serve"] <> place <> listenAnywhere <> ["--no-guide"]) (throwError . OldNotDriven) $ \server ->
        liftIO ((,,) server.public <$> statusOf (server.adminApi <> "/info") <*> statusOf (server.public <> "/healthz"))
      case reached of
        Right (public, answered, health) -> do
          public `shouldSatisfy` T.isPrefixOf "http://127.0.0.1:"
          public `shouldNotBe` "http://127.0.0.1:0"
          (answered, health) `shouldBe` (200, 200)
        Left _ -> expectationFailure "the server did not answer"

copySpec :: Backing -> Spec
copySpec backing = describe "the upgrade's rehearsal, its copy of the wiki" $ do
  it "reads every page an administrator may read, and leaves out the spaces nobody may" $ withDemoRunning backing identity $ \r -> do
    manager <- newManager defaultManagerSettings
    let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public, console = consoleOn r.place}
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
    -- An encrypted space as the server knew one before encrypted spaces had
    -- home pages: its key's id set, and no home page. Its pages are then
    -- not listed as plain text, and it is one of the spaces that may have
    -- no home page.
    withConnectionTo at $ \c -> do
      begin True c
      runScript c "UPDATE spaces SET key_id = 'k1', home_page = NULL WHERE slug = 'team';"
      commitTransaction c
    manager <- newManager defaultManagerSettings
    serve $ \r -> do
      let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public, console = consoleOn r.place}
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
  it "passes the ways in check when an account's hash from before OPAQUE becomes a record between the two halves" $ withDemoPlace backing $ \at serve -> do
    withConnectionTo at $ \c -> runDb c (setColumns "editor" Nothing Nothing (Just (hashWith parameters "salt of the test" (Password "editor's old password"))))
    rehearseCheck "ways in" at serve (consoleOn at ["users", "password", "editor"] "editor's new password\n" >>= (`shouldSatisfy` isRight)) `shouldReturn` Right ()
  it "fails the ways in check, naming the login, when a step between the two halves takes an account's password away" $ withDemoPlace backing $ \at serve -> do
    consoleOn at ["users", "password", "editor"] "editor's password\n" >>= (`shouldSatisfy` isRight)
    verdict <- rehearseCheck "ways in" at serve (withConnectionTo at $ \c -> runDb c (setColumns "editor" Nothing Nothing Nothing))
    verdict `shouldBe` Left "the login editor signed in with a password before the upgrade, and after it users list says no (no password)"
  it "fails the ways in check, naming the login, for an account whose display name holds a line break after \"  yes\"" $ withDemoPlace backing $ \at serve -> do
    consoleOn at ["users", "password", "editor"] "editor's password\n" >>= (`shouldSatisfy` isRight)
    withConnectionTo at $ \c -> runDb c (runUpdate (update wikiDb.users (\u -> u.display_name <-. val_ "One  yes\nTwo") (\u -> u.login ==. val_ "editor")))
    verdict <- rehearseCheck "ways in" at serve (withConnectionTo at $ \c -> runDb c (setColumns "editor" Nothing Nothing Nothing))
    verdict `shouldBe` Left "the login editor signed in with a password before the upgrade, and after it users list says no (no password)"
  it "passes the ways in check, and fails it naming the login, for a login and a name beyond ASCII, with the program's consoles as children in the C locale" $ do
    program <- wikiServerProgram
    environment <- cLocale
    let console at = runConsoleIn environment program (placeArgsOf at)
        prepare at = do
          withConnectionTo at $ \c -> runDb c (runUpdate (update wikiDb.users (\u -> (u.login <-. val_ "łucja") <> (u.display_name <-. val_ "Zażółć Gęślą")) (\u -> u.login ==. val_ "editor")))
          consoleOn at ["users", "password", "łucja"] "łucja's password\n" >>= (`shouldSatisfy` isRight)
    withDemoPlace backing $ \at serve -> do
      prepare at
      rehearseWith console "ways in" at serve pass serve `shouldReturn` Right ()
    withDemoPlace backing $ \at serve -> do
      prepare at
      verdict <- rehearseWith console "ways in" at serve (withConnectionTo at $ \c -> runDb c (setColumns "łucja" Nothing Nothing Nothing)) serve
      verdict `shouldBe` Left "the login łucja signed in with a password before the upgrade, and after it users list says no (no password)"
  it "cannot drive an old program whose users list is not the table, which the rehearsal ends with 7" $ withDemoRunning backing identity $ \r -> do
    manager <- newManager defaultManagerSettings
    let server = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public, console = \_ _ -> pure (Right "LOGIN  NAME\nadmin  Admin\n")}
    case [c | c@Check {name = "ways in"} <- checks] of
      [Check {holding, seed, before = beforeIt}] -> holding $ \held -> do
        seeded <- seed held Seeding {copy = r.place, console = consoleOn r.place, stepRan = copyHasStep r.place} >>= either (panic . ("the seed failed: " <>)) pure
        -- A 'Left' of a check's before is an old program the rehearsal
        -- cannot drive ('OldNotDriven'), not a failed check.
        beforeIt held seeded manager server >>= either (`shouldSatisfy` T.isInfixOf "did not print its table") (const (expectationFailure "the before read the output as the table"))
      _ -> expectationFailure "there is no check named ways in"
  it "passes the logins check when the upgrade renames the login it wrote, which signs in under the new one" $ withDemoPlace backing $ \at serve -> do
    -- This program plays an old one without step 15 of the schema: the
    -- rehearsal is told the copy has not had the step ('stepRan'), so
    -- the seed writes a login that breaks the rule, and between the before
    -- and the after the step runs on the copy again, as the new program's
    -- migration would run it.
    let stepAgain = withConnectionTo at $ \c -> do
          begin True c
          forgetStep 15 [] c
          commitTransaction c
    rehearseOver (\_ -> pure False) consoleOn "logins" at serve stepAgain serve `shouldReturn` Right ()
    -- The check had something to rehearse: its account was renamed.
    accounts <- withStorageAside at listAccounts
    [a.user.login.text | (a, _) <- accounts, a.user.displayName == "Rehearsal login"] `shouldSatisfy` \case
      [login] -> "user-" `T.isPrefixOf` login
      _ -> False
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
rehearseAcross = rehearseWith consoleOn

-- | 'rehearseAcross' with this console on a place, in place of the test's
-- own ('consoleOn'): a program run as a child, as the rehearsal runs one.
rehearseWith :: (Place -> [Text] -> Text -> IO (Either Text Text)) -> Text -> Place -> (forall a. (Running -> IO a) -> IO a) -> IO () -> (forall a. (Running -> IO a) -> IO a) -> IO (Either Text ())
rehearseWith consoleAt wanted at = rehearseOver (copyHasStep at) consoleAt wanted at

-- | 'rehearseWith', with what the rehearsal is told of the steps the old
-- program applied to the copy ('Seeding''s @stepRan@).
rehearseOver :: (Int -> IO Bool) -> (Place -> [Text] -> Text -> IO (Either Text Text)) -> Text -> Place -> (forall a. (Running -> IO a) -> IO a) -> IO () -> (forall a. (Running -> IO a) -> IO a) -> IO (Either Text ())
rehearseOver stepRan consoleAt wanted at serve between serveAfter = do
  manager <- newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 120_000_000}
  -- Each server's console runs on the database it serves: for a move, the
  -- after's is the moved database.
  let serverOf r = Server {adminApi = r.admin <> "/admin/api/v1", public = r.public, console = consoleAt r.place}
      orFail :: Text -> Either Text x -> IO x
      orFail what = either (\why -> panic (what <> " of the " <> wanted <> " check failed: " <> why)) pure
  case [c | c@Check {name} <- checks, name == wanted] of
    [Check {holding, seed, before = beforeIt, after = afterIt}] -> holding $ \held -> do
      seeded <- seed held Seeding {copy = at, console = consoleAt at, stepRan} >>= orFail "the seed"
      fixture <- serve (\r -> beforeIt held seeded manager (serverOf r)) >>= orFail "the before"
      between
      serveAfter (\r -> afterIt held fixture manager (serverOf r))
    _ -> panic ("no check is named " <> wanted)

-- | Set the password columns of the user with this login, as a step of a
-- migration might.
setColumns :: (Backend be) => Text -> Maybe Text -> Maybe Text -> Maybe Text -> Db be ()
setColumns login record stretch phc =
  runUpdate (update wikiDb.users (\u -> mconcat [u.opaque_record <-. val_ record, u.opaque_stretch <-. val_ stretch, u.password_hash <-. val_ phc]) (\u -> u.login ==. val_ login))

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
