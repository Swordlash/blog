-- | The editor's problems as CodeMirror marks them: each problem of the
-- page ("Wiki.Core.Markdown.Problems"), which is a range of source lines,
-- turned into a range of characters of the editor's text (WP5.65 of
-- docs/PLAN.md).
--
-- A range runs from the start of the problem's first line to the end of
-- its last line, without the line break. Lines outside the text are
-- clamped to its first and last lines: the text may have changed since the
-- problem was found (an island's library answers later), and CodeMirror
-- must not be given a range past the text's end. The browser side
-- (@jsbits/editor.js@) turns the characters into CodeMirror's UTF-16
-- positions, and clamps them again to the text CodeMirror holds.
module Wiki.App.Editor.Problems
  ( ProblemRange (..)
  , problemRanges
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Protolude
import Wiki.Core.Markdown.Problems (Problem (..), Severity (..), kindName)

-- | 'ProblemRange' is a problem as the editor shows it: the characters it
-- underlines, from (included) to (excluded), counted from 0 in the text,
-- the kind's name, how much it matters, and the message.
data ProblemRange = ProblemRange
  { from :: Int
  , to :: Int
  , kind :: Text
  , severity :: Text
  -- ^ @error@ or @warning@, as CodeMirror names them
  -- ('Wiki.Core.Markdown.Problems.Severity').
  , message :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON ProblemRange where
  toJSON r = object ["from" .= r.from, "to" .= r.to, "kind" .= r.kind, "severity" .= r.severity, "message" .= r.message]

-- | The ranges of some problems in a text, in the problems' order.
problemRanges :: Text -> [Problem] -> [ProblemRange]
problemRanges text = map range
  where
    -- Each line's first character and its length. A text ending with a
    -- line break has an empty last line, as CodeMirror counts lines.
    lineLengths = Seq.fromList (map T.length (T.splitOn "\n" text))
    starts = Seq.scanl (\at len -> at + len + 1) 0 lineLengths
    count = Seq.length lineLengths
    clamp n = max 1 (min count n)
    startOf n = fromMaybe 0 (Seq.lookup (clamp n - 1) starts)
    endOf n = startOf n + fromMaybe 0 (Seq.lookup (clamp n - 1) lineLengths)
    range p =
      let opening = min p.from p.to
          closing = max p.from p.to
       in ProblemRange {from = startOf opening, to = endOf closing, kind = kindName p.kind, severity = severityName p.severity, message = p.message}
    severityName = \case
      Error -> "error"
      Warning -> "warning"
