{-# LANGUAGE TemplateHaskell #-}

-- | The Markdown reference: @docs/markdown.md@, the description of the
-- wiki's Markdown for its authors, which the README links to and the
-- demo's guide follows. It is read when this package is compiled and
-- stored as text in the program. The writing assistant
-- ("Wiki.Core.Assistant.Prompt") puts it first in every request, so that
-- a model writes this wiki's Markdown (its alerts, its math, its fences
-- for Mermaid and TikZ, its links between pages) rather than Markdown in
-- general. Since the file is the single source of truth, the prompt
-- follows every change to the reference, with nothing to keep in sync by
-- hand. A change to the file recompiles this module.
module Wiki.Core.Assistant.Reference
  ( markdownReference
  )
where

import Protolude
import Wiki.Core.Template.Embed (embedText)

-- | The text of @docs/markdown.md@, at the repository's root, read through
-- the package's @reference/markdown.md@, a symbolic link to it (cabal
-- accepts no file outside the package).
markdownReference :: Text
markdownReference = $(embedText "reference/markdown.md")
