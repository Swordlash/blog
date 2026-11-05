-- | The page "What's new?" on a server (WP5.66 of docs/PLAN.md): the
-- changelog's entries read and refused ("Wiki.Server.WhatsNew.Entry"),
-- what the server was compiled with ("Wiki.Server.WhatsNew"), the
-- endpoint, the session's word on it, the page the server renders, and
-- the option that turns it all off.
module Test.Server.WhatsNew (unitSpec, spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (WikiApi (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.WhatsNew (WhatsNew (..), WhatsNewEntry (..), newestEntry)
import Wiki.Server.Options (ServeOptions (..), defaultServeOptions, serveOptions)
import Wiki.Server.Options qualified as Options
import Wiki.Server.WhatsNew (buildVersion, changelogEntries, embeddedWhatsNew)
import Wiki.Server.WhatsNew.Entry

-- | What needs no server: the entries' grammar, the newest twelve, and
-- what the server was compiled with.
unitSpec :: Spec
unitSpec = describe "the changelog's entries" $ do
  describe "an entry" $ do
    it "reads its front matter and its sections, in order, without the blank lines around them" $
      parseEntry (entry "158" "A copy button" [features, "## Bug fixes\n\n- No more hangs.\n"])
        `shouldBe` Right Entry {pr = 158, title = "A copy button", sections = [(NewFeatures, featuresText), (BugFixes, "- No more hangs.")]}

    it "takes any one section alone, and pr: 0, not numbered yet" $ do
      (\e -> (e.pr, map fst e.sections)) <$> parseEntry (entry "0" "Later" ["## Other changes\n\nFaster builds.\n"]) `shouldBe` Right (0, [OtherChanges])
      (\e -> map fst e.sections) <$> parseEntry (entry "1" "Fix" ["## Bug fixes\n\n- Fixed.\n"]) `shouldBe` Right [BugFixes]

    it "keeps a fence's own lines, a nested fence, a heading inside one, and deeper headings" $ do
      let nested = "## New features\n\n- Listings:\n\n  ````markdown\n  ```haskell\n  ## not a heading\n  ```\n  ````\n\n### A detail\n\n~~~sh\n# a comment\n~~~\n"
      (\e -> e.sections) <$> parseEntry (entry "5" "Nested" [nested])
        `shouldBe` Right [(NewFeatures, "- Listings:\n\n  ````markdown\n  ```haskell\n  ## not a heading\n  ```\n  ````\n\n### A detail\n\n~~~sh\n# a comment\n~~~")]

    it "is shown with each section under a heading of level three" $
      entryMarkdown Entry {pr = 1, title = "T", sections = [(NewFeatures, "a"), (OtherChanges, "b")]}
        `shouldBe` "### New features\n\na\n\n### Other changes\n\nb"

    it "is refused, with the line and what is wrong, when it is not written as the grammar says" $ do
      let refused contents fragment = parseEntry contents `shouldSatisfy` either (T.isInfixOf fragment) (const False)
      refused "pr: 1\ntitle: T\n" "front matter"
      refused "---\npr: 1\ntitle: T\n" "front matter"
      refused (entry "" "T" [bugs]) "line 2: pr is empty"
      refused (entry "12a" "T" [bugs]) "line 2: pr must be a number"
      refused (entry "012" "T" [bugs]) "line 2: pr has a leading zero"
      refused (entry "1234567" "T" [bugs]) "line 2: pr is too long"
      refused ("---\nnumber: 3\ntitle: T\n---\n\n" <> bugs) "line 2: expected \"pr: …\""
      refused (entry "3" "" [bugs]) "line 3: the title is empty"
      refused (entry "3" (T.replicate 81 "x") [bugs]) "81 bytes long, more than 80"
      -- Bytes, as the check script counts them: forty letters of two bytes.
      refused (entry "3" (T.replicate 41 "é") [bugs]) "82 bytes long, more than 80"
      refused (entry "3" "T" []) "the entry has no section"
      refused (entry "3" "T" ["Some words first.\n\n", bugs]) "line 6: text before the first section"
      refused (entry "3" "T" [bugs, features]) "line 10: ## New features comes after ## Bug fixes"
      refused (entry "3" "T" [bugs, bugs]) "comes after ## Bug fixes"
      refused (entry "3" "T" ["## Bug fixes\n\n", "## Other changes\n\nx\n"]) "line 6: the section ## Bug fixes is empty"
      refused (entry "3" "T" ["## New features\n\n- No example.\n"]) "line 6: ## New features has no fenced code block"
      refused (entry "3" "T" [bugs, "## Notes\n\nx\n"]) "\"## Notes\" is a heading of level one or two"
      refused (entry "3" "T" [bugs, "# Title\n"]) "\"# Title\" is a heading of level one or two"
      refused (entry "3" "T" ["## Bug fixes \n\nx\n"]) "is a heading of level one or two"
      refused (entry "3" "T" ["## New features\n\n```sh\nnever closed\n"]) "line 8: the code block opened here is not closed"
      refused (entry "3" "T" ["## New features\n\n````sh\n```\n"]) "the code block opened here is not closed"
      refused ("---\r\npr: 3\r\ntitle: T\r\n---\r\n\r\n" <> bugs) "Unix"

  describe "the directory" $ do
    it "names a file by its number and a slug" $ do
      map entryFileName ["changelog/00160-heading-spoilers.md", "00158-copy-code.md", "00000-a1-b2.md", "123456-x.md"] `shouldBe` replicate 4 True
      map entryFileName ["README.md", "heading-spoilers.md", "0160-x.md", "00160.md", "00160-.md", "00160-x_y.md", "00160--a.md", "00160-a--b.md", "00160-Ab.md", "00160-a.txt", "abcde-x.md"]
        `shouldBe` replicate 11 False

    it "refuses a malformed entry, naming its file and the problem" $
      readEntries [("changelog/00001-good.md", entry "1" "Good" [bugs]), ("changelog/00002-bad.md", entry "2" "Bad" ["## Bug fixes\n"])]
        `shouldBe` Left "changelog/00002-bad.md: line 6: the section ## Bug fixes is empty"

    it "refuses a file named with another number than its pr" $ do
      readEntries [("changelog/00159-spoilers.md", entry "160" "S" [bugs])]
        `shouldBe` Left "changelog/00159-spoilers.md: named with 00159 but its pr is 160: name it 00160-spoilers.md"
      readEntries [("changelog/00000-spoilers.md", entry "160" "S" [bugs])]
        `shouldSatisfy` either (T.isInfixOf "name it 00160-spoilers.md") (const False)
      length <$> readEntries [("changelog/123456-big.md", entry "123456" "Big" [bugs])] `shouldBe` Right 1

    it "refuses a file that is not an entry, and two entries with one number" $ do
      readEntries [("changelog/notes.txt", "x")] `shouldSatisfy` either (T.isPrefixOf "changelog/notes.txt: not an entry's name") (const False)
      readEntries [("changelog/00007-a.md", entry "7" "A" [bugs]), ("changelog/00007-b.md", entry "7" "B" [bugs])]
        `shouldBe` Left "pr 7 is in more than one entry: changelog/00007-a.md, changelog/00007-b.md"
      -- Not numbered yet is not a number: any entry may have it.
      length <$> readEntries [("changelog/00000-a.md", entry "0" "A" [bugs]), ("changelog/00000-b.md", entry "0" "B" [bugs])] `shouldBe` Right 2

    it "shows the newest twelve by number, the newest first, and none not numbered yet" $ do
      let numbered n = Entry {pr = n, title = show n, sections = [(BugFixes, "x")]}
          all' = map numbered ([0, 0] <> [1 .. 20])
      map (\e -> e.pr) (newestEntries shownEntries all') `shouldBe` [20, 19 .. 9]
      map (\e -> e.pr) (newestEntries 12 (map numbered [3, 0, 150, 7])) `shouldBe` [150, 7, 3]
      let answered = toWhatsNew "v1" (embeddedWhatsNew.built) all'
      map (\e -> e.pr) answered.entries `shouldBe` [20, 19 .. 9]
      map (\e -> e.url) (take 1 answered.entries) `shouldBe` ["https://github.com/Swordlash/blog/pull/20"]
      answered.version `shouldBe` "v1"

  describe "the server, as it was compiled" $ do
    -- The test runs in the package's directory, where the link to the
    -- repository's changelog is.
    it "carries every entry of the repository's changelog, as they read now" $ do
      names <- sort <$> listDirectory "changelog"
      files <- for names $ \name -> ("changelog/" <> name,) . decodeUtf8 <$> BS.readFile ("changelog" </> name)
      readEntries files `shouldBe` Right changelogEntries

    it "answers the newest of them, at most twelve, with its version" $ do
      map (\e -> e.pr) embeddedWhatsNew.entries `shouldBe` map (\e -> e.pr) (newestEntries 12 changelogEntries)
      length embeddedWhatsNew.entries `shouldSatisfy` (<= 12)
      embeddedWhatsNew.version `shouldBe` buildVersion
      buildVersion `shouldSatisfy` (not . T.null)

  it "is on unless the server is told --no-whats-new" $ do
    let parsed = execParserPure defaultPrefs (info serveOptions mempty)
    case (parsed ["--data", "data"], parsed ["--data", "data", "--no-whats-new"]) of
      (Success with, Success without) -> (with.whatsNew, without.whatsNew) `shouldBe` (True, False)
      _ -> expectationFailure "--no-whats-new was not taken"
    (defaultServeOptions "data").whatsNew `shouldBe` True
  where
    entry n t sections = "---\npr: " <> n <> "\ntitle: " <> t <> "\n---\n\n" <> T.concat sections
    featuresText = "- A button copies the code:\n\n  ```markdown\n  ```haskell {.numbered}\n  ```"
    features = "## New features\n\n" <> featuresText <> "\n\n"
    bugs = "## Bug fixes\n\n- Fixed.\n\n"

-- | What a running server answers.
spec :: Backing -> Spec
spec backing = describe "What's new" $ do
  it "is answered to anyone, as the server was compiled, and named in every session" $
    withDemoRunning backing identity $ \r -> do
      answered <- ok200 (getUrl r (r.public <> "/" <> links.whatsNew))
      answered `shouldBe` embeddedWhatsNew
      session <- ok200 (getUrl r (r.public <> "/" <> links.session))
      (session :: SessionInfo).whatsNew `shouldBe` Just (newestEntry embeddedWhatsNew)

  it "is rendered by the server at /whats-new/, with the version and the entries" $
    withDemoRunning backing identity $ \r -> do
      reply <- getUrl r (r.public <> "/whats-new/")
      reply.status `shouldBe` 200
      let html = decodeUtf8 (BSL.toStrict reply.body)
      html `shouldSatisfy` T.isInfixOf "new? · Wiki</title>"
      html `shouldSatisfy` T.isInfixOf "class=\"whats-new-version\""
      html `shouldSatisfy` T.isInfixOf buildVersion
      for_ embeddedWhatsNew.entries $ \e ->
        html `shouldSatisfy` T.isInfixOf ("href=\"" <> e.url <> "\"")
      -- And linked from the sidebar of every page.
      front <- getUrl r (r.public <> "/")
      decodeUtf8 (BSL.toStrict front.body) `shouldSatisfy` T.isInfixOf "class=\"whats-new-link\""

  it "is off with --no-whats-new: not found, no link, and the sessions say so" $
    withDemoRunning backing (\o -> o {Options.whatsNew = False}) $ \r -> do
      getUrl r (r.public <> "/" <> links.whatsNew) >>= jsonAs 404 >>= (`shouldBe` NotFound)
      session <- ok200 (getUrl r (r.public <> "/" <> links.session))
      (session :: SessionInfo).whatsNew `shouldBe` Nothing
      reply <- getUrl r (r.public <> "/whats-new/")
      reply.status `shouldBe` 404
      front <- getUrl r (r.public <> "/")
      decodeUtf8 (BSL.toStrict front.body) `shouldNotSatisfy` T.isInfixOf "whats-new-link"
