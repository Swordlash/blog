-- | Running the tools the toolchain is made of and reading what they print:
-- their versions, a one-line answer, whether they exist.
module Maker.Process
  ( output
  , outputIn
  , succeeds
  , firstLine
  , numericVersion
  , found
  , sha256Of
  , sha256Matches
  , sha256Text
  , removePath
  , relay
  , decodeFs
  , encodeFs
  , tailLog
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isSpace)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, removeDirectoryRecursive, removeFile)
import System.IO (Handle, hClose, hFlush, hSetBinaryMode, stderr, stdout)
import System.IO.Unsafe (unsafePerformIO)
import System.Process qualified as Pipe (createPipe)
import System.Process.Typed

-- | What a command prints on its standard output when it succeeds, or
-- 'Nothing' when it fails or cannot be started. Its standard error is
-- dropped, as the bootstrap's @2>/dev/null@ drops it.
output :: FilePath -> [String] -> IO (Maybe String)
output = outputIn Nothing

-- | 'output', run in the directory given.
outputIn :: Maybe FilePath -> FilePath -> [String] -> IO (Maybe String)
outputIn dir command args = do
  result <- try (readProcess (maybe id setWorkingDir dir (proc command args)))
  pure $ case result of
    Right (ExitSuccess, out, _) -> Just (text out)
    Right _ -> Nothing
    Left (_ :: IOException) -> Nothing

-- | Whether a command runs and succeeds.
succeeds :: FilePath -> [String] -> IO Bool
succeeds command args = (/= Nothing) <$> output command args

-- | The first line of a text, without the spaces around it.
firstLine :: String -> String
firstLine = trim . takeWhile (/= '\n')
  where
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | What @tool --numeric-version@ says, or the empty string, as the
-- bootstrap's @numeric_version@ gives it.
numericVersion :: FilePath -> IO String
numericVersion tool = maybe "" firstLine <$> output tool ["--numeric-version"]

-- | Where a command is on PATH, if it is.
found :: String -> IO (Maybe FilePath)
found = findExecutable

-- | A file's SHA-256, by @sha256sum@, as the bootstrap checks downloads.
sha256Of :: FilePath -> IO (Maybe String)
sha256Of file = fmap (takeWhile (not . isSpace)) <$> output "sha256sum" [file]

-- | Whether a file's SHA-256 is the one given.
sha256Matches :: FilePath -> String -> IO Bool
sha256Matches file expected = (== Just expected) <$> sha256Of file

-- | The SHA-256 of a text, by @sha256sum@, in hexadecimal.
sha256Text :: String -> IO String
sha256Text input = takeWhile (not . isSpace) . text <$> readProcessStdout_ (setStdin (byteStringInput (LBS.fromStrict (encodeUtf8 (T.pack input)))) (proc "sha256sum" []))

-- | What a program printed, as text.
text :: LBS.ByteString -> String
text = decodeFs

-- | A program's output as text in the filesystem encoding, as GHC decodes
-- paths and arguments: every byte comes back unchanged when the text is
-- passed to another process or printed (a byte that is not valid UTF-8
-- included), where a decoding by characters would change it. The maker
-- sets that encoding, and the terminal's, to UTF-8 with ROUNDTRIP
-- (app/Main.hs), so nothing it reads can fail to decode.
decodeFs :: LBS.ByteString -> String
decodeFs bytes = unsafePerformIO $ do
  encoding <- getFileSystemEncoding
  let strict = LBS.toStrict bytes
  BS.useAsCStringLen strict (GHC.peekCStringLen encoding)
{-# NOINLINE decodeFs #-}

-- | A text as the bytes 'decodeFs' read it from: the program's own bytes,
-- for a parser of them (JSON).
encodeFs :: String -> LBS.ByteString
encodeFs str = unsafePerformIO $ do
  encoding <- getFileSystemEncoding
  LBS.fromStrict <$> GHC.withCStringLen encoding str BS.packCStringLen
{-# NOINLINE encodeFs #-}

-- | The last lines of a log on standard error, byte for byte: a log holds
-- what programs printed, which need not be text in any encoding. Nothing
-- is shown when the log cannot be read.
tailLog :: Int -> FilePath -> IO ()
tailLog n file = do
  result <- try (BS.readFile file)
  case result of
    Left (_ :: IOException) -> pure ()
    Right bytes -> do
      let ls = BS.split 10 bytes
          ls' = if not (null ls) && BS.null (last ls) then init ls else ls
      hFlush stdout
      mapM_ (\l -> BS.hPut stderr l >> BS.hPut stderr "\n") (drop (length ls' - n) ls')
      hFlush stderr

-- | Remove a file or a directory with everything in it, if it is there.
removePath :: FilePath -> IO ()
removePath path = do
  isDir <- doesDirectoryExist path
  isFile <- doesFileExist path
  when isDir (removeDirectoryRecursive path)
  when isFile (removeFile path)

-- | Run a command with its output and errors through one pipe, copied as
-- they come, byte for byte, to the terminal and to a log when one is given,
-- as the shell's @2>&1 | tee -a@ did: nothing is decoded, so no output can
-- stop the copy, and nothing is added to it. Answers how the command ended
-- and what it printed; a command that cannot be started ends as 127.
relay :: Maybe Handle -> ProcessConfig () () () -> IO (ExitCode, LBS.ByteString)
relay logHandle config = do
  hFlush stdout
  (readEnd, writeEnd) <- Pipe.createPipe
  started <- try (startProcess (setStdin nullStream (setStdout (useHandleOpen writeEnd) (setStderr (useHandleOpen writeEnd) config))))
  hClose writeEnd
  case started of
    Left (_ :: IOException) -> hClose readEnd >> pure (ExitFailure 127, "")
    Right process -> do
      hSetBinaryMode readEnd True
      let copy kept = do
            chunk <- BS.hGetSome readEnd 4096
            if BS.null chunk
              then pure (reverse kept)
              else do
                BS.hPut stdout chunk
                hFlush stdout
                mapM_ (\h -> BS.hPut h chunk >> hFlush h) logHandle
                copy (chunk : kept)
      kept <- copy []
      hClose readEnd
      code <- waitExitCode process
      pure (code, LBS.fromChunks kept)
