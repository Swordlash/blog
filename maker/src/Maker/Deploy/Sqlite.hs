-- | 'Maker.Deploy.Sqlite' is the deploy's check that the new wiki-server
-- starts on the SQLite library the service will load, before anything of
-- the running deployment changes. wiki-server links the operating
-- system's SQLite (decision 79 of docs/PLAN.md), and the service runs
-- with its unit's environment, not the deploying shell's. So a library
-- the build found, through the shell's paths, may be missing or older
-- where the service looks. toolchain/check-native.sh checks the library
-- the shell's loader finds before the build; this check asks the built
-- program itself, in the service's environment, after it.
--
-- The check runs @wiki-server sqlite@ with the new program. It runs for
-- every server deploy, before the upgrade's rehearsal, so that it does
-- not depend on the rehearsal (@--no-rehearsal@, a first deploy). A
-- program that does not start (the loader finds no libsqlite3) stops the
-- deploy for a wiki in SQLite and in PostgreSQL alike, since wiki-server
-- links the library either way. A library the server refuses (too old,
-- or built without what it needs) stops a deploy of a wiki in SQLite
-- only: a wiki in PostgreSQL never opens a SQLite database, and the
-- deploy says so and goes on. A program from before the command answers
-- with its usage, which is not a refusal: the deploy says the library is
-- not checked, and goes on.
--
-- The environment is the unit's: the systemd user manager's environment
-- (@systemctl --user show-environment@), which every unit of the user
-- starts with, and the unit's own @Environment=@ lines over it
-- ('unitEnvironment', the same list the unit is written with).
module Maker.Deploy.Sqlite
  ( unitEnvironment
  , environmentLines
  , unitBasePath
  , checkServerSqlite
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Data.Maybe (fromMaybe, listToMaybe)
import Maker.Deploy.Plan
import Maker.Deploy.Unit (environmentValue)
import System.Directory (getHomeDirectory)
import System.Environment (lookupEnv)
import System.Process.Typed

-- | The PATH of a unit that uses the toolchain's TeX Live, after its bin
-- directory: the system's own programs. It is also the PATH the check
-- gives the server when the systemd user manager cannot be asked.
unitBasePath :: String
unitBasePath = "/usr/local/bin:/usr/bin:/bin"

-- | The variables a server's unit sets, in the order of its
-- @Environment=@ lines: the deploying shell's @LD_LIBRARY_PATH@ when it
-- has one, since a unit does not inherit the shell's environment and a
-- server linked against a library in a directory of one's own needs it;
-- and PATH with the toolchain's TeX Live first, when the TeX step chose
-- it. The deploy writes the unit and runs the check with this one list.
unitEnvironment :: Plan -> IO [(String, String)]
unitEnvironment p = do
  libraryPath <- fromMaybe "" <$> lookupEnv "LD_LIBRARY_PATH"
  when ('\n' `elem` libraryPath) (die "LD_LIBRARY_PATH holds a newline, which a unit file cannot hold")
  pure $
    [("LD_LIBRARY_PATH", libraryPath) | not (null libraryPath)]
      <> [("PATH", get p "tex_bin" <> ":" <> unitBasePath) | has p "tex_bin"]

-- | The unit's @Environment=@ lines for 'unitEnvironment'.
environmentLines :: [(String, String)] -> [String]
environmentLines = map (\(name, value) -> "Environment=\"" <> name <> "=" <> environmentValue value <> "\"")

-- | The environment the service starts with: the systemd user manager's,
-- with the unit's variables over it. When the manager cannot be asked,
-- HOME and the PATH systemd gives by default, with the unit's over them.
serviceEnvironment :: [(String, String)] -> IO [(String, String)]
serviceEnvironment unit = do
  (ok, out) <- outputOf "systemctl" ["--user", "show-environment"]
  home <- getHomeDirectory
  let manager = [(name, value) | l <- lines out, (name, '=' : value) <- [break (== '=') l], not (null name)]
      base = if ok && not (null manager) then manager else [("HOME", home), ("PATH", unitBasePath)]
  pure ([(name, value) | (name, value) <- base, name `notElem` map fst unit] <> unit)

-- | Run the new wiki-server's @sqlite@ command in the service's
-- environment, and stop the deploy, the running wiki untouched, when the
-- program does not start, or, for a wiki in SQLite, when it refuses the
-- library.
checkServerSqlite :: Plan -> [(String, String)] -> IO ()
checkServerSqlite p unit = do
  let program = get p "server_bin"
      postgres = get p "db" == "postgres"
  environment <- serviceEnvironment unit
  result <- try (readProcessInterleaved (setStdin nullStream (setEnv environment (proc program ["sqlite"]))))
  let (code, said) = case result of
        Right (c, out) -> (c, trimEnd (decodeFs out))
        Left (e :: IOException) -> (ExitFailure 127, show e)
      words' = unlines (map ("    " <>) (lines said))
      service = "in the service's environment (the systemd user manager's and the unit's Environment= lines, not this shell's)"
      untouched = "The running wiki is untouched."
  case code of
    ExitSuccess -> say ("the new wiki-server runs on " <> stripDot (firstLine said) <> ", " <> service)
    ExitFailure 1
      | not (any ("wiki-server: " `isPrefixOf`) (lines said)) ->
          warn
            ( "the new wiki-server does not know the command sqlite (a program from before it, as a --no-build over an older build gives), so the SQLite library it loads in the service's environment is not checked:\n"
                <> words'
            )
      | postgres ->
          warn
            ( "the new wiki-server would refuse the SQLite library it loads "
                <> service
                <> ":\n"
                <> words'
                <> "A wiki in PostgreSQL never opens a SQLite database, so the deploy goes on."
            )
      | otherwise -> do
          built <- buildLibrary program
          die
            ( "the new wiki-server refuses the SQLite library it loads "
                <> service
                <> ":\n"
                <> words'
                <> untouched
                <> " Install a SQLite library it runs on where the service finds it: on the loader's own path (a file in /etc/ld.so.conf.d naming its directory, then sudo ldconfig), or in a directory the deploying shell's LD_LIBRARY_PATH names, which the deploy writes into the unit."
                <> built
            )
    ExitFailure _ -> do
      built <- buildLibrary program
      die
        ( "the new wiki-server does not start "
            <> service
            <> ":\n"
            <> words'
            <> untouched
            <> " wiki-server links the system's SQLite library (libsqlite3), and the service must find it: put its directory on the loader's own path (a file in /etc/ld.so.conf.d naming it, then sudo ldconfig), or run the deploy from a shell whose LD_LIBRARY_PATH names it, which the deploy writes into the unit."
            <> built
        )
  where
    trimEnd = reverse . dropWhile (`elem` ("\n " :: String)) . reverse
    firstLine = takeWhile (/= '\n')
    stripDot s = fromMaybe s (reverse <$> stripPrefix "." (reverse s))

-- | Where the program loads libsqlite3 from in this shell's environment,
-- as @ldd@ says, as a sentence for the deploy's message; empty when
-- there is no ldd or it names none.
buildLibrary :: FilePath -> IO String
buildLibrary program = do
  (_, out) <- outputOf "ldd" [program]
  pure $ case listToMaybe [l | l <- lines out, "libsqlite3" `isInfixOf` l] of
    Just l
      | (_ : rest) <- dropWhile (/= "=>") (words l)
      , path : _ <- rest
      , path /= "not" ->
          " In this shell's environment the program loads " <> path <> " (ldd)."
    _ -> ""
