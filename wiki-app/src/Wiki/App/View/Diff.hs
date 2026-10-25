{-# LANGUAGE QuasiQuotes #-}

-- | A diff of two texts ("Wiki.Core.Diff"), rendered as Halogen HTML: a
-- table of lines with their numbers in the old and the new text, those
-- taken out and put in marked, and within a line that was changed rather
-- than replaced the words that changed; unchanged lines away from a change
-- are left out and counted. What the page's history shows between two
-- versions ("Wiki.App.View.History") and the editor between the author's
-- text and a version saved meanwhile ("Wiki.App.View.Editor").
module Wiki.App.View.Diff
  ( diffView
  , titleChange
  , unchangedLines
  )
where

import Halogen.HTML qualified as HH
import Halogen.TH (hh)
import Protolude
import Wiki.Core.Diff (Diff (..), Hunk (..), Line (..), LineKind (..), Segment (..), hunks, unchanged)

-- | The diff, or that the two texts are the same.
diffView :: Diff -> [HH.HTML w i]
diffView d
  | unchanged d = [[hh|<p class="diff-none">The text is the same.</p>|]]
  | otherwise =
      [ [hh|
          <table class="diff">
            <tbody>{{ concatMap hunk (hunks 3 d.rows) }}</tbody>
          </table>
        |]
      ]

hunk :: Hunk -> [HH.HTML w i]
hunk = \case
  Hidden n -> [[hh|<tr class="diff-gap"><td colspan="4">{{ unchangedLines n }}</td></tr>|]]
  Shown ls -> map line ls

line :: Line -> HH.HTML w i
line l =
  [hh|<tr class="diff-line {{ rowClass }}"><td class="diff-number">{{ number l.old }}</td><td class="diff-number">{{ number l.new }}</td><td class="diff-sign" aria-hidden="true">{{ sign }}</td><td class="diff-text">{{ map segment l.segments }}</td></tr>|]
  where
    (rowClass, sign) = case l.kind of
      Unchanged -> ("diff-kept", " ") :: (Text, Text)
      Removed -> ("diff-removed", "−")
      Added -> ("diff-added", "+")
    -- A line changed whole is marked by its row; only a line with
    -- something kept has its changed words marked.
    partly = any (\s -> not s.changed) l.segments
    segment s
      | s.changed && partly && l.kind == Removed = [hh|<del>{{ s.text }}</del>|]
      | s.changed && partly && l.kind == Added = [hh|<ins>{{ s.text }}</ins>|]
      | otherwise = HH.text s.text
    number = maybe "" (show :: Int -> Text)

-- | A title that changed, the old struck out and the new put in; nothing
-- for one that did not.
titleChange :: Text -> Text -> [HH.HTML w i]
titleChange old new
  | old == new = []
  | otherwise = [[hh|<p class="diff-title">The title: <del>{{ old }}</del> <ins>{{ new }}</ins></p>|]]

unchangedLines :: Int -> Text
unchangedLines n = show n <> (if n == 1 then " unchanged line" else " unchanged lines")
