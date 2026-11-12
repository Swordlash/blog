module Maker.CheckSpec (spec) where

import Maker.Check.Native
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
             , Ok "SQLite" "sqlite3.h and -lsqlite3, through cc (3.32.0 or later)"
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
  where
    line' = \case
      Ok item how -> itemLine "ok" item how
      Missing l -> itemLine "missing" l.item l.detail
      Uncounted status item text -> itemLine status item text
