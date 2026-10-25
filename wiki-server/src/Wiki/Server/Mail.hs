-- | The mail the server sends: an invitation's link, to the address it was
-- made for (WP3.5 of docs/PLAN.md), through the SMTP server the
-- configuration names (@--smtp-host@ and the rest, "Wiki.Server.Options").
--
-- Whoever reads an invitation's mail can make an account with it, so its
-- text never goes anywhere but to the mail server: a 'Message' shows no
-- body, and a failure is told in words of this module's own, never in the
-- mail library's, some of which quote the command that failed (the whole
-- mail, for the one that sends it). The password of the SMTP account comes
-- from the environment, never the command line, and is never shown either.
--
-- A server without SMTP mails nothing: the administration is given the
-- link to pass on itself ("Wiki.Server.Api").
module Wiki.Server.Mail
  ( -- * Sending
    Mailer (..)
  , Message (..)
  , invitationMessage
  , inviteLink

    -- * Over SMTP
  , Smtp (..)
  , Security (..)
  , securityFor
  , securityName
  , smtpMailer
  , mailTimeout
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Network.Mail.Mime (Address (..), plainPart, renderMail')
import Network.Mail.SMTP (SMTPConnection, closeSMTP, connectSMTP', connectSMTPS', connectSMTPSTARTTLS', sendCommand, simpleMail)
import Network.Mail.SMTP.Types (AuthType (..), Command (..))
import Protolude
import System.Timeout (timeout)
import Text.Show (Show (showsPrec))

-- | Where mail goes, and the wiki's address its links start with.
data Mailer = Mailer
  { publicUrl :: Text
  -- ^ The wiki's address as its readers reach it, ending in a slash
  -- (@https:\/\/wiki.example.org\/@): the start of every link in a mail.
  , deliver :: Message -> IO (Either Text ())
  -- ^ Send a message: 'Left' says, for a person, why it was not sent.
  }

-- | A mail to send.
data Message = Message
  { to :: Text
  , subject :: Text
  , body :: Text
  }
  deriving stock (Eq)

-- | Without its body, which may carry a link that lets its reader in.
instance Show Message where
  showsPrec _ m rest = "Message {to = " <> show m.to <> ", subject = " <> show m.subject <> ", body = <hidden>}" <> rest

-- | The link of an invitation: its page in the application, below the
-- wiki's address.
inviteLink :: Text -> Text -> Text
inviteLink publicUrl token = publicUrl <> "invite/" <> token <> "/"

-- | The mail that invites someone, with the link that makes their account
-- and when it stops doing so.
invitationMessage :: Text -> Text -> Text -> UTCTime -> Message
invitationMessage publicUrl email token expiresAt =
  Message
    { to = email
    , subject = "You are invited to the wiki at " <> host
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "You are invited to make yourself an account on the wiki at " <> publicUrl <> "."
          , "Follow this link to choose your login and your password:"
          , ""
          , inviteLink publicUrl token
          , ""
          , "The link works once, until " <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" expiresAt) <> "."
          , "If you did not expect this invitation, ignore this mail: nothing is made without you."
          ]
    }
  where
    host = T.takeWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') publicUrl))))

--------------------------------------------------------------------------------
-- Over SMTP

-- | How the connection to the SMTP server is protected.
data Security
  = -- | TLS from the start (SMTPS, port 465).
    ImplicitTls
  | -- | A plain connection that the client upgrades with @STARTTLS@ before
    -- it says anything else (submission, port 587).
    StartTls
  | -- | No TLS at all: only for a mail server on the same machine or the
    -- same private network, never across the internet, since the password
    -- and the mail would cross it in the clear.
    Plain
  deriving stock (Eq, Show, Enum, Bounded)

-- | What a port implies: implicit TLS on 465, @STARTTLS@ on any other.
securityFor :: Word16 -> Security
securityFor = \case
  465 -> ImplicitTls
  _ -> StartTls

-- | As @--smtp-security@ takes it.
securityName :: Security -> Text
securityName = \case
  ImplicitTls -> "tls"
  StartTls -> "starttls"
  Plain -> "plain"

-- | An SMTP server, as the configuration names it.
data Smtp = Smtp
  { host :: Text
  , port :: Word16
  , security :: Security
  , user :: Maybe Text
  -- ^ The account to sign in to the server as (@AUTH LOGIN@), if it asks
  -- for one; its password is the environment's.
  , from :: Text
  -- ^ The sender, @wiki\@example.org@ or @Wiki \<wiki\@example.org>@.
  }
  deriving stock (Eq, Show)

-- | How long sending one mail may take, in microseconds, before it is
-- given up: thirty seconds.
mailTimeout :: Int
mailTimeout = 30_000_000

-- | A mailer over an SMTP server, signing in with this password if the
-- server is given a user.
smtpMailer :: Smtp -> Maybe Text -> Text -> Mailer
smtpMailer smtp password publicUrl = Mailer {publicUrl, deliver = sendOver smtp password}

sendOver :: Smtp -> Maybe Text -> Message -> IO (Either Text ())
sendOver smtp password m = do
  outcome <- timeout mailTimeout (try (bracket connect closeQuietly converse))
  pure $ case outcome of
    Nothing -> Left ("The mail server at " <> where' <> " did not answer in time.")
    Just (Left (e :: SomeException)) -> Left ("The mail could not be sent through " <> where' <> ": " <> failure e)
    Just (Right result) -> result
  where
    where' = smtp.host <> ":" <> show smtp.port
    hostName = toS smtp.host
    port = fromIntegral smtp.port
    connect = case smtp.security of
      ImplicitTls -> connectSMTPS' hostName port
      StartTls -> connectSMTPSTARTTLS' hostName port
      Plain -> connectSMTP' hostName port
    closeQuietly c = closeSMTP c `catch` \(_ :: SomeException) -> pass
    sender = address smtp.from
    converse :: SMTPConnection -> IO (Either Text ())
    converse c = runExceptT $ do
      for_ smtp.user $ \u ->
        -- The library fails with its own words when the server refuses,
        -- which name nothing secret.
        void (liftIO (sendCommand c (AUTH LOGIN (toS u) (toS (fromMaybe "" password)))))
      rendered <- liftIO (renderMail' (simpleMail sender [address m.to] [] [] m.subject [plainPart (TL.fromStrict m.body)]))
      expect "MAIL FROM" 250 =<< liftIO (sendCommand c (MAIL (encodeUtf8 sender.addressEmail)))
      expect "RCPT TO" 250 =<< liftIO (sendCommand c (RCPT (encodeUtf8 (T.strip m.to))))
      expect "DATA" 250 =<< liftIO (sendCommand c (DATA (BSL.toStrict rendered)))
    expect :: Text -> Int -> (Int, ByteString) -> ExceptT Text IO ()
    expect what wanted (code, reply)
      | code == wanted = pass
      | otherwise = throwError ("the mail server answered " <> what <> " with " <> show code <> " " <> T.strip (decodeUtf8With lenientDecode (BC.takeWhile (/= '\n') reply)))
    -- Only what cannot carry the mail: the library's own refusals (a
    -- reply it did not expect to a command that is not the mail's), and
    -- the network's.
    failure :: SomeException -> Text
    failure e = case fromException e of
      Just (io :: IOException) -> T.takeWhile (/= '\n') (show io)
      Nothing -> "the connection failed"

-- | @Name \<address>@ or a bare address, as an address of mime-mail's.
address :: Text -> Address
address t = case T.breakOn "<" t of
  (name, rest)
    | Just inside <- T.stripPrefix "<" rest
    , Just email <- T.stripSuffix ">" (T.strip inside) ->
        Address (mfilter (not . T.null) (Just (T.strip (T.dropAround (== '"') (T.strip name))))) (T.strip email)
  _ -> Address Nothing (T.strip t)
