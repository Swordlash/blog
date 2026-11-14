-- | The canary of encrypted spaces (WP5.74 of docs/PLAN.md, decision 76):
-- marker strings that the suite writes into what an encrypted space
-- protects, and the check that none of them is found where the server
-- keeps or sends anything.
--
-- A marker is the word "canary", the place it was put in (a title, a
-- text, an older version) and a random part of this run's, so that a
-- marker found says which place leaked, and no other text of the suite can
-- hold one by chance. A part of the suite that protects a new place adds a
-- marker for it with 'marker', writes it there through the application,
-- and the one check below covers it.
--
-- The check reads, as bytes, for every marker:
--
-- * every file of the server's data directory, recursively: the SQLite
--   database with its write-ahead log, the attachments' files, the
--   backups;
-- * on PostgreSQL, a dump of the database's data (@pg_dump@, the program
--   the server's backups run);
-- * every request a watched browser sent, its address and its body, as a
--   route of the context's sees it ('watch'), and every frame of its pages'
--   WebSockets, both ways ('watchPage'): what the server was given, and
--   what it pushed to anyone;
-- * what the server answers: every @GET@ a watched browser made of the
--   server, asked again by the suite when the check is made, as whoever
--   the browser was signed in as when it asked ('watch'); for the
--   conversion's check, each such request since the conversion asked
--   again as each of the walk's users and as nobody;
-- * every answer the suite read from the server itself ('saw'), its
--   writes' answers among them.
--
-- The answers the browsers received are not read as they came: the
-- driver gives a route the request on its way and no answer, and delivers
-- no event of the DevTools protocol, so @Network.getResponseBody@, which
-- needs the id an event gives, cannot be asked. The question the canary
-- asks of an answer is whether the server gives out a marker; asked again
-- at the check, a @GET@ answers it for what the server holds then, which
-- for the conversion's check is the very question (a copy of plain text
-- still kept in a cache, an index or a compressed file of the server's
-- shows in an answer and not in a file). The answers to the browsers'
-- writes (@POST@, @PUT@) are not asked again: a write is not repeated.
module Server.Canary
  ( Canary
  , newCanary
  , marker
  , plainMarker
  , watch
  , Watched
  , watchPage
  , unwatchPage
  , saw
  , Since
  , since
  , Checked (..)
  , assertNoCanary
  , assertGone
  )
where

import Control.Exception (try)
import Control.Monad (forM, unless, when)
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Halogen.Playwright
import Halogen.Playwright.Hspec
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.Process.Typed qualified as Process
import Wiki.Smoke.Api (Reply (..), Session (..), Wiki (..), get)
import Wiki.Smoke.Server (Database (..))

-- | The run's markers and everything seen so far.
data Canary = Canary
  { run :: Text
  , markers :: IORef [(Text, Text)]
  -- ^ Each place and its marker, in the order they were made.
  , seen :: IORef (Seq Place)
  , pages :: IORef [(Int, Page, Int)]
  -- ^ The watched pages still open, by a number of their own, and how many
  -- of each one's frames are already in 'seen'.
  , next :: IORef Int
  , asked :: IORef (Seq BrowserRequest)
  -- ^ Every request the watched browsers made of the server, oldest
  -- first.
  , wiki :: Wiki
  }

-- | A request a watched browser made of the server: its method, its
-- address, and whose session the browser had when it asked.
data BrowserRequest = BrowserRequest {method :: Text, url :: Text, who :: Maybe Session}

-- | A page watched, to stop watching it.
newtype Watched = Watched Int

-- | Something seen: what it was, and its bytes.
data Place = Place {what :: Text, bytes :: ByteString}

-- | A canary for the server the suite drives.
newCanary :: Wiki -> IO Canary
newCanary wiki = do
  run <- Text.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 6 :: IO ByteString)
  markers <- newIORef []
  seen <- newIORef Seq.empty
  pages <- newIORef []
  next <- newIORef 0
  asked <- newIORef Seq.empty
  pure Canary {run, markers, seen, pages, next, asked, wiki}

-- | The marker for a place, made the first time it is asked for.
marker :: Canary -> Text -> IO Text
marker c place = atomicModifyIORef' c.markers $ \ms -> case lookup place ms of
  Just m -> (ms, m)
  Nothing -> let m = "canary-" <> slug place <> "-" <> c.run in (ms <> [(place, m)], m)

