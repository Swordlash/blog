{-# LANGUAGE TemplateHaskell #-}

-- | The application page's Content Security Policy in a browser (WP5.21
-- of docs/PLAN.md, "Wiki.Api.ContentPolicy"). The test page carries the
-- policy from before the suite starts (@test\/web\/policy.mjs@), so every
-- spec of the suite runs under it: the islands (KaTeX, Mermaid, TikZ,
-- highlighting), the editor's CodeMirror, the assistant's providers. The
-- policy refuses nothing those need: 'afterTheSuite', the suite's last
-- spec, fails on any violation the browser reported. The specs here check
-- the policy itself: that it is the application's and in force, that a
-- page's HTML runs nothing, that the providers' SDKs work under it, and
-- that an address it does not allow is refused, by the browser and first
-- by the assistant, which says why.
module Test.Browser.Policy (spec, afterTheSuite) where

import Data.Aeson (Value, decodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Protolude hiding (find)
import Test.Hspec.Halogen
import Wiki.Api.ContentPolicy (basePolicy)
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.Core.Assistant (ApiKey (..), AssistantError (..), ErrorKind (..), ModelName (..), Provider (..), Ready (..), errorText)
import Wiki.Core.Markdown.Render (defaultOptions, renderRawHtml)
import Wiki.Core.Url (Url (..))

$( browserJS
     ["jsbits/test-policy.js"]
     [ ("js_policy", "wiki_test_policy_text", Unsafe, [t|IO JSText|])
     , ("js_violations", "wiki_test_policy_violations", Unsafe, [t|IO JSText|])
     , ("js_forget", "wiki_test_policy_forget", Unsafe, [t|JSText -> IO ()|])
     , ("js_evaluates", "wiki_test_policy_evaluates", Safe, [t|IO Bool|])
     , ("js_raw_ran", "wiki_test_raw_ran", Unsafe, [t|IO JSText|])
     , ("js_refuses", "wiki_test_policy_refuses", Safe, [t|JSText -> IO Bool|])
     , ("js_sdk", "wiki_test_policy_sdk", Safe, [t|IO JSText|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadAssistant m) => Spec
spec m = do
  it "is the application's, and in force: no text is evaluated as code" $ runPage $ do
    unsafeIOToPageM (fromJSText <$> js_policy) `shouldReturn` basePolicy
    unsafeIOToPageM (evaluate =<< js_evaluates) `shouldReturn` False

  it "runs no handler and no script that a page's HTML holds" $ runPage $ do
    ui <- mount m rawHtml ()
    _ <- find ui ".raw-html img"
    -- Time for an image that fails to load to say so.
    unsafeIOToPageM (threadDelay 300000)
    unsafeIOToPageM (fromJSText <$> js_raw_ran) `shouldReturn` ""
    length <$> findAll ui ".raw-html script" `shouldReturn` 0

  it "lets the providers' SDKs run, with a fetch of the test's own" $ runPage $ do
    answer <- unsafeIOToPageM (evaluate . fromJSText =<< js_sdk)
    let decoded = decodeStrict (encodeUtf8 answer) :: Maybe Value
    (answer, KeyMap.member "error" <$> (objectOf =<< decoded)) `shouldBe` (answer, Just False)
    answer `shouldSatisfy` T.isInfixOf "\"id\":\"claude-test-1\""

  it "refuses an address it does not allow, and the assistant says so before sending anything" $ runPage $ do
    let blocked = "https://blocked.example/v1"
    unsafeIOToPageM (evaluate =<< js_refuses (toJSText blocked)) `shouldReturn` True
    unsafeIOToPageM (js_forget (toJSText "https://blocked.example"))
    refused <- unsafeIOToPageM (runTest (checkKey (ready (Just (Url blocked))) :: m (Maybe AssistantError)))
    (\e -> e.kind) <$> refused `shouldBe` Just Blocked
    let said = maybe "" (errorText Nothing) refused
    said `shouldSatisfy` T.isInfixOf "https://blocked.example is not among the addresses they allow: https://api.anthropic.com, https://api.openai.com."
    said `shouldSatisfy` T.isInfixOf "assistant's hosts"
    -- Nothing was sent, so nothing was refused by the browser.
    unsafeIOToPageM (fromJSText <$> js_violations) >>= (`shouldSatisfy` (not . T.isInfixOf "blocked.example"))
  where
    ready baseUrl = Ready {provider = OpenAI, model = ModelName "gpt-test", key = ApiKey "", effort = "low", baseUrl}
    objectOf = \case
      Aeson.Object o -> Just o
      _ -> Nothing

-- | The suite's last spec: no part of the suite made the browser refuse
-- anything under the page's policy. A violation names the directive, the
-- address refused and the script that tried.
afterTheSuite :: Spec
afterTheSuite =
  it "was broken by no spec of the suite" $ runPage $ do
    violations <- unsafeIOToPageM (fromJSText <$> js_violations)
    (decodeStrict (encodeUtf8 violations) :: Maybe [Value]) `shouldBe` Just []

-- | HTML in a page that would run a script if it were let through: an
-- image's error handler and a script element, rendered as a page renders
-- its raw HTML (through "Wiki.Core.Markdown.Html"'s allowlist).
rawHtml :: forall q o n. (Monad n) => H.Component q () o n
rawHtml =
  H.mkComponent
    H.ComponentSpec
      { initialState = pure
      , render = \() -> HH.div [HP.class_ (H.ClassName "raw-html")] (renderRawHtml defaultOptions html)
      , eval = H.mkEval H.defaultEval
      }
  where
    html = "<p><img src=\"missing.png\" onerror=\"globalThis.wikiRawRan = 'img'\"><script>globalThis.wikiRawRan = 'script'</script></p>"
