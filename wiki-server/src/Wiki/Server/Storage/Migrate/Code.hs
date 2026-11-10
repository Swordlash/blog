-- | 'Wiki.Server.Storage.Migrate.Code' holds the steps of the schema that
-- are written in Haskell rather than SQL (issue #202). "Wiki.Server.Storage.Migrate"
-- applies them with the schema files. They live under this module, not in
-- that one, because that one is compiled again on every build (it embeds
-- the files), and the steps would be compiled again with it.
module Wiki.Server.Storage.Migrate.Code
  ( CodeStep (..)
  , codeSteps
  )
where

import Wiki.Server.Storage.Migrate.Code.Step0012 (step0012)
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))

-- | Every step of the schema written in Haskell, in any order: each one in
-- a module of its own under this one, named by its number.
codeSteps :: [CodeStep]
codeSteps = [step0012]
