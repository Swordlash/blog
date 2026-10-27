{-# LANGUAGE TemplateHaskell #-}

-- | File embedding: a file of the package, read when the package is
-- compiled and stored as text in the program. The built-in templates
-- ("Wiki.Core.Template") are Markdown files next to the code rather than
-- strings in it, so that they are written and read as the pages they
-- become. This is a separate module because a Template Haskell splice
-- cannot use a function defined in its own module.
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
-- expression of type 'Text'. The file is read as UTF-8, whatever the
-- locale of the machine that compiles it. A change to the file recompiles
-- the module that embeds it.
embedText :: FilePath -> Q Exp
embedText path = do
  addDependentFile path
  contents <- runIO (decodeUtf8 <$> BS.readFile path)
  [|T.pack $(lift (T.unpack contents))|]
