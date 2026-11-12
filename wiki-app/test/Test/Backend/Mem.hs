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
import Test.Hspec
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend
import Wiki.App.Backend.Contract (As (..), Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Contract.Admin qualified as Admin
import Wiki.App.Backend.Contract.Backlinks qualified as Backlinks
import Wiki.App.Backend.Contract.Comments qualified as Comments
import Wiki.App.Backend.Contract.Notifications qualified as Notifications
import Wiki.App.Backend.Contract.Stars qualified as Stars
import Wiki.App.Backend.Mem
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Backend.Mem.Persist (records)
import Wiki.App.Backend.Mem.State (MemState (..), Prepared (..), setHome)
import Wiki.App.Backlinks (pageLinks)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Attachment (Attachment (..), Source (..), findAttachment)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Search (SearchHit (..), searchQuery, searchable)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Login (..), User (..))

-- | A fresh in-memory wiki with the demo in it, run as each of its users by
-- switching to them.
memFixture :: IO (Fixture (MemWiki IO))
memFixture = do
  ref <- newMemWiki (demoState demoNow)
  users <- runMemWiki ref memUsers
  let userId = \case
        Anonymous -> Nothing
        As login -> (\u -> u.id) <$> find (\u -> u.login.text == login) users
  pure (Fixture (\who program -> runMemWiki ref (switchUser (userId who) >> program)))

