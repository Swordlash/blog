-- | The program's name and version, as the server reports it: in its log,
-- its status and an export's manifest, and to @wiki-server --version@.
module Wiki.Server.Version
  ( serverVersion
  )
where

import Data.Version (showVersion)
import Paths_wiki_server (version)
import Protolude

-- | @wiki-server 0.1.0.0@: the package and its version, from its .cabal
-- file.
serverVersion :: Text
serverVersion = "wiki-server " <> toS (showVersion version)
