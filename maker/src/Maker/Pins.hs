-- | The toolchain's pins and floors, read from @toolchain/pins.env@, the one
-- place that says them. The file is a list of @KEY=VALUE@ lines with
-- comments, which toolchain/bootstrap.sh sources as shell, so this reads
-- only that much of the shell's syntax.
module Maker.Pins
  ( Pins (..)
  , parsePins
  , readPins
  , pinsFile
  )
where

import Data.Char (isSpace)
import Data.Map.Strict qualified as Map
import System.FilePath ((</>))

-- | Every pin and floor the maker uses. The names are those of the file.
data Pins = Pins
  { ghcVersion :: String
  , cabalVersion :: String
  , wasmGhcVersion :: String
  , ghcWasmMetaRev :: String
  , ghcWasmFlavour :: String
  , ghcupVersion :: String
  , ghcupSha256 :: String
  , nodeVersion :: String
  , nodeSha256 :: String
  , playwrightVersion :: String
  , fourmoluVersion :: String
  , fourmoluSha256 :: String
  , libsodiumVersion :: String
  , libsodiumTag :: String
  , libsodiumCommit :: String
  , ghcMinVersion :: String
  , cabalMinVersion :: String
  , nodeMinMajor :: Int
  }
  deriving (Eq, Show)

-- | Where the pins are, given the repository's root.
pinsFile :: FilePath -> FilePath
pinsFile root = root </> "toolchain" </> "pins.env"

-- | The pins from the file's text, or what is wrong with it: a line that is
-- neither a comment, blank, nor @KEY=VALUE@, or a key missing.
parsePins :: String -> Either String Pins
parsePins text = do
  pairs <- traverse line (zip [1 :: Int ..] (lines text))
  let values = Map.fromList (concat pairs)
      get key = maybe (Left ("toolchain/pins.env has no " <> key)) Right (Map.lookup key values)
  nodeMin <- get "NODE_MIN_MAJOR"
  nodeMinMajor' <- case reads nodeMin of
    [(n, "")] -> Right n
    _ -> Left ("toolchain/pins.env: NODE_MIN_MAJOR is not a number: " <> nodeMin)
  Pins
    <$> get "GHC_VERSION"
    <*> get "CABAL_VERSION"
    <*> get "WASM_GHC_VERSION"
    <*> get "GHC_WASM_META_REV"
    <*> get "GHC_WASM_FLAVOUR"
    <*> get "GHCUP_VERSION"
    <*> get "GHCUP_SHA256"
    <*> get "NODE_VERSION"
    <*> get "NODE_SHA256"
    <*> get "PLAYWRIGHT_VERSION"
    <*> get "FOURMOLU_VERSION"
    <*> get "FOURMOLU_SHA256"
    <*> get "LIBSODIUM_VERSION"
    <*> get "LIBSODIUM_TAG"
    <*> get "LIBSODIUM_COMMIT"
    <*> get "GHC_MIN_VERSION"
    <*> get "CABAL_MIN_VERSION"
    <*> pure nodeMinMajor'
  where
    line (number, raw) = case dropWhile isSpace raw of
      "" -> Right []
      '#' : _ -> Right []
      content -> case break (== '=') content of
        (key, '=' : value)
          | not (null key) && all isKeyChar key && not (any isSpace value) -> Right [(key, value)]
        _ -> Left ("toolchain/pins.env, line " <> show number <> ": not KEY=VALUE: " <> raw)
    isKeyChar c = c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c == '_'

-- | The pins of the repository at the root, failing with the file's problem.
readPins :: FilePath -> IO Pins
readPins root = do
  text <- readFile (pinsFile root)
  either fail pure (parsePins text)
