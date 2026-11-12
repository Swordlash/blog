-- | The SQLite library the server runs on ("Wiki.Server.Storage.SqliteLibrary"):
-- which libraries it refuses, and that it runs on the one it is linked
-- with here, the operating system's.
module Test.Storage.SqliteLibrary (unitSpec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Server.Storage.SqliteLibrary

unitSpec :: Spec
unitSpec = describe "the SQLite library" $ do
  it "runs on the library it is linked with, and reads its version and options" $ do
    l <- readSqliteLibrary
    sqliteLibrary `shouldReturn` Right l
    sqliteRefusal l `shouldBe` Nothing
    l.version `shouldSatisfy` ("3." `T.isPrefixOf`)
    l.options `shouldSatisfy` any ("THREADSAFE=" `T.isPrefixOf`)
    sqliteLine `shouldReturn` ("SQLite " <> l.version <> ", the system's library.")

  it "accepts 3.32.0 and later, the distributions' builds among them" $
    for_ ["3.32.0", "3.34.1", "3.45.1", "3.46.1", "3.53.2", "3.100.0", "4.0.0"] $ \v ->
      sqliteRefusal (library v) `shouldBe` Nothing

  it "refuses a version before 3.32.0, saying which it found and which it needs" $
    for_ ["3.31.1", "3.27.2", "3.7.17", "2.8.17"] $ \v ->
      case sqliteRefusal (library v) of
        Just why -> do
          why `shouldSatisfy` T.isInfixOf "needs SQLite 3.32.0 or later"
          why `shouldSatisfy` T.isInfixOf ("is " <> v <> ":")
        Nothing -> expectationFailure ("accepted SQLite " <> toS v)

  it "refuses a version it cannot read" $
    for_ ["", "3", "three", "3.45.x"] $ \v ->
      sqliteRefusal (library v) `shouldSatisfy` isJust

  it "refuses a library built without locks, the write-ahead log or foreign keys, or with fewer parameters" $
    for_ ["THREADSAFE=0", "OMIT_WAL", "OMIT_FOREIGN_KEY", "MAX_VARIABLE_NUMBER=999"] $ \option ->
      case sqliteRefusal (library "3.45.1") {options = ["THREADSAFE=1", option]} of
        Just why -> why `shouldSatisfy` T.isInfixOf option
        Nothing -> expectationFailure ("accepted a library built with " <> toS option)

  it "accepts the options of the distributions' builds" $ do
    sqliteRefusal (library "3.45.1") {options = ["THREADSAFE=1", "MAX_VARIABLE_NUMBER=250000", "ENABLE_FTS5"]} `shouldBe` Nothing
    sqliteRefusal (library "3.45.1") {options = ["THREADSAFE=2", "MAX_VARIABLE_NUMBER=32766"]} `shouldBe` Nothing
  where
    library v = SqliteLibrary {version = v, options = ["THREADSAFE=1"]}
