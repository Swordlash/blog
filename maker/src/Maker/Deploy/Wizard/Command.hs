-- | The deploy's command line for the wizard's answers
-- ("Maker.Deploy.Wizard.Answers"), and what in the answers the deploy
-- would refuse, said for the person at the wizard.
--
-- Every option of deploy-local.sh's header but --force (which does
-- nothing) and --yes (which the wizard, on a terminal, does not need) is a
-- string literal of the wizard's modules, this one, the answers' and the
-- screens', and every option literal in them is in the header:
-- toolchain/test-deploy-local.sh checks both ways.
module Maker.Deploy.Wizard.Command
  ( deployArgs
  , problems
  , commandLine
  , quote
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Maker.Deploy.Wizard.Answers

-- * The command line

-- | The deploy's arguments for the answers. Only options that apply are
-- given: the deploy refuses a server's options for the demo, --db-port
-- with SQLite, --tls-ca without a certificate, and an address other than
-- 127.0.0.1 behind tailscale serve or a reverse proxy, where the address
-- is therefore left to the deploy.
deployArgs :: Answers -> [Text]
deployArgs a = case a.action of
  Status -> "--status" : which
  Stop -> "--stop" : which
  Rollback -> "--rollback" : which
  -- The move builds wiki-server and starts PostgreSQL: its port and the
  -- build's semaphore are the move's own options.
  MoveToPostgres -> "--move-to-postgres" : which ++ option "--db-port" (a.dbPort) ++ semaphoreArgs
  Deploy ->
    concat
      [ [if server then "--server" else "--static"]
      , which
      , pageArgs
      , sourceArgs
      , if server then databaseArgs else []
      , if server then texArgs else []
      , if server then whatsNewArgs else []
      , wayArgs
      , option "--port" (a.port)
      , if a.way `elem` [PlainHttp, Certificate] then option "--bind" (a.bind) else []
      , if server then option "--admin-port" (a.adminPort) else []
      , option "--toolchain" (a.toolchain)
      , flag "--no-build" (a.noBuild)
      , if server && not (a.noBuild) then semaphoreArgs else []
      , flag "--no-firewall" (a.noFirewall)
      , if server then flag "--no-rehearsal" (a.noRehearsal) else []
      , flag "--enable-linger" (a.enableLinger)
      ]
  where
    server = a.mode == Server
    which =
      option "--prefix" (a.prefix)
        ++ if a.name == defaultAnswers.name then [] else option "--name" (a.name)
    pageArgs = case a.page of
      Downloaded ->
        (if T.null (a.pageRef) then "--backend-only" else "--backend-only=" <> a.pageRef)
          : flag "--refresh-page" (a.refreshPage)
          ++ bundleArgs
      FromFile -> option "--app-page" (a.appPage) ++ bundleArgs
      BuiltHere -> flag "--no-backend-only" (a.rememberedDownload)
    -- The bundles built here, for a page CI built; --no-bundle-locally
    -- forgets a remembered choice.
    bundleArgs
      | a.bundleLocally = ["--bundle-locally"]
      | otherwise = flag "--no-bundle-locally" (a.rememberedBundle)
    -- For a machine that installs nothing from the internet. What the
    -- state remembers and the answers drop is forgotten explicitly.
    -- libsodium's tarball is not remembered, so it has nothing to forget.
    sourceArgs =
      (if a.systemTools then ["--system-tools"] else flag "--no-system-tools" (a.rememberedSystemTools))
        ++ forgettable "--npm-registry" (a.npmRegistry) (a.rememberedNpmRegistry)
        ++ forgettable "--hackage-mirror" (a.hackageMirror) (a.rememberedHackageMirror)
        ++ option "--libsodium-source" (a.libsodiumSource)
    forgettable key v remembered
      | not (T.null v) = [key, v]
      | remembered = [key <> "="]
      | otherwise = []
    databaseArgs =
      ( case a.database of
          Postgres -> "--postgres" : option "--db-port" (a.dbPort)
          Sqlite -> ["--sqlite"]
      )
        ++ flag "--fresh" (a.fresh)
    -- The TeX on this machine is the deploy's default, so it takes no
    -- option, unless the state remembers TeX Live under the toolchain,
    -- which --no-texlive forgets.
    texArgs = case a.tex of
      MachineTex -> flag "--no-texlive" (a.rememberedTexLive)
      ToolchainTex ->
        "--texlive"
          : option "--texlive-mirror" (a.texMirror)
          ++ option "--texlive-installer" (a.texInstaller)
          ++ option "--perl-source" (a.perlSource)
      NoTex -> ["--no-texlive"]
    -- The page is on by default, so it takes no option, unless the state
    -- remembers it off, which --whats-new forgets.
    whatsNewArgs
      | a.whatsNew = flag "--whats-new" (a.rememberedNoWhatsNew)
      | otherwise = ["--no-whats-new"]
    semaphoreArgs = case a.semaphore of
      Probe -> []
      SemaphoreOn -> ["--semaphore"]
      SemaphoreOff -> ["--no-semaphore"]
    wayArgs = case a.way of
      Tailscale -> ["--https"]
      Proxy -> ["--behind-proxy"]
      PlainHttp -> ["--http"]
      Certificate ->
        ["--tls-cert", a.tlsCert, "--tls-key", a.tlsKey]
          ++ if T.null (a.tlsCa)
            then flag "--tls-ca=" (a.rememberedCa)
            else ["--tls-ca", a.tlsCa]
    option key v = if T.null v then [] else [key, v]
    flag key on' = [key | on']

