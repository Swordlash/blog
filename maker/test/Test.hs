-- | The maker's tests: the pure parts (versions, pins, the command line, the
-- store's fingerprint). The parts that run the toolchain's tools are tested
-- through toolchain/test-bootstrap.sh, which runs the bootstrap, and this
-- maker, against fake tools on PATH.
module Main (main) where

import Maker.CliSpec qualified
import Maker.PinsSpec qualified
import Maker.StoreSpec qualified
import Maker.VersionSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Maker.VersionSpec.spec
  Maker.PinsSpec.spec
  Maker.CliSpec.spec
  Maker.StoreSpec.spec
