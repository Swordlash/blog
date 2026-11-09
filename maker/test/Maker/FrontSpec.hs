module Maker.FrontSpec (spec) where

import Data.Char (isAsciiLower)
import Data.List (isPrefixOf, nub, sort)
import Maker.Cli qualified as Cli
import Maker.Deploy.Front (portProblem, urlProblem)
import Maker.Deploy.Options
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "the deploy's front" $ do
  it "takes the options the deploy's header lists, and the wizard offers no other" $ do
    header <- headerOptions <$> readFile ("../toolchain" </> "deploy-local.sh")
    length header `shouldSatisfy` (>= 20)
    -- --dir is the old name of --prefix, in the header's prose only; --help
    -- is the help's.
    sort header `shouldBe` sort (filter (`notElem` ["--dir", "--help"]) optionNames)
    wizardFiles <- (("../maker/tui/Maker/Tui/Deploy.hs" :) . map (("src/Maker/Deploy/Wizard" </>))) <$> listDirectory "src/Maker/Deploy/Wizard"
    wizard <- nub . sort . concatMap literals <$> mapM readFile wizardFiles
    -- Left out of the wizard on purpose: --force, which does nothing any
    -- more; --yes, which answers --rollback's question where there is no
    -- terminal, and the wizard runs on one. --args-from and --help are the
    -- wizard's own.
    filter (`notElem` ["--args-from", "--help"]) wizard `shouldBe` sort (filter (`notElem` ["--force", "--yes"]) header)
  it "hands every argument after deploy to the deploy, options included" $
    Cli.parseArgs ["deploy", "--server", "--port=8090", "--prefix", "/srv/wiki"] `shouldBe` Just (Cli.Deploy ["--server", "--port=8090", "--prefix", "/srv/wiki"])
  it "reads options with their value after = or as the next argument" $ do
    fmap (fmap (\o -> (o.optPort, o.optPrefix, o.optBackendOnly, o.optTlsCa, o.optTlsCaGiven))) (parsedOf ["--port=8090", "--prefix", "/srv/wiki", "--backend-only=main", "--tls-ca="])
      `shouldBe` Right (Just ("8090", "/srv/wiki", "main", "", True))
    fmap (fmap (.optBackendOnly)) (parsedOf ["--backend-only"]) `shouldBe` Right (Just "head")
    fmap (fmap (.optBackendOnly)) (parsedOf ["--backend-only="]) `shouldBe` Right (Just "head")
    fmap (fmap (.optPrefix)) (parsedOf ["--dir=/d"]) `shouldBe` Right (Just "/d")
    fmap (fmap (.optLibsodiumSource)) (parsedOf ["--libsodium-source", "libsodium-1.0.22.tar.gz"]) `shouldBe` Right (Just "libsodium-1.0.22.tar.gz")
    parseOptions ["--name"] `shouldBe` Left "--name needs a value"
    parseOptions ["--server", "-h"] `shouldBe` Right Help
  it "refuses what the shell refused, in its words" $ do
    parseOptions ["--texlive", "--no-texlive"] `shouldBe` Left "--texlive and --no-texlive exclude each other: give one"
    parseOptions ["--no-whats-new", "--whats-new"] `shouldBe` Left "--whats-new and --no-whats-new exclude each other: give one"
    parseOptions ["--frobnicate"] `shouldBe` Left "unknown option: --frobnicate (see --help)"
    parseOptions ["--server=yes"] `shouldBe` Left "unknown option: --server=yes (see --help)"
    either id (const "") (parseOptions ["--smtp-host=mail.example.org"]) `shouldSatisfy` ("--smtp-host is gone: " `isPrefixOf`)
    either id (const "") (parseOptions ["--trust-network"]) `shouldSatisfy` ("--trust-network is gone: " `isPrefixOf`)
    either id (const "") (parseOptions ["--github-token-file", "f"]) `shouldSatisfy` ("--github-token-file is not needed" `isPrefixOf`)
  it "names the ways to serve given, in the shell's order" $
    fmap (fmap ways) (parsedOf ["--behind-proxy", "--https", "--tls-key", "k"]) `shouldBe` Right (Just ["--https", "--tls-cert", "--behind-proxy"])
  it "says what is wrong with a port, a mirror or a registry" $ do
    portProblem "--port" "8090" `shouldBe` Nothing
    portProblem "--port" "080" `shouldBe` Just "invalid --port '080': a number from 1024 to 65535"
    portProblem "--port" "80" `shouldBe` Just "invalid --port 80: a number from 1024 to 65535 (lower ports need root)"
    portProblem "--admin-port" "70000" `shouldBe` Just "invalid --admin-port 70000: a number from 1024 to 65535"
    portProblem "--db-port" "" `shouldBe` Just "invalid --db-port '': a number from 1024 to 65535"
    urlProblem "npm-registry" "https://npm.example.org/" "https://npm.example.org/" `shouldBe` Nothing
    urlProblem "npm-registry" "https://npm.example.org/" "npm.example.org" `shouldBe` Just "--npm-registry npm.example.org: an http:// or https:// URL, such as https://npm.example.org/"
    urlProblem "hackage-mirror" "x" "https://h.example.org/$x" `shouldBe` Just "--hackage-mirror https://h.example.org/$x: an http:// or https:// URL without spaces or quotes"
    urlProblem "hackage-mirror" "x" "https://" `shouldBe` Just "--hackage-mirror https://: an http:// or https:// URL, such as x"
  where
    parsedOf args = case parseOptions args of
      Right (Parsed o) -> Right (Just o)
      Right Help -> Right Nothing
      Left e -> Left e
    headerOptions text =
      nub
        [ "--" <> takeWhile (\c -> isAsciiLower c || c == '-') rest
        | l <- takeWhile (/= "set -eu") (drop 1 (lines text))
        , Just rest <- [stripStart "#   --" l]
        , case rest of
            c : _ -> isAsciiLower c
            [] -> False
        ]
    stripStart p l = if p `isPrefixOf` l then Just (drop (length p) l) else Nothing
    -- The option literals of a Haskell source: "--name, up to the end of
    -- the name.
    literals [] = []
    literals ('"' : '-' : '-' : c : rest)
      | isAsciiLower c = ("--" <> (c : takeWhile (\x -> isAsciiLower x || x == '-') rest)) : literals rest
    literals (_ : rest) = literals rest
