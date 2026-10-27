-- | A page's Markdown, parsed ("Wiki.Core.Markdown.Ast") and rendered to
-- Halogen HTML ("Wiki.Core.Markdown.Render"), with its table of contents
-- ("Wiki.Core.Markdown.Toc"). The syntax authors write is
-- described in @docs/markdown.md@.
module Wiki.Core.Markdown
  ( renderMarkdown
  , module Wiki.Core.Markdown.Ast
  , module Wiki.Core.Markdown.Link
  , module Wiki.Core.Markdown.Render
  , module Wiki.Core.Markdown.Toc
  )
where

import Halogen.HTML qualified as HH
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Link
import Wiki.Core.Markdown.Render
import Wiki.Core.Markdown.Toc

-- | Parse a page's Markdown and render it in one step, for a caller that
-- does not need the parsed tree.
renderMarkdown :: Options page w i -> Text -> Either ParseError [HH.HTML w i]
renderMarkdown opts source = renderBlocks opts <$> parseMarkdown source
