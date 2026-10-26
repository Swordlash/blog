-- | The wiki's web manifest (@web\/manifest.webmanifest@, WP4.17 of
-- docs/PLAN.md), which a browser reads to install the wiki as an
-- application: valid JSON with the fields installing needs, every address
-- in it relative, so that one file serves the wiki under any base path
-- (the server's, the admin listener's @\/admin\/@, the demo's on Pages),
-- the icons @web\/src\/pwa.mjs@ draws at both sizes and in both purposes;
-- and the page every other is made from links it.
module Test.Manifest (spec) where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Protolude
import Test.Hspec

-- | Where the files are, from the package's directory, where the suite
-- runs.
manifestPath, pagePath :: FilePath
manifestPath = "../web/manifest.webmanifest"
pagePath = "../web/index.html"

spec :: Spec
spec = describe "manifest" $ do
  it "is a JSON object with what installing needs" $ do
    m <- readManifest
    for_ ["name", "short_name", "start_url", "scope", "display", "theme_color", "background_color"] $ \field ->
      text field m `shouldSatisfy` (not . T.null)
    text "display" m `shouldBe` "standalone"
    for_ ["theme_color", "background_color"] $ \field ->
      text field m `shouldSatisfy` (\c -> T.length c == 7 && T.take 1 c == "#" && T.all isHexDigit (T.drop 1 c))

  it "starts at the place it is served at, wherever that is" $ do
    m <- readManifest
    text "start_url" m `shouldBe` "./"
    text "scope" m `shouldBe` "./"
    for_ (icons m) $ \i -> text "src" i `shouldSatisfy` (\src -> not ("/" `T.isPrefixOf` src) && not ("://" `T.isInfixOf` src))

  it "has PNG icons of 192 and 512 pixels, plain and maskable, as the build draws them" $ do
    m <- readManifest
    let pngs = [(text "sizes" i, text "purpose" i, text "src" i) | i <- icons m, text "type" i == "image/png"]
    sort pngs
      `shouldBe` sort
        [ ("192x192", "any", "icons/icon-192.png")
        , ("512x512", "any", "icons/icon-512.png")
        , ("192x192", "maskable", "icons/maskable-192.png")
        , ("512x512", "maskable", "icons/maskable-512.png")
        ]

  it "is linked from the page, with the icon and the theme's colour" $ do
    page <- decodeUtf8 <$> BS.readFile pagePath
    page `shouldSatisfy` T.isInfixOf "<link rel=\"manifest\" href=\"./manifest.webmanifest\">"
    page `shouldSatisfy` T.isInfixOf "<link rel=\"icon\" href=\"./icon.svg\" type=\"image/svg+xml\">"
    m <- readManifest
    page `shouldSatisfy` T.isInfixOf ("<meta name=\"theme-color\" content=\"" <> text "theme_color" m <> "\"")
  where
    readManifest :: IO (KeyMap.KeyMap Value)
    readManifest =
      eitherDecodeStrict' <$> BS.readFile manifestPath >>= \case
        Right (Object o) -> pure o
        Right other -> panic ("the manifest is not an object: " <> show other)
        Left why -> panic ("the manifest is not JSON: " <> toS why)
    text :: Text -> KeyMap.KeyMap Value -> Text
    text field o = case KeyMap.lookup (Key.fromText field) o of
      Just (String t) -> t
      _ -> ""
    icons :: KeyMap.KeyMap Value -> [KeyMap.KeyMap Value]
    icons o = case KeyMap.lookup "icons" o of
      Just (Array is) -> [i | Object i <- toList is]
      _ -> []
