module Maker.CheckSpec (spec) where

import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Data.Maybe (listToMaybe)
import Maker.Check.Native
import System.IO (readFile')
import Test.Hspec

-- | Findings with everything there: the five commands, GMP, libpq, zlib
-- and SQLite counted; xelatex, libsodium (which the bootstrap builds) and terminfo
-- not.
allThere :: Findings
allThere =
  Findings
    { lines' =
        [Ok c ("/usr/bin/" <> c) | c <- ["cc", "make", "curl", "git", "pkg-config"]]
          <> [ Uncounted "ok" "xelatex" "working at /usr/bin/xelatex (for the PDF exports; not counted)"
             , Ok "GMP" "gmp.h, through cc -E"
             , Ok "libpq" "pg_config at /usr/bin/pg_config, headers in /usr/include/postgresql"
             , Ok "zlib" "pkg-config --exists zlib"
             , Ok "SQLite" "sqlite3.h and the library a program built with -lsqlite3 loads are 3.45.1 (/usr/lib/x86_64-linux-gnu/libsqlite3.so.0); 3.32.0 or later, built as wiki-server needs"
             , Uncounted "--" "libsodium" "not needed from the system: the bootstrap builds libsodium 1.0.22 from source (toolchain/libsodium.sh; not counted)"
             , Uncounted "skipped" "terminfo" "not needed (for the configuration wizard only: --with-wizard)"
             ]
    , texNote = Nothing
    , pgConfigElsewhere = Nothing
    }

spec :: Spec
spec = describe "the native check's report" $ do
  it "lines up its columns as check-native.sh's printf does" $ do
    itemLine "missing" "libpq" "no pg_config on PATH" `shouldBe` "missing  libpq       no pg_config on PATH"
    itemLine "ok" "pkg-config" "/usr/bin/pkg-config" `shouldBe` "ok       pkg-config  /usr/bin/pkg-config"
  it "counts the items that are checked, and only those" $
    render defaultOptions allThere `shouldBe` (map line' allThere.lines' <> ["All 9 items the native build of wiki-server needs are there."], True)
  it "says the wizard's items need, not needs" $
    last (fst (render defaultOptions {wizard = True} allThere)) `shouldBe` "All 9 items the native build of wiki-server and the configuration wizard need are there."
  it "names a missing item's packages, and the pg_config off PATH to put on it" $ do
    let f =
          allThere
            { lines' = [Missing (Lack "libpq" "libpq-dev" "libpq-devel" "no pg_config on PATH, but there is one at /usr/pgsql-16/bin/pg_config")]
            , pgConfigElsewhere = Just "/usr/pgsql-16/bin/pg_config"
            }
        (report, ok) = render defaultOptions f
    ok `shouldBe` False
    report `shouldContain` ["missing  libpq       no pg_config on PATH, but there is one at /usr/pgsql-16/bin/pg_config (Debian: libpq-dev; RHEL: libpq-devel)"]
    report `shouldContain` ["Missing for the native build of wiki-server: libpq.", "Install them and run this again:", "    Debian, Ubuntu: sudo apt-get install libpq-dev", "    RHEL, Fedora:   sudo dnf install libpq-devel"]
    report `shouldContain` ["    PATH=/usr/pgsql-16/bin:$PATH sh toolchain/deploy-local.sh ..."]
  it "reports libsodium without counting it, from the repository's pins" $ do
    f <- findings ".." defaultOptions {tex = False}
    [l | l@(Uncounted _ "libsodium" _) <- f.lines']
      `shouldBe` [Uncounted "--" "libsodium" "not needed from the system: the bootstrap builds libsodium 1.0.22 from source (toolchain/libsodium.sh; not counted)"]
  it "never fails for xelatex, and says in the summary why there would be no PDFs" $ do
    let (report, ok) = render defaultOptions allThere {texNote = Just "none is on PATH"}
    ok `shouldBe` True
    last report `shouldBe` "PDF exports need xelatex: none is on PATH, so the server would offer no PDFs (the deploy offers TeX Live under the toolchain: sh toolchain/deploy-local.sh --server --texlive)."
  describe "the SQLite item" sqliteSpec
  where
    line' = \case
      Ok item how -> itemLine "ok" item how
      Missing l -> itemLine "missing" l.item l.detail
      Uncounted status item text -> itemLine status item text

-- | The floors of toolchain/pins.env.
floor' :: SqliteFloor
floor' = SqliteFloor {version = "3.32.0", number = 3032000, variables = 32766}

-- | What the probe prints for a library like Debian's, with changes.
probeSays :: [(String, String)] -> [String]
probeSays changes =
  [ key <> " " <> maybe value id (lookup key changes)
  | (key, value) <-
      [ ("header", "3.45.1")
      , ("version", "3.45.1")
      , ("number", "3045001")
      , ("file", "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0")
      , ("threadsafe", "1")
      , ("omit_wal", "0")
      , ("omit_foreign_key", "0")
      , ("max_variable_number", "250000")
      ]
  ]

sqliteSpec :: Spec
sqliteSpec = do
  it "passes a library new enough and built with the defaults, naming its version and its file" $
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays []))
      `shouldBe` Ok "SQLite" "sqlite3.h and the library a program built with -lsqlite3 loads are 3.45.1 (/usr/lib/x86_64-linux-gnu/libsqlite3.so.0); 3.32.0 or later, built as wiki-server needs"
  it "refuses a library too old, even with a header new enough, naming both" $
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("header", "3.53.2"), ("version", "3.26.0"), ("number", "3026000"), ("file", "/usr/lib64/libsqlite3.so.0")]))
      `shouldBe` Missing (lack "sqlite3.h is 3.53.2 and the library a program built with -lsqlite3 loads is 3.26.0 (/usr/lib64/libsqlite3.so.0): wiki-server needs SQLite 3.32.0 or later")
  it "takes the floor's version itself, and refuses the release before it" $ do
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("header", "3.32.0"), ("version", "3.32.0"), ("number", "3032000")])) `shouldSatisfy` isOk
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("header", "3.31.1"), ("version", "3.31.1"), ("number", "3031001")])) `shouldSatisfy` (not . isOk)
  it "says a header and a library that differ even when both are new enough" $
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("header", "3.53.2"), ("file", "/usr/lib/libsqlite3.so.0")]))
      `shouldBe` Ok "SQLite" "sqlite3.h is 3.53.2 and the library a program built with -lsqlite3 loads is 3.45.1 (/usr/lib/libsqlite3.so.0); 3.32.0 or later, built as wiki-server needs, but the two differ: the build and the run find SQLite in different places"
  it "refuses each option wiki-server refuses" $ do
    let refusedFor changes option =
          sqliteVerdict floor' (ProbeRan 0 "" (probeSays changes))
            `shouldBe` Missing (lack ("sqlite3.h and the library a program built with -lsqlite3 loads are 3.45.1 (/usr/lib/x86_64-linux-gnu/libsqlite3.so.0), built with " <> option <> ", which wiki-server refuses"))
    refusedFor [("threadsafe", "0")] "THREADSAFE=0"
    refusedFor [("omit_wal", "1")] "OMIT_WAL"
    refusedFor [("omit_foreign_key", "1")] "OMIT_FOREIGN_KEY"
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("max_variable_number", "999")]))
      `shouldBe` Missing (lack "sqlite3.h and the library a program built with -lsqlite3 loads are 3.45.1 (/usr/lib/x86_64-linux-gnu/libsqlite3.so.0), built with MAX_VARIABLE_NUMBER=999, which wiki-server refuses (it needs 32766 or more)")
    sqliteVerdict floor' (ProbeRan 0 "" (probeSays [("threadsafe", "2"), ("max_variable_number", "32766")])) `shouldSatisfy` isOk
  it "says a program that builds and does not run, in the loader's words" $ do
    sqliteVerdict floor' (ProbeRan 127 "error while loading shared libraries: libsqlite3.so.0: cannot open shared object file: No such file or directory" [])
      `shouldBe` Missing (lack "a program built with sqlite3.h and -lsqlite3 does not run: error while loading shared libraries: libsqlite3.so.0: cannot open shared object file: No such file or directory; the loader does not find at run time the library the build linked: give its directory in LD_LIBRARY_PATH, or put it on the loader's path (/etc/ld.so.conf.d, then ldconfig)")
    sqliteVerdict floor' (ProbeRan 0 "" []) `shouldBe` Missing (lack "a program built with sqlite3.h and -lsqlite3 does not run: it exited 0")
  it "passes a program that cannot be executed here, saying the library is not checked" $
    sqliteVerdict floor' (ProbeRan 126 "Permission denied" [])
      `shouldBe` Ok "SQLite" "sqlite3.h and -lsqlite3 build a program, which cannot be run here (Permission denied): the library it would load is not checked"
  it "says a program cc cannot build" $
    sqliteVerdict floor' ProbeNotBuilt `shouldBe` Missing (lack "cc cannot build a program with sqlite3.h and -lsqlite3")
  it "prints in its probe each key the verdict reads, and builds the probe check-native.sh builds" $ do
    for_' ["header", "version", "number", "file", "threadsafe", "omit_wal", "omit_foreign_key", "max_variable_number"] $ \key ->
      probeSource `shouldSatisfy` isInfixOf ("printf(\"" <> key <> " ")
    script <- readFile' "../toolchain/check-native.sh"
    let heredoc = takeWhile (/= "EOF") (drop 1 (dropWhile (/= "  cat >\"$probe/sqlite.c\" <<'EOF'") (lines script)))
    unlines heredoc `shouldBe` probeSource
  it "reads its floors from toolchain/pins.env, which agree with wiki-server's own" $ do
    pins <- readFile' "../toolchain/pins.env"
    sqliteFloor pins `shouldBe` Just floor'
    server <- readFile' "../wiki-server/src/Wiki/Server/Storage/SqliteLibrary.hs"
    let definition name = listToMaybe [rest | l <- lines server, Just rest <- [stripPrefix (name <> " = ") l]]
    definition "oldestSqlite" `shouldBe` Just (show floor'.version)
    definition "fewestVariables" `shouldBe` Just (show floor'.variables)
    -- toolchain/check-native.sh reads the same lines of the same file.
    script <- readFile' "../toolchain/check-native.sh"
    filter ("sqlite_min=$(sed -n 's/^SQLITE_MIN_VERSION=//p'" `isPrefixOf`) (lines script) `shouldSatisfy` (not . null)
    filter ("sqlite_variables=$(sed -n 's/^SQLITE_MIN_VARIABLE_NUMBER=//p'" `isPrefixOf`) (lines script) `shouldSatisfy` (not . null)
  it "takes no floors from a file without them" $
    sqliteFloor "GHC_VERSION=9.14.1\nSQLITE_MIN_VERSION=3.32\nSQLITE_MIN_VARIABLE_NUMBER=32766\n" `shouldBe` Nothing
  where
    lack = Lack "SQLite" "libsqlite3-dev" "sqlite-devel"
    isOk = \case
      Ok {} -> True
      _ -> False
    for_' xs f = mapM_ f xs
