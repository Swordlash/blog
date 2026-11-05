{-# LANGUAGE TemplateHaskell #-}
-- The changelog is a directory read when this module is compiled
-- ("Wiki.Api.WhatsNew.Embed"), and GHC knows only the files it found
-- there last time: an entry added later would not make it compile this
-- module again. cabal does see the new file (extra-source-files lists
-- the entries) and rebuilds the package, so this module is compiled
-- whenever the package is, which also takes the version and the time of
-- that build. It is small and cheap; the modules that import it are
-- compiled again only if its interface changes, which the NOINLINE
-- pragmas below keep from happening when only the values do.
{-# OPTIONS_GHC -fforce-recomp #-}

-- | The page "What's new?" as this server was built (WP5.66 of
-- docs/PLAN.md): the newest changelog entries of the repository's
-- @changelog\/@, the version and the time of the build, read when the
-- server was compiled ("Wiki.Api.WhatsNew.Embed"), so that the binary
-- carries them wherever it runs. @GET api\/v1\/whats-new@ answers
-- 'embeddedWhatsNew', unless the server runs with @--no-whats-new@.
module Wiki.Server.WhatsNew
  ( embeddedWhatsNew
  , changelogEntries
  , buildVersion
  , buildTime
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Protolude
import Wiki.Api.WhatsNew (WhatsNew)
import Wiki.Api.WhatsNew.Embed (embedBuildTime, embedEntries)
import Wiki.Api.WhatsNew.Entry (Entry, toWhatsNew)
import Wiki.Server.WhatsNew.Version (embedVersion)

-- | Every entry of the changelog this server was compiled with, numbered
-- or not.
changelogEntries :: [Entry]
changelogEntries = $(embedEntries)
{-# NOINLINE changelogEntries #-}

-- | The build's version: @WIKI_BUILD_VERSION@, or @git describe@, or
-- @unknown@.
buildVersion :: Text
buildVersion = $(embedVersion)
{-# NOINLINE buildVersion #-}

-- | When the server was compiled.
buildTime :: UTCTime
buildTime = fromMaybe (posixSecondsToUTCTime 0) (iso8601ParseM (T.unpack $(embedBuildTime)))
{-# NOINLINE buildTime #-}

-- | What @GET api\/v1\/whats-new@ answers: the version, the time and the
-- newest entries.
embeddedWhatsNew :: WhatsNew
embeddedWhatsNew = toWhatsNew buildVersion buildTime changelogEntries
{-# NOINLINE embeddedWhatsNew #-}
