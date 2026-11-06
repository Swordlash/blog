-- | The page step of a deploy whose page CI built: the page from GitHub
-- (@--backend-only[=REF]@) or from a file (@--app-page FILE@), through the
-- page cache, unpacked into the deploy's page directory (@out@).
--
-- CI (@.github/workflows/server-page.yml@) builds the server's page and the
-- demo's and keeps each as a zip of the page's directory, a release asset:
-- @app-server-<hash>.zip@ and @app-demo-<hash>.zip@ on the pre-release
-- @main-latest@ for each of main's newest five commits, and
-- @app-server-<tag>.zip@ and @app-demo-<tag>.zip@ on a tag's release.
-- Release assets of a public repository need no token, unlike a workflow's
-- artifacts. The list of a release's assets comes from api.github.com, the
-- zip from github.com.
--
-- The step sets @backend_only_commit@, the commit the page was built from
-- (empty when it cannot be told), which the state keeps. It is
-- @toolchain/deploy-local.sh@'s @page_source@ and @download_page@, with
-- their messages; the shell keeps the check of an @--app-page@ file given
-- now that is not there, which runs before the toolchain.
module Maker.Deploy.Page
  ( pageStep
  , Asset (..)
  , repoOf
  , isCode
  , tagAsset
  , parseAssets
  , newestCommitAsset
  , pruneOrder
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isDigit, isHexDigit, toLower)
import Data.Foldable (toList)
import Data.IORef
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (pageBackend)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (exitWith)
import System.FilePath (takeDirectory, (</>))
import System.IO
import System.Process.Typed

-- | Download or take the page when the deploy builds and its page is one
-- CI built, and answer the plan with the page's commit and the place of
-- CI's copy of the page, which @--bundle-locally@ compares with.
pageStep :: Plan -> IO Plan
pageStep p0 = do
  let p = set "ci_page" (get p0 "root" </> "dist-newstyle" </> "wasm-opt" </> "ci-page") p0
  if has p "build" && has p "prebuilt"
    then do
      source <- if has p "app_page" then pure (appPageSource p) else resolvePage p
      either die pure source >>= \s -> do
        downloadPage p s
        pure (set "backend_only_commit" s.commit p)
    else pure p

-- | The page the deploy takes: where it is on GitHub (or the file), and
-- what is known of it.
data Source = Source
  { repo :: String
  -- ^ owner/repo on GitHub, empty for a file.
  , tag :: String
  -- ^ The release, or the file's path.
  , asset :: String
  -- ^ The zip's name: the release asset, or the file's name.
  , commit :: String
  -- ^ The commit the page was built from, empty when unknown.
  , meta :: String
  -- ^ The asset's identity on GitHub (@id=… updated_at=… size=…@), which
  -- the page cache keeps beside the zip; for a file, @file=<its path>@.
  , words_ :: String
  -- ^ What the deploy calls a page from a file.
  }

-- | A release's asset as api.github.com lists it: its name, the time it was
-- uploaded at (@-@ when GitHub gives none), its size in bytes and GitHub's
-- id for it. A replaced asset gets a new id and time.
data Asset = Asset {name :: String, time :: String, size :: String, assetId :: String}
  deriving (Eq, Show)

-- | The deploy's page directory and the page's kind (@server@ or @demo@).
kindOf :: Plan -> String
kindOf p = get p "page_kind"

-- | Whether an asset name is a commit's page of a kind:
-- @app-<kind>-<40 hex digits>.zip@.
commitAsset :: String -> String -> Maybe String
commitAsset kind n = do
  rest <- stripPrefix' ("app-" <> kind <> "-") n
  hash <- stripSuffix' ".zip" rest
  if length hash == 40 && all isLowerHex hash then Just hash else Nothing

isLowerHex :: Char -> Bool
isLowerHex c = isDigit c || c `elem` ['a' .. 'f']

stripPrefix' :: String -> String -> Maybe String
stripPrefix' pre s = if pre `isPrefixOf` s then Just (drop (length pre) s) else Nothing

stripSuffix' :: String -> String -> Maybe String
stripSuffix' suf s = if suf `isSuffixOf` s then Just (take (length s - length suf) s) else Nothing

-- | A command's output without its trailing newlines, as the shell's
-- @$(…)@ gives it.
chomp :: String -> String
chomp = reverse . dropWhile (== '\n') . reverse

