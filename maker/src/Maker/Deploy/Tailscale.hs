-- | What the deploy asks Tailscale: the machine's address and MagicDNS name,
-- and @tailscale serve@, which serves HTTPS on that name with a certificate
-- tailscaled fetches and renews, proxying to the deployment on 127.0.0.1.
-- The serve configuration is tailscaled's and survives restarts, so a deploy
-- sets it once and checks it afterwards. Changing it needs root or
-- tailscaled's operator; the deploy never runs sudo for it and prints the
-- command instead. This is @toolchain/deploy-lib.sh@'s, which undeploy-local.sh
-- still uses.
module Maker.Deploy.Tailscale
  ( Serve (..)
  , serveRoot
  , serveRead
  , proxiesTo
  , rightsHint
  , serveOff
  , oldVersion
  , isOldVersion
  , tailscaleIp
  , magicDnsName
  , dnsNameOf
  , Https (..)
  , httpsOf
  , tailscaleHttps
  , timeout
  , outputOfBoth
  , indented
  )
where

import Data.Aeson (Value (..), decode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isDigit)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Maker.Deploy.Plan (encodeFs, outputOf, prog, say, warn)
import System.Directory (findExecutable)
import System.IO (hPutStr, stderr)

-- | What is served at @https://<name>/@: the handler's type (@proxy@,
-- @path@, …), its target, and whether Funnel publishes it (@funnel@ or
-- @tailnet@). All empty when nothing is served there.
data Serve = Serve {kind :: String, target :: String, funnel :: String}
  deriving (Eq, Show)

-- | A command under @timeout@, as the shell runs Tailscale: tailscaled can
-- hang.
timeout :: Int -> String -> [String] -> IO (Bool, String)
timeout seconds program args = outputOf "timeout" (show seconds : program : args)

-- | The root handler of the HTTPS server on port 443, from the text of
-- @tailscale serve status@: a block headed by @https://<name> (tailnet only)@
-- (or @(Funnel on)@; any port but 443 is in the header), whose lines are
-- @|-- <mount> <type> <target>@.
serveRoot :: String -> Serve
serveRoot = go False False . lines
  where
    go _ _ [] = Serve "" "" ""
    go inBlock isFunnel (l : ls)
      | isHeader l = go (isHttpsName (firstWord l)) ("(Funnel on)" `isInfixOf` l) ls
      | inBlock
      , ("|--" : "/" : rest) <- words l =
          let (k, t) = case rest of
                a : b : _ -> (a, b)
                [a] -> (a, "")
                [] -> ("", "")
           in Serve k t (if isFunnel then "funnel" else "tailnet")
      | otherwise = go inBlock isFunnel ls
    firstWord l = case words l of
      w : _ -> w
      [] -> ""
    -- A line that starts with a scheme: lower-case letters, + and -, then ://.
    isHeader l =
      let (scheme, rest) = span (\c -> c `elem` ['a' .. 'z'] || c == '+' || c == '-') l
       in not (null scheme) && "://" `isPrefixOf` rest
    isHttpsName w = case T.stripPrefix "https://" (T.pack w) of
      Just host -> not (T.null host) && not (T.any (`elem` [':', '/']) host)
      Nothing -> False

-- | The serve configuration, or 'Nothing' when tailscale is missing or does
-- not answer.
serveRead :: IO (Maybe Serve)
serveRead = do
  present <- isJust <$> findExecutable "tailscale"
  if not present
    then pure Nothing
    else do
      (ok, out) <- timeout 10 "tailscale" ["serve", "status"]
      pure (if ok then Just (serveRoot out) else Nothing)

-- | Whether the root proxies to 127.0.0.1 on a port.
proxiesTo :: Serve -> String -> Bool
proxiesTo s port = s.kind == "proxy" && (s.target == "http://127.0.0.1:" <> port || s.target == "http://127.0.0.1:" <> port <> "/")

-- | What to run when the user may not change the serve configuration: the
-- command as root, or, once, making the user tailscaled's operator.
rightsHint :: String -> IO ()
rightsHint cmd = do
  (_, me) <- outputOf "id" ["-un"]
  let user = takeWhile (/= '\n') me
  putStrLn (prog <> ": run it as root:\n    sudo tailscale " <> cmd)
  putStrLn (prog <> ": or let " <> user <> " configure Tailscale without sudo, once, and run this again:\n    sudo tailscale set --operator=" <> user)

