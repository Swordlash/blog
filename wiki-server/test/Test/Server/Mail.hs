-- | The mail the server sends: an invitation's message, and the SMTP
-- conversation that delivers it, against a mail server of the test's own on
-- a free port of 127.0.0.1 (plain, as one on the same machine would be):
-- what it was told, and that a refusal is said in words that carry nothing
-- of the mail. And a server whose mail server is set while it runs (WP4.4),
-- which mails through it at once, as set at the time of each mail.
module Test.Server.Mail (spec) where

import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.Socket (AddrInfo (..), AddrInfoFlag (..), SockAddr (..), Socket, SocketType (..), accept, bind, close, defaultHints, getAddrInfo, getSocketName, listen, openSocket)
import Network.Socket.ByteString (recv, sendAll)
import Protolude
import Test.Hspec
import Test.Server.Fixture (Running (..), jsonAs, sendJson, setServer, withDemoRunning)
import Wiki.Api (AdminApi (..), WikiApi (..))
import Wiki.Api.Admin (Invited (..), NewInvitation (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (MailSettingsOf (..), MailTest (..), MailTestResult (..), ServerSettingsOf (..), noServerSettings)
import Wiki.Server.Log (redactedPath)
import Wiki.Server.Mail

spec :: Spec
spec = describe "mail" $ do
  messages
  overSmtp
  atRunTime
  logs

expiry :: UTCTime
expiry = UTCTime (fromGregorian 2026 11 1) 3600

messages :: Spec
messages = describe "an invitation's message" $ do
  it "is to its address, with the link below the wiki's address, and when it stops working" $ do
    let m = invitationMessage "https://wiki.example.org/team/" "bea@example.org" "s3cr3t" expiry
    m.to `shouldBe` "bea@example.org"
    m.subject `shouldBe` "You are invited to the wiki at wiki.example.org"
    m.body `shouldSatisfy` T.isInfixOf "https://wiki.example.org/team/invite/s3cr3t/"
    m.body `shouldSatisfy` T.isInfixOf "2026-11-01 01:00 UTC"

  it "never shows its body" $
    show (invitationMessage "https://wiki.example.org/" "bea@example.org" "s3cr3t" expiry) `shouldSatisfy` (not . T.isInfixOf "s3cr3t")

overSmtp :: Spec
overSmtp = describe "over SMTP" $ do
  it "signs in, says who from and to whom, and sends the mail whole" $ do
    (told, port) <- sink (const True)
    let smtp = Smtp {host = "127.0.0.1", port, security = Plain, user = Just "wiki", from = "Wiki <wiki@example.org>"}
        mailer = smtpMailer smtp (Just "smtp password") "https://wiki.example.org/"
    mailer.deliver (invitationMessage mailer.publicUrl "bea@example.org" "s3cr3t" expiry) `shouldReturn` Right ()
    said <- readIORef told
    said `shouldContain` ["AUTH LOGIN"]
    -- Base64 of the user and the password, as AUTH LOGIN sends them.
    said `shouldContain` ["d2lraQ==", "c210cCBwYXNzd29yZA=="]
    said `shouldContain` ["MAIL FROM:<wiki@example.org>"]
    said `shouldContain` ["RCPT TO:<bea@example.org>"]
    let mail = T.unlines (drop 1 (dropWhile (/= "DATA") said))
    mail `shouldSatisfy` T.isInfixOf "To: <bea@example.org>"
    mail `shouldSatisfy` T.isInfixOf "Wiki?= <wiki@example.org>"
    -- Quoted-printable breaks long lines and writes some characters as
    -- codes: the link is whole once read back.
    T.replace "=2E" "." (T.replace "=\n" "" mail) `shouldSatisfy` T.isInfixOf "https://wiki.example.org/invite/s3cr3t/"

  it "says why a recipient was refused, and nothing of the mail" $ do
    (_, port) <- sink (not . ("RCPT" `T.isPrefixOf`))
    let mailer = smtpMailer Smtp {host = "127.0.0.1", port, security = Plain, user = Nothing, from = "wiki@example.org"} Nothing "https://wiki.example.org/"
    result <- mailer.deliver (invitationMessage mailer.publicUrl "nobody@example.org" "s3cr3t" expiry)
    result `shouldSatisfy` either (T.isInfixOf "RCPT TO with 550") (const False)
    result `shouldSatisfy` either (not . T.isInfixOf "s3cr3t") (const False)

  it "says so when nothing listens" $ do
    port <- freePort
    let mailer = smtpMailer Smtp {host = "127.0.0.1", port, security = Plain, user = Nothing, from = "wiki@example.org"} Nothing "https://wiki.example.org/"
    mailer.deliver (invitationMessage mailer.publicUrl "bea@example.org" "s3cr3t" expiry) >>= (`shouldSatisfy` isLeft)

  it "takes implicit TLS on 465, and STARTTLS on any other port" $
    map securityFor [465, 587, 25] `shouldBe` [ImplicitTls, StartTls, StartTls]

atRunTime :: Spec
atRunTime = describe "through the mail server set while the server runs" $
  it "mails an invitation with the settings as they are when it is sent, the password included" $
    withDemoRunning identity $ \r -> do
      let through port password = MailSettings {host = "127.0.0.1", port, security = Plain, user = Just "wiki", password, from = "Wiki <wiki@example.org>"}
          settings port password = noServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just (through port password)}
          invite email = sendJson r "POST" (r.admin <> "/admin/" <> links.admin.invite) NewInvitation {email} >>= jsonAs @Invited 201
      -- Nothing set: nothing mailed, the link given.
      (\i -> isJust i.token) <$> invite "first@example.org" `shouldReturn` True
      (told, port) <- sink (const True)
      _ <- setServer r (settings port (Just "first password"))
      made <- invite "bea@example.org"
      (made.token, made.mailError) `shouldBe` (Nothing, Nothing)
      said <- readIORef told
      said `shouldContain` ["RCPT TO:<bea@example.org>"]
      -- Base64 of the password, as AUTH LOGIN sends it.
      said `shouldContain` ["Zmlyc3QgcGFzc3dvcmQ="]
      -- Another server and another password, at once.
      (told', port') <- sink (const True)
      _ <- setServer r (settings port' (Just "second password"))
      _ <- invite "cy@example.org"
      said' <- readIORef told'
      said' `shouldContain` ["RCPT TO:<cy@example.org>"]
      said' `shouldContain` ["c2Vjb25kIHBhc3N3b3Jk"]
      -- And the test mail goes the same way.
      (told'', port'') <- sink (const True)
      _ <- setServer r (settings port'' Nothing)
      (sendJson r "POST" (r.admin <> "/admin/" <> links.admin.testMail) MailTest {to = "ada@example.org"} >>= jsonAs 200) `shouldReturn` MailTestResult {failure = Nothing}
      readIORef told'' >>= (`shouldContain` ["RCPT TO:<ada@example.org>"])

logs :: Spec
logs = describe "the log" $
  it "writes no invitation's secret in a path" $ do
    redactedPath "/invite/s3cr3t/" `shouldBe` "/invite/…/"
    redactedPath "/wiki/api/v1/invitations/s3cr3t" `shouldBe` "/wiki/api/v1/invitations/…"
    redactedPath "/admin/api/v1/admin/invitations/i1" `shouldBe` "/admin/api/v1/admin/invitations/…"
    redactedPath "/api/v1/spaces" `shouldBe` "/api/v1/spaces"

-- | A mail server for one conversation, on a free port: the lines it was
-- told, and the port. It answers every command as a mail server would,
-- but refuses with a 550 a command the predicate does not take.
sink :: (Text -> Bool) -> IO (IORef [Text], Word16)
sink takes = do
  told <- newIORef []
  socket <- listening
  port <- portOf socket
  _ <- forkIO (bracket (fst <$> accept socket) close (converse told) `finally` close socket)
  pure (told, port)
  where
    converse :: IORef [Text] -> Socket -> IO ()
    converse told c = do
      sendAll c "220 sink.test ESMTP\r\n"
      buffer <- newIORef ""
      let line = do
            waiting <- readIORef buffer
            case BS.breakSubstring "\r\n" waiting of
              (l, rest) | not (BS.null rest) -> modifyIORef' buffer (const (BS.drop 2 rest)) $> Just (decodeUtf8With lenientDecode l)
              _ -> do
                more <- recv c 4096
                if BS.null more then pure Nothing else modifyIORef' buffer (<> more) >> line
          heard l = modifyIORef' told (<> [l])
          reply code = sendAll c (code <> "\r\n")
          loop =
            line >>= \case
              Nothing -> pass
              Just l -> do
                heard l
                let command = T.toUpper (T.takeWhile (/= ' ') l)
                case () of
                  _
                    | not (takes l) -> reply "550 no such mailbox" >> loop
                    | command == "EHLO" -> reply "250-sink.test\r\n250 AUTH LOGIN" >> loop
                    | l == "AUTH LOGIN" -> do
                        reply "334 VXNlcm5hbWU6"
                        traverse_ heard =<< line
                        reply "334 UGFzc3dvcmQ6"
                        traverse_ heard =<< line
                        reply "235 accepted"
                        loop
                    | command == "DATA" -> do
                        reply "354 go on"
                        let body =
                              line >>= \case
                                Just "." -> pass
                                Just b -> heard b >> body
                                Nothing -> pass
                        body
                        reply "250 queued"
                        loop
                    | command == "QUIT" -> reply "221 bye"
                    | otherwise -> reply "250 ok" >> loop
      loop

listening :: IO Socket
listening = do
  infos :: [AddrInfo] <- getAddrInfo (Just defaultHints {addrFlags = [AI_NUMERICHOST, AI_NUMERICSERV], addrSocketType = Stream}) (Just "127.0.0.1") (Just "0")
  info <- maybe (panic "no address") pure (head infos)
  socket <- openSocket info
  bind socket (addrAddress info)
  listen socket 1
  pure socket

portOf :: Socket -> IO Word16
portOf socket =
  getSocketName socket <&> \case
    SockAddrInet p _ -> fromIntegral p
    other -> panic ("not IPv4: " <> show other)

-- | A port nothing listens on: one that was free a moment ago.
freePort :: IO Word16
freePort = bracket listening close portOf
