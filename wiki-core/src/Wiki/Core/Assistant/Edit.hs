-- | How the writing assistant changes a page, as pure functions: the edits
-- a model asks for through its two tools, where each one goes in the page
-- as it is now, and the changes the author then accepts or rejects.
--
-- A model edits by quoting: 'Replace' names text the page has, and the text
-- to put in its place; 'Insert' names text to put before or after a quote,
-- or at the page's start or end. A quote must occur exactly once in the
-- page, so that there is no doubt where the edit goes; one that does not
-- occur, or occurs more than once, is refused, and the refusal goes back to
-- the model as its tool's answer ('answer'), which tells it what to do
-- instead (quote more of the text around it). Offsets count characters
-- (code points), as 'Text' does; the browser's side converts them to the
-- UTF-16 units CodeMirror counts.
--
-- An edit made is a tracked change ('Change'): the new text is in the page
-- (so the preview, the draft and a save see it), and what it replaced is
-- kept beside it until the author decides. Accepting a change forgets what
-- it replaced; rejecting it puts that back ('settle'). CodeMirror keeps the
-- changes, moving them as the author types around them, and hands them
-- here when a decision is made. A change never overlaps another: an edit
-- that touches a change not yet decided takes it in ('propose'), so that
-- rejecting the new one goes back to the text before it, the earlier
-- change's text included, as accepted.
module Wiki.Core.Assistant.Edit
  ( -- * Edits
    Edit (..)
  , Anchor (..)
  , Place (..)
  , parseEdit
  , describeEdit

    -- * Where an edit goes
  , Replacement (..)
  , Refusal (..)
  , plan
  , occurrences
  , answer
  , apply

    -- * Tracked changes
  , Change (..)
  , propose
  , track
  , Decision (..)
  , settle
  )
where

import Control.Monad (fail)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import Data.Text qualified as T
import Protolude

-- | An edit a model asks for.
data Edit
  = -- | Put @new@ in the place of @old@, which the page has exactly once.
    Replace {old :: Text, new :: Text}
  | -- | Put text before or after an anchor.
    Insert {anchor :: Anchor, place :: Place, text :: Text}
  deriving stock (Eq, Show)

-- | Where an insertion is made relative to.
data Anchor = AtStart | AtEnd | AtText Text
  deriving stock (Eq, Show)

data Place = Before | After
  deriving stock (Eq, Show)

-- | A tool call's edit, from the tool's name and its input; or why it is no
-- edit, which goes back to the model as its answer.
parseEdit :: Text -> Value -> Either Refusal Edit
parseEdit name input = case name of
  "replace" -> parsed $ withObject "replace" $ \o -> Replace <$> o .: "old_text" <*> o .: "new_text"
  "insert" -> parsed $ withObject "insert" $ \o -> do
    anchor <- anchorOf <$> o .: "anchor"
    place <- o .: "where" >>= placeOf
    text <- o .: "text"
    pure Insert {anchor, place, text}
  _ -> Left (UnknownTool name)
  where
    parsed :: (Value -> Parser Edit) -> Either Refusal Edit
    parsed p = first (Malformed . toS) (parseEither p input)
    anchorOf :: Text -> Anchor
    anchorOf = \case
      "start" -> AtStart
      "end" -> AtEnd
      t -> AtText t
    placeOf :: Text -> Parser Place
    placeOf = \case
      "before" -> pure Before
      "after" -> pure After
      other -> fail ("\"where\" is \"before\" or \"after\", not " <> show other)

-- | An edit in a few words, for the conversation: what was replaced with
-- what, or what was put where, each quote cut short.
describeEdit :: Edit -> Text
describeEdit = \case
  Replace old new
    | T.null new -> "Removed " <> quote old
    | otherwise -> "Replaced " <> quote old <> " with " <> quote new
  Insert anchor place text ->
    "Inserted " <> quote text <> " " <> case (anchor, place) of
      (AtStart, _) -> "at the start"
      (AtEnd, _) -> "at the end"
      (AtText a, Before) -> "before " <> quote a
      (AtText a, After) -> "after " <> quote a
  where
    quote t =
      let flat = T.unwords (T.words t)
       in "\8220" <> (if T.length flat > 60 then T.take 57 flat <> "\8230" else flat) <> "\8221"

-- | Text in place of a part of the page: the characters from @from@ up to
-- @to@ (not included) give way to @text@.
data Replacement = Replacement
  { from :: Int
  , to :: Int
  , text :: Text
  }
  deriving stock (Eq, Show)

-- | Why an edit was not made.
data Refusal
  = -- | The quote is not in the page.
    NotFound Text
  | -- | The quote is in the page this many times.
    FoundMany Text Int
  | -- | A replacement of nothing, which is an insertion.
    EmptyQuote
  | -- | The model called a tool there is none of.
    UnknownTool Text
  | -- | The tool's input was not what it takes.
    Malformed Text
  deriving stock (Eq, Show)

