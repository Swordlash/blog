module Maker.DeploySpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import Maker.Deploy.Apply (sanName)
import Maker.Deploy.Firewall (quoteArgs)
import Maker.Deploy.Plan (decodeFs, encodeFs, get, has, parsePlan, set)
import Maker.Deploy.Prepare (localYml, pageBackend, pgWrapper)
import Maker.Deploy.State (renderState, stateKeys)
import Maker.Deploy.Tailscale (Https (..), Serve (..), dnsNameOf, httpsOf, isOldVersion, serveRoot)
import Maker.Deploy.Tex (sourceWords, texYear, texlivePackages)
import Maker.Deploy.Unit
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
