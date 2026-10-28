-- | The administration's provider form explains itself
-- ("Wiki.App.View.Server"): a hint under each field, in the README's words,
-- the client id's, the address's and the secret's following the kind
-- chosen; and the line on the redirect URI to register in its three
-- states, rendered natively as the page shows it. The form opens only from
-- "Add a provider" or "Change", so no prerendered page holds it; the browser
-- suite (Test.Browser.Server) sees the same texts in the open form.
module Test.Server (spec) where

import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Static (renderToHtml)
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings (ProviderKind (..))
import Wiki.App.View.Server (ProviderHints (..), providerHints, providerRedirect)
import Wiki.Core.Url (Url (..))

-- | Some HTML as the page has it, rendered by a component that shows only
-- it.
rendered :: (forall w i. HH.HTML w i) -> IO Text
rendered html =
  renderToHtml
    ( H.mkComponent
        H.ComponentSpec
          { initialState = \() -> pure ()
          , render = \() -> html
          , eval = H.mkEval H.defaultEval
          }
    )
    ()

contains :: Text -> Text -> Expectation
contains text part = (part, part `T.isInfixOf` text) `shouldBe` (part, True)

lacks :: Text -> Text -> Expectation
lacks text part = (part, part `T.isInfixOf` text) `shouldBe` (part, False)

spec :: Spec
spec = describe "Wiki.App.View.Server's provider form" $ do
  describe "the redirect URI to register" $ do
    it "says the public address must be set first, while it is not" $ do
      html <- rendered (providerRedirect Nothing "google")
      html `contains` "The wiki's public address must be set first"
      html `lacks` "auth/google/callback"
      html `lacks` "once it has a name"

    it "asks for the name, while it is empty" $ do
      html <- rendered (providerRedirect (Just (Url "https://wiki.example.org/")) "")
      html `contains` "Type the name above and the redirect URI to register appears here."
      html `lacks` "once it has a name"
      html `lacks` "callback"

    it "shows the URI once the name is typed, and what to do with it" $ do
      html <- rendered (providerRedirect (Just (Url "https://wiki.example.org/")) "google")
      html `contains` "Redirect URI to register: <code class=\"server-provider-redirect\">https://wiki.example.org/auth/google/callback</code>"
      html `contains` "Register it with the provider as its redirect (callback) URI; Google's “Authorized JavaScript origins” may stay empty."

  describe "the hints" $ do
    it "say what the name is and where it goes" $
      for_ [minBound .. maxBound] $ \k -> do
        let h = providerHints k
        h.name `contains` "lower-case letters, digits and dashes"
        h.name `contains` "redirect URI"
        h.name `contains` "sign-in button"
        h.kind `contains` "whether the wiki knows the provider's addresses"

    it "say where each kind's client id and secret come from" $ do
      (providerHints Google).clientId `contains` "Google Cloud console"
      (providerHints GitHub).clientId `contains` "OAuth Apps"
      (providerHints Apple).clientId `contains` "Services ID"
      (providerHints Generic).clientId `contains` "confidential client"
      (providerHints Google).secret `contains` "Google Cloud console"
      (providerHints GitHub).secret `contains` "Generate a new client secret"
      (providerHints Apple).secret `contains` "JWT"
      (providerHints Generic).secret `contains` "confidential client"

    it "say what the fourth field is for each kind" $ do
      (providerHints Generic).address `contains` "/.well-known/openid-configuration"
      (providerHints GitHub).address `contains` "GitHub Enterprise"
      (providerHints GitHub).address `contains` "empty for github.com"
      for_ [Google, Apple] $ \k -> (providerHints k).address `contains` "unless a proxy stands in"

    it "are one sentence each" $
      for_ [minBound .. maxBound] $ \k -> do
        let h = providerHints k
        for_ [h.name, h.kind, h.clientId, h.address, h.secret] $ \hint -> do
          T.takeEnd 1 hint `shouldBe` "."
          length (T.splitOn ". " hint) `shouldBe` 1