-- | owner/repo of a GitHub repository's address, in its https or ssh form,
-- or why it is not one.
repoOf :: String -> Either String String
repoOf origin
  | onGitHub = case repo3 of
      r
        | null r || "/" `isPrefixOf` r || "/" `isSuffixOf` r || length (filter (== '/') r) >= 2 -> cannotTell
        | '/' `elem` r -> Right r
        | otherwise -> cannotTell
  | otherwise = Left ("origin is " <> origin <> ", not a repository on GitHub: --backend-only downloads the page from the GitHub repository origin names")
  where
    cannotTell = Left ("cannot tell the GitHub repository from origin's address " <> origin)
    onGitHub =
      any (`isPrefixOf` origin) ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/", "ssh://git@github.com:"]
        || maybe False ("@github.com/" `isInfixOf`) (stripPrefix' "https://" origin)
    -- \${origin#*github.com}, one leading : or /, one trailing /, a .git.
    afterHost = dropThrough "github.com" origin
    repo1 = case afterHost of
      c : rest | c `elem` [':', '/'] -> rest
      other -> other
    repo2 = fromMaybe repo1 (stripSuffix' "/" repo1)
    repo3 = fromMaybe repo2 (stripSuffix' ".git" repo2)
    dropThrough needle s
      | needle `isPrefixOf` s = drop (length needle) s
      | otherwise = case s of
          [] -> []
          _ : rest -> dropThrough needle rest

-- | Whether a file of the repository is code: something the page or the
-- server is built from. Markdown files are documentation, except the
-- Markdown compiled into the programs: wiki-core's built-in templates, and
-- its Markdown reference, which is docs/markdown.md through a symbolic link
-- in wiki-core/reference (a change to the reference changes
-- docs/markdown.md, not the link). The @paths@ filters of
-- .github/workflows/build.yml and server-page.yml must say the same, since
-- CI builds a page only for a commit that changes code. build.yml also runs
-- on changelog/, whose entries wiki-server embeds but the page is not built
-- from: a commit that changes entries alone has no page of its own, and the
-- page of the commit before it is the one to download.
isCode :: FilePath -> Bool
isCode f
  | any (`isPrefixOf` f) ["wiki-core/templates/", "wiki-core/reference/"] || f == "docs/markdown.md" = True
  | ".md" `isSuffixOf` f = False
  | otherwise = True

-- | The asset name of a tag's page of a kind: a tag may hold a slash, an
-- asset name not.
tagAsset :: String -> String -> String
tagAsset kind t = "app-" <> kind <> "-" <> map (\c -> if c == '/' then '-' else c) t <> ".zip"

-- | The assets of a release from api.github.com's answer, or 'Nothing' when
-- the answer is not one.
parseAssets :: BS.ByteString -> Maybe [Asset]
parseAssets bytes = case eitherDecodeStrict' bytes of
  Right (Object o) -> Just $ case KeyMap.lookup "assets" o of
    Just (Array as) -> [asset o' | Object o' <- toList as]
    _ -> []
  _ -> Nothing
  where
    field o k = KeyMap.lookup (Key.fromString k) o
    text o k = case field o k of
      Just (String t) | not (T.null t) -> Just (T.unpack t)
      _ -> Nothing
    shown o k = case field o k of
      Just n@(Number _) -> decodeFs (encode n)
      Just (String t) -> T.unpack t
      _ -> "-"
    asset o =
      Asset
        { name = fromMaybe "" (text o "name")
        , time = fromMaybe "-" (maybe (text o "created_at") Just (text o "updated_at"))
        , size = shown o "size"
        , assetId = shown o "id"
        }

-- | The newest commit's page of a kind among a release's assets: by the
-- time each was uploaded at, newest first, as @sort -k 2 -r@ orders the
-- shell's lines.
newestCommitAsset :: String -> [Asset] -> Maybe Asset
newestCommitAsset kind assets =
  listToMaybe (sortOn (Down . key) [a | a <- assets, commitAsset kind a.name /= Nothing])
  where
    key a = (unwords [a.time, a.size, a.assetId], unwords [a.name, a.time, a.size, a.assetId])

-- | The page cache's zips to delete: all but the five newest by
-- modification time, as @ls -t | tail -n +6@ picks them (equal times by
-- name).
pruneOrder :: [(FilePath, UTCTime)] -> [FilePath]
pruneOrder zips = map fst (drop 5 (sortOn (\(f, t) -> (Down t, f)) zips))

-- | Which page @--backend-only=REF@ names.
resolvePage :: Plan -> IO (Either String Source)
resolvePage p = do
  let kind = kindOf p
      root = get p "root"
      pageName = if kind == "server" then "page" else "demo page"
      noPage r = die ("no " <> pageName <> " was built for " <> r <> " on GitHub; push it, or name main, a tag or another hash (main's pages are kept for its newest five commits)")
      git args = outputOf "git" (["-C", root] <> args)
  (originOk, origin) <- git ["remote", "get-url", "origin"]
  unless originOk (die "--backend-only downloads the page from the GitHub repository origin names, and this checkout has no origin (git remote get-url origin)")
  repo <- either die pure (repoOf (chomp origin))
  ref <- case get p "backend_only" of
    r | r `elem` ["head", "HEAD"] -> do
      (ok, out) <- git ["rev-parse", "HEAD"]
      unless ok (die "--backend-only without =REF names this checkout's commit, and git rev-parse HEAD fails here: name main, a tag or a hash")
      pure (chomp out)
    r -> pure r
  let metaOf assets a = case [x | x <- assets, x.name == a] of
        x : _ -> "id=" <> x.assetId <> " updated_at=" <> x.time <> " size=" <> x.size
        [] -> ""
      source t a c assets = Right Source {repo, tag = t, asset = a, commit = c, meta = metaOf assets a, words_ = ""}
      commitIn a = fromMaybe "" (commitAsset kind a)
  if ref == "main"
    then do
      assets <- releaseAssets repo "main-latest"
      case newestCommitAsset kind assets of
        Nothing -> die ("GitHub has no " <> pageName <> " of main yet (the release main-latest has none): CI makes one on the next push to main")
        Just a -> pure (source "main-latest" a.name (commitIn a.name) assets)
    else
      if length ref >= 7 && length ref <= 40 && all isHexDigit ref
        then do
          let lower = map toLower ref
          assets <- releaseAssets repo "main-latest"
          let names = map (.name) assets
          (known, full0) <- git ["rev-parse", "-q", "--verify", lower <> "^{commit}"]
          a <-
            if known
              then do
                let full = chomp full0
                (_, listed) <- git ["rev-list", "--max-count=20", full]
                -- CI builds no page for a commit that changes documentation
                -- alone (isCode), so the newest commit before it that differs
                -- from it in documentation alone has the same page.
                let go [] = noPage lower
                    go (c : cs) = do
                      same <- sameCode root c full
                      if not same
                        then noPage lower
                        else
                          if ("app-" <> kind <> "-" <> c <> ".zip") `elem` names
                            then do
                              unless (c == full) (say (full <> " changes Markdown files alone since " <> c <> ", which has a page on GitHub: taking that one"))
                              pure ("app-" <> kind <> "-" <> c <> ".zip")
                            else go cs
                go (words listed)
              else case [n | n <- names, Just rest <- [stripPrefix' ("app-" <> kind <> "-" <> lower) n], Just more <- [stripSuffix' ".zip" rest], all isLowerHex more] of
                [] -> noPage lower
                [one] -> pure one
                _ -> die (lower <> " is the start of several commits with a page on GitHub: give more of the hash")
          pure (source "main-latest" a (commitIn a) assets)
        else do
          let a = tagAsset kind ref
          assets <- releaseAssets repo ref
          let tagNames = filter (not . null) (map (.name) assets)
          when (null tagNames) (die ("GitHub has no release " <> ref <> " with a page, and " <> ref <> " is neither main nor a commit hash: name main, a tag pushed since CI keeps pages, or a hash"))
          unless (a `elem` tagNames) (die ("the release " <> ref <> " on GitHub has no " <> a <> ": CI attaches it when the tag is pushed"))
          (tagged, c) <- git ["rev-parse", "-q", "--verify", "refs/tags/" <> ref <> "^{commit}"]
          pure (source ref a (if tagged then chomp c else "") assets)

-- | Whether two commits differ in documentation alone (or not at all),
-- which changes nothing the page is built from; 'False' when git does not
-- know one.
sameCode :: FilePath -> String -> String -> IO Bool
sameCode root a b = do
  (ok, changed) <- outputOf "git" ["-C", root, "diff", "--name-only", a, b]
  pure (ok && not (any isCode (filter (not . null) (lines changed))))

-- | The assets of a release, empty when there is no such release. Stops
-- the deploy on any other answer.
releaseAssets :: String -> String -> IO [Asset]
releaseAssets repo release = do
  dir <- getTemporaryDirectory
  (listing, h) <- openBinaryTempFile dir "release.json"
  hClose h
  hFlush stdout
  result <-
    try . readProcessStdout . setStdin nullStream $
      proc "curl" ["-sS", "-L", "--max-time", "60", "--retry", "3", "-H", "Accept: application/vnd.github+json", "-o", listing, "-w", "%{http_code}", "https://api.github.com/repos/" <> repo <> "/releases/tags/" <> release]
  let gone = removeFile listing `orElse` pure ()
  case result of
    Right (ExitSuccess, code) -> case chomp (decodeFs code) of
      "200" -> do
        answer <- BS.readFile listing
        gone
        maybe (die ("could not read the answer of api.github.com about the release " <> release)) pure (parseAssets answer)
      "404" -> gone >> pure []
      other -> gone >> die ("api.github.com answered " <> other <> " about the release " <> release <> " (its rate limit without a token is sixty requests an hour)")
    Right _ -> gone >> die "could not reach api.github.com to find the page (see above)"
    Left (_ :: IOException) -> gone >> die "could not reach api.github.com to find the page (see above)"

-- | Run an action, and another when the first fails with an IO error.
orElse :: IO a -> IO a -> IO a
orElse action fallback = try action >>= either (\(_ :: IOException) -> fallback) pure

-- | The page @--app-page@ names: the zip's name, under which the page cache
-- keeps it; the commit in that name when it follows CI's naming
-- (@app-<kind>-<hash>.zip@), and otherwise none; what the deploy calls the
-- page. A name of CI's that says the other kind of page is refused.
appPageSource :: Plan -> Either String Source
appPageSource p
  | Just named <- namedKind
  , named /= kind =
      Left ("--app-page " <> file <> " is the " <> named <> "'s page, by its name, and this deploy is of the " <> kind <> " (--" <> get p "mode" <> "): give an app-" <> kind <> "-….zip")
  | otherwise =
      Right
        Source
          { repo = ""
          , tag = file
          , asset = a
          , commit = fromMaybe "" c
          , meta = "file=" <> file
          , words_ = maybe ("a page from " <> file) (\h -> "the page of " <> h <> ", from " <> file) c
          }
  where
    kind = kindOf p
    file = get p "app_page"
    a = takeFileNameShell file
    c = commitAsset kind a
    namedKind
      | isZip "app-server-" = Just "server"
      | isZip "app-demo-" = Just "demo"
      | otherwise = Nothing
    isZip pre = pre `isPrefixOf` a && ".zip" `isSuffixOf` a && length a >= length pre + 4

-- | \${file##*/}: what follows the last slash.
takeFileNameShell :: FilePath -> String
takeFileNameShell = reverse . takeWhile (/= '/') . reverse

-- | The page cache: the zips of the pages CI built, downloaded or from a
-- file, under the toolchain directory, or in the user's cache directory
-- when the toolchain is in the home directory.
pageCacheDir :: Plan -> IO FilePath
pageCacheDir p
  | has p "toolchain_home" = pure (get p "toolchain_home" </> ".wiki-toolchain" </> "pages")
  | otherwise = do
      xdg <- lookupEnv "XDG_CACHE_HOME"
      home <- fromMaybe "" <$> lookupEnv "HOME"
      let base = case xdg of
            Just d | not (null d) -> d
            _ -> home </> ".cache"
      pure (base </> "wiki-demo" </> "pages")

-- | The cache entries of the page from a file whose @.meta@ file says its
-- path (@file=<path>@), sorted by name, as the shell's glob lists them.
appPageEntries :: FilePath -> String -> String -> IO [FilePath]
appPageEntries cache kind meta = do
  names <- listDirectory cache `orElse` pure []
  let metas = sort [cache </> n | n <- names, ("app-" <> kind <> "-file-") `isPrefixOf` n, ".zip.meta" `isSuffixOf` n]
  concat
    <$> mapM
      ( \m -> do
          let zipFile = take (length m - length (".meta" :: String)) m
          isMeta <- doesFileExist m
          isZip <- doesFileExist zipFile
          said <- if isMeta && isZip then readMeta m else pure Nothing
          pure [zipFile | said == Just meta]
      )
      metas

-- | A @.meta@ file's line, 'Nothing' when it cannot be read.
readMeta :: FilePath -> IO (Maybe String)
readMeta file = (Just . chomp . decodeFs . LBS.fromStrict <$> BS.readFile file) `orElse` pure Nothing

-- | Mark a cache entry as used now.
touch :: FilePath -> IO ()
touch file = (getCurrentTime >>= setModificationTime file) `orElse` pure ()

-- | Run a command with the terminal's output; on failure the deploy stops
-- with its status, as a failed command does under @set -e@.
orExit :: FilePath -> [String] -> IO ()
orExit program args = do
  code <- runInherit program args
  unless (code == ExitSuccess) (exitWith code)

-- | Unpack a page's zip into @work/app@ and check that it is a page of the
-- deploy's kind; on failure, the reason. python3 unpacks it (unzip where
-- there is none).
unpackPage :: String -> String -> FilePath -> FilePath -> IO (Either String ())
unpackPage kind a work zipFile = do
  let app = work </> "app"
  removePathForcibly app
  createDirectoryIfMissing True app
  python <- findExecutable "python3"
  code <- case python of
    Just _ -> runInherit "python3" ["-m", "zipfile", "-e", zipFile, app]
    Nothing -> runInherit "unzip" ["-q", zipFile, "-d", app]
  if code /= ExitSuccess
    then pure (Left ("could not unpack " <> a <> " (see above)"))
    else do
      missing <- filterM' (\f -> not <$> doesFileExist (app </> f)) ["index.html", "404.html", "app.wasm"]
      pure $ case missing of
        f : _ -> Left (a <> " lacks " <> f <> ": it is not a page CI built for the " <> kind)
        [] -> Right ()
  where
    filterM' f = fmap concat . mapM (\x -> (\b -> [x | b]) <$> f x)

-- | The SHA-256 of a file, in hex, with sha256sum, shasum or python3.
fileSha256 :: FilePath -> IO String
fileSha256 file = do
  sha256sum <- findExecutable "sha256sum"
  shasum <- findExecutable "shasum"
  (_, out) <- case (sha256sum, shasum) of
    (Just _, _) -> outputOf "sha256sum" [file]
    (_, Just _) -> outputOf "shasum" ["-a", "256", file]
    _ -> outputOf "python3" ["-c", "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], \"rb\").read()).hexdigest())", file]
  pure (takeWhile (/= ' ') (chomp out))

-- | Take the page into the deploy's page directory, through a directory
-- beside it, so that a failed download leaves the last page as it was.
--
-- The zip comes from the page cache when the cache has it and it is still
-- the page GitHub has. A page of a commit (@app-<kind>-<hash>.zip@) never
-- changes. A tag's asset can be uploaded again (CI replaces it), and two
-- zips can have the same size, so a tag's cached zip is taken only while
-- its @.meta@ file names the id and time the release lists for the asset; a
-- zip without one is downloaded again. @--refresh-page@ skips the cache. A
-- downloaded zip enters the cache only after it unpacked as a page, under a
-- temporary name first, so a broken or partial download is never taken
-- from there.
--
-- A page from a file has a cache entry of its own,
-- @app-<kind>-file-<SHA-256>.zip@, with the file's path in its @.meta@ file,
-- apart from the zips downloaded from GitHub: a file named as CI names its
-- zips is still not one CI's release served. While the file can be read,
-- the file is the page: its zip enters the cache when the cache does not
-- have it (the entries of an earlier version of the same file are deleted
-- then), and is touched when it does. When the file is gone, or cannot be
-- read, on a later run (the state remembers @--app-page@), the newest
-- entry for its path is the page, as a downloaded page's cached zip is. A
-- zip of the same bytes given under another path takes the entry over.
downloadPage :: Plan -> Source -> IO ()
downloadPage p s = do
  let kind = kindOf p
      root = get p "root"
      out = get p "out"
      appPage = get p "app_page"
      fromFile = has p "app_page"
      url = "https://github.com/" <> s.repo <> "/releases/download/" <> s.tag <> "/" <> s.asset
      work = root </> "dist-newstyle" </> "wasm-opt" </> "download"
      unpack = unpackPage kind s.asset work
  cache <- pageCacheDir p
  removePathForcibly work
  createDirectoryIfMissing True work
  cachedRef <- newIORef (cache </> s.asset)
  fromCacheRef <- newIORef False
  keepFileRef <- newIORef False
  if fromFile
    then do
      createDirectoryIfMissing True cache `orElse` pure ()
      readable <- (readable <$> getPermissions appPage) `orElse` pure False
      if readable
        then do
          say ("the page: " <> s.words_)
          code <- runInherit "cp" [appPage, work </> "page.zip"]
          unless (code == ExitSuccess) (die ("--app-page " <> appPage <> ": cannot read it (see above); give the file again, or another"))
          either die pure =<< unpack (work </> "page.zip")
          -- The file's page says which kind it is in its <meta
          -- name="wiki-backend">, as CI's pages do. One of the other kind
          -- is refused here, before the cache is touched, so that the copy
          -- of the last page that passed stays there for a run without the
          -- file.
          index <- decodeFs . LBS.fromStrict <$> BS.readFile (work </> "app" </> "index.html")
          case pageBackend index of
            Just backend
              | not (null backend) && backend /= kind ->
                  die ("--app-page " <> appPage <> " is the " <> backend <> "'s page (its index.html says so), and this deploy is of the " <> kind <> " (--" <> get p "mode" <> "); the page cache keeps the last page of the " <> kind <> " given from it")
            _ -> pure ()
          sha <- fileSha256 (work </> "page.zip")
          let cached = cache </> ("app-" <> kind <> "-file-" <> sha <> ".zip")
          writeIORef cachedRef cached
          there <- doesFileExist cached
          said <- readMeta (cached <> ".meta")
          if there && fromMaybe "" said == s.meta
            then touch cached
            else writeIORef keepFileRef True
        else do
          -- One entry a path: a new version of the file replaces the old
          -- one's.
          entries <- appPageEntries cache kind s.meta
          cached <- case entries of
            e : _ -> pure e
            [] -> die ("--app-page " <> appPage <> " is gone, or cannot be read, and the page cache " <> cache <> " keeps no copy of it: give the file again (--app-page FILE), or take the page from GitHub (--backend-only)")
          writeIORef cachedRef cached
          unpack cached >>= either (\e -> die ("--app-page " <> appPage <> " is gone, or cannot be read, and its copy in the page cache, " <> cached <> ", is not a page (" <> e <> "): give the file again (--app-page FILE)")) pure
          touch cached
          writeIORef fromCacheRef True
          say ("--app-page " <> appPage <> " is gone, or cannot be read: the page is the copy the page cache kept of it when it was last deployed, " <> cached)
    else do
      cached <- readIORef cachedRef
      there <- doesFileExist cached
      when (not (has p "refresh_page") && there) $
        if commitAsset kind s.asset /= Nothing
          then writeIORef fromCacheRef True
          else unless (null s.meta || "id=- " `isPrefixOf` s.meta || " updated_at=- " `isInfixOf` s.meta) $ do
            said <- readMeta (cached <> ".meta")
            when (fromMaybe "" said == s.meta) (writeIORef fromCacheRef True)
  cached <- readIORef cachedRef
  let writeMeta = unless (null s.meta) $ do
        let part = cache </> ("." <> s.asset <> ".meta.part")
        ok <- (writeFile part (s.meta <> "\n") >> renameFile part (cached <> ".meta") >> pure True) `orElse` pure False
        unless ok (removeFile part `orElse` pure ())
  fromCache0 <- readIORef fromCacheRef
  when (fromCache0 && not fromFile) $
    unpack cached >>= \case
      Right () -> do
        touch cached
        metaThere <- doesFileExist (cached <> ".meta")
        unless metaThere writeMeta
        say ("the page of " <> (if null s.commit then s.tag else s.commit) <> " from the cache: " <> cached)
      Left e -> do
        warn ("the cached " <> cached <> " is not a page (" <> e <> "), so it is deleted and downloaded again")
        mapM_ (\f -> removeFile f `orElse` pure ()) [cached, cached <> ".meta"]
        writeIORef fromCacheRef False
  fromCache <- readIORef fromCacheRef
  when (not fromCache && not fromFile) $ do
    say ("downloading the page" <> (if null s.commit then "" else " of " <> s.commit) <> ": " <> url)
    code <- runInherit "curl" ["-fsSL", "--max-time", "900", "--retry", "3", "-o", work </> "page.zip", url]
    unless (code == ExitSuccess) (die ("could not download " <> url <> " (see above)"))
    either die pure =<< unpack (work </> "page.zip")
  keepFile <- readIORef keepFileRef
  when (not fromCache && (not fromFile || keepFile)) $ do
    let part = cache </> ("." <> s.asset <> ".part")
    made <- (createDirectoryIfMissing True cache >> pure True) `orElse` pure False
    copied <- if made then (== ExitSuccess) <$> runInherit "cp" [work </> "page.zip", part] else pure False
    moved <- if copied then (== ExitSuccess) <$> runInherit "mv" ["-f", part, cached] else pure False
    if moved
      then do
        -- The entries of an earlier version of the same file go.
        when fromFile $ do
          entries <- appPageEntries cache kind s.meta
          forM_ (filter (/= cached) entries) $ \e -> mapM_ (\f -> removeFile f `orElse` pure ()) [e, e <> ".meta"]
        writeMeta
        prunePages cache
      else do
        removeFile part `orElse` pure ()
        warn ("could not keep the page in the cache " <> cache <> "; the next deploy downloads it again")
  -- CI's page as it is, for the comparison after the bundles are built
  -- here.
  when (has p "bundle_locally") $ do
    removePathForcibly (get p "ci_page")
    orExit "cp" ["-R", work </> "app", get p "ci_page"]
  removePathForcibly out
  createDirectoryIfMissing True (takeDirectory out)
  orExit "mv" [work </> "app", out]
  removePathForcibly work
  checkVersions p s

-- | Warn when the page is of another commit than the checkout. The page
-- and the server talk over the API, so they should be of one version; a
-- page of another commit is taken, with a warning. The demo talks to no
-- server, but a demo of another commit than the checkout's is as easily a
-- surprise, so it is said too. A file's page is not checked against the
-- checkout: the deploy has said which page it is.
checkVersions :: Plan -> Source -> IO ()
checkVersions p s = do
  let root = get p "root"
      server = kindOf p == "server"
  (ok, head0) <- outputOf "git" ["-C", root, "rev-parse", "HEAD"]
  let checkout = if ok then chomp head0 else ""
      orNone x alt = if null x then alt else x
  if has p "app_page"
    then pure ()
    else
      if null s.commit
        then
          if server
            then warn ("cannot tell which commit the page of " <> s.tag <> " was built from (the tag is not in this checkout); wiki-server is built from " <> orNone checkout "this checkout" <> ", and the two should be of one version")
            else warn ("cannot tell which commit the demo page of " <> s.tag <> " was built from (the tag is not in this checkout)")
        else do
          same <- if s.commit == checkout then pure True else sameCode root s.commit checkout
          unless same $
            if server
              then warn ("the page is of " <> s.commit <> ", and wiki-server is built from this checkout, " <> orNone checkout "of no commit" <> ": they talk over the API, so keep them of one version (check that commit out, or deploy with --backend-only alone, the checkout's own page)")
              else warn ("the demo page is of " <> s.commit <> ", and this checkout is " <> orNone checkout "of no commit" <> ": the demo served is that commit's (deploy with --backend-only alone for the checkout's own)")

-- | Delete all but the five newest zips in the page cache, by modification
-- time, with their @.meta@ files. A zip's time is when it was downloaded or
-- last used.
prunePages :: FilePath -> IO ()
prunePages cache = do
  names <- listDirectory cache `orElse` pure []
  zips <- mapM (\n -> (cache </> n,) <$> getModificationTime (cache </> n)) [n | n <- names, ".zip" `isSuffixOf` n, not ("." `isPrefixOf` n)]
  forM_ (pruneOrder zips) $ \old -> mapM_ (\f -> removeFile f `orElse` pure ()) [old, old <> ".meta"]
