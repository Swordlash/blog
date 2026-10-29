-- | Mentions: an @\@login@ in text that names one of the wiki's users
-- (WP4.13 of docs/PLAN.md). This module finds the mentions in a page's or
-- a comment's text. "Wiki.Core.Markdown.Ast" runs it on the text of the
-- parsed tree, outside code, links and embeds, and turns each mention into
-- a 'Wiki.Core.Markdown.Ast.Mention'. Whether the login belongs to a user
-- is checked when the mention is rendered.
--
-- A mention is an @\@@ that starts a word, followed by a login made of
-- letters, digits, @_@, @.@ and @-@ and ending in a letter, a digit or @_@
-- (so that "thanks \@ada." mentions @ada@). An @\@@ after a letter, a digit
-- or one of @.@, @_@, @-@, @+@, @/@ and @\@@ is part of something else (an
-- email address, a path) and mentions nobody. A login with other
-- characters (one from a sign-in provider, with a space or an @\@@ in it)
-- cannot be mentioned.
--
-- This is a pass over the parsed text rather than a commonmark syntax spec
-- (as "Wiki.Core.Markdown.TexMath" is) because a spec's parser is called
-- at the @\@@ and cannot see the character before it. Commonmark records
-- the preceding character only for its own delimiters, and @\@@ is not one.
module Wiki.Core.Markdown.Mention
  ( splitMentions
  , isLoginChar
  , mentionsWhole
  )
where

import Data.Char (isMark)
import Data.Text qualified as T
import Protolude

-- | Text split at its mentions: 'Left' for plain text, 'Right' for the
-- login a mention names (without its @\@@). Adjacent plain text is one
-- 'Left', and no 'Left' is empty, so text without a mention is
-- @[Left text]@ (or the empty list, for the empty text).
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

-- | Whether @\@login@, written after a space, mentions this login and
-- nothing less: whether the login can be mentioned at all. A login with a
-- character a mention stops at (a space, an @\@@ or other punctuation),
-- or that ends in a @.@ or a @-@, is read as a mention of a shorter login
-- or of nobody. The editor offers to complete a mention only with logins
-- for which this holds ("Wiki.App.Backend.Notifications"'
-- @mentionCandidates@).
mentionsWhole :: Text -> Bool
mentionsWhole login = splitMentions ("@" <> login) == [Right login]

-- | Whether an @\@@ after this character ('Nothing': the start of the
-- text) starts a word.
startsWord :: Maybe Char -> Bool
startsWord = \case
  Nothing -> True
  Just c -> not (isAlphaNum c || isMark c || c `elem` ("._-+/@" :: [Char]))

-- | The login at the start of some text: the longest run of login
-- characters, without trailing dots and hyphens, which are taken to be
-- the sentence's punctuation.
loginAt :: Text -> Text
loginAt = T.dropWhileEnd (`elem` (".-" :: [Char])) . T.takeWhile isLoginChar

-- | A character a mentioned login may contain.
isLoginChar :: Char -> Bool
isLoginChar c = isAlphaNum c || isMark c || c `elem` ("._-" :: [Char])
