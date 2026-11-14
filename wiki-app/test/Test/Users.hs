-- | The administration's table of users ("Wiki.App.View.Users"), the real
-- component, mounted on the in-memory DOM ("Test.Harness.MemDom") over the
-- in-memory backend, on a clock the test owns
-- ('Test.Harness.MemDom.withTestClock'). Its search box writes the words
-- typed into the address once the typing has paused ('H.delayCounted'):
-- the test moves the clock past the pause instead of sleeping through it.
--
-- The address is read from what the view's router tells of
-- ('Router.changes'), not from the in-memory document's location: that is
-- the process's one, and specs beside this one write it (the prerender's
-- router, "Wiki.App.Static").
module Test.Users (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Halogen.Activity (Activity (..), idle)
import Halogen.Router qualified as Router
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Protolude hiding (find)
import Test.Harness.MemDom (View (..), advance, settle, typeInto, withTestClock, withView)
import Test.Hspec
import Wiki.App.Backend (anonymousIn)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (AdminSection (..), Route (..), UserFilter (..), UserListing (..), route)
import Wiki.App.View.Common (Context (..), PageWidth (..))
import Wiki.App.View.Users qualified as Users
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))

spec :: Spec
spec = describe "Wiki.App.View.Users, mounted on the in-memory DOM" $
  it "writes the words typed into the address once the typing has paused 300 ms, on the test's clock" $
    withTestClock $ \clock -> do
      wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
      let run :: MemWiki MemDOM a -> IO a
          run = runMemDOM . runMemWiki wiki
          listing search = UserListing {search, page = 1, only = Everyone}
      router <- run (Router.newRouter "/" Unknown route)
      went <- newIORef []
      _ <- HS.subscribe (Router.changes router) (\r -> modifyIORef' went (<> [r]))
      let ctx = Context {router, session = anonymousIn Open, sessionNumber = 0, spaces = [], icons = mempty, revision = 0, pageWidth = Compact}
      withView run Users.component Users.Input {context = ctx, listing = listing ""} $ \view -> do
        settle view
        -- Typed, and typed again before the pause is over: the pause
        -- starts again from the last keystroke. The pause counts as the
        -- program waiting, so a wait for the program to be quiet waits
        -- for it.
        typeInto view ".users-search-input" "ad" `shouldReturn` True
        view.waitActivity idle
        (\a -> a.waiting) <$> view.activity `shouldReturn` 1
        advance clock 0.2
        typeInto view ".users-search-input" "ada" `shouldReturn` True
        view.waitActivity idle
        advance clock 0.2
        readIORef went `shouldReturn` []
        -- The pause is over: the address is written as the clock moves,
        -- with nothing slept.
        advance clock 0.1
        readIORef went `shouldReturn` [Admin (Users (listing "ada"))]
        settle view
      Router.stop router
