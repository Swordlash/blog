-- | The README's promises about the demo (WP5.3 of docs/PLAN.md): every
-- example of Markdown it shows is on the demo's page it links to, word for
-- word, so that the link leads to where the example renders; every link it
-- makes into the demo leads to a space or a page the demo has; and the
-- screenshots it shows are there, each small enough for a page that is
-- read on GitHub.
--
-- An example is a fenced block of @markdown@ (a page's text) or @tex@ (a
-- space's math macros), and the paragraph right after it names the place
-- it is on: its first link into the demo. A page's text is checked against
-- the page's body, and a space's macros (linked by the space's "Pages and
-- settings", where they are set) against the space's, line for line: the
-- example's lines have to appear there together and in order.
module Test.Readme (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.Router.Duplex (parse)
import Protolude
import System.Directory (getFileSize)
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route, route)
import Wiki.App.Route qualified as Route
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))

-- | The repository's root, from the package's directory, where the suite
-- runs.
root :: FilePath
root = ".."

-- | Where the demo is published (WP5.2), which the README links into.
demoAddress :: Text
demoAddress = "https://swordlash.github.io/blog"

demo :: MemState
demo = demoState demoNow

spec :: Spec
spec = describe "README" $ do
  it "links into the demo only where the demo has a space or a page" $ do
    readme <- readReadme
    let links = demoLinks readme
    length links `shouldSatisfy` (>= 10)
    for_ links $ \address ->
      (address, either (const False) placeOf (parse route address)) `shouldBe` (address, True)

  it "shows each example on the demo's page it links to, as it is written there" $ do
    readme <- readReadme
    let snippets = snippetsOf readme
    -- One per library at least, and the deck.
    length snippets `shouldSatisfy` (>= 10)
    for_ snippets $ \snippet -> do
      let place = case snippet.link of
            Nothing -> Left "no link into the demo after it"
            Just address -> first show (parse route address) >>= textAt snippet.language
      (snippet.firstLine, fmap (snippet.content `isInfixOf`) place) `shouldBe` (snippet.firstLine, Right True)

  it "shows the screenshots it names, each under 300 KB" $ do
    readme <- readReadme
    let shots = screenshotsOf readme
    length shots `shouldSatisfy` (>= 4)
    for_ shots $ \shot -> do
      size <- getFileSize (root <> "/" <> toS shot)
      (shot, size < 300 * 1024) `shouldBe` (shot, True)

readReadme :: IO Text
readReadme = decodeUtf8 <$> BS.readFile (root <> "/README.md")

-- | Every address in the README under the demo's, as the path the
-- application routes by: what follows the base path, from its slash, to
-- the fragment that names a heading, if there is one.
demoLinks :: Text -> [Text]
demoLinks readme =
  [ T.takeWhile (`notElem` (")># \n" :: [Char])) piece
  | piece <- drop 1 (T.splitOn demoAddress readme)
  , "/" `T.isPrefixOf` piece
  ]

-- | The images under @docs/screenshots/@ the README shows.
screenshotsOf :: Text -> [Text]
screenshotsOf readme =
  [ "docs/screenshots/" <> T.takeWhile (`notElem` (")\" \n" :: [Char])) piece
  | piece <- drop 1 (T.splitOn "(docs/screenshots/" readme)
  ]

-- | Whether a route of the README's names something the demo has.
placeOf :: Route -> Bool
placeOf = \case
  Route.Home -> True
  Route.Space s -> isJust (spaceAt s)
  Route.SpacePages s -> isJust (spaceAt s)
  Route.Page s p -> isJust (pageAt s p)
  Route.PageSlides s p _ -> isJust (pageAt s p)
  Route.PageSource s p -> isJust (pageAt s p)
  _ -> False

-- | The text an example of a language is checked against, at the place a
-- route names: a page's body for Markdown, a space's macros for TeX.
textAt :: Text -> Route -> Either Text [Text]
textAt language at = case (language, at) of
  ("markdown", Route.Page s p) -> body s p
  ("markdown", Route.PageSlides s p _) -> body s p
  ("markdown", Route.PageSource s p) -> body s p
  ("tex", Route.SpacePages s) -> maybe (Left "no such space") (\sp -> Right (T.lines sp.mathMacros)) (spaceAt s)
  _ -> Left ("a " <> language <> " example linked to " <> show at)
  where
    body s p = maybe (Left "no such page") (\pg -> Right (T.lines pg.body)) (pageAt s p)

spaceAt :: [Slug] -> Maybe Space
spaceAt path = rightToMaybe (resolvePath (findChild (Map.elems demo.spaces)) path) >>= lastMay

pageAt :: [Slug] -> [Slug] -> Maybe Page
pageAt spacePath pagePath = do
  s <- spaceAt spacePath
  let inSpace = filter (\q -> q.space == s.id) (Map.elems demo.pages)
  rightToMaybe (resolvePath (findChild inSpace) pagePath) >>= lastMay

-- | An example of the README: a fenced block in a language the demo's
-- content is written in, and the first link into the demo in the paragraph
-- after it.
data Snippet = Snippet
  { language :: Text
  , content :: [Text]
  , firstLine :: Text
  , link :: Maybe Text
  }

snippetsOf :: Text -> [Snippet]
snippetsOf = go . T.lines
  where
    go [] = []
    go (line : rest)
      | Just (fence, language) <- opening line =
          let (content, remaining) = break (closes fence) rest
              following = takeWhile (not . T.null) (dropWhile T.null (drop 1 remaining))
              snippet =
                Snippet
                  { language
                  , content
                  , firstLine = fromMaybe "" (head content)
                  , link = head (demoLinks (T.unlines following))
                  }
           in [snippet | language `elem` ["markdown", "tex"]] <> go (drop 1 remaining)
      | otherwise = go rest
    -- A fence at the start of a line: three backticks or more, and the
    -- block's language.
    opening line =
      let (ticks, info) = T.span (== '`') line
       in if T.length ticks >= 3 then Just (ticks, T.strip info) else Nothing
    closes fence line = T.strip line == fence
