-- | What every smoke suite's walk is made of: examples that go on one from
-- another on one page ('Chain', 'step'), the page with the driver at hand
-- for the other browsers an example opens ('Walker', 'onWalkPage'), the
-- gate a page's program is held at while the page is read as the server
-- sent it ('ProgramGate'), and the lines of the report.
--
-- A walk is one long test cut into examples, as the JavaScript smoke tests
-- were one script with an @ok:@ line per part. Each example needs the ones
-- before it, so once one fails the ones after it are pending, saying
-- where the walk stopped, rather than each failing after its own timeout
-- on a page left somewhere else.
module Wiki.Smoke.Walk
  ( -- * A walk of examples
    Chain
  , newChain
  , step

    -- * One page, and the driver
  , Walker (..)
  , onWalkPage

    -- * The program's gate
  , ProgramGate
  , newProgramGate
  , armProgram
  , gateOf

    -- * The report
  , report
  , expect
  , tshow
  )
where

import Control.Exception (onException)
import Control.Monad (unless)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Test.Hspec qualified as Hspec
import Wiki.Smoke.Adoption (adoptionOptions)

----------------------------------------------------------------------
-- A walk of examples

-- | Examples that go on one from another on one page: once one has
-- failed, the ones after it are pending, saying which, rather than each
-- failing after its own timeout on a page left elsewhere.
newtype Chain = Chain (IORef (Maybe String))

newChain :: IO Chain
newChain = Chain <$> newIORef Nothing

-- | An example of the chain, by its name, given what the walk's examples
-- share (a 'Page' for 'onOnePage', a 'Walker' for 'onWalkPage').
step :: Chain -> String -> (a -> IO ()) -> SpecWith a
step (Chain failed) name body = it name $ \shared ->
  readIORef failed >>= \case
    Just before -> pendingWith ("the walk stopped at: " <> before)
    Nothing -> body shared `onException` writeIORef failed (Just name)

----------------------------------------------------------------------
-- One page, and the driver

-- | What an example of a walk on one page is given: the page, and the
-- driver, for the other browsers (contexts) the example opens beside it:
-- another user's, a fresh one, one with the service worker let in.
data Walker = Walker
  { browser :: Playwright
  , page :: Page
  }

-- | A group of examples that share one page, in a context of its own with
-- these options, in order, as 'onOnePage' has them, each also given the
-- driver ('Walker'). The setup runs once, before the first example, with
-- the page fresh. Each example's failure says what the page said, as
-- 'onOnePage''s does.
onWalkPage :: (HasCallStack) => ContextOptions -> (Walker -> IO ()) -> SpecWith Walker -> SpecWith Playwright
onWalkPage options setup =
  Hspec.aroundAllWith
    ( \examples pw -> withContext pw options $ \ctx -> do
        page <- newPage ctx
        let walker = Walker {browser = pw, page}
        setup walker
        examples walker
    )
    . Hspec.aroundWith (\example walker -> withFailureContext walker.page (example walker))

----------------------------------------------------------------------
-- The program's gate

-- | The gate a page's program is held at while the page is read as the
-- server sent it: one for the page, made when the page is, armed again
-- for every load ('rearm'), and never taken away while the page loads.
newtype ProgramGate = ProgramGate (IORef (Maybe Gate))

newProgramGate :: IO ProgramGate
newProgramGate = ProgramGate <$> newIORef Nothing

-- | Make the page's gate for its program (@app.wasm@), released: the setup
-- of a walk whose loads are checked for their adoption.
armProgram :: ProgramGate -> Page -> IO ()
armProgram (ProgramGate ref) page = do
  gate <- hold page adoptionOptions.program
  release gate
  writeIORef ref (Just gate)

gateOf :: ProgramGate -> IO Gate
gateOf (ProgramGate ref) = readIORef ref >>= maybe (fail "the page has no gate: armProgram in its setup") pure

----------------------------------------------------------------------
-- The report

-- | A line of the report, under the example's own: what the script
-- printed as a note.
report :: Text -> IO ()
report line = Text.putStrLn ("      " <> line)

-- | Fail with the message unless the condition holds.
expect :: (HasCallStack) => Bool -> String -> IO ()
expect holds message = unless holds (expectationFailure message)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
