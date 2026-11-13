-- | The server's smoke test: the server's build of the wiki, served by a
-- real wiki-server, driven in headless Chromium through
-- haskell-halogen-playwright, which waits after every action until the
-- page's program says it is idle.
--
-- > sh toolchain/smoke-suite.sh server            # on SQLite; after npm run build-wasm
-- > sh toolchain/smoke-suite.sh server-postgres   # on PostgreSQL (WIKI_TEST_DATABASE_URL)
-- > HALOGEN_PLAYWRIGHT_THROTTLE=4 sh toolchain/smoke-suite.sh server   # every page four times slower
--
-- The build in @dist-newstyle/wasm/public/app@ is the demo's; its app.wasm
-- is the server's too. The suite copies it into a temporary directory,
-- without the demo's pages, and writes the server's there with
-- @wiki-app-prerender --server@. It makes an administrator and a reader
-- with the console, starts wiki-server on a temporary data directory (or
-- databases of its own on PostgreSQL) and free ports of 127.0.0.1, beside
-- a fake OpenID Connect provider on localhost, and drives the application
-- end to end against it ("Wiki.Smoke.Server" says how):
--
-- 1. The front page as the server renders it to someone not signed in,
--    with its content before app.wasm runs, adopted by the program with
--    nothing to repair and without asking the API anything; then signing in
--    through the header's form, as the administrator ("Server.Walk").
-- 2. A space and a page made through the forms; typing and saving; a
--    draft kept and restored after a reload; a file attached and served; a
--    conflict ended with "Take theirs"; search; the page's history; the
--    export, a user and a group made in the administration; the server's
--    settings with a provider; backups and the console's restore; a space
--    made public, which a visitor sees, and only that; a page's permanent
--    address; a public blog with its feeds; a closed wiki and an
--    invitation; signing in with the provider, a password set by the
--    administration, sessions and a second factor; a fresh browser finding
--    all of it there; a page exported as a Word document; a comment and who
--    is editing, across two tabs of two users over the WebSocket; a mention
--    told under the bell ("Server.Walk").
-- 3. Every route the walk went through, loaded afresh: each served with
--    its status and its content before app.wasm runs, adopted with nothing
--    to repair and no request to the API; and a page read with JavaScript
--    off ("Server.Walk").
-- 4. The demo's pages brought into the server, as its owner would
--    ("Server.Migrate").
-- 5. Interactive SVGs (WP5.90) ("Server.Svg").
-- 6. Encrypted spaces (WP5.74), and the canary ("Server.Encrypted",
--    "Server.Canary").
-- 7. What the server says of itself: its health, its metrics, its
--    activity ("Server.Health").
-- 8. Reading offline, through the service worker ("Server.Offline").
--
-- The parts run in this order and share the server, so the walk is one
-- chain: once an example has failed, the ones after it are pending, saying
-- where it stopped. An error a page throws, or writes on its console,
-- fails the example it is in, but for what the walk makes happen on
-- purpose ("Wiki.Smoke.Browser"). Without the builds the suite is one
-- pending example, unless @WIKI_SMOKE_REQUIRED=1@ (as
-- @toolchain/smoke-suite.sh@ sets it).
module Main (main) where

import Data.IORef (newIORef)
import Halogen.Playwright.Hspec
import Server.Canary (newCanary)
import Server.Encrypted qualified as Encrypted
import Server.Health qualified as Health
import Server.Migrate qualified as Migrate
import Server.Offline qualified as Offline
import Server.Provider (withProvider)
import Server.Site
import Server.Svg qualified as Svg
import Server.Walk qualified as Walk
import System.FilePath ((</>))
import Wiki.Smoke.Api (newWiki)
import Wiki.Smoke.Server
import Wiki.Smoke.Walk (newChain)

main :: IO ()
main = withServerSuite "the server's build, served by a real wiki-server" $ \built run ->
  withDatabase $ \(database, restoreDatabase) ->
    withServerBuild built "wiki-smoke-server-" $ \build -> do
      let dataDir = build.work </> "data"
      addUser built database dataDir NewUser {login = adminLogin, displayName = adminName, password = adminPassword, admin = True}
      addUser built database dataDir readerUser
      withProvider $ \provider ->
        -- Without the guide (--no-guide): the walk starts from a wiki with
        -- no spaces, as the import of the demo's counts what it brings.
        withServer build (serverOptions dataDir database) {guide = False} $ \server -> do
          wiki <- newWiki server.origin
          admin <- newIORef Nothing
          canary <- newCanary
          chain <- newChain
          let smoke = Smoke {build, server, wiki, origin = server.origin, dataDir, database, restoreDatabase, provider, admin, canary, chain}
          run . playwright $ do
            Walk.spec smoke
            Migrate.spec smoke
            Svg.spec smoke
            Encrypted.spec smoke
            Health.spec smoke
            Offline.spec smoke
