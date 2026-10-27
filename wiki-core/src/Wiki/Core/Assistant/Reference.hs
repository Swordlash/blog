{-# LANGUAGE TemplateHaskell #-}

-- | The wiki's Markdown as its authors are told it: @docs/markdown.md@, the
-- reference the README links to and the demo's guide follows, read when
-- this package is compiled and kept as text in the program. The writing
-- assistant ("Wiki.Core.Assistant.Prompt") puts it first in every request,
-- so that a model writes this wiki's Markdown (its alerts, its math, its
-- fences for Mermaid and TikZ, its links between pages) rather than
-- Markdown in general; and since it is the one source of truth, the prompt
-- follows the reference whenever the reference changes, with nothing to
-- keep in step by hand. A change to the file recompiles this module.
module Wiki.Core.Assistant.Reference
  ( markdownReference
  )
where

import Protolude
import Wiki.Core.Template.Embed (embedText)

-- | The text of @docs/markdown.md@, at the repository's root, through the
-- package's @reference/markdown.md@, a symbolic link to it (cabal takes no
-- file outside the package).
markdownReference :: Text
markdownReference = $(embedText "reference/markdown.md")
