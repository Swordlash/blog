-- | Mentions, @\@login@, as text is scanned for them (WP4.13 of
-- docs/PLAN.md): which runs of a page's or a comment's text name one of
-- the wiki's users by their login. "Wiki.Core.Markdown.Ast" applies this to
-- the text of the parsed tree, outside code, links and embeds, and makes a
-- 'Wiki.Core.Markdown.Ast.Mention' of each; whether the login is a user's
-- is decided when it is rendered.
--
-- A mention is an @\@@ that starts a word, followed by a login written with
-- letters, digits, @_@, @.@ and @-@, ending in a letter, a digit or @_@ (so
-- that "thanks \@ada." mentions @ada@). An @\@@ after a letter, a digit or
-- one of @.@, @_@, @-@, @+@, @/@ and @\@@ is part of something else (an
-- address, a path) and mentions nobody. A login with other characters
-- (one a provider gave, with a space or an @\@@ in it) cannot be mentioned.
--
-- This is a pass over the parsed text rather than a commonmark syntax spec
-- (as "Wiki.Core.Markdown.TexMath" is) because a spec's parser is tried at
-- the @\@@ with no way to see the character before it: commonmark records
-- what precedes a delimiter of its own, and the @\@@ is none.
module Wiki.Core.Markdown.Mention
  ( splitMentions
  , isLoginChar
  )
where

import Data.Char (isMark)
import Data.Text qualified as T
import Protolude

-- | Some text, cut at its mentions: 'Left' for text, 'Right' for the login
-- a mention names (without its @\@@). Text next to text is one 'Left', and
-- no 'Left' is empty, so text without a mention is @[Left text]@ (or
-- nothing, for the empty text).
splitMentions :: Text -> [Either Text Text]
splitMentions = merge . go Nothing
  where
    go :: Maybe Char -> Text -> [Either Text Text]
    go before rest = case T.breakOn "@" rest of
      (text, "") -> [Left text]
      (text, at) ->
        let prev = if T.null text then before else Just (T.last text)
            afterAt = T.drop 1 at
            login = loginAt afterAt
            next = T.drop (T.length login) afterAt
         in if startsWord prev && not (T.null login) && not ("@" `T.isPrefixOf` next)
              then Left text : Right login : go (T.unsnoc login <&> snd) next
              else Left (text <> "@") : go (Just '@') afterAt
    merge = \case
      Left a : Left b : rest -> merge (Left (a <> b) : rest)
      Left a : rest | T.null a -> merge rest
      x : rest -> x : merge rest
      [] -> []

-- | Whether an @\@@ after this character (none: the start of the text)
-- starts a word.
startsWord :: Maybe Char -> Bool
startsWord = \case
  Nothing -> True
  Just c -> not (isAlphaNum c || isMark c || c `elem` ("._-+/@" :: [Char]))

-- | The login at the start of some text: the longest run of a login's
-- characters, without the dots and hyphens that end it, which are taken to
-- be the sentence's.
loginAt :: Text -> Text
loginAt = T.dropWhileEnd (`elem` (".-" :: [Char])) . T.takeWhile isLoginChar

-- | A character a mentioned login may have.
isLoginChar :: Char -> Bool
isLoginChar c = isAlphaNum c || isMark c || c `elem` ("._-" :: [Char])
