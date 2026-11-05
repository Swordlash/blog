{-# LANGUAGE TemplateHaskell #-}

-- | What the server reads about its own build when it is compiled, for the
-- page "What's new?" ("Wiki.Server.WhatsNew", which splices these): the
-- changelog's entries, the version and the time. A separate module
-- because a Template Haskell splice cannot use a function defined in its
-- own module.
--
-- The entries are the repository's @changelog\/@, at its root. The package
-- reaches it through the symbolic link @wiki-server\/changelog@ to
-- @..\/changelog@, as wiki-core reaches docs\/markdown.md: the splice finds
-- the link relative to the package's directory ('makeRelativeToProject'),
-- and the package's @extra-source-files@ lists every entry through
-- it, so that cabal rebuilds the server when an entry is added or edited.
module Wiki.Server.WhatsNew.Embed
  ( embedEntries
  , embedVersion
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
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Wiki.Server.WhatsNew.Entry (readEntries)

-- | Every entry of the changelog, as an expression of type
-- @['Wiki.Server.WhatsNew.Entry.Entry']@. An entry that is not written as
-- "Wiki.Server.WhatsNew.Entry" says is a compile error, which names the
-- file and the problem. Each file read is a dependency of the module, so
-- that GHC compiles it again when one changes; a file added is seen
-- because the module is compiled every time the package is
-- (@-fforce-recomp@ there).
embedEntries :: Q Exp
embedEntries = do
  dir <- makeRelativeToProject "changelog"
  there <- runIO (doesDirectoryExist dir)
  unless there $
    reportError ("What's new: no changelog directory at " <> dir <> " (wiki-server/changelog is a link to the repository's changelog/)")
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
    Right entries -> lift entries

-- | The build's version, as an expression of type 'Text': the environment
-- variable @WIKI_BUILD_VERSION@ when it is set and not blank (CI and the
-- deploy set it), else what @git describe --tags --always --dirty@ prints
-- in the package's directory, else @unknown@ (a build from a copy without
-- git's history, such as the Docker image's).
embedVersion :: Q Exp
embedVersion = do
  given <- runIO (fmap T.strip . mfilter (not . T.null . T.strip) . fmap toS <$> lookupEnv "WIKI_BUILD_VERSION")
  described <- case given of
    Just v -> pure (Just v)
    Nothing -> runIO $ do
      result <- try (readProcessWithExitCode "git" ["describe", "--tags", "--always", "--dirty"] "")
      pure $ case result of
        Right (ExitSuccess, out, _) | v <- T.strip (toS out), not (T.null v) -> Just v
        Right _ -> Nothing
        Left (_ :: IOException) -> Nothing
  let version = fromMaybe "unknown" described
  [|T.pack $(lift (T.unpack version))|]

-- | The time of the build, as an expression of type 'Text' in ISO 8601.
embedBuildTime :: Q Exp
embedBuildTime = do
  now <- runIO getCurrentTime
  [|T.pack $(lift (iso8601Show now))|]
