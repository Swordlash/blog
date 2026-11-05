module Maker.CliSpec (spec) where

import Maker.Cli
import Maker.Context (Mode (..))
import Maker.Rules (Target (..))
import Test.Hspec

spec :: Spec
spec = describe "the command line" $ do
  it "takes the bootstrap's hand-over with every path it computed" $
    parseArgs ["bootstrap", "build", "--root", "/r", "--base", "/b", "--named-base", "--ghcup-bin", "/g", "--log-size", "12", "--started", "100", "--lock-fd", "9"]
      `shouldBe` Just (RunBootstrap (Bootstrap Build "/r" "/b" True "/g" 12 100 (Just 9)))
  it "refuses a mode the maker does not carry on with" $
    parseArgs ["bootstrap", "native", "--root", "/r", "--base", "/b", "--ghcup-bin", "/g", "--log-size", "0", "--started", "0"] `shouldBe` Nothing
  it "names the components to install by their targets' names" $
    parseArgs ["toolchain", "install", "node", "chromium"] `shouldBe` Just (Install Nothing [Node, Chromium])
  it "refuses an unknown component" $
    parseArgs ["toolchain", "install", "ghc"] `shouldBe` Nothing
  it "reports the status of the repository given" $
    parseArgs ["status", "--root", ".."] `shouldBe` Just (Status (Just ".."))
  it "passes a build's remaining arguments, options included, to cabal" $
    parseArgs ["build", "native", "--constraint=example ==1", "-j2"] `shouldBe` Just (RunBuild BuildNative ["--constraint=example ==1", "-j2"])
  it "passes a test's options to cabal" $
    parseArgs ["test", "wasm", "--test-options=--match \"/Slug/\""] `shouldBe` Just (RunTest TestWasm ["--test-options=--match \"/Slug/\""])
  it "knows the production build and the serve command" $
    (parseArgs ["build", "wasm-opt"], parseArgs ["serve", "-j2"]) `shouldBe` (Just (RunBuild BuildWasmOpt []), Just (Serve ["-j2"]))
