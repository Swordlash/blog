-- | How many cases this suite's properties run on each backend.
--
-- The suite runs twice in CI: natively in the native jobs, and compiled to
-- wasm under Node in the wasm job. The code under test is pure, so the two
-- runs differ by the compiler and by what CPP gives each backend, not by
-- the inputs. A mistake only the wasm build makes (an 'Int' of 32 bits, a
-- branch of CPP) shows on most inputs, not on a rare one. So the native run
-- is where the inputs are searched, at the full count, and the wasm run
-- checks that the wasm build agrees, at a quarter of it ('wasmCases').
--
-- A property's coverage ('Test.QuickCheck.cover') is checked natively
-- only ('coverage'). 'checkCoverage' runs a property until it is
-- statistically sure of its coverage, whatever the count says: up to 1600
-- cases for one of the slide rows' properties, which took four minutes on
-- wasm in CI on 2026-11-13. The generators are the same on both backends,
-- so the coverage they reach is the same too. On wasm the property runs
-- at the wasm count and prints its coverage, but too little of it does not
-- fail the property there.
--
-- Wasm runs the Markdown parser, which most properties here call, about
-- ten times slower than the native build does without optimisation
-- (measured on 2026-11-13), so a full count there made the wasm job the
-- run's length.
module Test.Cases (wasmCases, coverage) where

import Protolude
import Test.Hspec (SpecWith)
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck (Property, Testable, checkCoverage, property)

-- | Whether this is the wasm build of the suite.
onWasm :: Bool
#if defined(wasm32_HOST_ARCH)
onWasm = True
#else
onWasm = False
#endif

-- | The suite with its properties' count cut to a quarter on wasm, at
-- least one case each, and unchanged natively. Applied once, to the whole
-- suite, in its main.
wasmCases :: SpecWith a -> SpecWith a
wasmCases
  | onWasm = modifyMaxSuccess (\n -> max 1 (n `div` 4))
  | otherwise = identity

-- | A property whose coverage is checked: with 'checkCoverage' natively,
-- and as a plain property on wasm, where its 'Test.QuickCheck.cover'
-- labels are printed but not required.
coverage :: (Testable prop) => prop -> Property
coverage
  | onWasm = property
  | otherwise = checkCoverage