-- | Turn off the HTTPS server on 443 when it proxies to a port (the
-- deployment's previous one), and leave it alone otherwise. Never fails:
-- what it cannot do it prints.
serveOff :: String -> IO ()
serveOff port = do
  current <- serveRead
  case current of
    Nothing -> say ("Tailscale does not answer, so cannot tell whether tailscale serve still proxies to 127.0.0.1:" <> port <> "; if it does: tailscale serve --https=443 off")
    Just s
      | not (proxiesTo s port) -> say ("tailscale serve does not proxy to 127.0.0.1:" <> port <> ": nothing of this deployment's to turn off")
      | otherwise -> do
          say "tailscale serve --https=443 off"
          (ok, out) <- outputOfBoth 30 ["serve", "--https=443", "off"]
          if ok
            then say ("turned tailscale serve off: https://<this machine>/ no longer proxies to 127.0.0.1:" <> port)
            else do
              hPutStr stderr (indented out)
              warn "could not turn tailscale serve off (see above)"
              rightsHint "serve --https=443 off"

-- | A tailscale command under @timeout@, with no input and its errors in
-- its output, as the shell's @</dev/null 2>&1@ gives them.
outputOfBoth :: Int -> [String] -> IO (Bool, String)
outputOfBoth seconds args =
  outputOf "sh" (["-c", "exec timeout \"$0\" tailscale \"$@\" </dev/null 2>&1", show seconds] <> args)

-- | Lines indented by four spaces, as the shell's @sed 's/^/    /'@.
indented :: String -> String
indented = unlines . map ("    " <>) . lines

-- | The version of the tailscale command when it is older than 1.52, whose
-- @tailscale serve@ took @https:443 / <target>@ rather than @--bg@.
oldVersion :: IO (Maybe String)
oldVersion = do
  (_, out) <- timeout 10 "tailscale" ["version"]
  let v = takeWhile (/= '\n') out
  pure (if isOldVersion v then Just v else Nothing)

-- | Whether a version is before 1.52.
isOldVersion :: String -> Bool
isOldVersion v = case break (== '.') v of
  ("1", '.' : rest) ->
    let (minor, after) = span isDigit rest
     in not (null minor)
          && (null after || "." `isPrefixOf` after)
          && length minor <= 2
          && (read minor :: Int) < 52
  _ -> False

-- | The machine's Tailscale IPv4 address.
tailscaleIp :: IO (Maybe String)
tailscaleIp = do
  present <- isJust <$> findExecutable "tailscale"
  if not present
    then pure Nothing
    else do
      (_, out) <- timeout 10 "tailscale" ["ip", "-4"]
      let ip = takeWhile (/= '\n') out
      pure (if null ip then Nothing else Just ip)

-- | The machine's MagicDNS name, or the empty string.
magicDnsName :: IO String
magicDnsName = do
  present <- isJust <$> findExecutable "tailscale"
  if not present
    then pure ""
    else do
      (_, out) <- timeout 10 "tailscale" ["status", "--json"]
      pure (dnsNameOf out)

-- | @Self.DNSName@ of @tailscale status --json@, without its final dot.
dnsNameOf :: String -> String
dnsNameOf json = case decode (encodeFs json) of
  Just (Object o)
    | Just (Object self) <- KeyMap.lookup "Self" o
    , Just (String n) <- KeyMap.lookup "DNSName" self ->
        let s = T.unpack n in if "." `isSuffixOf` s then init s else s
  _ -> ""

-- | Whether HTTPS can be served on the machine's MagicDNS name: the name
-- ("-" for none), whether MagicDNS is on, and whether the tailnet issues
-- certificates for the name (it lists it among @CertDomains@ only when its
-- "HTTPS Certificates" are on).
data Https = Https {name :: String, magicDns :: Bool, certificates :: Bool}
  deriving (Eq, Show)

-- | 'Https' from @tailscale status --json@, or 'Nothing' when Tailscale is
-- not running or the JSON cannot be read.
httpsOf :: String -> Maybe Https
httpsOf json = case decode (encodeFs json) of
  Just (Object o)
    | running o ->
        let n = T.unpack (T.dropWhileEnd (== '.') (textAt ["Self", "DNSName"] o))
            magic = case lookupPath ["CurrentTailnet", "MagicDNSEnabled"] o of
              Just (Bool False) -> False
              _ -> True
            certs = case KeyMap.lookup "CertDomains" o of
              Just (Array domains) -> not (null n) && String (T.pack n) `elem` domains
              _ -> False
         in Just Https {name = if null n then "-" else n, magicDns = magic, certificates = certs}
  _ -> Nothing
  where
    running o = case KeyMap.lookup "BackendState" o of
      Just (String s) -> T.null s || s == "Running"
      _ -> True
    lookupPath [] _ = Nothing
    lookupPath [k] o = KeyMap.lookup k o
    lookupPath (k : ks) o = case KeyMap.lookup k o of
      Just (Object inner) -> lookupPath ks inner
      _ -> Nothing
    textAt ks o = case lookupPath ks o of
      Just (String s) -> s
      _ -> ""

-- | 'Https' as Tailscale answers now, or 'Nothing' when it does not.
tailscaleHttps :: IO (Maybe Https)
tailscaleHttps = do
  present <- isJust <$> findExecutable "tailscale"
  if not present
    then pure Nothing
    else do
      (ok, out) <- timeout 10 "tailscale" ["status", "--json"]
      pure (if ok then httpsOf out else Nothing)
