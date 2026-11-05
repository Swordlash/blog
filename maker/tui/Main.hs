-- | The maker's terminal interface; see "Maker.Tui".
module Main (main) where

import Maker.Cli (contextFromEnvironment)
import Maker.Context (Mode (..))
import Maker.Tui qualified
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let root = case args of
        ["--root", dir] -> Just dir
        _ -> Nothing
  ctx <- contextFromEnvironment root Toolchain
  Maker.Tui.run ctx
