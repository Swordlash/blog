-- | The program's name and version, as the server reports it: in its log,
-- its status and an export's manifest, and to @wiki-server --version@.
module Wiki.Server.Version
  ( serverVersion
  , serverBackends
  , versionReport
  )
where

import Data.Text qualified as T
import Data.Version (showVersion)
import Paths_wiki_server (version)
import Protolude
import Wiki.Server.Storage.Layout (withPostgres)

-- | @wiki-server 0.1.0.0@: the package and its version, from its .cabal
-- file.
serverVersion :: Text
serverVersion = "wiki-server " <> toS (showVersion version)

-- | The databases this wiki-server can keep the wiki in: SQLite always,
-- and PostgreSQL when it was built with it (the cabal flag @postgres@,
-- 'withPostgres').
serverBackends :: [Text]
serverBackends = "sqlite" : ["postgresql" | withPostgres]

-- | What @wiki-server --version@ prints: 'serverVersion', and on a second
-- line the databases it was built for (@backends: sqlite, postgresql@), so
-- that an operator can tell a build without PostgreSQL from one with it.
versionReport :: Text
versionReport = serverVersion <> "\nbackends: " <> T.intercalate ", " serverBackends
