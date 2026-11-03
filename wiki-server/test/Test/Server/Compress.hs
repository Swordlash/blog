-- | The gzip copies @wiki-server compress@ writes ("Wiki.Server.Compress"),
-- which a deployment without Node serves instead of brotli copies.
module Test.Server.Compress (spec) where

import Codec.Compression.GZip qualified as GZip
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Protolude
import System.Directory (createDirectory, doesFileExist, setModificationTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Wiki.Server.Compress (compressDirectory, compressible)

spec :: Spec
spec = describe "wiki-server compress" $ do
  it "chooses the files the deploy script compresses: its extensions, over 1 KiB" $ do
    compressible "app.wasm" 4096 `shouldBe` True
    compressible "s/blog/index.html" 1025 `shouldBe` True
    compressible "index.js" 1024 `shouldBe` False
    compressible "tikzjax/core.dump.gz" 100000 `shouldBe` False
    compressible "notes.txt" 100000 `shouldBe` False

  it "writes a gzip copy of each large file that decompresses to it, none of a small one, and nothing on a second run" $
    withSystemTempDirectory "wiki-compress" $ \dir -> do
      let large = BSL.fromStrict (encodeUtf8 (T.replicate 400 "console.log(1);\n"))
      createDirectory (dir </> "islands")
      BSL.writeFile (dir </> "islands" </> "app.js") large
      BSL.writeFile (dir </> "small.js") "console.log(1);\n"
      BSL.writeFile (dir </> "notes.txt") large
      compressDirectory dir `shouldReturn` 1
      (GZip.decompress <$> BSL.readFile (dir </> "islands" </> "app.js.gz")) `shouldReturn` large
      doesFileExist (dir </> "small.js.gz") `shouldReturn` False
      doesFileExist (dir </> "notes.txt.gz") `shouldReturn` False
      compressDirectory dir `shouldReturn` 0
      -- A file changed after its copy was written gets a new one.
      let changed = large <> "console.log(2);\n"
      BSL.writeFile (dir </> "islands" </> "app.js") changed
      later <- addUTCTime 60 <$> getCurrentTime
      setModificationTime (dir </> "islands" </> "app.js") later
      compressDirectory dir `shouldReturn` 1
      (GZip.decompress <$> BSL.readFile (dir </> "islands" </> "app.js.gz")) `shouldReturn` changed
