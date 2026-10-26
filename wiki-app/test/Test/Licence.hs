-- | The repository's licence as its packages declare it (WP5.1 of
-- docs/PLAN.md): every package's @.cabal@ file says @license: MIT@ and
-- names its licence file, and that file is the repository's @LICENSE@,
-- word for word. Each package carries a copy rather than pointing at the
-- root one, because cabal refuses a @license-file@ outside the package
-- (@cabal check@: "parent directory segment"), so the copies could drift
-- from the root without this.
module Test.Licence (spec) where

import Data.ByteString qualified as BS
import Data.List (lookup)
import Data.Text qualified as T
import Protolude
import System.Directory (doesFileExist, listDirectory)
import Test.Hspec

-- | The repository's root, from the package's directory, where the suite
-- runs.
root :: FilePath
root = ".."

spec :: Spec
spec = describe "licence" $ do
  it "is the MIT licence, with the owner's copyright" $ do
    licence <- decodeUtf8 <$> BS.readFile (root <> "/LICENSE")
    T.lines licence `shouldSatisfy` (\ls -> take 1 ls == ["MIT License"])
    licence `shouldSatisfy` T.isInfixOf "Copyright (c) 2026 Mateusz Goślinowski\n"
    licence `shouldSatisfy` T.isInfixOf "THE SOFTWARE IS PROVIDED \"AS IS\""

  it "is found in every package of the repository" $ do
    packages <- cabalPackages
    -- Found by looking, so that a fifth package is checked too; the four
    -- known ones guard against a look that finds nothing.
    packages `shouldSatisfy` (\ps -> all (`elem` ps) ["wiki-api", "wiki-app", "wiki-core", "wiki-server"])

  it "is declared, and shipped word for word, by every package" $ do
    licence <- BS.readFile (root <> "/LICENSE")
    packages <- cabalPackages
    for_ packages $ \package -> do
      -- As bytes, decoded as UTF-8: the files are, whatever the locale says.
      fields <- cabalFields . decodeUtf8 <$> BS.readFile (root <> "/" <> package <> "/" <> package <> ".cabal")
      (package, lookup "license" fields) `shouldBe` (package, Just "MIT")
      (package, lookup "license-file" fields) `shouldBe` (package, Just "LICENSE")
      copy <- BS.readFile (root <> "/" <> package <> "/LICENSE")
      (package, copy == licence) `shouldBe` (package, True)

-- | The directories at the root that hold a package of the same name.
cabalPackages :: IO [FilePath]
cabalPackages = do
  entries <- sort <$> listDirectory root
  filterM (\d -> doesFileExist (root <> "/" <> d <> "/" <> d <> ".cabal")) entries

-- | A @.cabal@ file's top-level fields, the ones at the start of a line
-- before the first stanza, with their values trimmed.
cabalFields :: Text -> [(Text, Text)]
cabalFields =
  mapMaybe field . takeWhile (not . stanza) . T.lines
  where
    field line
      | T.null line || T.isPrefixOf " " line || T.isPrefixOf "--" line = Nothing
      | otherwise = case T.breakOn ":" line of
          (name, rest) | not (T.null rest) -> Just (T.toLower (T.strip name), T.strip (T.drop 1 rest))
          _ -> Nothing
    stanza line = any (`T.isPrefixOf` line) ["common ", "library", "executable ", "test-suite ", "benchmark ", "flag ", "source-repository "]
