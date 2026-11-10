-- | The files a deploy writes for its service: the systemd user unit, and
-- the server's console @<dir>/bin/wiki@. Their text is the shell's
-- (@toolchain/deploy-local.sh@), byte for byte: the unit is read back by
-- undeploy-local.sh and @--status@ (its @# Prefix:@ line), and its quoting
-- is what systemd parses.
module Maker.Deploy.Unit
  ( unitWord
  , environmentValue
  , Unit (..)
  , renderUnit
  , consoleWrapper
  , dbUrl
  , databaseWords
  )
where

import System.FilePath ((</>))

-- | A word of a unit's @ExecStart=@, quoted for systemd: in double quotes,
-- with backslashes and quotes escaped, and @%@ and @$@ doubled, which
-- systemd would otherwise expand.
unitWord :: String -> String
unitWord s = "\"" <> concatMap escape s <> "\""
  where
    escape = \case
      '\\' -> "\\\\"
      '"' -> "\\\""
      '%' -> "%%"
      '$' -> "$$"
      c -> [c]

-- | The value of an @Environment="NAME=value"@ line: backslashes and quotes
-- escaped and @%@ doubled. Unlike 'unitWord', @$@ is left alone: systemd
-- does not expand variables in @Environment=@.
environmentValue :: String -> String
environmentValue = concatMap $ \case
  '\\' -> "\\\\"
  '"' -> "\\\""
  '%' -> "%%"
  c -> [c]

-- | What a unit says.
data Unit = Unit
  { root :: FilePath
  -- ^ The repository the deploy ran from.
  , name :: String
  , prefix :: FilePath
  -- ^ The deployment's prefix, empty for one in the home directory.
  , description :: String
  , execStart :: String
  , extra :: [String]
  -- ^ The service's lines after the fixed ones (a server's umask, its
  -- stop timeout and environment).
  }

-- | The unit file's text.
renderUnit :: Unit -> String
renderUnit u =
  unlines $
    [ "# Written by toolchain/deploy-local.sh from " <> u.root <> ";"
    , "# run it again to change this deployment, or toolchain/undeploy-local.sh --name " <> u.name <> prefixArg
    , "# to take it down."
    ]
      <> ["# Prefix: " <> u.prefix | not (null u.prefix)]
      <> [ "[Unit]"
         , "Description=" <> u.description
         , "After=network-online.target"
         , "# Restart for as long as it takes: at boot the Tailscale address may appear a"
         , "# little after this starts, and listening on it fails until then."
         , "StartLimitIntervalSec=0"
         , ""
         , "[Service]"
         , "ExecStart=" <> u.execStart
         , "Restart=on-failure"
         , "RestartSec=5"
         , "NoNewPrivileges=yes"
         ]
      -- The shell's heredoc has a line for its extra lines, empty when
      -- there are none.
      <> (if null u.extra then [""] else u.extra)
      <> [ ""
         , "[Install]"
         , "WantedBy=default.target"
         ]
  where
    prefixArg = if null u.prefix then "" else " --prefix " <> u.prefix

-- | The URL of a deployment's PostgreSQL database on its port, without its
-- password, which is in a file of the deployment's.
dbUrl :: String -> String
dbUrl port = "postgres://wiki@127.0.0.1:" <> port <> "/wiki"

-- | The words of a server unit's @ExecStart=@ that name its database, with
-- the space before them: @--sqlite@ and the deployment's file, or the
-- PostgreSQL database with its password file and its @pg_dump@ and
-- @pg_restore@. The arguments are the database (@postgres@ or not), the
-- deployment's directory, the database's port and the PostgreSQL
-- directory. The deploy writes them, and the move to PostgreSQL
-- ("Maker.Deploy.Move") finds the first and puts the second in its place.
databaseWords :: String -> FilePath -> String -> FilePath -> String
databaseWords db dir dbPort pgDir
  | db == "postgres" =
      " --database " <> dbUrl dbPort <> " --database-password-file " <> unitWord (pgDir </> "db-password") <> " --pg-dump " <> unitWord (pgDir </> "pg_dump") <> " --pg-restore " <> unitWord (pgDir </> "pg_restore")
  | otherwise = " --sqlite " <> unitWord (dir </> "data" </> "wiki.sqlite")

-- | The console of a deployment, @<dir>/bin/wiki@: wiki-server with the
-- deployment's database, given in the environment, for @users@, @backup@,
-- @restore@ and @oidc check@ with @--data@ alone. The arguments are the
-- deployment's name and directory, its database (@postgres@ or not), its
-- database's port and its PostgreSQL directory.
consoleWrapper :: String -> FilePath -> String -> String -> FilePath -> String
consoleWrapper name dir db dbPort pgDir =
  unlines $
    [ "#!/bin/sh"
    , "# wiki-server with the database of the deployment " <> name <> ", written by"
    , "# toolchain/deploy-local.sh. For example: " <> dir <> "/bin/wiki users list --data " <> dir <> "/data"
    ]
      <> ( if db == "postgres"
             then
               [ "WIKI_DATABASE_URL='" <> dbUrl dbPort <> "'"
               , "WIKI_DATABASE_PASSWORD_FILE='" <> pgDir <> "/db-password'"
               , "WIKI_PG_DUMP='" <> pgDir <> "/pg_dump'"
               , "WIKI_PG_RESTORE='" <> pgDir <> "/pg_restore'"
               , "export WIKI_DATABASE_URL WIKI_DATABASE_PASSWORD_FILE WIKI_PG_DUMP WIKI_PG_RESTORE"
               ]
             else
               [ "# The database is the SQLite file in the data directory."
               , "unset WIKI_DATABASE_URL WIKI_DATABASE_PASSWORD_FILE"
               ]
         )
      <> ["exec '" <> dir <> "/bin/wiki-server' \"$@\""]
