{-# LANGUAGE TemplateHaskell #-}

-- | The server's version, read when it is compiled, for the page "What's
-- new?" ("Wiki.Server.WhatsNew", which splices it). The entries and the
-- time come from "Wiki.Api.WhatsNew.Embed", which the demo uses too; the
-- version is the server's own, since only a native compiler's Template
-- Haskell can read the environment and run git. A separate module because
-- a Template Haskell splice cannot use a function defined in its own
-- module.
module Wiki.Server.WhatsNew.Version
  ( embedVersion
  )
where

import Data.Text qualified as T
import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (lift)
import Protolude hiding (lift)
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)

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
