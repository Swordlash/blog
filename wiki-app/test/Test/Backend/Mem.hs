-- | The in-memory backend: the contract, run against it over 'IO' with the
-- demo's content, and what only it does.
module Test.Backend.Mem (spec) where

import Data.ByteString.Base64 qualified as Base64
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Static (renderToHtmlWith)
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Protolude
import Test.Backend.Contract (As (..), Fixture (..))
import Test.Backend.Contract qualified as Contract
import Test.Hspec
import Wiki.App.Backend
import Wiki.App.Backend.Mem
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Attachment (Attachment (..), Source (..), findAttachment)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (User (..))

-- | A fresh in-memory wiki with the demo in it, run as each of its users by
-- switching to them.
memFixture :: IO (Fixture (MemWiki IO))
memFixture = do
  ref <- newMemWiki (demoState demoNow)
  users <- runMemWiki ref memUsers
  let userId = \case
        Anonymous -> Nothing
        As login -> (\u -> u.id) <$> find (\u -> u.login == login) users
  pure (Fixture (\who program -> runMemWiki ref (switchUser (userId who) >> program)))

spec :: Spec
spec = do
  describe "MemWiki" $ do
    Contract.spec (type (MemWiki IO)) memFixture

    it "offers the demo's users to switch between" $ do
      ref <- newMemWiki (demoState demoNow)
      users <- runMemWiki ref memUsers
      map (\u -> u.login) users `shouldBe` ["admin", "editor", "reader"]

    it "takes someone who is not a user for nobody" $ do
      ref <- newMemWiki (demoState demoNow)
      s <- runMemWiki ref (switchUser (Just (UserId "user-nobody")) >> session)
      s `shouldBe` anonymous
      names <- runMemWiki ref (map (\sp -> sp.name) <$> listSpaces)
      names `shouldBe` ["Blog", "Docs"]

    it "makes ids from a counter, the same on every run" $ do
      let ids st = (Map.keys st.spaces, Map.keys st.pages)
      ids (demoState demoNow) `shouldBe` ids (demoState demoNow)
      demoState demoNow `shouldBe` demoState demoNow

    it "serves an uploaded file natively as a data: URL, once" $ do
      ref <- newMemWiki (demoState demoNow)
      let run :: MemWiki IO x -> IO x
          run = runMemWiki ref
          docs = either (panic . show) identity (parsePath "docs")
          tour = either (panic . show) identity (parsePath "tour")
      a <- run $ do
        switchUser (Just (UserId "user-admin"))
        space <- either (panic . show) identity <$> getSpace docs
        page <- either (panic . show) identity <$> getPage space.id tour
        either (panic . show) identity <$> uploadAttachment page.id "hi.txt" "text/plain" "hello"
      url <- run (attachmentUrl a)
      url `shouldBe` "data:text/plain;base64," <> decodeUtf8 (Base64.encode "hello")
      run (attachmentUrl a) `shouldReturn` url
      st <- readIORef ref
      case a.source of
        SourceBlob b -> Map.lookup b st.objectUrls `shouldBe` Just url
        SourceUrl _ -> expectationFailure "an upload is kept as a blob"
      void (run (deleteAttachment a.id))
      st' <- readIORef ref
      Map.size st'.objectUrls `shouldBe` 0

    it "gives an attachment on the web its own URL" $ do
      ref <- newMemWiki (demoState demoNow)
      let guidePath = either (panic . show) identity (parsePath "markdown-guide")
          docs = either (panic . show) identity (parsePath "docs")
      earth <- runMemWiki ref $ do
        space <- either (panic . show) identity <$> getSpace docs
        page <- either (panic . show) identity <$> getPage space.id guidePath
        pure (findAttachment "earth.jpg" page.attachments)
      case earth of
        Just a@Attachment {source = SourceUrl url} -> do
          url `shouldSatisfy` T.isPrefixOf "https://upload.wikimedia.org/"
          runMemWiki ref (attachmentUrl a) `shouldReturn` url
        other -> expectationFailure ("expected earth.jpg by URL, got " <> show other)

    it "runs a Halogen component that asks it for the wiki" $ do
      ref <- newMemWiki (demoState demoNow)
      html <- renderToHtmlWith (runMemDOM . runMemWiki ref) spaceList ()
      html `shouldSatisfy` T.isInfixOf "<li>Blog</li>"
      html `shouldSatisfy` T.isInfixOf "<li>Docs</li>"

-- | A component that lists the spaces it is shown, read in its initializer:
-- what a component of the application does, here in 'MemWiki' over the
-- in-memory DOM.
spaceList :: H.Component q () o (MemWiki MemDOM)
spaceList =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> pure []
      , render = \names -> HH.ul_ [HH.li_ [HH.text n] | n <- names]
      , eval = H.mkEval H.defaultEval {H.initialize = Just (), H.handleAction = \() -> listSpaces >>= put . map (\s -> s.name)}
      }
