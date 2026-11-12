-- | How the accounts sign in, as @wiki-server check@ reads it (WP5.85 of
-- docs/PLAN.md, "Wiki.Server.WaysIn"): the rule that refuses a stored
-- password no sign-in can use, and the summary a check that passes gives,
-- first as pure functions, then through @wiki-server check@ on a database
-- of each backing.
module Test.Server.WaysIn (unitSpec, spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Database.Beam (insert, insertValues, runInsert, runUpdate, update, val_, (<-.), (==.))
import Protolude
import Test.Database (Backing (..), placeOptionsOf, withConnectionTo)
import Test.Hspec
import Test.Server.Program (cLocale, placeArgsOf, runBytes, wikiServerProgram)
import Test.Storage.Fixture (decodableRecord, withPlaceIn)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), Password (..))
import Wiki.Server.Console (CheckOutcome (..), runCheck)
import Wiki.Server.Password (hashWith, parameters)
import Wiki.Server.Storage (migrateDatabase)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (PasswordColumns (..))
import Wiki.Server.Storage.Schema
import Wiki.Server.Storage.SqliteLibrary (sqliteLine)
import Wiki.Server.WaysIn

unitSpec :: Spec
unitSpec = do
  ruleSpec
  summarySpec

-- | A hash 'Wiki.Server.Password.verifyPassword' reads.
goodHash :: Text
goodHash = hashWith parameters "salt of the test" (Password "a password")

-- | A stretching a sign-in accepts.
goodStretch :: Text
goodStretch = "t=4,m=134217728"

columns :: Maybe Text -> Maybe Text -> Maybe Text -> PasswordColumns
columns record stretch phc = PasswordColumns {record, stretch, hash = phc}

noColumns :: PasswordColumns
noColumns = columns Nothing Nothing Nothing

-- | An enabled account with these password columns and nothing else.
account :: Text -> PasswordColumns -> AccountWays
account login password = accountWith login password False [] False

-- | An account with these password columns, disabled or not, with
-- identities at these providers, and a passkey or not.
accountWith :: Text -> PasswordColumns -> Bool -> [Text] -> Bool -> AccountWays
accountWith login password disabled providers passkey = AccountWays {id = UserId ("u-" <> login), login = Login login, disabled, password, providers, passkey}

ruleSpec :: Spec
ruleSpec = describe "wiki-server check, the rule on stored passwords" $ do
  it "refuses a record without its stretch, and a stretch without its record, with or without a hash beside" $ do
    credentialProblem (columns (Just decodableRecord) Nothing Nothing) `shouldSatisfy` mentions "without its stretch"
    credentialProblem (columns (Just decodableRecord) Nothing (Just goodHash)) `shouldSatisfy` mentions "without its stretch"
    credentialProblem (columns Nothing (Just goodStretch) Nothing) `shouldSatisfy` mentions "without its record"
    credentialProblem (columns Nothing (Just goodStretch) (Just goodHash)) `shouldSatisfy` mentions "without its record"
  it "refuses a record that is not base64url, one that is not an OPAQUE record, and a stretch a sign-in does not accept" $ do
    credentialProblem (columns (Just "not base64url!") (Just goodStretch) Nothing) `shouldSatisfy` mentions "not base64url"
    credentialProblem (columns (Just "AAAA") (Just goodStretch) Nothing) `shouldSatisfy` mentions "not a valid one"
    credentialProblem (columns (Just decodableRecord) (Just "t=4,m=100") Nothing) `shouldSatisfy` mentions "t=4,m=100"
    credentialProblem (columns (Just decodableRecord) (Just "fast") Nothing) `shouldSatisfy` mentions "fast"
  it "refuses a hash from before OPAQUE that the verifier does not read" $ do
    credentialProblem (columns Nothing Nothing (Just "")) `shouldSatisfy` mentions "cannot read"
    credentialProblem (columns Nothing Nothing (Just "$2b$12$bcryptbcryptbcryptbcrypt")) `shouldSatisfy` mentions "cannot read"
    -- A salt of four bytes and a hash of four.
    credentialProblem (columns Nothing Nothing (Just "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA")) `shouldSatisfy` mentions "cannot read"
  it "takes no password, a hash alone, and a whole record, with or without a hash left beside it" $ do
    credentialProblem noColumns `shouldBe` Nothing
    credentialProblem (columns Nothing Nothing (Just goodHash)) `shouldBe` Nothing
    credentialProblem (columns (Just decodableRecord) (Just goodStretch) Nothing) `shouldBe` Nothing
    credentialProblem (columns (Just decodableRecord) (Just goodStretch) (Just "not a hash")) `shouldBe` Nothing
  it "names each account it refuses by login and id, a disabled one too, and no other" $ do
    let broken = accountWith "alice" (columns (Just decodableRecord) Nothing Nothing) True [] False
        fine = account "bob" (columns Nothing Nothing (Just goodHash))
        providerOnly = accountWith "carol" noColumns False ["github"] False
        passkeyOnly = accountWith "dave" noColumns False [] True
    brokenCredentials [broken, fine, providerOnly, passkeyOnly]
      `shouldBe` ["The account alice (u-alice) has an OPAQUE record without its stretch (opaque_stretch is empty), which no sign-in can use."]
  where
    mentions part = maybe False (part `T.isInfixOf`)

