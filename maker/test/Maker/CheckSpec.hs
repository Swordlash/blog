module Maker.CheckSpec (spec) where

import Maker.Check.Native
import Test.Hspec

-- | Findings with everything there: the five commands, GMP, libpq, zlib and
-- libsodium counted, xelatex and terminfo not.
allThere :: Findings
allThere =
  Findings
    { lines' =
        [Ok c ("/usr/bin/" <> c) | c <- ["cc", "make", "curl", "git", "pkg-config"]]
          <> [ Uncounted "ok" "xelatex" "working at /usr/bin/xelatex (for the PDF exports; not counted)"
             , Ok "GMP" "gmp.h, through cc -E"
             , Ok "libpq" "pg_config at /usr/bin/pg_config, headers in /usr/include/postgresql"
             , Ok "zlib" "pkg-config --exists zlib"
             , Ok "libsodium" "sodium.h and -lsodium, through cc"
             , Uncounted "skipped" "terminfo" "not needed (for the configuration wizard only: --with-wizard)"
             ]
    , texNote = Nothing
    , pgConfigElsewhere = Nothing
    , sodiumHint = Nothing
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
  it "gives libsodium's hint and the way to build it from source" $ do
    let f =
          allThere
            { lines' = [Missing (Lack "libsodium" "libsodium-dev" "libsodium-devel" "cc cannot compile and link a program with sodium.h and -lsodium")]
            , sodiumHint = Just "pkg-config finds a libsodium in /opt/lib, but cc does not: the build looks where cc does, so give it LIBRARY_PATH=/opt/lib C_INCLUDE_PATH=/opt/include"
            }
    fst (render defaultOptions f)
      `shouldContain` [ "pkg-config finds a libsodium in /opt/lib, but cc does not: the build looks where cc does, so give it LIBRARY_PATH=/opt/lib C_INCLUDE_PATH=/opt/include."
                      , "RHEL has libsodium in EPEL only. Built from source into a directory <dir> of your own:"
                      ]
  it "never fails for xelatex, and says in the summary why there would be no PDFs" $ do
    let (report, ok) = render defaultOptions allThere {texNote = Just "none is on PATH"}
    ok `shouldBe` True
    last report `shouldBe` "PDF exports need xelatex: none is on PATH, so the server would offer no PDFs (the deploy offers TeX Live under the toolchain: sh toolchain/deploy-local.sh --server --texlive)."
  where
    line' = \case
      Ok item how -> itemLine "ok" item how
      Missing l -> itemLine "missing" l.item l.detail
      Uncounted status item text -> itemLine status item text