-- | A marker of text the suite writes plain on purpose, to be found
-- nowhere once a conversion has encrypted it: not one of the markers
-- above, whose check covers every request since the start, which carried
-- this one plain before the conversion.
plainMarker :: Canary -> Text -> Text
plainMarker c place = "plaincanary-" <> slug place <> "-" <> c.run

-- | The place's name in a marker: letters and digits, the rest a dash.
slug :: Text -> Text
slug = Text.intercalate "-" . filter (not . Text.null) . Text.split (\ch -> not (ch `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'])))

-- | Record every request the context's pages send, its address and its
-- body, as a route of the context's sees it on its way, and let it go on.
-- An object URL (@blob:@) is the browser's own memory, never the network,
-- and passes no route: the decrypted bytes of an encrypted attachment are
-- read from one. Each request of the server's is also kept with the
-- session the context had when it was made (its @wiki_session@ cookie, which
-- a route is not shown), to be asked again at a check.
watch :: Canary -> Context -> IO ()
watch c ctx = do
  _ <- route ctx "**" $ \request -> do
    add c ("request " <> request.method <> " " <> request.url) (Text.encodeUtf8 request.url <> fromMaybe "" request.postData)
    when ((c.wiki.origin <> "/") `Text.isPrefixOf` request.url) $ do
      jar <- try (cookies ctx)
      let who = case jar of
            Right cs -> (\k -> Session k.value) <$> find (\k -> k.name == "wiki_session") cs
            Left (_ :: PlaywrightError) -> Nothing
      atomicModifyIORef' c.asked (\a -> (a |> BrowserRequest {method = request.method, url = request.url, who}, ()))
    pure Continue
  pure ()

-- | Keep the frames of the page's WebSockets, both ways, for the check:
-- they are read from the page when it is closed ('unwatchPage') and when a
-- check is made.
watchPage :: Canary -> Page -> IO Watched
watchPage c page = do
  n <- atomicModifyIORef' c.next (\k -> (k + 1, k))
  atomicModifyIORef' c.pages (\ps -> (ps <> [(n, page, 0)], ()))
  pure (Watched n)

-- | Take the page's frames into what was seen, and stop watching it,
-- before it is closed.
unwatchPage :: Canary -> Watched -> IO ()
unwatchPage c (Watched n) = do
  collect c
  atomicModifyIORef' c.pages (\ps -> (filter (\(k, _, _) -> k /= n) ps, ()))

-- | Something the suite read from the server itself.
saw :: Canary -> Text -> ByteString -> IO ()
saw = add

add :: Canary -> Text -> ByteString -> IO ()
add c what bytes = atomicModifyIORef' c.seen (\s -> (s |> Place {what, bytes}, ()))

-- | The frames of every watched page that are not in 'seen' yet.
collect :: Canary -> IO ()
collect c = do
  ps <- readIORef c.pages
  updated <- forM ps $ \(n, page, taken) -> do
    frames' <- webSocketFrames page
    let new = drop taken frames'
    mapM_ (\f -> add c ((if f.sent then "frame sent on " else "frame received on ") <> f.url) (Text.encodeUtf8 f.payload)) new
    pure (n, page, taken + length new)
  atomicModifyIORef' c.pages (const (updated, ()))

-- | Where a later check starts: what was seen, and asked, so far.
data Since = Since Int Int

since :: Canary -> IO Since
since c = do
  collect c
  Since <$> (Seq.length <$> readIORef c.seen) <*> (Seq.length <$> readIORef c.asked)

-- | The server's answers to the watched browsers' @GET@s since a point,
-- asked again now: as whoever each browser was signed in as, or, when
-- sessions are given, as each of them.
answers :: Canary -> Int -> Maybe [Maybe Session] -> IO [Place]
answers c from as' = do
  gets <- filter (\a -> a.method == "GET") . toList . Seq.drop from <$> readIORef c.asked
  fmap concat . forM gets $ \a ->
    forM (maybe [a.who] id as') $ \who -> do
      r <- get c.wiki who a.url
      pure Place {what = "answer to GET " <> a.url <> " (asked again" <> maybe ", as nobody" (const "") who <> ")", bytes = r.body}

-- | What a check read: how many markers, in how many places.
data Checked = Checked
  { markers :: Int
  , places :: Int
  , kinds :: [(Text, Int)]
  -- ^ How many places of each kind: files, the database's dump, requests,
  -- frames, and what the suite read itself.
  }

-- | Fail, naming each marker and where it was found, if any marker made so
-- far is in the data directory, the database or what was seen. The
-- markers are first checked to be in the text the suite read back in the
-- browsers, so that a check that finds nothing is a check of text that was
-- really written.
assertNoCanary :: Canary -> FilePath -> Database -> Text -> IO Checked
assertNoCanary c dataDir database shown = do
  ms <- map snd <$> readIORef c.markers
  unless (not (null ms)) $ expectationFailure "no marker was made"
  let unread = filter (not . (`Text.isInfixOf` shown)) ms
  unless (null unread) $ expectationFailure ("markers not read back in the browser: " <> show unread)
  collect c
  ps <- places dataDir database (const False) (Since 0 0) Nothing c
  leaks ms ps "a marker of an encrypted space was found in plain text"
  pure Checked {markers = length ms, places = length ps, kinds = kindsOf ps}

-- | Fail, naming each marker and where it was found, if a marker given is
-- in a file of the data directory but those left out, in the database's
-- dump, in what was seen since the point given, or in the server's
-- answers to the browsers' @GET@s since then, asked again as each of the
-- sessions given (a 'Nothing' for nobody). What was read, by kind.
assertGone :: Canary -> FilePath -> Database -> [Text] -> Since -> (FilePath -> Bool) -> [Maybe Session] -> IO Checked
assertGone c dataDir database ms from leftOut sessions = do
  collect c
  ps <- places dataDir database leftOut from (Just sessions) c
  leaks ms ps "a marker of a space encrypted by a conversion was found in plain text"
  pure Checked {markers = length ms, places = length ps, kinds = kindsOf ps}

places :: FilePath -> Database -> (FilePath -> Bool) -> Since -> Maybe [Maybe Session] -> Canary -> IO [Place]
places dataDir database leftOut (Since from fromAsked) sessions c = do
  files <- filter (not . leftOut) <$> filesUnder dataDir
  fileBytes <- forM files $ \f -> Place ("the file " <> Text.pack f) <$> ByteString.readFile f
  dump <- case database of
    SQLite -> pure []
    PostgreSQL {url = databaseUrl, pgDump} -> do
      let program = if Text.null pgDump then "pg_dump" else Text.unpack pgDump
      out <- Process.readProcessStdout_ (Process.proc program ["--data-only", "--inserts", Text.unpack databaseUrl])
      pure [Place "the database's dump" (LazyByteString.toStrict out)]
  seen' <- toList . Seq.drop from <$> readIORef c.seen
  answered <- answers c fromAsked sessions
  pure (fileBytes <> dump <> seen' <> answered)

-- | How many places of each kind there are, by the first word of what
-- each is: @the file@, @the database's dump@, @request@, @answer@,
-- @frame@ (sent or received), and
-- anything else the suite read itself.
kindsOf :: [Place] -> [(Text, Int)]
kindsOf ps = [(k, length (filter ((== k) . kind) ps)) | k <- ["files", "the database's dump", "requests", "answers", "frames sent", "frames received", "read by the suite"], any ((== k) . kind) ps]
  where
    kind p
      | "the file " `Text.isPrefixOf` p.what = "files"
      | "the database's dump" == p.what = "the database's dump"
      | "request " `Text.isPrefixOf` p.what = "requests"
      | "answer " `Text.isPrefixOf` p.what = "answers"
      | "frame sent " `Text.isPrefixOf` p.what = "frames sent"
      | "frame received " `Text.isPrefixOf` p.what = "frames received"
      | otherwise = "read by the suite"

leaks :: [Text] -> [Place] -> String -> IO ()
leaks ms ps message = do
  let found = [m <> " in " <> p.what | m <- ms, p <- ps, Text.encodeUtf8 m `ByteString.isInfixOf` p.bytes]
  unless (null found) $ expectationFailure (message <> ":\n" <> unlines (map Text.unpack found))

filesUnder :: FilePath -> IO [FilePath]
filesUnder dir = do
  names <- listDirectory dir
  concat
    <$> forM
      names
      ( \n -> do
          let path = dir </> n
          isDir <- doesDirectoryExist path
          isFile <- doesFileExist path
          if isDir then filesUnder path else pure [path | isFile]
      )
