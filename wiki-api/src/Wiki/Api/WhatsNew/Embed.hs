{-# LANGUAGE TemplateHaskell #-}

-- | The changelog read when a package is compiled, for the page "What's
-- new?": the entries, the version the build's stamp names, and the time.
-- wiki-server splices these into "Wiki.Server.WhatsNew", and wiki-app into
-- "Wiki.App.Demo.WhatsNew" for the demo, which has no server to ask. A
-- separate module because a Template Haskell splice cannot use a function
-- defined in its own module.
--
-- Each package reaches the repository's @changelog\/@ through a symbolic
-- link of its own to @..\/changelog@ (@wiki-server\/changelog@,
-- @wiki-app\/changelog@), as wiki-core reaches docs\/markdown.md: the
-- splice finds the link relative to the directory of the package it runs
-- in ('makeRelativeToProject'). The package's @extra-source-files@ lists
-- every entry through the link and the stamp beside it
-- (@toolchain\/changelog-stamp.sh@ writes it), so that cabal rebuilds the
-- package when an entry is added or edited.
module Wiki.Api.WhatsNew.Embed
  ( embedEntries
  , stampVersion
  , embedBuildTime
  )
where

import Control.Monad.Fail (fail)
import Data.ByteString qualified as BS
import Data.FileEmbed (makeRelativeToProject)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Language.Haskell.TH (Exp, Q, reportError, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import Protolude hiding (lift)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Wiki.Api.WhatsNew.Entry (readEntries, userEntries)

-- | Every entry of the changelog that is not technical, as an expression
-- of type @['Wiki.Api.WhatsNew.Entry.Entry']@. An entry that is not written
-- as "Wiki.Api.WhatsNew.Entry" says is a compile error, which names the
-- file and the problem, technical or not: every entry is read and checked
-- before the technical ones are left out ('userEntries'). Each file read is a dependency of the module, so that
-- GHC compiles it again when one changes; a file added is seen because the
-- module is compiled every time the package is (@-fforce-recomp@ there).
embedEntries :: Q Exp
embedEntries = do
  dir <- makeRelativeToProject "changelog"
  there <- runIO (doesDirectoryExist dir)
  unless there $
    reportError ("What's new: no changelog directory at " <> dir <> " (the package's changelog is a link to the repository's changelog/)")
  names <- if there then runIO (sort . filter (not . isPrefixOf ".") <$> listDirectory dir) else pure []
  files <- for names $ \name -> do
    let path = dir </> name
    addDependentFile path
    contents <- runIO (decodeUtf8' <$> BS.readFile path)
    case contents of
      Left _ -> fail ("What's new: changelog/" <> name <> " is not UTF-8")
      Right t -> pure ("changelog/" <> name, t)
  case readEntries files of
    Left why -> fail ("What's new: a changelog entry is malformed: " <> toS why)
    Right entries -> lift (userEntries entries)

-- | The version the package's @changelog.stamp@ names (its line
-- @version=…@, from the environment variable @WIKI_BUILD_VERSION@ when
-- @toolchain\/changelog-stamp.sh@ wrote it), or 'Nothing' when the stamp
-- names none or is not there. Read from the file rather than the
-- environment because Template Haskell on the WebAssembly compiler sees no
-- environment variables, and files it does.
stampVersion :: Q (Maybe Text)
stampVersion = do
  stamp <- makeRelativeToProject "changelog.stamp"
  there <- runIO (doesFileExist stamp)
  if not there
    then pure Nothing
    else do
      addDependentFile stamp
      contents <- runIO (BS.readFile stamp)
      pure $
        listToMaybe
          [ v
          | line <- T.lines (decodeUtf8 contents)
          , Just v <- [T.strip <$> T.stripPrefix "version=" line]
          , not (T.null v)
          ]

-- | The time of the build, as an expression of type 'Text' in ISO 8601.
embedBuildTime :: Q Exp
embedBuildTime = do
  now <- runIO getCurrentTime
  [|T.pack $(lift (iso8601Show now))|]