spec :: Spec
spec = do
  describe "MemWiki" $ do
    Contract.spec (type (MemWiki IO)) (memFixture >>=)
    Admin.spec (type (MemWiki IO)) (memFixture >>=)
    Comments.spec (type (MemWiki IO)) (memFixture >>=)
    Notifications.spec (type (MemWiki IO)) (memFixture >>=)
    Stars.spec (type (MemWiki IO)) (memFixture >>=)
    Backlinks.spec (type (MemWiki IO)) (memFixture >>=)

    it "offers the demo's users to switch between" $ do
      ref <- newMemWiki (demoState demoNow)
      users <- runMemWiki ref memUsers
      map (\u -> u.login.text) users `shouldBe` ["admin", "editor", "reader"]

    it "takes someone who is not a user for nobody" $ do
      ref <- newMemWiki (demoState demoNow)
      s <- runMemWiki ref (switchUser (Just (UserId "user-nobody")) >> session)
      -- Nobody, with the kinds of box the demo defines, which everyone's
      -- pages are rendered with.
      (s.user, s.groups, s.grants, s.standing) `shouldBe` (anonymous.user, anonymous.groups, anonymous.grants, anonymous.standing)
      s.boxes `shouldBe` (demoState demoNow).server.boxes
      names <- runMemWiki ref (map (\sp -> sp.name) <$> listSpaces)
      names `shouldBe` ["Blog", "Docs"]

    it "refuses to delete a page with its space's home page under it, or to move it to another space, and moves it within the space" $ do
      -- A home page under another page, as a space may have had one from
      -- before the home page was the root of its pages: made without the
      -- backend's checks, which would not make it. The pages are found by
      -- their ids, since their paths start under the home page, which
      -- this one is not.
      let demo = demoState demoNow
          docs = fromMaybe (panic "the demo has no Docs") (find (\s -> s.name == "Docs") (Map.elems demo.spaces))
          titled t = fromMaybe (panic ("the demo has no " <> t)) (find (\p -> p.title == t) (Map.elems demo.pages))
          diagrams = titled "Diagrams"
      ref <- newMemWiki (setHome docs.id diagrams.id demo)
      let run :: MemWiki IO x -> IO x
          run = runMemWiki ref
          at t = either (panic . show) identity (parsePath t)
          invalid = \case
            Left (Invalid _) -> pass
            other -> expectationFailure ("expected Invalid, got " <> show (void other))
      run (switchUser (Just (UserId "user-admin")))
      let guide = titled "Markdown guide"
          tour = titled "Tour"
      blog <- run (getSpace (at "blog")) >>= either (panic . show) pure
      aside <- run (createPage docs.id (Just tour.id) "Aside" "") >>= either (panic . show) pure
      run (deletePage guide.id) >>= invalid
      run (movePage guide.id blog.id Nothing) >>= invalid
      run (movePage guide.id docs.id (Just aside.id)) >>= either (panic . show) (const pass)
      (\s -> s.homePage) <$> (run (getSpace (at "docs")) >>= either (panic . show) pure) `shouldReturn` Just diagrams.id
      listed <- run (listPages docs.id) >>= either (panic . show) pure
      [p.parent | p <- listed, p.id == guide.id] `shouldBe` [Just aside.id]

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
      url <- run (attachmentUrl (UrlOwner 0) a)
      url `shouldBe` "data:text/plain;base64," <> decodeUtf8 (Base64.encode "hello")
      run (attachmentUrl (UrlOwner 0) a) `shouldReturn` url
      st <- readIORef ref
      case a.source of
        SourceBlob b -> Map.lookup b st.objectUrls `shouldBe` Just url
        SourceUrl _ -> expectationFailure "an upload is kept as a blob"
      void (run (deleteAttachment a.id))
      st' <- readIORef ref
      Map.size st'.objectUrls `shouldBe` 0

    it "gives an uploaded SVG no interactive form: the demo has no server to send its policy" $ do
      ref <- newMemWiki (demoState demoNow)
      let docs = either (panic . show) identity (parsePath "docs")
          tour = either (panic . show) identity (parsePath "tour")
      svg <- runMemWiki ref $ do
        switchUser (Just (UserId "user-admin"))
        space <- either (panic . show) identity <$> getSpace docs
        page <- either (panic . show) identity <$> getPage space.id tour
        either (panic . show) identity <$> uploadAttachment page.id "flame.svg" "image/svg+xml" "<svg/>"
      runMemWiki ref (attachmentFrameUrl svg) `shouldReturn` Nothing

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
          url.text `shouldSatisfy` T.isPrefixOf "https://upload.wikimedia.org/"
          runMemWiki ref (attachmentUrl (UrlOwner 0) a) `shouldReturn` url.text
        other -> expectationFailure ("expected earth.jpg by URL, got " <> show other)

    it "keeps each page's text prepared for the search in step with the page, and nowhere else" $ do
      ref <- newMemWiki (demoState demoNow)
      let run :: MemWiki IO x -> IO x
          run program = runMemWiki ref (switchUser (Just (UserId "user-admin")) >> program)
          ok :: (Show e) => Either e x -> x
          ok = either (panic . show) identity
          inStep = do
            st <- readIORef ref
            Map.keys st.searchText `shouldBe` Map.keys st.pages
            for_ (Map.elems st.pages) $ \p ->
              Map.lookup p.id st.searchText `shouldBe` Just Prepared {version = p.updatedAt, text = searchable p.title p.body, links = pageLinks p.body}
            -- Made from the pages, so neither the store nor an export has it.
            records st `shouldBe` records st {searchText = mempty}
            toArchive demoNow "test" st `shouldBe` toArchive demoNow "test" st {searchText = mempty}
          found word = map (\h -> h.page) <$> run (searchPages (searchQuery word))
      inStep
      docs <- ok <$> run (getSpace (ok (parsePath "docs")))
      page <- ok <$> run (createPage docs.id Nothing "Marsupials" "A wombat.")
      inStep
      found "wombat" `shouldReturn` [page.id]
      saved <- ok <$> run (savePage page.id page.updatedAt "Marsupials" "A quokka.")
      inStep
      found "quokka" `shouldReturn` [page.id]
      found "wombat" `shouldReturn` []
      ok <$> run (deletePage saved.id)
      inStep
      found "quokka" `shouldReturn` []
      ok <$> run (deleteSpace docs.id)
      inStep

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