-- | What the deploy would refuse in the answers, said for the person at
-- the wizard; empty when the command line can run.
problems :: Answers -> [Text]
problems a =
  concat
    [ ["The name may hold letters, digits, '-', '_', '.' and '@', and not start with '.'." | not (validName (a.name))]
    , case a.action of
        Deploy ->
          concat
            [ portProblem "The port" (a.port)
            , if server then portProblem "The admin port" (a.adminPort) else []
            , if server && a.database == Postgres then portProblem "The database's port" (a.dbPort) else []
            , ["The admin port and the port must differ." | server, not (T.null (a.port)), a.port == a.adminPort]
            , [ "The database's port must differ from the listeners' ports."
              | server
              , a.database == Postgres
              , not (T.null (a.dbPort))
              , a.dbPort `elem` [a.port, a.adminPort]
              ]
            , ["A certificate needs its file." | a.way == Certificate, T.null (a.tlsCert)]
            , [ "The CTAN mirror is an http:// or https:// URL, without spaces or quotes."
              | server
              , a.tex == ToolchainTex
              , not (T.null (a.texMirror))
              , not (validMirror (a.texMirror))
              ]
            , [ what <> " is a git repository's http:// or https:// URL, without spaces or quotes, or a directory of this machine."
              | server
              , a.tex == ToolchainTex
              , (what, v) <- [("TeX Live's installer", a.texInstaller), ("Perl's source", a.perlSource)]
              , "://" `T.isInfixOf` v
              , not (validMirror v)
              ]
            , ["A certificate needs its key's file (the same file when one .pem holds both)." | a.way == Certificate, T.null (a.tlsKey)]
            , ["A page from a file needs the file, the zip CI built (--app-page)." | a.page == FromFile, T.null (a.appPage)]
            , [ "The machine's own toolchain (--system-tools) needs the page CI built, downloaded or from a file: building the page here needs the wasm toolchain, which only the bootstrap installs."
              | a.systemTools
              , a.page == BuiltHere
              , not (a.noBuild)
              ]
            , [ what <> " is an http:// or https:// URL, without spaces or quotes."
              | (what, v) <- [("The npm registry", a.npmRegistry), ("The Hackage mirror", a.hackageMirror)]
              , not (T.null v)
              , not (validMirror v)
              ]
            , [ "The Hackage mirror is written into the toolchain's own cabal configuration, never ~/.cabal: give a prefix, or a toolchain directory of its own."
              | not (T.null (a.hackageMirror))
              , T.null (a.prefix)
              , T.null (a.toolchain)
              ]
            ]
        MoveToPostgres -> portProblem "The database's port" (a.dbPort)
        _ -> []
    ]
  where
    server = a.mode == Server
    portProblem what v
      | T.null v = []
      | T.all isDigit v && not ("0" `T.isPrefixOf` v) && T.length v <= 5 && within (read (T.unpack v) :: Int) = []
      | otherwise = [what <> " is a number from 1024 to 65535."]
    within n = n >= 1024 && n <= 65535
    -- As the deploy checks --texlive-mirror, and the URLs of
    -- --texlive-installer and --perl-source (a value without :// is a
    -- directory, whose existence the deploy checks).
    validMirror m =
      any (\scheme -> scheme `T.isPrefixOf` m && T.length m > T.length scheme) ["http://", "https://"]
        && not (T.any (\c -> c `elem` ("\"'\\`$" :: String) || c == ' ' || c == '\t' || c == '\n') m)
    validName n =
      not (T.null n)
        && not ("." `T.isPrefixOf` n)
        && T.all (\c -> c `elem` ("_.@-" :: String) || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || isDigit c) n

-- | The command line as it can be pasted into a shell at the checkout's
-- root: every argument that holds anything but plain characters is in
-- single quotes.
commandLine :: Answers -> Text
commandLine a = T.unwords ("sh" : "toolchain/deploy-local.sh" : map quote (deployArgs a))

quote :: Text -> Text
quote w
  | not (T.null w) && T.all plain w = w
  | otherwise = "'" <> T.replace "'" "'\\''" w <> "'"
  where
    plain c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || isDigit c || c `elem` ("_@%+=:,./-" :: String)
