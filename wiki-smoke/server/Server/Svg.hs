-- | Interactive SVGs (WP5.90 of docs/PLAN.md, decision 73): SVG
-- attachments of a private space's page, embedded with @{.interactive}@,
-- in frames the server prerenders and the program adopts without loading
-- any again, and which the program makes itself in the editor's preview
-- and the page after it, loading each once; a click in a flame graph's
-- shape runs its script; a hostile SVG finds no cookie, no storage, no way
-- into the page, no fetch to the wiki or another site, no tab and no
-- dialog (its WebRTC connection is recorded); the same address opened in a
-- tab is a download, whether its frame loaded first or not; another site
-- cannot frame it; one that navigates its frame to the wiki's API arrives
-- there signed out; the frames load with the service worker on too; and
-- offline, over plain HTTP to a host that is not the loopback one, and in
-- a link's text, the page shows the image instead.
--
-- What a frame's document does (its script's run, its navigation, its
-- load) is the frame's, not the program's: each is waited for as a
-- condition, on the frame's document or its address.
--
-- The way back from the editor's preview. The JavaScript test went back
-- with Playwright's @page.goBack()@, which waits for the page's own
-- navigation and its load; it timed out four times in a day. The SVG that
-- navigates its frame (@wander.svg@) does so 50 ms after its load, and a
-- frame's navigation is an entry of the page's session history, after the
-- preview's own (the editor pushes one, with the same address, so that
-- Back returns to the text). When the frame had navigated before Back,
-- Back took the frame back, not the page: no navigation of the page came,
-- and the wait for its load ran out; when it had not yet, Back went to the
-- text. The driver's @goBack@ waits for a load too. So the suite first
-- waits for the frame's document at the API's address (the frame's own
-- navigation, a condition), checks that the history has the two entries,
-- the preview's and the frame's, and goes back over both
-- (@history.go(-2)@), then waits for the program's text to show again,
-- which the page's @popstate@ brings.
module Server.Svg (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (bracket)
import Control.Monad (forM_, forever, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Network.HTTP.Types (hContentType, status200)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Network.Wai (rawPathInfo, responseLBS)
import Network.Wai.Handler.Warp (withApplication)
import Server.Site
import Wiki.Smoke.Api
import Wiki.Smoke.Browser
import Wiki.Smoke.Demo (nothingThrown)
import Wiki.Smoke.Walk

spec :: Smoke -> SpecWith Playwright
spec smoke = describe "interactive SVGs" $
  step smoke.chain "runs an interactive SVG of a private space in a frame the server prerenders and the program adopts, loaded once, reaching nothing of the wiki's or another site's, a download in a tab, framed by no other site, and shown as the image where no frame can be" $ \pw ->
    withElsewhere $ \elsewhere ->
      withStun $ \stun -> svgs smoke pw elsewhere stun

-- | Another site, on localhost: what reaches it is counted, but for its
-- page that frames the wiki's SVG.
data Elsewhere = Elsewhere {origin :: Text, reached :: IORef [Text], framing :: IORef Text}

withElsewhere :: (Elsewhere -> IO a) -> IO a
withElsewhere body = do
  reached <- newIORef []
  framing <- newIORef ""
  let app request respond = case rawPathInfo request of
        "/framing" -> readIORef framing >>= \html -> respond (responseLBS status200 [(hContentType, "text/html")] (LazyByteString.fromStrict (Text.encodeUtf8 html)))
        path -> do
          atomicModifyIORef' reached (\xs -> (xs <> [Text.decodeUtf8Lenient path], ()))
          respond (responseLBS status200 [(hContentType, "text/plain"), ("Access-Control-Allow-Origin", "*")] "elsewhere")
  withApplication (pure app) $ \port -> body Elsewhere {origin = "http://localhost:" <> tshow port, reached, framing}

-- | A UDP socket on 127.0.0.1 that counts the packets it gets: the STUN
-- packets a WebRTC connection sends to the server it names.
data Stun = Stun {port :: Int, packets :: IORef Int}

withStun :: (Stun -> IO a) -> IO a
withStun body =
  bracket (Socket.socket Socket.AF_INET Socket.Datagram Socket.defaultProtocol) Socket.close $ \sock -> do
    Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    port <- fromIntegral <$> Socket.socketPort sock
    packets <- newIORef 0
    bracket (forkIO (forever (void (SocketBytes.recv sock 2048) >> atomicModifyIORef' packets (\n -> (n + 1, ()))))) killThread $ \_ ->
      body Stun {port, packets}

svgs :: Smoke -> Playwright -> Elsewhere -> Stun -> IO ()
svgs smoke pw elsewhere stun = do
  space <- asAdmin smoke "POST" "spaces" (Just (object ["parent" .= Null, "name" .= ("Flames" :: Text)])) >>= expectStatus 201 "the space of the SVGs" >>= apiJson
  spaceId <- text (space .! "id")
  let body =
        Text.intercalate
          "\n\n"
          [ "![Where the time goes](attachment:flame.svg){.interactive}"
          , "![hostile](attachment:hostile.svg){.interactive height=160}"
          , "![wander](attachment:wander.svg){.interactive height=120}"
          , "![still](attachment:flame.svg)"
          , "[![linked](attachment:flame.svg){.interactive}](https://example.com/)"
          ]
  made <- asAdmin smoke "POST" ("spaces/" <> escape spaceId <> "/pages") (Just (object ["parent" .= Null, "title" .= ("Profiles" :: Text), "body" .= body])) >>= expectStatus 201 "the page of the SVGs" >>= apiJson
  pageId <- text (made .! "id")
  s <- adminSession smoke
  let uploadSvg name svg = upload smoke.wiki s ("pages/" <> escape pageId <> "/attachments") "file" name "image/svg+xml" (Text.encodeUtf8 svg) [] >>= expectStatus 201 ("uploading " <> Text.unpack name) >>= apiJson
      framed a = do
        aid <- text (a .! "id")
        name <- text (a .! "name")
        pure ("/api/v1/attachments/" <> escape aid <> "/" <> escape name <> "?interactive")
  flame <- uploadSvg "flame.svg" flameSvg >>= framed
  hostile <- uploadSvg "hostile.svg" (hostileSvg elsewhere.origin stun.port) >>= framed
  _ <- uploadSvg "wander.svg" wanderSvg
  -- To a visitor, no form of a private space's SVG.
  (.status) <$> get smoke.wiki Nothing hostile `shouldReturn` 404
  let path = "/s/flames/p/profiles/"
      flameIn scope = locator (inFrame scope "iframe.wiki-svg[title='Where the time goes']") "#status"

  inBrowser smoke pw Admin $ \page -> do
    loads <- holdLoads page
    loaded <- loadAdopted smoke loads page path
    loaded.status `shouldBe` Just 200
    loaded.repairs `shouldBe` []
    let frames' = locator page "#app .page-body .svg-frame iframe.wiki-svg"
    count frames' `shouldReturn` 3
    attributes :: [(Maybe Text, Maybe Text)] <- evaluateAll frames' "(all) => all.map((f) => [f.getAttribute('sandbox'), f.getAttribute('src')])" ()
    forM_ attributes $ \(sandbox, src) -> do
      sandbox `shouldBe` Just "allow-scripts"
      expect (maybe False ("?interactive" `Text.isSuffixOf`) src) ("a frame's address: " <> show src)
    getAttribute (locator page "#app .page-body img[alt=still]") "src" `shouldReturn` Just (Text.replace "?interactive" "" (Text.drop 1 flame))
    -- In a link's text, the image, which the page adopted unchanged.
    count (locator page "#app .page-body a[href='https://example.com/'] > img[alt=linked]") `shouldReturn` 1

    -- A click in the flame graph changes it: its script ran. The frame's
    -- own script: conditions.
    _ <- awaitText (flameIn page) (== "ready")
    click (locator (inFrame page "iframe.wiki-svg[title='Where the time goes']") "#child rect")
    _ <- awaitText (flameIn page) (== "zoomed child")

    -- What the hostile SVG found it could do, written into its own text,
    -- which the suite reads in the frame, since the SVG cannot tell the
    -- page; once it says it is done.
    reportText <- awaitText (locator (frameAt page "**/hostile.svg*") "#report") (\t -> "\"done\":\"true\"" `Text.isInfixOf` t)
    inFrame' <- either (fail . ("the hostile SVG's report: " <>)) pure (Aeson.eitherDecodeStrict (Text.encodeUtf8 reportText)) :: IO (Map Text Text)
    let told k = Map.findWithDefault "" k inFrame'
    told "script" `shouldBe` "ran"
    told "framed" `shouldBe` "true"
    told "origin" `shouldBe` "null"
    told "cookie" `shouldBe` "threw SecurityError"
    told "localStorage" `shouldBe` "threw SecurityError"
    told "parent" `shouldBe` "threw SecurityError"
    told "top" `shouldBe` "threw SecurityError"
    told "open" `shouldBe` "null"
    expect ("failed" `Text.isPrefixOf` told "fetchWiki") ("the wiki's API, from the frame: " <> show (told "fetchWiki"))
    expect ("failed" `Text.isPrefixOf` told "fetchElsewhere") ("another site, from the frame: " <> show (told "fetchElsewhere"))
    expect (any (`Text.isPrefixOf` told "xhr") ["failed", "threw"]) ("another site by XMLHttpRequest, from the frame: " <> show (told "xhr"))
    expect (any (`Text.isPrefixOf` told "socket") ["failed", "threw"]) ("a WebSocket, from the frame: " <> show (told "socket"))
    -- WebRTC is not stopped, by the sandbox or by the policy's webrtc
    -- 'block', which Chromium does not know: what the frame sent the STUN
    -- server it named is recorded, not refused (Wiki.Core.Markdown.Frame).
    -- Nothing is asserted of it, so nothing is waited for: the count is
    -- what had arrived when the report was read.
    stunPackets <- readIORef stun.packets
    report ("the hostile SVG's WebRTC connection: " <> told "webrtc" <> ", and " <> tshow stunPackets <> " STUN packets had reached the host it named")
    -- Its report is done, so every attempt has been made: the page did
    -- not navigate, and no dialog was shown (a tab opened would have
    -- reached the other site, which is checked at the end).
    here page `shouldReturn` path
    dialogs page `shouldReturn` []

    -- The SVG that navigates its frame to the wiki's API finds itself
    -- signed out there: the cookie is not sent from the frame. The frame's
    -- navigation, then its document: conditions.
    sessionThere <- innerText (locator (frameAt page "**/api/v1/session") "body")
    there <- either (fail . ("the session's answer in the frame: " <>)) pure (Aeson.eitherDecodeStrict (Text.encodeUtf8 sessionThere)) :: IO Value
    there .! "user" `shouldBe` Null

    -- Adopting the page loaded no frame twice, and a render after it (the
    -- page laid out at full width, and back) loads none again.
    click (locator page "#app .page-width-option-full")
    click (locator page "#app .page-width-option-compact")
    frameLoads page `shouldReturn` [1, 1, 1]

    -- The frames made by the program rather than the server, which the
    -- island gives their address: in the editor's preview, then in the
    -- page reached from the editor. Each shown once is loaded once. A
    -- frame's load is its own: the counts are conditions.
    click (locator page "#app .page-actions a[href$='/profiles/edit/']")
    waitQuiet page
    editorReady page
    entriesBefore :: Int <- evaluate page "history.length"
    click (locator page "#app .editor-show-preview")
    _ <- awaitText (flameIn (locator page "#app .editor-preview")) (== "ready")
    eventually page (frameLoads page `shouldReturn` [2, 2, 2])
    -- Back to the Markdown, over the preview's entry of the history and
    -- the one the wandering SVG's frame made when it navigated (see the
    -- module's head): the frame's navigation first, a condition.
    eventually page (frames page >>= \fs -> expect (any ("/api/v1/session" `Text.isSuffixOf`) fs) "the preview's wandering frame has not navigated yet")
    entriesNow :: Int <- evaluate page "history.length"
    entriesNow - entriesBefore `shouldBe` 2
    report "the preview's history: its own entry, and the wandering frame's navigation after it"
    _ :: Value <- evaluate page "(() => { history.go(-2); return null; })()"
    -- The page's popstate, which the history's traversal fires, brings
    -- the text back: the program's, once the event has come.
    waitFor (editorText page) Visible
    settle page
    count (locator page "#app .editor-preview iframe.wiki-svg") >>= \n -> expect (n == 0 || n == 3) "the preview's frames"
    click (locator page "#app .editor-cancel")
    waitQuiet page
    expect' (count (locator page "#app .page-view .page-body .svg-frame")) (> 0) "no frame in the page reached from the editor"
    _ <- awaitText (flameIn (locator page "#app .page-view")) (== "ready")
    eventually page (frameLoads page `shouldReturn` [3, 3, 3])

    -- The same address opened by itself in a tab of the signed-in browser,
    -- just after its frames loaded: the plain answer, a download, in which
    -- nothing runs, though the browser's cache holds the frame's.
    opened smoke.origin page hostile `shouldReturn` "hostile.svg"

  -- The other order, in a browser of its own: the tab first, a download,
  -- and then the page, whose frame runs the SVG all the same.
  inBrowser smoke pw Admin $ \tabFirst -> do
    opened smoke.origin tabFirst flame `shouldReturn` "flame.svg"
    visit tabFirst (address smoke path)
    _ <- awaitText (flameIn (locator tabFirst "#app .page-view")) (== "ready")
    pure ()

  -- With the service worker on, as a reader's browser has it, the frame
  -- of a private space's SVG loads and runs, with the session's cookie.
  withContext pw defaultContextOptions $ \workerContext -> do
    addCookies workerContext [sessionCookie smoke.origin s]
    workerPage <- newPage workerContext
    withFailureContext workerPage $ do
      visit workerPage (address smoke path)
      -- The worker taking the page over: its own, a condition.
      holdsInPage workerPage "navigator.serviceWorker.controller !== null"
      visit workerPage (address smoke path)
      _ <- awaitText (flameIn (locator workerPage "#app .page-view")) (== "ready")
      -- The server out of reach while the browser still has a network (a
      -- VPN gone down): the worker serves the page it kept, which shows the
      -- image where the frame was, since the worker cannot serve the frame.
      unreachable <- route workerContext (smoke.origin <> "/**") (\_ -> pure (Abort "connectionrefused"))
      reload workerPage
      evaluate workerPage "navigator.onLine" `shouldReturn` True
      count (locator workerPage "head meta[name=wiki-offline-copy]") `shouldReturn` 1
      waitStarted workerPage
      waitQuiet workerPage
      count (locator workerPage "#app .page-body img[alt='Where the time goes']") `shouldReturn` 1
      count (locator workerPage "#app .page-body iframe.wiki-svg") `shouldReturn` 0
      unroute unreachable
      -- Offline, the same.
      setOffline workerContext True
      reload workerPage
      waitStarted workerPage
      waitQuiet workerPage
      count (locator workerPage "#app .page-body img[alt='Where the time goes']") `shouldReturn` 1
      count (locator workerPage "#app .page-body iframe.wiki-svg") `shouldReturn` 0
      nothingThrown workerPage

  -- Another site's page that frames the SVG, made public for it: its
  -- frame load asks as a frame, and the answer's frame-ancestors 'self'
  -- refuses to be shown there.
  _ <- asAdmin smoke "PUT" ("spaces/" <> escape spaceId <> "/public") (Just (object ["public" .= True])) >>= expectStatus 200 "the space of the SVGs made public"
  writeIORef elsewhere.framing ("<iframe sandbox=\"allow-scripts\" src=\"" <> address smoke flame <> "\"></iframe>")
  withContext pw defaultContextOptions $ \outsiderContext -> do
    outsider <- newPage outsiderContext
    withFailureContext outsider $ do
      goto outsider (elsewhere.origin <> "/framing")
      -- Refused by the browser, which shows its error page in the frame's
      -- place: the frame's document, a condition.
      eventually outsider $ do
        fs <- drop 1 <$> frames outsider
        length fs `shouldBe` 1
        expect (all ("chrome-error:" `Text.isPrefixOf`) fs) ("another site's frame of the SVG: " <> show fs)
      count (locator (frameAt outsider "chrome-error:**") "#status") `shouldReturn` 0

  -- Over plain HTTP to a host that is not the loopback one, the page is no
  -- secure context and the browser names no frame's load to the server:
  -- the program shows the image in the frame's place (a repair of the page
  -- the server prerendered with the frame). A browser of its own, which
  -- sends that host to the loopback.
  options <- optionsFromEnvironment
  let port = Text.takeWhileEnd (/= ':') smoke.origin
  withPlaywright options {browserArgs = ["--host-resolver-rules=MAP wiki.example.test 127.0.0.1"]} $ \insecure ->
    withContext insecure defaultContextOptions $ \ctx -> do
      reader <- newPage ctx
      withFailureContext reader $ do
        visit reader ("http://wiki.example.test:" <> port <> path)
        evaluate reader "window.isSecureContext" `shouldReturn` False
        waitQuiet reader
        count (locator reader "#app .page-body img[alt='Where the time goes']") `shouldReturn` 1
        count (locator reader "#app .page-body iframe.wiki-svg") `shouldReturn` 0
        nothingThrown reader

  -- No frame reached the other site: no request, no image, no beacon, no
  -- form, no popup, no navigation.
  readIORef elsewhere.reached `shouldReturn` []
  where
    expect' get' holds message = get' >>= \v -> expect (holds v) message

-- | How many times each interactive frame's address was loaded in the
-- page's browser so far, in the order they were first loaded.
frameLoads :: Page -> IO [Int]
frameLoads page = do
  asked <- filter ("?interactive" `Text.isInfixOf`) . map (.url) <$> requests (pageContext page)
  pure [length (filter (== u) asked) | u <- nub asked]

-- | The address opened by itself in a new tab of the page's browser: a
-- download, whose suggested name this is.
opened :: Text -> Page -> Text -> IO Text
opened address' page path = do
  tab <- newPage (pageContext page)
  got <- download tab (goto tab (address' <> path))
  closePage tab
  pure got.suggestedFilename

-- | A flame graph's shape, as flamegraph.pl and inferno write one: frames
-- that zoom on a click, through the SVG's own script and handlers.
flameSvg :: Text
flameSvg =
  Text.unlines
    [ "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"120\" onload=\"init()\">"
    , "<script><![CDATA["
    , "function init() { document.getElementById(\"status\").textContent = \"ready\"; }"
    , "function zoom(g) { g.querySelector(\"rect\").setAttribute(\"width\", \"600\"); document.getElementById(\"status\").textContent = \"zoomed \" + g.id; }"
    , "]]></script>"
    , "<text id=\"status\" x=\"4\" y=\"16\">not run</text>"
    , "<g id=\"main\" onclick=\"zoom(this)\"><rect x=\"0\" y=\"80\" width=\"400\" height=\"20\" fill=\"orange\"/><text x=\"4\" y=\"94\">main</text></g>"
    , "<g id=\"child\" onclick=\"zoom(this)\"><rect x=\"0\" y=\"58\" width=\"150\" height=\"20\" fill=\"tomato\"/><text x=\"4\" y=\"72\">child</text></g>"
    , "</svg>"
    ]

-- | An SVG that navigates its own frame to the wiki's API, which then
-- answers without the session's cookie, as it answers any other site.
wanderSvg :: Text
wanderSvg = "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"setTimeout(function () { location.href = '/api/v1/session'; }, 50)\"><text y=\"16\">leaving</text></svg>"

-- | An SVG that tries every way out of its frame and writes what happened
-- into its own text. The other site is the address of a server that counts
-- what reaches it, and the port of a UDP socket that counts the STUN
-- packets a WebRTC connection sends there.
hostileSvg :: Text -> Int -> Text
hostileSvg elsewhere stunPort =
  Text.replace "ELSEWHERE" elsewhere . Text.replace "ELSEWHERE_WS" (Text.replace "http:" "ws:" elsewhere) . Text.replace "STUN_PORT" (tshow stunPort) $
    Text.unlines
      [ "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"200\" onload=\"tryAll()\">"
      , "<script><![CDATA["
      , "var told = {};"
      , "function tell(k, v) { told[k] = String(v); document.getElementById(\"report\").textContent = JSON.stringify(told); }"
      , "function attempt(k, f) { try { tell(k, f()); } catch (e) { tell(k, \"threw \" + e.name); } }"
      , "function settle(k, p) { return p.then(function (r) { tell(k, \"answered \" + (r && r.status)); }, function (e) { tell(k, \"failed \" + e.name); }); }"
      , "function tryAll() {"
      , "  tell(\"script\", \"ran\");"
      , "  attempt(\"origin\", function () { return window.origin; });"
      , "  attempt(\"cookie\", function () { return JSON.stringify(document.cookie); });"
      , "  attempt(\"localStorage\", function () { return localStorage.length; });"
      , "  var framed = window.top !== window;"
      , "  tell(\"framed\", framed);"
      , "  if (framed) {"
      , "    attempt(\"parent\", function () { return parent.document.title; });"
      , "    attempt(\"top\", function () { top.location.href = \"ELSEWHERE/top\"; return \"navigated\"; });"
      , "  }"
      , "  attempt(\"open\", function () { return window.open(\"ELSEWHERE/popup\"); });"
      , "  attempt(\"alert\", function () { alert(\"from the SVG\"); return \"returned\"; });"
      , "  attempt(\"form\", function () {"
      , "    var f = document.createElementNS(\"http://www.w3.org/1999/xhtml\", \"form\");"
      , "    f.action = \"ELSEWHERE/form\"; document.documentElement.appendChild(f); f.submit(); return \"submitted\";"
      , "  });"
      , "  attempt(\"beacon\", function () { return navigator.sendBeacon(\"ELSEWHERE/beacon\", \"x\"); });"
      , "  attempt(\"webrtc\", function () {"
      , "    var pc = new RTCPeerConnection({ iceServers: [{ urls: \"stun:127.0.0.1:STUN_PORT\" }] });"
      , "    pc.createDataChannel(\"out\");"
      , "    pc.createOffer().then(function (o) { return pc.setLocalDescription(o); });"
      , "    return \"constructed\";"
      , "  });"
      , "  var img = document.createElementNS(\"http://www.w3.org/2000/svg\", \"image\");"
      , "  img.setAttribute(\"href\", \"ELSEWHERE/image\"); document.documentElement.appendChild(img);"
      , "  var waits = ["
      , "    settle(\"fetchWiki\", fetch(\"/api/v1/session\")),"
      , "    settle(\"fetchElsewhere\", fetch(\"ELSEWHERE/fetch\")),"
      , "    new Promise(function (done) {"
      , "      try {"
      , "        var x = new XMLHttpRequest(); x.open(\"GET\", \"ELSEWHERE/xhr\");"
      , "        x.onload = function () { tell(\"xhr\", \"answered \" + x.status); done(); };"
      , "        x.onerror = function () { tell(\"xhr\", \"failed\"); done(); };"
      , "        x.send();"
      , "      } catch (e) { tell(\"xhr\", \"threw \" + e.name); done(); }"
      , "    }),"
      , "    new Promise(function (done) {"
      , "      try {"
      , "        var w = new WebSocket(\"ELSEWHERE_WS/socket\");"
      , "        w.onopen = function () { tell(\"socket\", \"opened\"); done(); };"
      , "        w.onerror = function () { tell(\"socket\", \"failed\"); done(); };"
      , "      } catch (e) { tell(\"socket\", \"threw \" + e.name); done(); }"
      , "    })"
      , "  ];"
      , "  Promise.all(waits).then(function () { tell(\"done\", true); });"
      , "}"
      , "]]></script>"
      , "<text id=\"report\" x=\"4\" y=\"16\" font-size=\"10\">not run</text>"
      , "</svg>"
      ]
