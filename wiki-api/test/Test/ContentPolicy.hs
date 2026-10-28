-- | The page's Content Security Policy ("Wiki.Api.ContentPolicy"): what it
-- allows and refuses, the hosts an administrator adds, and the addresses
-- accepted as such hosts.
module Test.ContentPolicy (spec) where

import Protolude
import Test.Hspec
import Wiki.Api.ContentPolicy

spec :: Spec
spec = describe "Wiki.Api.ContentPolicy" $ do
  let directive name policy = snd <$> find ((== name) . fst) (directives policy)

  it "lets scripts come from the wiki only, and evaluate no text as code" $ do
    directive "script-src" basePolicy `shouldBe` Just ["'self'", "'wasm-unsafe-eval'"]
    directive "default-src" basePolicy `shouldBe` Just ["'none'"]
    directive "object-src" basePolicy `shouldBe` Just ["'none'"]
    for_ (directives basePolicy) $ \(_, sources) -> sources `shouldNotContain` ["'unsafe-eval'"]

  it "gives 'unsafe-inline' to styles only" $
    [name | (name, sources) <- directives basePolicy, "'unsafe-inline'" `elem` sources] `shouldBe` ["style-src"]

  it "keeps the page's base and its forms on the wiki" $ do
    directive "base-uri" basePolicy `shouldBe` Just ["'self'"]
    directive "form-action" basePolicy `shouldBe` Just ["'self'"]

  it "lets the page connect to the wiki and to the providers' APIs only" $ do
    connectSources basePolicy `shouldBe` ["'self'", "https://api.anthropic.com", "https://api.openai.com"]
    providerHosts `shouldBe` ["https://api.anthropic.com", "https://api.openai.com"]

  it "is the base policy for a wiki with no assistant hosts" $
    pagePolicy [] `shouldBe` basePolicy

  it "adds the administrator's hosts to connect-src, each once" $ do
    let policy = pagePolicy ["http://localhost:11434", "https://openrouter.ai", "https://api.openai.com"]
    connectSources policy `shouldBe` ["'self'", "https://api.anthropic.com", "https://api.openai.com", "http://localhost:11434", "https://openrouter.ai"]
    extraHosts policy `shouldBe` ["https://api.anthropic.com", "https://api.openai.com", "http://localhost:11434", "https://openrouter.ai"]
    [d | d@(name, _) <- directives policy, name /= "connect-src"] `shouldBe` [d | d@(name, _) <- directives basePolicy, name /= "connect-src"]

  it "keeps frames out in the header, which alone can say so" $ do
    directive "frame-ancestors" basePolicy `shouldBe` Nothing
    directive "frame-ancestors" (headerPolicy []) `shouldBe` Just ["'none'"]
    connectSources (headerPolicy ["https://openrouter.ai"]) `shouldContain` ["https://openrouter.ai"]

  it "lets a sign-in page's form lead to the provider" $ do
    directive "form-action" (signInPolicy ["https://accounts.example.com"]) `shouldBe` Just ["'self'", "https://accounts.example.com"]
    directive "frame-ancestors" (signInPolicy []) `shouldBe` Just ["'none'"]

  it "reads the policy back from its text" $
    renderPolicy (directives (headerPolicy ["https://a.example"])) `shouldBe` headerPolicy ["https://a.example"]

  describe "allowsConnect" $ do
    let page = "https://wiki.example.org"
        policy = pagePolicy ["http://localhost:11434", "https://*.example.net", "https://proxy.example.com:*"]
    it "allows the providers, the wiki itself and the hosts added, by origin" $ do
      for_ ["https://api.openai.com/v1", "https://api.anthropic.com", "https://wiki.example.org/api/v1/info", "http://localhost:11434/v1", "https://a.example.net/v1", "https://proxy.example.com:8443/x"] $ \address ->
        (address, allowsConnect page policy address) `shouldBe` (address, True)
    it "refuses every other address" $
      for_ ["https://openrouter.ai/api/v1", "http://localhost:1234/v1", "https://example.net", "http://api.openai.com", "https://api.openai.com:8443", "https://wiki.example.org:444", "ftp://api.openai.com", "nonsense"] $ \address ->
        (address, allowsConnect page policy address) `shouldBe` (address, False)
    it "lets an http: source allow its host over https: too" $
      allowsConnect page policy "https://localhost:11434/v1" `shouldBe` True

  describe "parseAssistantHost" $ do
    it "takes an origin, in lower case" $ do
      parseAssistantHost "https://OpenRouter.ai" `shouldBe` Right "https://openrouter.ai"
      parseAssistantHost " http://localhost:11434 " `shouldBe` Right "http://localhost:11434"
      parseAssistantHost "http://[::1]:1234" `shouldBe` Right "http://[::1]:1234"
      parseAssistantHost "https://*.example.org:*" `shouldBe` Right "https://*.example.org:*"

    it "takes a base URL, and keeps its origin" $
      parseAssistantHost "https://openrouter.ai/api/v1" `shouldBe` Right "https://openrouter.ai"

    it "refuses what would change the policy's meaning" $
      for_ ["https://a.example; script-src *", "https://a.example 'unsafe-eval'", "'self'", "*", "https:", "ftp://a.example", "https://", "https://user@a.example", "https://a.example:99999", "https://-a.example", "https://a..example"] $ \bad ->
        parseAssistantHost bad `shouldSatisfy` isLeft
