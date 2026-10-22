-- | Write the application's page with the component already in it.
--
--   wiki-app-prerender TEMPLATE OUTPUT-DIR
--
-- The template, @web/index.html@, has an empty @\<div id=\"app\">\<\/div>@;
-- the @index.html@ written into OUTPUT-DIR has the component's HTML in it,
-- rendered natively by "Halogen.Static", so the page shows the application
-- before @app.wasm@ has loaded. @toolchain/build-wasm.sh@ runs it so.
module Main (main) where

import Data.ByteString qualified as B
import Halogen.Static (fillMountPoint, renderToHtml)
import Protolude
import System.FilePath ((</>))
import Wiki.App (component)

main :: IO ()
main = do
  (template, outputDir) <-
    getArgs >>= \case
      [template, outputDir] -> pure (template, outputDir)
      _ -> die "usage: wiki-app-prerender TEMPLATE OUTPUT-DIR"
  page <- decodeUtf8 <$> B.readFile template
  html <- renderToHtml component ()
  either (die . ((toS template <> ": ") <>)) (B.writeFile (outputDir </> "index.html") . encodeUtf8) (fillMountPoint "app" html page)
