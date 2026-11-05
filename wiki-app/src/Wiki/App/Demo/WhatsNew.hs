{-# LANGUAGE TemplateHaskell #-}
-- The changelog is a directory read when this module is compiled
-- ("Wiki.Api.WhatsNew.Embed"), and GHC knows only the files it found
-- there last time: an entry added later would not make it compile this
-- module again. cabal does see the new file (extra-source-files lists the
-- entries and changelog.stamp) and rebuilds the package, so this module is
-- compiled whenever the package is. It is small; the modules that import
-- it are compiled again only if its interface changes, which the NOINLINE
-- pragma keeps from happening when only the value does.
{-# OPTIONS_GHC -fforce-recomp #-}

-- | The page "What's new?" in the demo (WP5.71 of docs/PLAN.md): the
-- newest entries of the repository's @changelog\/@, read when the
-- application was compiled, as the server reads them, since the demo has
-- no server to ask. The demo's wiki ("Wiki.App.Demo") carries it, and its
-- backend answers it ("Wiki.App.Backend.Mem"). The version is the one the
-- build's stamp names (@WIKI_BUILD_VERSION@ in CI), else @unknown@: the
-- WebAssembly compiler's Template Haskell cannot read the environment or
-- run git, as the server's does.
module Wiki.App.Demo.WhatsNew
  ( demoWhatsNew
  )
where

import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Language.Haskell.TH.Syntax (lift)
import Protolude hiding (lift)
import Wiki.Api.WhatsNew (WhatsNew)
import Wiki.Api.WhatsNew.Embed (embedBuildTime, embedEntries, stampVersion)
import Wiki.Api.WhatsNew.Entry (toWhatsNew)

-- | The demo's answer to "What's new?": the newest twelve entries, the
-- version and the time of the build.
demoWhatsNew :: WhatsNew
demoWhatsNew =
  toWhatsNew
    (T.pack $(stampVersion >>= lift . T.unpack . fromMaybe "unknown"))
    (fromMaybe (posixSecondsToUTCTime 0) (iso8601ParseM (T.unpack $(embedBuildTime))))
    $(embedEntries)
{-# NOINLINE demoWhatsNew #-}
