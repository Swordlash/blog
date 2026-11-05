module Maker.StoreSpec (spec) where

import Maker.Store
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "the store's fingerprint" $ do
  it "lists the package descriptions in path order, outside build directories, node_modules, .git and the maker's own" $ do
    tmp <- getTemporaryDirectory
    let root = tmp </> "maker-store-spec"
    createDirectoryIfMissing True (root </> "b")
    mapM_ (createDirectoryIfMissing True . (root </>)) ["a", "dist-newstyle/x", "node_modules/y", ".git/z", "maker", "b/maker"]
    mapM_ (\f -> writeFile (root </> f) f) ["b/b.cabal", "a/a.cabal", "dist-newstyle/x/x.cabal", "node_modules/y/y.cabal", ".git/z/z.cabal", "a/notes.txt", "maker/maker.cabal", "b/maker/m.cabal"]
    files <- cabalFiles root
    removeDirectoryRecursive root
    files `shouldBe` [root </> "a/a.cabal", root </> "b/b.cabal", root </> "b/maker/m.cabal"]
  it "hashes the project files, then the packages, then the compilers, as the bootstrap did" $ do
    tmp <- getTemporaryDirectory
    let root = tmp </> "maker-store-spec-2"
    createDirectoryIfMissing True root
    writeFile (root </> "cabal.project") "P\n"
    writeFile (root </> "cabal.project.local") "L\n"
    writeFile (root </> "x.cabal") "X\n"
    text <- fingerprintInput root ["cabal.project"] [root </> "x.cabal"] "9.14.1\n" ""
    removeDirectoryRecursive root
    text `shouldBe` "P\nL\nX\n9.14.1\n"
