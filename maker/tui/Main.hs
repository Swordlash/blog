-- | The maker's terminal interface: the toolchain's status ("Maker.Tui"),
-- or, with @deploy@, the deploy's configuration wizard
-- ("Maker.Tui.Deploy"), which takes the rest of the arguments.
module Main (main) where

import Maker.Cli (contextFromEnvironment)
import Maker.Context (Mode (..))
import Maker.Tui qualified
import Maker.Tui.Deploy qualified
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let (root, rest) = case args of
        "--root" : dir : more -> (Just dir, more)
        more -> (Nothing, more)
  case rest of
    "deploy" : wizardArgs -> Maker.Tui.Deploy.run wizardArgs
    _ -> do
      ctx <- contextFromEnvironment root Toolchain
      Maker.Tui.run ctx
