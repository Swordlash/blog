module Maker.DeploySpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Time (UTCTime (..), fromGregorian)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import Maker.Deploy.Apply (sanName)
import Maker.Deploy.Firewall (quoteArgs)
import Maker.Deploy.Move (replaceOnce)
import Maker.Deploy.Page (Asset (..), isCode, newestCommitAsset, parseAssets, pruneOrder, repoOf, tagAsset)
import Maker.Deploy.Plan (decodeFs, encodeFs, get, has, parsePlan, set)
import Maker.Deploy.Prepare (localYml, pageBackend, pgWrapper)
import Maker.Deploy.State (renderState, stateKeys, stateReplace)
import Maker.Deploy.Tailscale (Https (..), Serve (..), dnsNameOf, httpsOf, isOldVersion, serveRoot)
import Maker.Deploy.Tex (sourceWords, texYear, texlivePackages)
import Maker.Deploy.Unit
import Maker.Deploy.Upgrade (Kept (..), asideName, keepPrevious, newBackup, readKept)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "the deploy's part in the maker" $ do
  describe "the plan" $ do
    it "takes each line's value after the first =, the last one for a key twice" $ do
      let plan = parsePlan "# a comment\nname=wiki\nout=/a=b\nport=1\nport=2\nnot a line\n"
      (get plan "name", get plan "out", get plan "port") `shouldBe` ("wiki", "/a=b", "2")
    it "decodes a program's output so that every byte comes back when it is passed on" $ do
      let bytes = BS.pack [0x2f, 0x6f, 0x70, 0x74, 0x2f, 0xc5, 0xbc, 0x2f, 0xff, 0x62, 0x69, 0x6e]
      encoding <- getFileSystemEncoding
      back <- GHC.withCStringLen encoding (decodeFs (LBS.fromStrict bytes)) BS.packCStringLen
      back `shouldBe` bytes
    it "encodes the decoded text back to the same bytes, for a parser of them" $ do
      let bytes = LBS.pack [0x7b, 0x22, 0xc5, 0xbc, 0x22, 0x3a, 0xff, 0x7d]
      encodeFs (decodeFs bytes) `shouldBe` bytes
    it "reads a missing or empty key as empty, as an unset variable" $ do
      let plan = parsePlan "nodeless=\n"
      (get plan "nodeless", has plan "nodeless", has plan "missing") `shouldBe` ("", False, False)

  describe "the state file" $ do
    it "writes deploy-lib.sh's keys in its order, with the rule port the deploy has now" $ do
      let plan = parsePlan "name=wiki\ndir=/srv/wiki\ntoolchain_dir=/t\nport=8080\nrule_port=9\nmode=server\n"
          text = lines (renderState plan "8080")
      take 5 text `shouldBe` ["# Written by toolchain/deploy-local.sh; read by it and by undeploy-local.sh.", "name=wiki", "dir=/srv/wiki", "toolchain=/t", "port=8080"]
      text `shouldContain` ["rule_port=8080", "mode=server"]
      length text `shouldBe` 1 + length stateKeys
    it "names a deployment without a mode static" $
      lines (renderState (parsePlan "name=demo\n") "") `shouldContain` ["mode=static"]

  describe "the move to PostgreSQL" $ do
    it "puts the PostgreSQL words in place of the unit's SQLite words, found once" $ do
      let sqlite = databaseWords "sqlite" "/srv/wiki" "" "/srv/wiki/state/wiki.postgres"
          postgres = databaseWords "postgres" "/srv/wiki" "5433" "/srv/wiki/state/wiki.postgres"
          line = "ExecStart=\"/srv/wiki/bin/wiki-server\" serve --listen 127.0.0.1:8080" <> sqlite <> " --no-pdf"
      sqlite `shouldBe` " --sqlite \"/srv/wiki/data/wiki.sqlite\""
      postgres `shouldBe` " --database postgres://wiki@127.0.0.1:5433/wiki --database-password-file \"/srv/wiki/state/wiki.postgres/db-password\" --pg-dump \"/srv/wiki/state/wiki.postgres/pg_dump\" --pg-restore \"/srv/wiki/state/wiki.postgres/pg_restore\""
      replaceOnce sqlite postgres line `shouldBe` Just ("ExecStart=\"/srv/wiki/bin/wiki-server\" serve --listen 127.0.0.1:8080" <> postgres <> " --no-pdf")
    it "refuses words that are not there, or there twice" $ do
      replaceOnce "--sqlite x" "y" "serve" `shouldBe` Nothing
      replaceOnce "--sqlite x" "y" "--sqlite x --sqlite x" `shouldBe` Nothing
    it "replaces the state's values where they are, and adds a missing one at the end" $ do
      tmp <- getTemporaryDirectory
      let dir = tmp </> "maker-state-replace-test"
          file = dir </> "wiki.state"
      removePathForcibly dir
      createDirectoryIfMissing True dir
      writeFile file "# comment\nname=wiki\ndb=sqlite\nport=8080\ndb=sqlite\n"
      stateReplace [("db", "postgres"), ("db_port", "5433")] file
      text <- readFile file
      length text `seq` lines text `shouldBe` ["# comment", "name=wiki", "db=postgres", "port=8080", "db_port=5433"]
      removePathForcibly dir

  describe "the unit" $ do
    it "quotes an ExecStart word for systemd" $
      unitWord "/home/a b/\"x\"\\%$y" `shouldBe` "\"/home/a b/\\\"x\\\"\\\\%%$$y\""
    it "escapes an Environment= value without doubling $" $
      environmentValue "/opt/lib:$X%\"" `shouldBe` "/opt/lib:$X%%\\\""
    it "writes the shell's unit, with its prefix and extra lines" $
      renderUnit Unit {root = "/r", name = "wiki", prefix = "/p", description = "Wiki server (wiki) from /p on 127.0.0.1:8080", execStart = "\"/p/bin/wiki-server\" serve", extra = ["UMask=0077", "TimeoutStopSec=30"]}
        `shouldBe` unlines
          [ "# Written by toolchain/deploy-local.sh from /r;"
          , "# run it again to change this deployment, or toolchain/undeploy-local.sh --name wiki --prefix /p"
          , "# to take it down."
          , "# Prefix: /p"
          , "[Unit]"
          , "Description=Wiki server (wiki) from /p on 127.0.0.1:8080"
          , "After=network-online.target"
          , "# Restart for as long as it takes: at boot the Tailscale address may appear a"
          , "# little after this starts, and listening on it fails until then."
          , "StartLimitIntervalSec=0"
          , ""
          , "[Service]"
          , "ExecStart=\"/p/bin/wiki-server\" serve"
          , "Restart=on-failure"
          , "RestartSec=5"
          , "NoNewPrivileges=yes"
          , "UMask=0077"
          , "TimeoutStopSec=30"
          , ""
          , "[Install]"
          , "WantedBy=default.target"
          ]
    it "keeps the heredoc's empty line where a demo has no extra lines" $
      lines (renderUnit Unit {root = "/r", name = "demo", prefix = "", description = "d", execStart = "e", extra = []})
        `shouldContain` ["NoNewPrivileges=yes", "", "", "[Install]"]
    it "gives the console the PostgreSQL database in its environment" $ do
      let console = lines (consoleWrapper "wiki" "/d" "postgres" "5433" "/s/wiki.postgres")
      console `shouldContain` ["WIKI_DATABASE_URL='postgres://wiki@127.0.0.1:5433/wiki'"]
      last console `shouldBe` "exec '/d/bin/wiki-server' \"$@\""

  describe "Tailscale" $ do
    it "finds the root handler of https://<name>/ in tailscale serve status" $
      serveRoot "https://box.tail.ts.net (tailnet only)\n|-- / proxy http://127.0.0.1:8080\n"
        `shouldBe` Serve "proxy" "http://127.0.0.1:8080" "tailnet"
    it "tells a Funnel, and skips a server on another port" $ do
      serveRoot "https://box.tail.ts.net:8443 (tailnet only)\n|-- / proxy http://127.0.0.1:1\n" `shouldBe` Serve "" "" ""
      serveRoot "https://box.tail.ts.net (Funnel on)\n|-- / proxy http://127.0.0.1:2\n" `shouldBe` Serve "proxy" "http://127.0.0.1:2" "funnel"
    it "tells a tailscale older than 1.52" $
      map isOldVersion ["1.50.1", "1.51", "1.9", "1.52.0", "1.80.2", "2.0"] `shouldBe` [True, True, True, False, False, False]
    it "reads the MagicDNS name without its final dot" $
      dnsNameOf "{\"Self\": {\"DNSName\": \"box.tail.ts.net.\"}}" `shouldBe` "box.tail.ts.net"

  describe "the certificate's name" $
    it "takes the first DNS name of openssl's subjectAltName, after its heading line" $ do
      sanName "X509v3 Subject Alternative Name: \n    DNS:wiki.example.org\n" `shouldBe` Just "wiki.example.org"
      sanName "X509v3 Subject Alternative Name: \n    IP Address:10.0.0.1, DNS:a.example.org, DNS:b.example.org\n" `shouldBe` Just "a.example.org"
      sanName "X509v3 Subject Alternative Name: \n    IP Address:10.0.0.1\n" `shouldBe` Nothing

  describe "the preparing steps" $ do
    it "lets a value the maker works out replace the shell's" $
      get (set "node" "/n" (parsePlan "node=\n")) "node" `shouldBe` "/n"
    it "reads the backend a page was built for from its meta tag" $ do
      pageBackend "<head>\n<meta name=\"wiki-backend\" content=\"demo\">\n" `shouldBe` Just "demo"
      pageBackend "<head><title>x</title></head>" `shouldBe` Nothing
      pageBackend "<meta name=\"wiki-backend\" content=\"demo2\">" `shouldBe` Nothing
    it "tells whether HTTPS can be served on the machine's MagicDNS name" $ do
      httpsOf "{\"BackendState\": \"Running\", \"Self\": {\"DNSName\": \"box.tail.ts.net.\"}, \"CertDomains\": [\"box.tail.ts.net\"]}"
        `shouldBe` Just (Https "box.tail.ts.net" True True)
      httpsOf "{\"Self\": {\"DNSName\": \"box.tail.ts.net.\"}, \"CurrentTailnet\": {\"MagicDNSEnabled\": false}}"
        `shouldBe` Just (Https "box.tail.ts.net" False False)
      httpsOf "{\"BackendState\": \"Stopped\"}" `shouldBe` Nothing
      httpsOf "{\"Self\": {}}" `shouldBe` Just (Https "-" True False)
    it "writes the PostgreSQL files the shell wrote" $ do
      lines (localYml "wiki") `shouldContain` ["      - \"127.0.0.1:${WIKI_DB_PORT}:5432\""]
      lines (pgWrapper "wiki" "/s/wiki.postgres" "5433" "pg_dump")
        `shouldContain` [ "WIKI_DB_PASSWORD_FILE='/s/wiki.postgres/db-password' WIKI_DB_PORT='5433' exec docker compose --project-name 'wiki' \\"
                        , "  --file '/s/wiki.postgres/docker-compose.yml' --file '/s/wiki.postgres/local.yml' exec -T postgres pg_dump \"$@\""
                        ]

  describe "the page CI built" $ do
    it "tells owner/repo from origin's address in its https and ssh forms" $ do
      map repoOf ["https://github.com/Owner/blog.git", "https://token@github.com/Owner/blog/", "git@github.com:Owner/blog.git", "ssh://git@github.com/Owner/blog"]
        `shouldBe` replicate 4 (Right "Owner/blog")
    it "refuses an origin elsewhere, and one it cannot tell a repository from" $ do
      repoOf "https://gitlab.com/Owner/blog" `shouldBe` Left "origin is https://gitlab.com/Owner/blog, not a repository on GitHub: --backend-only downloads the page from the GitHub repository origin names"
      repoOf "https://github.com/Owner" `shouldBe` Left "cannot tell the GitHub repository from origin's address https://github.com/Owner"
      repoOf "https://github.com/Owner/blog/tree" `shouldBe` Left "cannot tell the GitHub repository from origin's address https://github.com/Owner/blog/tree"
    it "counts Markdown as documentation, except what the programs compile in" $
      map isCode ["README.md", "changelog/00001-x.md", "wiki-core/templates/page.md", "wiki-core/reference/markdown.md", "docs/markdown.md", "web/index.html"]
        `shouldBe` [False, False, True, True, True, True]
    it "names a tag's asset without the tag's slashes" $
      tagAsset "server" "release/1.0" `shouldBe` "app-server-release-1.0.zip"
    it "reads a release's assets from api.github.com's answer, with - for what it lacks" $ do
      parseAssets (BS8.pack "{\"assets\":[{\"name\":\"a.zip\",\"updated_at\":\"2026-11-02T10:00:00Z\",\"size\":12,\"id\":7},{\"name\":\"b.zip\",\"created_at\":\"2026-11-01T10:00:00Z\"}]}")
        `shouldBe` Just [Asset "a.zip" "2026-11-02T10:00:00Z" "12" "7", Asset "b.zip" "2026-11-01T10:00:00Z" "-" "-"]
      parseAssets (BS8.pack "{}") `shouldBe` Just []
      parseAssets (BS8.pack "not json") `shouldBe` Nothing
    it "takes main's newest commit page by its upload time, of the deploy's kind" $ do
      let hash c = replicate 40 c
          assets =
            [ Asset ("app-server-" <> hash 'a' <> ".zip") "2026-11-01T10:00:00Z" "1" "1"
            , Asset ("app-server-" <> hash 'b' <> ".zip") "2026-11-02T10:00:00Z" "1" "2"
            , Asset ("app-demo-" <> hash 'c' <> ".zip") "2026-11-03T10:00:00Z" "1" "3"
            , Asset "app-server-v1.zip" "2026-11-04T10:00:00Z" "1" "4"
            ]
      (.name) <$> newestCommitAsset "server" assets `shouldBe` Just ("app-server-" <> hash 'b' <> ".zip")
      newestCommitAsset "server" (take 0 assets) `shouldBe` Nothing
    it "keeps the five newest zips of the page cache, newest by time, then by name" $ do
      let at s = UTCTime (fromGregorian 2026 11 1) s
          zips = [("f", at 1), ("a", at 6), ("b", at 5), ("c", at 4), ("d", at 3), ("e", at 3), ("g", at 2)]
      pruneOrder zips `shouldBe` ["g", "f"]

  describe "the TeX step" $ do
    it "says where a source comes from: a repository cloned at a tag, or a directory" $ do
      sourceWords "https://github.com/Perl/perl5" "v5.44.0" `shouldBe` "cloned from https://github.com/Perl/perl5 at v5.44.0"
      sourceWords "https://github.com/TeX-Live/installer" "" `shouldBe` "cloned from https://github.com/TeX-Live/installer"
      sourceWords "/srv/install-tl" "" `shouldBe` "from the directory /srv/install-tl"
    it "reads the year of TeX Live an installer installs" $ do
      texYear "TeX Live (https://tug.org/texlive) version 2026\n" `shouldBe` Just "2026"
      texYear "install-tl: unknown option\n" `shouldBe` Nothing
    it "takes the package list's words without its comments" $
      texlivePackages "# what the exports need\nxetex fontspec # fonts\n\nunicode-math\n" `shouldBe` ["xetex", "fontspec", "unicode-math"]

  describe "the firewall"
    $ it "quotes only the arguments that need it, as a shell would need them typed"
    $ quoteArgs ["allow", "in", "on", "tailscale0", "comment", "my wiki"] `shouldBe` "allow in on tailscale0 comment 'my wiki'"

  describe "the upgrade" $ do
    it "takes the newest backup a backup command added, and none when it added none" $ do
      let listed0 = ["/d/backups/20261101T000000Z.sqlite"]
          listed1 = listed0 <> ["/d/backups/20261106T101500Z.sqlite", "/d/backups/20261106T101500Z.pgdump.json"]
      newBackup listed0 listed1 `shouldBe` Just "/d/backups/20261106T101500Z.sqlite"
      newBackup listed0 listed0 `shouldBe` Nothing
      newBackup [] ["/d/backups/a.pgdump.json", "/d/backups/a.pgdump"] `shouldBe` Just "/d/backups/a.pgdump"
    it "names a directory for a wiki set aside by the time, with a number when the time is taken" $ do
      asideName [] "20261106T101500Z" `shouldBe` "20261106T101500Z"
      asideName ["20261106T101500Z"] "20261106T101500Z" `shouldBe` "20261106T101500Z-2"
      asideName ["20261106T101500Z", "20261106T101500Z-2", "fake"] "20261106T101500Z" `shouldBe` "20261106T101500Z-3"
    it "keeps a server deployment in previous/ with its commit, a copy of its backup, whether it ran and whether it had a unit, and only a server's" $ do
      tmp <- getTemporaryDirectory
      let dir = tmp </> "maker-upgrade-spec"
      removePathForcibly dir
      createDirectoryIfMissing True (dir </> "app")
      writeFile (dir </> "unit") "[Unit]\n"
      writeFile (dir </> "state") "git_commit=abc\n"
      demo <- keepPrevious dir (dir </> "unit") (dir </> "state") "abc" Nothing True True "" ""
      demo `shouldBe` False
      createDirectoryIfMissing True (dir </> "bin")
      writeFile (dir </> "bin" </> "wiki-server") "old"
      createDirectoryIfMissing True (dir </> "backups")
      writeFile (dir </> "backups" </> "b.pgdump") "dump"
      writeFile (dir </> "backups" </> "b.pgdump.json") "facts"
      kept <- keepPrevious dir (dir </> "unit") (dir </> "state") "" (Just (dir </> "backups" </> "b.pgdump")) True True "" ""
      kept `shouldBe` True
      moved <- (,) <$> doesDirectoryExist (dir </> "bin") <*> doesDirectoryExist (dir </> "app")
      moved `shouldBe` (False, False)
      k <- readKept dir
      fmap (\x -> (x.commit, x.backup, x.running, x.unit)) k `shouldBe` Just ("unknown", dir </> "previous" </> "b.pgdump", True, True)
      readFile (dir </> "previous" </> "b.pgdump.json") >>= (`shouldBe` "facts")
      readFile (dir </> "previous" </> "state") >>= (`shouldBe` "git_commit=abc\n")
      -- A server taken down with --stop (no unit, not running) is kept as
      -- such, in place of the one kept before.
      createDirectoryIfMissing True (dir </> "bin")
      writeFile (dir </> "bin" </> "wiki-server") "stopped"
      stopped <- keepPrevious dir (dir </> "no-unit") (dir </> "state") "abc" Nothing False False "" ""
      stopped `shouldBe` True
      k' <- readKept dir
      fmap (\x -> (x.commit, x.backup, x.running, x.unit)) k' `shouldBe` Just ("abc", "", False, False)
      -- An upgrade that started an empty wiki, or adopted the deployment
      -- under --prefix, records where the old wiki and state were.
      createDirectoryIfMissing True (dir </> "bin")
      writeFile (dir </> "bin" </> "wiki-server") "fresh"
      fresh <- keepPrevious dir (dir </> "unit") (dir </> "state") "abc" Nothing True False "/d/data/replaced/t" "/h/.config/w/w.state"
      fresh `shouldBe` True
      k'' <- readKept dir
      fmap (\x -> (x.backup, x.aside, x.adoptedFrom)) k'' `shouldBe` Just ("", "/d/data/replaced/t", "/h/.config/w/w.state")
      removePathForcibly dir
