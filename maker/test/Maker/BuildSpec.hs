module Maker.BuildSpec (spec) where

import Maker.Build.Env (crossVariables, parseNulEnvironment, withoutCross)
import Maker.Build.Native (testTarget)
import Maker.Build.Wasm (Backend (..), WasmBuild (..), wasmBuildFrom)
import Test.Hspec

spec :: Spec
spec = do
  describe "the wasm build's settings" $ do
    it "builds the everyday demo into dist-newstyle/wasm when nothing is set" $
      wasmBuildFrom False (const Nothing)
        `shouldBe` Right (WasmBuild "cabal-wasm.project" "dist-newstyle/wasm" "dist-newstyle/wasm/public/app" Demo "cabal-native-fast.project" "dist-newstyle/native-fast" [])
    it "takes the project, the build directory and the output from the environment, as the Dockerfile sets them" $
      wasmBuildFrom False (`lookup` [("WASM_PROJECT", "p"), ("WASM_BUILDDIR", "b"), ("WIKI_PUBLIC_DIR", "/out/app"), ("WIKI_BACKEND", "server")])
        `shouldBe` Right (WasmBuild "p" "b" "/out/app" Server "cabal-native-fast.project" "dist-newstyle/native-fast" [])
    it "builds the prerender where a deploy says, with the constraints it gives, one per line" $
      fmap (\wb -> (wb.nativeProject, wb.nativeBuildDir, wb.nativeConstraints)) (wasmBuildFrom True (`lookup` [("NATIVE_PROJECT", "cabal-native-opt.project"), ("NATIVE_BUILDDIR", "dist-newstyle/native-opt"), ("NATIVE_CONSTRAINTS", "wiki-server -postgres\n\nother +flag\n")]))
        `shouldBe` Right ("cabal-native-opt.project", "dist-newstyle/native-opt", ["wiki-server -postgres", "other +flag"])
    it "puts the production build in a directory of its own, whatever WASM_PROJECT says" $
      fmap (\wb -> (wb.project, wb.buildDir, wb.publicDir)) (wasmBuildFrom True (`lookup` [("WASM_PROJECT", "p"), ("WASM_BUILDDIR", "b")]))
        `shouldBe` Right ("cabal-wasm-opt.project", "dist-newstyle/wasm-opt", "dist-newstyle/wasm-opt/public/app")
    it "refuses a backend it does not know" $
      wasmBuildFrom False (`lookup` [("WIKI_BACKEND", "serverless")]) `shouldBe` Left "WIKI_BACKEND is demo or server, not serverless"
  describe "the native tests' groups" $ do
    it "runs every suite when no group is set, and for all and unit" $
      map testTarget [Nothing, Just "all", Just "unit"] `shouldBe` replicate 3 (Right "all")
    it "runs only the server's suite for a database" $
      map testTarget [Just "sqlite", Just "postgres"] `shouldBe` replicate 2 (Right "wiki-server:test:wiki-server-test")
    it "refuses an empty or unknown group" $
      map testTarget [Just "", Just "postgress"] `shouldBe` replicate 2 (Left "WIKI_TEST_GROUP must be all, unit, sqlite or postgres")
  describe "the build environments" $ do
    it "reads env -0's output, values with newlines and equals signs included" $
      parseNulEnvironment "A=1\0B=two\nlines\0C=x=y\0" `shouldBe` [("A", "1"), ("B", "two\nlines"), ("C", "x=y")]
    it "keeps the cross compiler's variables out of the native environment" $
      withoutCross ([(v, "x") | v <- crossVariables] <> [("PATH", "/bin"), ("CABAL_DIR", "/c")]) `shouldBe` [("PATH", "/bin"), ("CABAL_DIR", "/c")]