-- | One account of each kind, with "github" in the settings and "gitlab"
-- removed from them.
eachKind :: [AccountWays]
eachKind =
  [ account "anna" (columns (Just decodableRecord) (Just goodStretch) Nothing)
  , account "ben" (columns Nothing Nothing (Just goodHash))
  , accountWith "cleo" noColumns False ["github"] False
  , accountWith "dora" noColumns False [] True
  , accountWith "emil" (columns Nothing Nothing (Just goodHash)) True [] False
  , account "finn" noColumns
  , accountWith "gwen" noColumns False ["gitlab"] False
  ]

summarySpec :: Spec
summarySpec = describe "wiki-server check, how the accounts sign in" $ do
  it "tells each way in apart, the first an account has" $ do
    map (wayIn ["github"]) eachKind
      `shouldBe` [ByPassword False, ByPassword True, ByProvider, ByPasskey, Disabled, NoWay NoPasswordSet, NoWay (OnlyRemovedProviders ["gitlab"])]
    -- A password comes before a provider and a passkey, and a provider
    -- before a passkey.
    wayIn ["github"] (accountWith "hugo" (columns Nothing Nothing (Just goodHash)) False ["github"] True) `shouldBe` ByPassword True
    wayIn ["github"] (accountWith "ida" noColumns False ["github"] True) `shouldBe` ByProvider
    wayIn [] (accountWith "jan" noColumns False ["gitlab"] True) `shouldBe` ByPasskey
  it "says how many sign in each way, and lists the enabled accounts with no way in" $
    waysInLines (waysIn ["github"] eachKind)
      `shouldBe` [ "Accounts: 7 (6 enabled, 1 disabled). How the enabled ones sign in:"
                 , "  with a password: 2, of which 1 with a hash from before OPAQUE until its next sign-in"
                 , "  through a provider the settings name, with no password: 1"
                 , "  with a passkey alone: 1"
                 , "  no way in: 2"
                 , "    finn: no password set"
                 , "    gwen: only a provider the settings no longer name (gitlab)"
                 ]
  it "counts every account with no way in, names the first twenty by login, and says how many more there are" $ do
    -- Logins given in reverse, as a database's order need not be the
    -- logins'.
    let crowd = [account ("user" <> T.justifyRight 4 '0' (show i)) noColumns | i <- [1234 :: Int, 1233 .. 1]]
        lines' = waysInLines (waysIn [] crowd)
    take 1 (drop 4 lines') `shouldBe` ["  no way in: 1234"]
    take 2 (drop 5 lines') `shouldBe` ["    user0001: no password set", "    user0002: no password set"]
    drop 24 lines' `shouldBe` ["    user0020: no password set", "    and 1214 more"]
    length lines' `shouldBe` 5 + listedNoWayIn + 1
    -- Twenty, and no line for none more.
    waysInLines (waysIn [] (take listedNoWayIn crowd)) `shouldSatisfy` all (not . T.isInfixOf "more")
  it "writes a line break or another control character in a login or a provider's name as an escape, keeping one line for each" $ do
    let odd' = accountWith "old\nlogin" noColumns False ["git\rlab"] False
    waysInLines (waysIn [] [odd']) `shouldSatisfy` elem "    old\\u000alogin: only a provider the settings no longer name (git\\u000dlab)"
    brokenCredentials [accountWith "old\nlogin" (columns (Just decodableRecord) Nothing Nothing) False [] False]
      `shouldSatisfy` all (\l -> not ("\n" `T.isInfixOf` l) && "old\\u000alogin" `T.isInfixOf` l)
  it "says there are none of each on a wiki with no accounts" $
    waysInLines (waysIn [] [])
      `shouldBe` [ "Accounts: 0 (0 enabled, 0 disabled). How the enabled ones sign in:"
                 , "  with a password: 0, of which 0 with a hash from before OPAQUE until its next sign-in"
                 , "  through a provider the settings name, with no password: 0"
                 , "  with a passkey alone: 0"
                 , "  no way in: 0"
                 ]

-- | @wiki-server check@ on a database with accounts in it: the database
-- written row by row, as no program would write the broken ones.
spec :: Backing -> Spec
spec backing = describe "wiki-server check, the accounts" $ do
  for_ brokenKinds $ \(what, password, line) ->
    it ("refuses " <> toS what <> ", naming the account (exit 5)") $ withPlaceIn backing $ \at -> do
      _ <- migrateDatabase at
      withConnectionTo at $ \c -> runDb c (users [("u-anna", "anna", False, columns (Just decodableRecord) (Just goodStretch) Nothing), ("u-x", "broken.one", True, password)])
      runCheck (placeOptionsOf at) >>= \case
        CheckUnreadable lines' -> do
          lines' `shouldSatisfy` any (\l -> ("The account broken.one (u-x) has " <> line) `T.isPrefixOf` l)
          lines' `shouldSatisfy` all (not . T.isInfixOf "anna")
        other -> expectationFailure ("expected the check to refuse the account, got " <> show other)
  it "prints a login and a name beyond ASCII as UTF-8 in the C locale, in check, a refusal and users list" $ withPlaceIn backing $ \at -> do
    _ <- migrateDatabase at
    -- A login with no password; a name beyond ASCII with one; and, written
    -- by hand, a login beyond ASCII (which logins have not been since step
    -- 15 of the schema) whose record lacks its stretch.
    withConnectionTo at $ \c -> runDb c $ do
      users [("u-lucja", "lucja", False, noColumns), ("u-zofia", "zofia", False, columns (Just decodableRecord) (Just goodStretch) Nothing)]
      runUpdate (update wikiDb.users (\u -> u.display_name <-. val_ "Zażółć") (\u -> u.id ==. val_ "u-zofia"))
    program <- wikiServerProgram
    environment <- cLocale
    (checked, out, _) <- runBytes environment program ("check" : placeArgsOf at)
    checked `shouldBe` ExitSuccess
    out `shouldSatisfy` BS.isInfixOf (encodeUtf8 "\n    lucja: no password set\n")
    (listed, table, _) <- runBytes environment program (["users", "list"] <> placeArgsOf at)
    listed `shouldBe` ExitSuccess
    table `shouldSatisfy` BS.isInfixOf (encodeUtf8 "Zażółć  ")
    withConnectionTo at $ \c -> runDb c (users [("u-jerzy", "jerzy-żółw", False, columns (Just decodableRecord) Nothing Nothing)])
    (refused, _, err) <- runBytes environment program ("check" : placeArgsOf at)
    refused `shouldBe` ExitFailure 5
    err `shouldSatisfy` BS.isInfixOf (encodeUtf8 "The account jerzy-żółw (u-jerzy) has an OPAQUE record without its stretch")
    err `shouldSatisfy` BS.isInfixOf (encodeUtf8 "The account jerzy-żółw (u-jerzy) has a login the rules of a login refuse: A login has only ASCII letters, digits and punctuation.")
  it "passes a wiki with one account of each kind, and says how each signs in" $ withPlaceIn backing $ \at -> do
    _ <- migrateDatabase at
    withConnectionTo at $ \c -> runDb c $ do
      users [("u-" <> a.login.text, a.login.text, a.disabled, a.password) | a <- eachKind]
      runInsert (insert wikiDb.sign_in_providers (insertValues [ProviderRow {name = "github", position = 0, kind = "github", client_id = "client", issuer = Nothing, secret = Nothing}]))
      runInsert . insert wikiDb.identities $
        insertValues
          [ IdentityRow {provider = "github", subject = "cleo-at-github", user_id = "u-cleo", email = Nothing, display_name = Nothing, linked_at = moment}
          , IdentityRow {provider = "gitlab", subject = "gwen-at-gitlab", user_id = "u-gwen", email = Nothing, display_name = Nothing, linked_at = moment}
          ]
      runInsert (insert wikiDb.passkeys (insertValues [PasskeyRow {credential_id = "dora-key", user_id = "u-dora", public_key = "key", algorithm = -7, sign_count = 0, name = "Laptop", created_at = moment, last_used_at = Nothing, wrapped_nonce = Nothing, wrapped_key = Nothing}]))
    runCheck (placeOptionsOf at) >>= \case
      CheckPassed lines' -> do
        -- On SQLite the first line names the SQLite library; on
        -- PostgreSQL no line does.
        case backing of
          OnSqlite -> sqliteLine >>= \line -> take 1 lines' `shouldBe` [line]
          _ -> filter ("SQLite" `T.isPrefixOf`) lines' `shouldBe` []
        let summary = dropWhile (/= "Every table and every record read.") lines'
        summary
          `shouldBe` [ "Every table and every record read."
                     , "Accounts: 7 (6 enabled, 1 disabled). How the enabled ones sign in:"
                     , "  with a password: 2, of which 1 with a hash from before OPAQUE until its next sign-in"
                     , "  through a provider the settings name, with no password: 1"
                     , "  with a passkey alone: 1"
                     , "  no way in: 2"
                     , "    finn: no password set"
                     , "    gwen: only a provider the settings no longer name (gitlab)"
                     ]
      other -> expectationFailure ("expected the check to pass, got " <> show other)
  where
    moment = UTCTime (fromGregorian 2026 11 10) 0
    brokenKinds :: [(Text, PasswordColumns, Text)]
    brokenKinds =
      [ ("a record without its stretch", columns (Just decodableRecord) Nothing Nothing, "an OPAQUE record without its stretch")
      , ("a stretch without its record", columns Nothing (Just goodStretch) (Just goodHash), "an OPAQUE stretch without its record")
      , ("a record that does not decode", columns (Just "AAAA") (Just goodStretch) Nothing, "a password no sign-in can use: its OPAQUE record is not a valid one")
      , ("a stretch that does not read", columns (Just decodableRecord) (Just "t=0,m=0") Nothing, "a password no sign-in can use: its stretch")
      , ("a hash the verifier does not read", columns Nothing Nothing (Just "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA"), "a password hash from before OPAQUE that the sign-in cannot read")
      ]
    users rows =
      runInsert . insert wikiDb.users $
        insertValues
          [ UserRow
              { id = u
              , login
              , display_name = login
              , password_hash = password.hash
              , disabled
              , email = Nothing
              , email_verified_at = Nothing
              , notification_mail = Nothing
              , watch_own = True
              , feed_token = Nothing
              , avatar_blob = Nothing
              , avatar_media_type = Nothing
              , opaque_record = password.record
              , opaque_stretch = password.stretch
              }
          | (u, login, disabled, password) <- rows
          ]
