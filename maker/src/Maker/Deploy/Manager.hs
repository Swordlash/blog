-- | 'Maker.Deploy.Manager' reads the environment of the user's systemd
-- manager, which every unit of the user starts with: the deploy's check of
-- the server's SQLite library ("Maker.Deploy.Sqlite") runs the server with
-- it, and the TeX step ("Maker.Deploy.Tex") takes its PATH.
--
-- @systemctl --user show-environment@ prints one @NAME=value@ line per
-- variable, but not always the value as it is. A value with whitespace, a
-- control character or a character the shell treats specially is written
-- in the shell's dollar-single-quote form, @$'value'@, with C escapes
-- inside (systemd 247 and later, systemctl(1)): a space or a @$@ stays as
-- it is, a backslash and a single quote get a backslash in front, a
-- newline or a tab is @\\n@ or @\\t@, and another control character is a
-- backslash and three octal digits. 'showEnvironmentLine' undoes that
-- quoting; taking the text after the @=@ as the value would run the
-- server with another value than the service gets.
module Maker.Deploy.Manager
  ( managerEnvironment
  , showEnvironmentLine
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Char (chr, digitToInt, isHexDigit, isOctDigit)
import Maker.Deploy.Plan (decodeFs)
import System.Process.Typed

-- | The systemd user manager's environment, as names and values, and the
-- names of the lines it could not read (left out, so that no variable is
-- given a wrong value). 'Nothing' when systemctl cannot be asked.
managerEnvironment :: IO (Maybe ([(String, String)], [String]))
managerEnvironment = do
  result <- try @IOException (readProcessStdout (setStdin nullStream (setStderr nullStream (proc "systemctl" ["--user", "show-environment"]))))
  pure $ case result of
    Right (ExitSuccess, out) ->
      let ls = filter (not . BS.null) (BC.lines (LBS.toStrict out))
          text = decodeFs . LBS.fromStrict
       in Just
            ( [(text name, text value) | Just (name, value) <- map showEnvironmentLine ls]
            , [text (BC.takeWhile (/= '=') l) | l <- ls, Nothing <- [showEnvironmentLine l]]
            )
    _ -> Nothing

-- | One line of @systemctl show-environment@ as bytes: the variable's name
-- and its value, with systemd's quoting undone. 'Nothing' for a line that
-- is not an assignment, or whose quoted value does not read: no closing
-- quote, an unescaped quote inside, or an escape the shell's
-- dollar-single-quote form does not have.
showEnvironmentLine :: BS.ByteString -> Maybe (BS.ByteString, BS.ByteString)
showEnvironmentLine line = case BC.break (== '=') line of
  (name, rest)
    | not (BS.null name)
    , Just value <- BC.stripPrefix "=" rest ->
        (name,) <$> case BC.stripPrefix "$'" value of
          Nothing -> Just value
          Just quoted -> BC.pack <$> unquote (BC.unpack quoted)
  _ -> Nothing
  where
    -- The bytes between @$'@ and the closing quote, each a Char below 256.
    unquote = \case
      "'" -> Just []
      '\'' : _ -> Nothing
      '\\' : c : rest -> escaped c rest
      "\\" -> Nothing
      [] -> Nothing
      c : rest -> (c :) <$> unquote rest
    escaped c rest = case c of
      'a' -> one '\a'
      'b' -> one '\b'
      'e' -> one '\ESC'
      'E' -> one '\ESC'
      'f' -> one '\f'
      'n' -> one '\n'
      'r' -> one '\r'
      't' -> one '\t'
      'v' -> one '\v'
      '\\' -> one '\\'
      '\'' -> one '\''
      '"' -> one '"'
      '?' -> one '?'
      'x'
        | (ds@(_ : _), rest') <- spanUpTo 2 isHexDigit rest -> byte (number 16 ds) rest'
      _
        | isOctDigit c
        , (ds, rest') <- spanUpTo 2 isOctDigit rest ->
            byte (number 8 (c : ds)) rest'
      _ -> Nothing
      where
        one x = (x :) <$> unquote rest
    byte n rest
      | n <= 255 = (chr n :) <$> unquote rest
      | otherwise = Nothing
    number base = foldl (\n d -> n * base + digitToInt d) 0
    spanUpTo n p s = let (a, _) = span p (take n s) in (a, drop (length a) s)
