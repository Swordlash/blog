{-# LANGUAGE TemplateHaskell #-}

-- | A file of the package's, read when the package is compiled and kept as
-- text in the program: the built-in templates ("Wiki.Core.Template") are
-- Markdown files beside the code rather than strings in it, so that they
-- are written and read as the pages they become. A module of its own,
-- since a splice cannot use a function of the module it is in.
module Wiki.Core.Template.Embed
  ( embedText
  )
where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import Protolude hiding (lift)

-- | The text of a file, by its path from the package's directory, as an
-- expression of type 'Text'; the file is UTF-8, whatever the locale of
-- the machine that compiles it. A change to the file recompiles the module
-- that embeds it.
embedText :: FilePath -> Q Exp
embedText path = do
  addDependentFile path
  contents <- runIO (decodeUtf8 <$> BS.readFile path)
  [|T.pack $(lift (T.unpack contents))|]