-- | Where an edit goes in the page as it is now, or why it cannot.
plan :: Edit -> Text -> Either Refusal Replacement
plan edit page = case edit of
  Replace old new
    | T.null old -> Left EmptyQuote
    | otherwise -> (\at -> Replacement at (at + T.length old) new) <$> unique old
  Insert anchor place text -> do
    at <- case anchor of
      AtStart -> pure 0
      AtEnd -> pure (T.length page)
      AtText a
        | T.null a -> Left EmptyQuote
        | otherwise -> (\start -> if place == Before then start else start + T.length a) <$> unique a
    pure (Replacement at at text)
  where
    unique quote = case occurrences quote page of
      [at] -> Right at
      [] -> Left (NotFound quote)
      several -> Left (FoundMany quote (length several))

-- | Where a quote starts in the page, each place it does (not overlapping).
occurrences :: Text -> Text -> [Int]
occurrences quote page
  | T.null quote = []
  | otherwise = go 0 page
  where
    go offset rest = case T.breakOn quote rest of
      (_, found) | T.null found -> []
      (before, found) ->
        let at = offset + T.length before
         in at : go (at + T.length quote) (T.drop (T.length quote) found)

-- | The tool's answer to the model: that the edit was made, or why not and
-- what to do instead.
answer :: Either Refusal a -> Text
answer = \case
  Right _ -> "Applied. The user will accept or reject the change."
  Left (NotFound _) -> "Not applied: the page does not contain that text. Quote the page exactly as it is now, including its Markdown."
  Left (FoundMany _ n) -> "Not applied: that text occurs " <> show n <> " times in the page. Quote more of the text around it, so that it occurs once."
  Left EmptyQuote -> "Not applied: the text to look for is empty. To add text, use insert, with \"start\" or \"end\" or a quote as its anchor."
  Left (UnknownTool name) -> "Not applied: there is no tool called " <> name <> "; there are replace and insert."
  Left (Malformed why) -> "Not applied: the tool's input is not what it takes (" <> why <> ")."

-- | The page with a replacement made.
apply :: Replacement -> Text -> Text
apply r page = T.take r.from page <> r.text <> T.drop r.to page

-- | A change not yet accepted or rejected: the characters from @from@ up to
-- @to@ are the text the edit put in, and @removed@ what was there before.
data Change = Change
  { id :: Int
  , from :: Int
  , to :: Int
  , removed :: Text
  }
  deriving stock (Eq, Show)

-- | The change a replacement makes to the page as it was, by its id, with
-- the changes not yet decided that it takes in: those it overlaps, which
-- stop being tracked (as if accepted), so that the new change's removed
-- text is all that rejecting it has to put back.
propose :: Int -> Replacement -> Text -> [Change] -> (Change, [Int])
propose i r page pending =
  ( Change {id = i, from = r.from, to = r.from + T.length r.text, removed = T.take (r.to - r.from) (T.drop r.from page)}
  , [c.id | c <- pending, overlaps c]
  )
  where
    overlaps c
      -- An insertion: inside a change's text, not at either end of it.
      | r.from == r.to = c.from < r.from && r.from < c.to
      -- A deletion's change holds no text, only a place: one in the part
      -- replaced, or at either end of it, is taken in, so that two removals
      -- one after the other are one change.
      | c.from == c.to = r.from <= c.from && c.from <= r.to
      | otherwise = r.from < c.to && c.from < r.to

-- | An edit made and tracked, as the editor does it: the page with the
-- replacement made, and the changes with the new one, those it took in
-- gone, and those after it moved along with the text. CodeMirror does the
-- same (@web/src/editor.js@), and moves the changes as the author types
-- too; this is its model, which the tests check 'settle' against.
track :: Int -> Replacement -> Text -> [Change] -> (Text, [Change])
track i r page pending = (apply r page, change : map moved (filter ((`notElem` taken) . (\c -> c.id)) pending))
  where
    (change, taken) = propose i r page pending
    delta = T.length r.text - (r.to - r.from)
    moved c
      | c.from >= r.to = Change {id = c.id, from = c.from + delta, to = c.to + delta, removed = c.removed}
      | otherwise = c

data Decision = Accept | Reject
  deriving stock (Eq, Show)

-- | What to write to settle these changes: nothing to accept them (their
-- text is in the page already), and to reject them what each replaced, put
-- back in its place. The replacements are given from the last in the page
-- to the first (of two at one place, the one with text first), so that
-- each, made in turn, finds its place where it was: changes never overlap.
settle :: Decision -> [Change] -> [Replacement]
settle Accept _ = []
settle Reject changes = [Replacement c.from c.to c.removed | c <- sortOn (\c -> Down (c.from, c.to)) changes]
