-- | Accounts and sessions as the storage keeps them, passwords as they are
-- hashed, failed sign-ins as they are counted, and the console that makes
-- users: everything about signing in short of HTTP ("Test.Server.Accounts"
-- has that).
module Test.Storage.Accounts (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Wiki.Api.Account (Account (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.User (Login (..), Standing (..), User (..))
import Wiki.Server.Accounts
import Wiki.Server.Console (Users (..), UsersCommand (..), runUsers)
import Wiki.Server.Limiter (Limits (..), Verdict (..), failed, newLimiter, succeeded, verdict)
import Wiki.Server.Password
import Wiki.Server.Storage (Storage, Who (..), defaultConfig, runSqliteWiki, withStorage)

spec :: Spec
spec = describe "accounts" $ do
  passwords
  limits
  accounts
  sessions
  console

-- | A storage in a directory of its own, empty.
withEmpty :: (Storage -> IO a) -> IO a
withEmpty action = withSystemTempDirectory "wiki-accounts-test" $ \dir -> withStorage defaultConfig (dir </> "data") action

-- | Something that should have worked.
ok :: (HasCallStack, Show e) => IO (Either e a) -> IO a
ok act = act >>= either (\e -> panic ("expected it to work: " <> show e)) pure

passwords :: Spec
passwords = describe "passwords" $ do
  it "match the hash made from them, and no other password" $ do
    phc <- hashPassword "correct horse battery staple"
    verifyPassword phc "correct horse battery staple" `shouldBe` True
    verifyPassword phc "correct horse battery stapler" `shouldBe` False
    verifyPassword phc "" `shouldBe` False

  it "are hashed as argon2id with the parameters chosen, a salt of their own each time" $ do
    a <- hashPassword "same"
    b <- hashPassword "same"
    a `shouldNotBe` b
    a `shouldSatisfy` T.isPrefixOf "$argon2id$v=19$m=19456,t=2,p=1$"

  it "are the hashes another implementation makes (Node's, OpenSSL's), with their parameters" $ do
    -- crypto.argon2Sync('argon2id', {message, nonce, memory, passes,
    -- parallelism, tagLength: 32}) in Node 24.
    hashWith parameters "wiki-test-salt-1" "correct horse battery staple"
      `shouldBe` "$argon2id$v=19$m=19456,t=2,p=1$d2lraS10ZXN0LXNhbHQtMQ$euKVLgBJjO4DyH+Cv85FSuFxwP2L5mqOfM7AK3iPHOA"
    verifyPassword "$argon2id$v=19$m=65536,t=2,p=4$c29tZXNhbHQ$GpZ3sK/oH9p7VIiV56G/64Zo/8GaUw434IimaPqxwCo" "password" `shouldBe` True
    verifyPassword "$argon2id$v=19$m=65536,t=2,p=4$c29tZXNhbHQ$GpZ3sK/oH9p7VIiV56G/64Zo/8GaUw434IimaPqxwCo" "Password" `shouldBe` False

  it "match nothing against a hash this server would not have written" $ do
    for_
      [ ""
      , "plain text"
      , "$argon2i$v=19$m=19456,t=2,p=1$d2lraS10ZXN0LXNhbHQtMQ$euKVLgBJjO4DyH+Cv85FSuFxwP2L5mqOfM7AK3iPHOA"
      , "$argon2id$v=19$m=99999999,t=2,p=1$d2lraS10ZXN0LXNhbHQtMQ$euKVLgBJjO4DyH+Cv85FSuFxwP2L5mqOfM7AK3iPHOA"
      , "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$euKVLgBJjO4DyH+Cv85FSuFxwP2L5mqOfM7AK3iPHOA"
      ]
      $ \phc -> verifyPassword phc "correct horse battery staple" `shouldBe` False

  it "are refused when too short or too long" $ do
    checkPassword "seven 7" `shouldSatisfy` isLeft
    checkPassword "eight 88" `shouldBe` Right "eight 88"
    checkPassword (T.replicate 1025 "x") `shouldSatisfy` isLeft

  it "make session ids that are random, and kept by a hash of them" $ do
    a <- newToken
    b <- newToken
    a `shouldNotBe` b
    T.length a `shouldBe` 43
    tokenHash a `shouldNotBe` a
    T.length (tokenHash a) `shouldBe` 64

limits :: Spec
limits = describe "failed sign-ins" $ do
  let small = Limits {perLogin = 3, perAddress = 5, window = 60}
  it "are allowed up to the limit for a login from an address, then refused until the oldest is old enough" $ do
    l <- newLimiter small
    now <- getCurrentTime
    for_ [0 .. 2 :: Int] $ \i -> do
      verdict l (addUTCTime (fromIntegral i) now) "ada" "10.0.0.1" `shouldReturn` Allowed
      failed l (addUTCTime (fromIntegral i) now) "ada" "10.0.0.1"
    verdict l (addUTCTime 3 now) "ada" "10.0.0.1" `shouldReturn` Refused 57
    -- The login without regard to case, as it is typed.
    verdict l (addUTCTime 3 now) " ADA " "10.0.0.1" `shouldReturn` Refused 57
    -- Another address, or another login, is not refused for these.
    verdict l (addUTCTime 3 now) "ada" "10.0.0.2" `shouldReturn` Allowed
    verdict l (addUTCTime 3 now) "bea" "10.0.0.1" `shouldReturn` Allowed
    verdict l (addUTCTime 61 now) "ada" "10.0.0.1" `shouldReturn` Allowed

  it "are limited for an address whatever the logins tried" $ do
    l <- newLimiter small
    now <- getCurrentTime
    for_ ["a", "b", "c", "d", "e"] $ \login -> failed l now login "10.0.0.1"
    verdict l now "f" "10.0.0.1" >>= (`shouldSatisfy` (/= Allowed))
    verdict l now "f" "10.0.0.2" `shouldReturn` Allowed

  it "are forgotten for the login once it has signed in from there" $ do
    l <- newLimiter small
    now <- getCurrentTime
    replicateM_ 3 (failed l now "ada" "10.0.0.1")
    succeeded l "ada" "10.0.0.1"
    verdict l now "ada" "10.0.0.1" `shouldReturn` Allowed

accounts :: Spec
accounts = describe "the storage's accounts" $ do
  it "are made with a password, and sign in with it" $ withEmpty $ \st -> do
    made <- ok (createAccount st "ada" "Ada" (Just "correct horse"))
    (made.user.login.text, made.user.displayName, made.hasPassword, made.disabled) `shouldBe` ("ada", "Ada", True, False)
    now <- getCurrentTime
    Right (user, token) <- signIn st now "127.0.0.1" "ada" "correct horse"
    user `shouldBe` made.user
    T.length token `shouldBe` 43
    -- As people type a login: without regard to case or blanks around it.
    signIn st now "127.0.0.1" " ADA " "correct horse" >>= (`shouldSatisfy` isRight)

  it "refuse a wrong password, an unknown login, a login without a password and a disabled one alike" $ withEmpty $ \st -> do
    ada <- ok (createAccount st "ada" "" (Just "correct horse"))
    _ <- ok (createAccount st "bea" "" Nothing)
    now <- getCurrentTime
    signIn st now "127.0.0.1" "ada" "wrong horse" `shouldReturn` Left NoSuchAccount
    signIn st now "127.0.0.1" "nobody" "correct horse" `shouldReturn` Left NoSuchAccount
    signIn st now "127.0.0.1" "bea" "" `shouldReturn` Left NoSuchAccount
    _ <- ok (setDisabled st ada.user.id True)
    signIn st now "127.0.0.1" "ada" "correct horse" `shouldReturn` Left NoSuchAccount
    _ <- ok (setDisabled st ada.user.id False)
    signIn st now "127.0.0.1" "ada" "correct horse" >>= (`shouldSatisfy` isRight)

  it "refuse a login taken in another case, a blank or spaced one, and a short password" $ withEmpty $ \st -> do
    _ <- ok (createAccount st "ada" "" (Just "correct horse"))
    createAccount st "ADA" "" (Just "correct horse") >>= (`shouldSatisfy` \case Left (Conflict _) -> True; _ -> False)
    for_ ["", "   ", "two words", "~operator", T.replicate 65 "x"] $ \login ->
      createAccount st login "" (Just "correct horse") >>= (`shouldSatisfy` \case Left (Invalid _) -> True; _ -> False)
    createAccount st "bea" "" (Just "short") >>= (`shouldSatisfy` \case Left (Invalid _) -> True; _ -> False)

  it "are named by their login when no name is given, and trimmed" $ withEmpty $ \st -> do
    a <- ok (createAccount st "  ada  " "   " (Just "correct horse"))
    (a.user.login.text, a.user.displayName) `shouldBe` ("ada", "ada")

  it "are made administrators and unmade, and listed with it" $ withEmpty $ \st -> do
    ada <- ok (createAccount st "ada" "Ada" (Just "correct horse"))
    bea <- ok (createAccount st "bea" "Bea" Nothing)
    _ <- ok (setAdministrator st ada.user.id True)
    _ <- ok (setAdministrator st ada.user.id True)
    map (\(a, admin) -> (a.user.login.text, admin)) <$> listAccounts st `shouldReturn` [("ada", True), ("bea", False)]
    s <- runSqliteWiki st (AsUser ada.user.id) session
    (s.user, s.standing) `shouldBe` (Just ada.user, SignedIn)
    _ <- ok (setAdministrator st ada.user.id False)
    map snd <$> listAccounts st `shouldReturn` [False, False]
    setAdministrator st (UserId "nobody") True `shouldReturn` Left NotFound
    accountOf st bea.user.id `shouldReturn` Just bea

  it "take a disabled user for nobody, wherever they are named" $ withEmpty $ \st -> do
    ada <- ok (createAccount st "ada" "Ada" (Just "correct horse"))
    _ <- ok (setDisabled st ada.user.id True)
    s <- runSqliteWiki st (AsUser ada.user.id) session
    (s.user, s.standing) `shouldBe` (Nothing, NotSignedIn)

sessions :: Spec
sessions = describe "sessions" $ do
  let signedIn st = do
        ada <- ok (createAccount st "ada" "Ada" (Just "correct horse"))
        now <- getCurrentTime
        Right (_, token) <- signIn st now "127.0.0.1" "ada" "correct horse"
        pure (ada, now, token)

  it "are found by the id their cookie carries, and by nothing else" $ withEmpty $ \st -> do
    (ada, now, token) <- signedIn st
    resolveSession st now "127.0.0.1" token `shouldReturn` Just Resolved {user = ada.user.id, refreshed = False}
    resolveSession st now "127.0.0.1" (tokenHash token) `shouldReturn` Nothing
    other <- newToken
    resolveSession st now "127.0.0.1" other `shouldReturn` Nothing

  it "end when signed out" $ withEmpty $ \st -> do
    (_, now, token) <- signedIn st
    endSession st token
    resolveSession st now "127.0.0.1" token `shouldReturn` Nothing

  it "end when their user is disabled or given a new password" $ withEmpty $ \st -> do
    (ada, now, token) <- signedIn st
    _ <- ok (setDisabled st ada.user.id True)
    _ <- ok (setDisabled st ada.user.id False)
    resolveSession st now "127.0.0.1" token `shouldReturn` Nothing
    signedInAgain <- getCurrentTime
    Right (_, again) <- signIn st signedInAgain "127.0.0.1" "ada" "correct horse"
    _ <- ok (setPassword st ada.user.id "battery staple")
    resolveSession st now "127.0.0.1" again `shouldReturn` Nothing
    signIn st now "127.0.0.1" "ada" "correct horse" `shouldReturn` Left NoSuchAccount
    signIn st now "127.0.0.1" "ada" "battery staple" >>= (`shouldSatisfy` isRight)

  it "end after being idle for the idle time, and each use moves their end on (at most hourly)" $ withEmpty $ \st -> do
    (ada, now, token) <- signedIn st
    let later = addUTCTime (refreshEvery + 1) now
    resolveSession st later "127.0.0.1" token `shouldReturn` Just Resolved {user = ada.user.id, refreshed = True}
    resolveSession st (addUTCTime 1 later) "127.0.0.1" token `shouldReturn` Just Resolved {user = ada.user.id, refreshed = False}
    -- Idle from the last recorded use, not from signing in.
    resolveSession st (addUTCTime (idleTime - 1) later) "127.0.0.1" token >>= (`shouldSatisfy` isJust)
    let idle = addUTCTime (2 * idleTime + 10) later
    resolveSession st idle "127.0.0.1" token `shouldReturn` Nothing
    -- And it is gone, not merely refused.
    resolveSession st now "127.0.0.1" token `shouldReturn` Nothing

console :: Spec
console = describe "wiki-server users" $ do
  let run dir password command = do
        asked <- newIORef []
        result <- runUsers (\login -> modifyIORef' asked (login :) $> password) Users {dataDir = dir, command}
        (result,) <$> readIORef asked
  it "makes the first administrator, who then signs in, with the password it asked for" $
    withSystemTempDirectory "wiki-console-test" $ \dir -> do
      (listed, _) <- run dir (Left "not asked") ListUsers
      listed `shouldSatisfy` either (const False) (any (T.isInfixOf "There are no users yet"))
      (made, asked) <- run dir (Right "correct horse") (AddUser "ada" (Just "Ada") True True)
      asked `shouldBe` ["ada"]
      made `shouldSatisfy` isRight
      (table, _) <- run dir (Left "not asked") ListUsers
      table `shouldBe` Right ["LOGIN  NAME  ADMINISTRATOR  SIGNS IN", "ada    Ada   yes            yes"]
      withStorage defaultConfig dir $ \st -> do
        now <- getCurrentTime
        Right (user, _) <- signIn st now "127.0.0.1" "ada" "correct horse"
        s <- runSqliteWiki st (AsUser user.id) session
        [g.permission | g <- s.grants.global] `shouldBe` [Administer]

  it "sets a password, disables and enables a login, and makes and unmakes an administrator" $
    withSystemTempDirectory "wiki-console-test" $ \dir -> do
      _ <- run dir (Right "correct horse") (AddUser "bea" Nothing False True)
      (changed, asked) <- run dir (Right "battery staple") (SetUserPassword "BEA")
      (changed, asked) `shouldSatisfy` \(r, a) -> isRight r && a == ["BEA"]
      _ <- run dir (Left "not asked") (SetUserDisabled "bea" True)
      _ <- run dir (Left "not asked") (SetUserAdministrator "bea" True)
      (table, _) <- run dir (Left "not asked") ListUsers
      table `shouldBe` Right ["LOGIN  NAME  ADMINISTRATOR  SIGNS IN", "bea    bea   yes            no (disabled)"]
      _ <- run dir (Left "not asked") (SetUserDisabled "bea" False)
      withStorage defaultConfig dir $ \st -> do
        now <- getCurrentTime
        signIn st now "127.0.0.1" "bea" "battery staple" >>= (`shouldSatisfy` isRight)

  it "says what is wrong, and changes nothing: an unknown login, a password not given, one too short" $
    withSystemTempDirectory "wiki-console-test" $ \dir -> do
      (unknown, _) <- run dir (Right "correct horse") (SetUserPassword "nobody")
      unknown `shouldBe` Left "There is no user with the login nobody."
      (noPassword, _) <- run dir (Left "No password on standard input.") (AddUser "ada" Nothing False True)
      noPassword `shouldBe` Left "No password on standard input."
      (short, _) <- run dir (Right "short") (AddUser "ada" Nothing False True)
      short `shouldSatisfy` isLeft
      (table, _) <- run dir (Left "not asked") ListUsers
      table `shouldSatisfy` either (const False) (any (T.isInfixOf "There are no users yet"))
