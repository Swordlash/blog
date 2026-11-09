-- | 'Wiki.Server.Storage.Migrate.Code' holds the steps of the schema that
-- are written in Haskell rather than SQL (issue #202). "Wiki.Server.Storage.Migrate"
-- applies them with the schema files. They live in this module, not in
-- that one, because that one is compiled again on every build (it embeds
-- the files), and the steps would be compiled again with it.
module Wiki.Server.Storage.Migrate.Code
  ( CodeStep (..)
  , codeSteps
  )
where

import Protolude
import Wiki.Server.Storage.Backend (Backend (..))

-- | 'CodeStep' is one step of the schema written in Haskell: a change that
-- SQL alone cannot make, such as rewriting the text of every page from an
-- old syntax to a new one.
--
-- A step in code is numbered in the same sequence as the schema files
-- (@wiki-server/migrations@): its number is one that no file of either
-- database has. It runs in the same transaction as the other pending
-- steps, in the order of the numbers, and is recorded in @wiki_schema@ as
-- a file is. So a database is at the version before the step or at the
-- version after it, never halfway, and a step that fails leaves the
-- database as it was before the whole migration. One step runs on both
-- databases. A step once released is never edited: a change is a new step.
--
-- A step reads and writes the database through the connection it is
-- given, with SQL of its own: Beam statements ('runDb') over tables that
-- the step declares itself, or statements that return nothing
-- ('runScript'). Where the SQL of SQLite and PostgreSQL differ, the step
-- asks 'schemaSuffix'. Two rules keep a step working after the program
-- moves on:
--
-- * A step must not use the live schema: 'Wiki.Server.Storage.Schema.wikiDb',
--   the row types of "Wiki.Server.Storage.Schema", or the storage's
--   queries built on them ("Wiki.Server.Storage.Rows" and the like). That
--   schema is the one of the version being built, not the one at the
--   step's number. A later step that adds or renames a column changes it,
--   and the step, run on an older database, would then read or write
--   columns that are not there yet. Each step declares the row shapes it
--   reads and writes, as they are at its number, in its own module, and
--   they never change.
--
-- * A step that rewrites the syntax of pages carries its own rewriter from
--   the old syntax to the new one. It does not call the live parser
--   ("Wiki.Core.Markdown"): once the syntax has changed, that parser no
--   longer understands the old syntax, and the step would stop working.
--
-- A step may need a check of the upgrade's rehearsal of its own: the data
-- in the old form made through the old program, and read back in the new
-- form after the migration. That check goes into
-- 'Wiki.Server.Rehearsal.checks', with the others.
data CodeStep = CodeStep
  { version :: Int
  -- ^ Its number, in the sequence of the schema files.
  , name :: Text
  -- ^ What it does, for a person to read, as a file's name says it.
  , run :: forall be. (Backend be) => Connection be -> IO ()
  -- ^ The step, run in the migration's transaction.
  }

-- | Every step of the schema written in Haskell, in any order: each one in
-- a module of its own under this one, named by its number. None yet; the
-- first come with issues #195 and #201.
codeSteps :: [CodeStep]
codeSteps = []
