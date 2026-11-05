-- | The maker's command line; see "Maker.Cli".
module Main (main) where

import Maker.Cli qualified

main :: IO ()
main = Maker.Cli.main
