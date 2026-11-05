{-# LANGUAGE DeriveLift #-}

-- | A changelog entry: one Markdown file under the repository's
-- @changelog\/@, which says what one pull request changed, for the wiki's
-- users (WP5.66 of docs/PLAN.md). This module reads one, and refuses one
-- that is not written as the grammar below says. The server reads every
-- entry when it is compiled ("Wiki.Server.WhatsNew"), so a malformed entry
-- is a compile error. @toolchain\/check-changelog.sh@ checks the same
-- grammar in a pull request's CI, and the two must say the same: a change
-- to one is a change to the other, and to the README's "Changelog
-- entries".
--
-- = The grammar
--
-- A file is named @\<number>-\<slug>.md@: the number is the entry's @pr@
-- with zeros in front to five digits (@00000@ while it is not numbered
-- yet), so that the files list in the order the pull requests were opened;
-- the slug is lower-case letters and digits in words joined by single
-- hyphens (@00160-heading-spoilers.md@). It is UTF-8 with Unix line ends,
-- and reads:
--
-- > ---
-- > pr: 158
-- > title: A copy button on code blocks
-- > ---
-- >
-- > ## New features
-- >
-- > …
-- >
-- > ## Bug fixes
-- >
-- > …
-- >
-- > ## Other changes
-- >
-- > …
--
-- * The front matter is the first four lines, exactly: @---@, then
--   @pr: N@, then @title: T@, then @---@. N is the pull request's number,
--   digits without a leading zero; 0 means "not numbered yet", which an
--   entry has between its commit and the pull request's opening, and the
--   page leaves out. T is the title, not empty, at most 80 bytes of
--   UTF-8 (80 letters of English; a letter outside ASCII takes two or
--   more). Spaces and tabs around N and T are not part of them.
-- * After it, blank lines, then the sections. A section starts with one of
--   the lines @## New features@, @## Bug fixes@ and @## Other changes@,
--   written exactly so; each comes at most once, in that order, and at
--   least one is there. A section holds everything up to the next one,
--   and holds something.
-- * No other heading of level one or two (a line of @#@ or @##@ and a
--   space, after at most three spaces) outside a code block: the page
--   heads the entry and its sections itself. Deeper headings are allowed.
-- * @## New features@ holds at least one fenced code block: every new
--   feature comes with an example.
-- * A fenced code block opens with a line of three or more backticks or
--   tildes (after any indentation, as in a list item) and closes with a
--   line of at least as many of the same character and nothing else; one
--   left open at the end of the file is refused.
module Wiki.Api.WhatsNew.Entry
  ( -- * Entries
    Entry (..)
  , Section (..)
  , sectionHeading
  , parseEntry
  , entryMarkdown

    -- * The directory
  , entryFileName
  , readEntries
  , newestEntries
  , shownEntries
  , toWhatsNew
  )
where

import Data.ByteString qualified as BS
import Data.Char (isAsciiLower)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Language.Haskell.TH.Syntax (Lift)
import Protolude
import System.FilePath (takeExtension, takeFileName)
import Wiki.Api.WhatsNew (WhatsNew (..), WhatsNewEntry (..), pullRequestUrl)

-- | 'Entry' is a changelog entry as its file says it.
data Entry = Entry
  { pr :: Int
  -- ^ The pull request's number, 0 for one not numbered yet.
  , title :: Text
  , sections :: [(Section, Text)]
  -- ^ Its sections, in order, each with its Markdown without the
  -- section's heading and without blank lines around it.
  }
  deriving stock (Eq, Show, Lift)

-- | 'Section' is one of the three sections an entry may have, in the order
-- they come.
data Section = NewFeatures | BugFixes | OtherChanges
  deriving stock (Eq, Ord, Show, Enum, Bounded, Lift)

-- | A section's heading, as the file writes it after @## @ and the page
-- shows it.
sectionHeading :: Section -> Text
sectionHeading = \case
  NewFeatures -> "New features"
  BugFixes -> "Bug fixes"
  OtherChanges -> "Other changes"

-- | An entry's text read, or what is wrong with it, with the line it is
-- on.
parseEntry :: Text -> Either Text Entry
parseEntry contents
  | T.any (== '\r') contents = Left "line ends must be Unix ones (\\n), without \\r"
  | otherwise = case T.lines contents of
      (open : prLine : titleLine : close : rest)
        | open == "---"
        , close == "---" -> do
            n <- at 2 (number =<< field "pr" prLine)
            t <- at 3 (titleOf =<< field "title" titleLine)
            found <- sectionsOf 5 rest
            pure Entry {pr = n, title = t, sections = found}
      _ -> Left "the file must start with the front matter: ---, pr: N, title: T, --- (four lines)"
  where
    field name line = maybe (Left ("expected \"" <> name <> ": …\"")) (Right . T.dropAround (`elem` [' ', '\t'])) (T.stripPrefix (name <> ":") line)
    number t
      | T.null t = Left "pr is empty: write the pull request's number (0 until it is opened)"
      | not (T.all isDigit t) = Left ("pr must be a number, not \"" <> t <> "\"")
      | T.length t > 1 && T.isPrefixOf "0" t = Left ("pr has a leading zero: " <> t)
      | T.length t > 6 = Left ("pr is too long a number: " <> t)
      | otherwise = maybe (Left ("pr must be a number, not \"" <> t <> "\"")) Right (readMaybe (T.unpack t) :: Maybe Int)
    titleOf t
      | T.null t = Left "the title is empty"
      | BS.length (encodeUtf8 t) > 80 = Left ("the title is " <> show (BS.length (encodeUtf8 t)) <> " bytes long, more than 80")
      | otherwise = Right t

at :: Int -> Either Text a -> Either Text a
at n = first (\e -> "line " <> show n <> ": " <> e)

-- | The sections, from the lines after the front matter; the first of
-- them is the file's line @start@.
sectionsOf :: Int -> [Text] -> Either Text [(Section, Text)]
sectionsOf start ls = do
  marked <- classify Nothing (zip [start ..] ls)
  case dropWhile (blank . snd) marked of
    [] -> Left "the entry has no section: add ## New features, ## Bug fixes or ## Other changes"
    (n, Body _ _) : _ -> Left ("line " <> show n <> ": text before the first section, which starts with ## New features, ## Bug fixes or ## Other changes")
    rest -> collect Nothing [] rest
  where
    blank = \case
      Body _ t -> T.null (T.strip t)
      Heading _ -> False
    collect _ done [] = pure (reverse done)
    collect previous done ((n, line) : more) = case line of
      Body _ _ -> Left ("line " <> show n <> ": text outside a section")
      Heading s
        | Just p <- previous
        , p >= s ->
            Left ("line " <> show n <> ": ## " <> sectionHeading s <> " comes after ## " <> sectionHeading p <> "; each section comes at most once, in the order New features, Bug fixes, Other changes")
        | otherwise -> do
            let (body, after) = break (isHeading . snd) more
                text = T.intercalate "\n" (trimBlank [t | (_, Body _ t) <- body])
            when (T.null text) $
              Left ("line " <> show n <> ": the section ## " <> sectionHeading s <> " is empty")
            when (s == NewFeatures && not (or [f | (_, Body f _) <- body])) $
              Left ("line " <> show n <> ": ## New features has no fenced code block; every new feature comes with an example in one")
            collect (Just s) ((s, text) : done) after
    isHeading = \case
      Heading _ -> True
      Body _ _ -> False
    trimBlank = reverse . dropWhile (T.null . T.strip) . reverse . dropWhile (T.null . T.strip)

-- | A line after the front matter, as the sections see it: a section's
-- heading, or a line of a section's text, marked when it opens a fenced
-- code block.
data Line = Heading Section | Body Bool Text

-- | Each line classified, with the fenced code blocks followed: inside
-- one, nothing is a heading. The fence's character, its length and the
-- line it opened on are carried until it closes.
classify :: Maybe (Char, Int, Int) -> [(Int, Text)] -> Either Text [(Int, Line)]
classify fence = \case
  [] -> case fence of
    Just (_, _, opened) -> Left ("line " <> show opened <> ": the code block opened here is not closed")
    Nothing -> pure []
  (n, l) : rest -> case fence of
    Just (c, k, opened) ->
      ((n, Body False l) :) <$> classify (if closes c k l then Nothing else Just (c, k, opened)) rest
    Nothing
      | Just (c, k) <- opens l -> ((n, Body True l) :) <$> classify (Just (c, k, n)) rest
      | Just s <- sectionLine l -> ((n, Heading s) :) <$> classify Nothing rest
      | topHeading l ->
          Left ("line " <> show n <> ": \"" <> T.strip l <> "\" is a heading of level one or two; the only ones allowed are ## New features, ## Bug fixes and ## Other changes (### and deeper inside a section)")
      | otherwise -> ((n, Body False l) :) <$> classify Nothing rest

-- | The fence a line opens, if it opens one: three or more backticks or
-- tildes after any indentation.
opens :: Text -> Maybe (Char, Int)
opens l = case T.uncons (T.stripStart l) of
  Just (c, _)
    | c == '`' || c == '~', k <- T.length (T.takeWhile (== c) (T.stripStart l)), k >= 3 -> Just (c, k)
  _ -> Nothing

-- | Whether a line closes a fence of this character and length: as many
-- of the character or more, and nothing else.
closes :: Char -> Int -> Text -> Bool
closes c k l =
  let t = T.strip l
   in T.length t >= k && T.all (== c) t

-- | The section a line starts, if it is one of the three headings exactly.
sectionLine :: Text -> Maybe Section
sectionLine l = find (\s -> l == "## " <> sectionHeading s) [minBound .. maxBound]

-- | Whether a line is a heading of level one or two: at most three spaces,
-- one or two @#@, then a space, a tab or the end of the line.
topHeading :: Text -> Bool
topHeading l =
  let (spaces, after) = T.span (== ' ') l
      hashes = T.takeWhile (== '#') after
      next = T.drop (T.length hashes) after
   in T.length spaces <= 3 && T.length hashes `elem` [1, 2] && (T.null next || T.take 1 next `elem` [" ", "\t"])

-- | An entry's sections as the page shows them, in Markdown: each under a
-- heading of level three, since the page heads the entry at level two.
entryMarkdown :: Entry -> Text
entryMarkdown e = T.intercalate "\n\n" ["### " <> sectionHeading s <> "\n\n" <> text | (s, text) <- e.sections]

-- | Whether a file's name is an entry's: a number of five digits or more,
-- a hyphen, a slug, then @.md@. That the number is the entry's own is
-- checked by 'readEntries', which has read the entry.
entryFileName :: FilePath -> Bool
entryFileName path = takeExtension name == ".md" && named (T.splitOn "-" (T.pack (take (length name - 3) name)))
  where
    name = takeFileName path
    named = \case
      number : slug@(_ : _) -> T.length number >= 5 && T.all isDigit number && all word slug
      _ -> False
    word w = not (T.null w) && T.all (\c -> isAsciiLower c || isDigit c) w

-- | The number an entry's file is named with: its @pr@, with zeros in front
-- to five digits.
fileNumber :: Int -> Text
fileNumber n = let digits = show n in T.replicate (5 - T.length digits) "0" <> digits

-- | The entries of the directory's files, by their names and texts; or the
-- first problem, naming its file. Every file must be an entry, and no two
-- entries may have the same number (but for 0, not numbered yet).
readEntries :: [(FilePath, Text)] -> Either Text [Entry]
readEntries files = do
  entries <- for (sortOn fst files) $ \(path, contents) -> do
    unless (entryFileName path) $
      Left (toS path <> ": not an entry's name; an entry is named changelog/<number>-<slug>.md, the number its pr with zeros in front to five digits, the slug lower-case letters and digits in words joined by hyphens")
    e <- first (\problem -> toS path <> ": " <> problem) (parseEntry contents)
    let named = T.takeWhile (/= '-') (T.pack (takeFileName path))
    unless (named == fileNumber e.pr) $
      Left (toS path <> ": named with " <> named <> " but its pr is " <> show e.pr <> ": name it " <> fileNumber e.pr <> "-" <> T.drop 1 (T.dropWhile (/= '-') (T.pack (takeFileName path))))
    pure (path, e)
  let numbered = Map.fromListWith (<>) [(e.pr, [p]) | (p, e) <- entries, e.pr /= 0]
  case [(n, ps) | (n, ps) <- Map.toList numbered, length ps > 1] of
    (n, ps) : _ -> Left ("pr " <> show n <> " is in more than one entry: " <> T.intercalate ", " (map toS (sort ps)))
    [] -> pure (map snd entries)

-- | How many entries the page shows: the newest twelve.
shownEntries :: Int
shownEntries = 12

-- | The newest entries by number, the newest first, at most this many;
-- the entries not numbered yet (0) are left out.
newestEntries :: Int -> [Entry] -> [Entry]
newestEntries n = take n . sortOn (Down . (\e -> e.pr)) . filter (\e -> e.pr /= 0)

-- | The response of @GET api\/v1\/whats-new@: the build's version and time,
-- and the newest entries.
toWhatsNew :: Text -> UTCTime -> [Entry] -> WhatsNew
toWhatsNew version built es =
  WhatsNew
    { version
    , built
    , entries = [WhatsNewEntry {pr = e.pr, url = pullRequestUrl e.pr, title = e.title, markdown = entryMarkdown e} | e <- newestEntries shownEntries es]
    }
