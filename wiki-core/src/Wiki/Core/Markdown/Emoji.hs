-- | The search of emoji names for the editor (WP5.86 of docs/PLAN.md): the
-- list the editor shows after a colon, and the toolbar's "Emoji" menu.
--
-- The names are those the wiki's Markdown parses as emoji: the @emojis@
-- package's list of GitHub's names (1,913 of them), which
-- commonmark-extensions reads to parse @:name:@. Both the editor and the
-- parser read that one list, so a name the editor offers is always one the
-- page shows as an emoji. The editor has no list of its own: CodeMirror asks
-- the component, which answers with 'emojiMatches'.
module Wiki.Core.Markdown.Emoji
  ( emojiMatches
  , allEmoji
  , emojiLimit
  , commonEmoji
  , isEmojiNameChar
  )
where

import Data.Char (isAsciiLower)
import Data.Text qualified as T
import Protolude
import Text.Emoji (emojiFromAlias, emojis)

-- | The emoji whose names match what was typed, as (name, emoji) pairs,
-- at most 'emojiLimit' of them. The name equal to the letters comes first,
-- then the names that start with them, then the names with a word (a part
-- after @_@ or @-@) that starts with them, each group in the list's own
-- order, which keeps similar emoji together. A name that holds the letters
-- only inside a word does not match: @30@ finds no clock, so a time typed
-- as @12 :30@ opens no list. Upper and lower case are the same, and a space
-- is an @_@, so the menu's field finds "party popper" as @party_popper@.
-- No letters at all give 'commonEmoji'.
emojiMatches :: Text -> [(Text, Text)]
emojiMatches typed
  | T.null letters = commonEmoji
  | otherwise = take emojiLimit (exact <> starting <> inside)
  where
    letters = T.replace " " "_" (T.toLower (T.strip typed))
    exact = [e | e@(name, _) <- allEmoji, name == letters]
    starting = [e | e@(name, _) <- allEmoji, name /= letters, letters `T.isPrefixOf` name]
    inside = [e | e@(name, _) <- allEmoji, not (letters `T.isPrefixOf` name), any (letters `T.isPrefixOf`) (laterWords name)]
    laterWords name = drop 1 (T.split (\c -> c == '_' || c == '-') name)

-- | Every emoji the wiki knows by name, as (name, emoji) pairs, in the
-- @emojis@ package's order: GitHub's list, grouped as Unicode groups the
-- emoji (faces first). An emoji with several names (@+1@ and @thumbsup@)
-- is here once for each.
allEmoji :: [(Text, Text)]
allEmoji = emojis

-- | How many emoji a search offers at most: a list the editor shows in a
-- few screens, and a grid the menu shows without scrolling far.
emojiLimit :: Int
emojiLimit = 50

-- | The emoji offered before a letter of a name is typed: a few that pages
-- of a wiki use often (agreement, done and not done, warnings, ideas,
-- notes), rather than the list's first ones, which are all faces.
commonEmoji :: [(Text, Text)]
commonEmoji =
  mapMaybe
    (\name -> (name,) <$> emojiFromAlias name)
    [ "+1"
    , "tada"
    , "white_check_mark"
    , "x"
    , "warning"
    , "bulb"
    , "memo"
    , "pushpin"
    , "rocket"
    , "sparkles"
    , "fire"
    , "eyes"
    , "heart"
    , "smile"
    , "thinking"
    , "question"
    , "exclamation"
    , "construction"
    , "bug"
    , "calendar"
    , "link"
    , "star"
    , "-1"
    , "zap"
    ]

-- | Whether a character can be part of an emoji's name: the list's names
-- are lower-case letters, digits, @_@, @+@ and @-@ (@+1@, @t-rex@).
isEmojiNameChar :: Char -> Bool
isEmojiNameChar c = isAsciiLower c || isDigit c || c `elem` ("_+-" :: [Char])
