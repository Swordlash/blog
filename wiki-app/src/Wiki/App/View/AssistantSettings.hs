{-# LANGUAGE QuasiQuotes #-}

-- | The writing assistant's settings, a page of the signed-in user's own
-- ("Assistant" in the account menu; WP4.19 of docs/PLAN.md): an API key
-- per provider, the provider the assistant asks, and the model to use,
-- one of a short list per provider (the newest general models first) or
-- any other typed in.
--
-- The assistant is bring-your-own-key (decision 21): a key is the user's,
-- billed by its provider, and stays in this browser, kept under the user's
-- id ("Wiki.App.Assistant"); it goes to its provider only, from the
-- browser, never to the wiki's server. The page says so, and that every
-- request sends the wiki's Markdown reference, which the providers cache
-- where they can. "Test the key" makes the smallest request there is (the
-- model looked up, which costs nothing) and says what the provider
-- answered. "Forget" takes the key away. A key is never shown again once
-- kept, only that there is one.
--
-- Over plain HTTP (anywhere but the machine's own address) the page warns
-- that it is not secure: the key still travels to the provider over TLS,
-- but anyone who can change this page on its way could read what is typed
-- into it.
--
-- Everything is read in the initializer, in the browser: a page rendered
-- ahead (the prerender, the server), which has none of it, says that the
-- settings are being read, and the program adopts that as it is.
module Wiki.App.View.AssistantSettings
  ( Input (..)
  , component
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Backend (Session (..))
import Wiki.App.View.Common (Context (..), attr)
import Wiki.Core.Assistant
  ( Model (..)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (..)
  , Settings (..)
  , chooseProvider
  , errorText
  , keyPage
  , models
  , providerKey
  , providerLabel
  , providers
  , settingsOf
  , withKey
  , withModel
  )
import Wiki.Core.Id (UserId)
import Wiki.Core.User (User (id))

newtype Input = Input {context :: Context}

-- | What "Test the key" found.
data Check = Checking | Works | Fails Text

data State = State
  { input :: Input
  , user :: Maybe UserId
  , settings :: Maybe (Either Text Settings)
  , secure :: Bool
  , scripted :: Bool
  , typedKeys :: Map Provider Text
  , typedModels :: Map Provider Text
  -- ^ A model typed in the "Another" field, kept while another is chosen.
  , checks :: Map Provider Check
  , problem :: Maybe Text
  , busy :: Bool
  }

data Action
  = Initialize
  | Receive Input
  | TypedKey Provider Text
  | KeepKey Provider
  | Forget Provider
  | Choose Provider
  | ChooseModel Provider Text
  | TypedModel Provider Text
  | Test Provider

component :: forall query output m. (MonadAssistant m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input ->
          pure
            State
              { input
              , user = userOf input
              , settings = Nothing
              , secure = True
              , scripted = False
              , typedKeys = mempty
              , typedModels = mempty
              , checks = mempty
              , problem = Nothing
              , busy = False
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="assistant-settings">
          <h1>Writing assistant</h1>
          {{ body }}
        </section>
      |]
      where
        body = case (st.user, st.settings) of
          (Nothing, _) -> [hh|<p class="sign-in-hint">Sign in to set the assistant up: its settings are kept in this browser for each user.</p>|]
          -- What a page rendered ahead shows too: the settings are this
          -- browser's, which no server has.
          (_, Nothing) -> [hh|<p class="loading">Reading the settings this browser keeps for you…</p>|]
          (_, Just (Left why)) -> [hh|<p class="error" role="alert">{{ why }}</p>|]
          (_, Just (Right s)) -> settingsView st s

    settingsView :: State -> Settings -> H.ComponentHTML Action Empty m
    settingsView st s =
      [hh|
        <div class="assistant-settings-body">
          <p class="assistant-intro">
            The assistant in the editor edits a page with you, through Anthropic's Claude or OpenAI's models, with an API key of your own.
            Each key is billed by its provider, to your account there, for every request the assistant makes.
            It stays in this browser, kept for you alone, and goes from here to its provider only, never to this wiki's server.
            Each request also sends the wiki's Markdown reference, about seven thousand tokens, which the provider caches where it can, so that a request soon after another costs less.
          </p>
          {% if not st.secure %}
            <p class="warning assistant-insecure" role="alert">
              This page was not served over HTTPS. Your key still goes to its provider over an encrypted connection, but anyone between you and this wiki could change this page to read what you type into it. Use the assistant from an HTTPS address of this wiki.
            </p>
          {% end %}
          <fieldset class="assistant-provider" disabled={{ st.busy }}>
            <legend>The assistant asks</legend>
            {% for p in providers st.scripted %}
              <label class="choice">
                <input type="radio" name="assistant-provider" value={{ providerKey p }} checked={{ s.provider == p }} onChange={{ const (Choose p) }}>
                <span>{{ providerLabel p }}</span>
              </label>
            {% end %}
          </fieldset>
          {% for p in providers st.scripted %}
            {{ providerView st s p }}
          {% end %}
          {% for why in maybeToList st.problem %}
            <p class="error" role="alert">{{ why }}</p>
          {% end %}
        </div>
      |]

    providerView :: State -> Settings -> Provider -> H.ComponentHTML Action Empty m
    providerView st s p =
      [hh|
        <section class="assistant-provider-settings" {{ attr "data-provider" (providerKey p) }} aria-label={{ providerLabel p }}>
          <h2>{{ providerLabel p }}</h2>
          {% if p == Scripted %}
            <p class="account-note">Answers from a script the tests install; it needs no key.</p>
            <div class="actions">
              <button type="button" class="assistant-test" disabled={{ checking }} onClick={{ const (Test p) }}>Test the key</button>
            </div>
          {% else %}
            {% if isJust ps.key %}
              <p class="assistant-key-kept">A key is kept for {{ providerLabel p }} in this browser.</p>
              <div class="actions">
                <button type="button" class="assistant-test" disabled={{ checking }} onClick={{ const (Test p) }}>Test the key</button>
                <button type="button" class="danger assistant-forget" disabled={{ st.busy }} onClick={{ const (Forget p) }}>Forget</button>
              </div>
            {% else %}
              <form class="assistant-key-form" {{ HE.preventingDefault (HE.onSubmit (const (KeepKey p))) }}>
                <label class="field">
                  <span>API key</span>
                  <input type="password" class="assistant-key" autocomplete="off" spellcheck="false" value={{ Map.findWithDefault "" p st.typedKeys }} onValueInput={{ TypedKey p }}>
                </label>
                <button type="submit" class="primary" disabled={{ st.busy || T.null (T.strip (Map.findWithDefault "" p st.typedKeys)) }}>Keep the key</button>
              </form>
              {% for url in maybeToList (keyPage p) %}
                <p class="account-note">Make one at <a href={{ url }} target="_blank" rel="noopener noreferrer">{{ url }}</a>.</p>
              {% end %}
            {% end %}
          {% end %}
          <fieldset class="assistant-model" disabled={{ st.busy }}>
            <legend>Model</legend>
            {% for m in models p %}
              <label class="choice">
                <input type="radio" name={{ "assistant-model-" <> providerKey p }} value={{ m.id }} checked={{ ps.model == m.id }} onChange={{ const (ChooseModel p m.id) }}>
                <span>{{ m.label }}</span> <code>{{ m.id }}</code>
              </label>
            {% end %}
            <label class="choice assistant-other-model">
              <input type="radio" name={{ "assistant-model-" <> providerKey p }} value="" checked={{ other }} onChange={{ const (ChooseModel p typedModel) }}>
              <span>Another:</span>
              <input type="text" class="assistant-model-name" spellcheck="false" aria-label={{ "Another model of " <> providerLabel p }} value={{ if other then ps.model else typedModel }} onValueChange={{ TypedModel p }}>
            </label>
          </fieldset>
          {{ checkView }}
        </section>
      |]
      where
        ps = settingsOf p s
        other = ps.model `notElem` map (\m -> m.id) (models p)
        typedModel = Map.findWithDefault "" p st.typedModels
        checking = case Map.lookup p st.checks of
          Just Checking -> True
          _ -> False
        checkView = case Map.lookup p st.checks of
          Nothing -> Nothing
          Just Checking -> Just [hh|<p class="assistant-check" role="status">Asking {{ providerLabel p }}…</p>|]
          Just Works -> Just [hh|<p class="assistant-check assistant-check-works" role="status">The key works, and {{ ps.model }} is there.</p>|]
          Just (Fails why) -> Just [hh|<p class="error assistant-check assistant-check-fails" role="alert">{{ why }}</p>|]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      -- Rendered ahead of the program, the page stays as it was first
      -- rendered, which the program adopts.
      Initialize -> whenM (H.liftEffect assistantHere) $ do
        secure <- H.liftEffect secureContext
        scripted <- H.liftEffect scriptedInstalled
        modify (\st -> st {secure, scripted})
        load
      Receive input -> do
        before <- gets (\st -> st.user)
        modify (\st -> st {input, user = userOf input})
        -- Someone else signed in: their settings, not the last one's.
        here <- H.liftEffect assistantHere
        when (here && userOf input /= before) $ do
          modify (\st -> st {settings = Nothing, typedKeys = mempty, typedModels = mempty, checks = mempty, problem = Nothing})
          load
      TypedKey p k -> modify (\st -> st {typedKeys = Map.insert p k st.typedKeys})
      KeepKey p -> do
        typed <- gets (\st -> Map.findWithDefault "" p st.typedKeys)
        unless (T.null (T.strip typed)) $ do
          change (withKey p (Just typed))
          -- The key is not kept in the page once it is kept in the browser.
          modify (\st -> st {typedKeys = Map.delete p st.typedKeys, checks = Map.delete p st.checks})
      Forget p -> do
        change (withKey p Nothing)
        modify (\st -> st {checks = Map.delete p st.checks})
      Choose p -> change (chooseProvider p)
      ChooseModel p m -> do
        change (withModel p m)
        modify (\st -> st {checks = Map.delete p st.checks})
      TypedModel p m -> do
        modify (\st -> st {typedModels = Map.insert p m st.typedModels})
        unless (T.null (T.strip m)) $ do
          change (withModel p m)
          modify (\st -> st {checks = Map.delete p st.checks})
      Test p ->
        gets (\st -> st.settings) >>= \case
          Just (Right s) | Just key <- if p == Scripted then Just "" else (settingsOf p s).key -> do
            modify (\st -> st {checks = Map.insert p Checking st.checks})
            let r = Ready {provider = p, model = (settingsOf p s).model, key, effort = (settingsOf p s).effort}
            result <- lift (checkKey r)
            modify (\st -> st {checks = Map.insert p (maybe Works (Fails . errorText (Just key)) result) st.checks})
          _ -> pass

    load :: H.HalogenM State Action Empty output m ()
    load =
      gets (\st -> st.user)
        >>= traverse_
          ( \user -> do
              settings <- lift (assistantSettings user)
              -- Only if the same user is still asking.
              whenM (gets (\st -> st.user == Just user)) $ modify (\st -> st {settings = Just settings})
          )

    -- Change the settings, and keep them at once.
    change :: (Settings -> Settings) -> H.HalogenM State Action Empty output m ()
    change f =
      gets (\st -> (st.user, st.settings)) >>= \case
        (Just user, Just (Right s)) -> do
          let new = f s
          modify (\st -> st {busy = True, problem = Nothing})
          result <- lift (keepAssistantSettings user new)
          modify $ \st -> case result of
            Right () -> st {busy = False, settings = Just (Right new)}
            Left why -> st {busy = False, problem = Just why}
        _ -> pass

userOf :: Input -> Maybe UserId
userOf input = (\u -> u.id) <$> input.context.session.user
