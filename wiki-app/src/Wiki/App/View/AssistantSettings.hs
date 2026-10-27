{-# LANGUAGE QuasiQuotes #-}

-- | The writing assistant's settings, a page of the signed-in user's own
-- ("Assistant" in the account menu; WP4.19 of docs/PLAN.md): an API key
-- per provider, the provider the assistant asks, and the model to use:
-- one of the provider's own list, fetched with the key when it is kept or
-- tested and with "Refresh the list", grouped into the recommended ones
-- and all the others ("Wiki.Core.Assistant"'s
-- 'Wiki.Core.Assistant.modelChoices'; the short list the wiki has until
-- there is a key), or any other typed in.
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
-- OpenAI's settings take another address for its API ("Base URL"), for
-- any service that speaks it: GitHub Models, OpenRouter, a server on this
-- machine (Ollama, LM Studio), which needs no key. One over plain HTTP to
-- another machine gets the same warning: the key would cross the network
-- readable. A provider that could not be reached the last time it was
-- asked (a network that blocks it) is said to be so.
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
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Backend (Session (..))
import Wiki.App.View.Common (Context (..), attr)
import Wiki.Core.Assistant
  ( AssistantError (..)
  , ErrorKind (Unreachable)
  , Model (..)
  , ModelChoices (..)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (..)
  , Settings (..)
  , baseUrlOf
  , chooseProvider
  , chosenModel
  , errorText
  , insecureUrl
  , keyPage
  , modelChoices
  , providerKey
  , providerLabel
  , providers
  , readyFor
  , serviceName
  , settingsOf
  , usable
  , withBaseUrl
  , withKey
  , withModel
  , withModels
  , withReached
  )
import Wiki.Core.Id (UserId)
import Wiki.Core.User (User (id))

newtype Input = Input {context :: Context}

-- | What "Test the key" found.
data Check = Checking | Works | Fails Text

-- | What fetching a provider's list of models came to.
data Listing = Listing | Fetched Int | NotFetched Text

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
  , listings :: Map Provider Listing
  , otherModels :: Set Provider
  -- ^ The providers for which "Other…" is chosen, which shows its field.
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
  | Refresh Provider
  | TypedBaseUrl Provider Text

component :: forall query output m. (MonadAssistant m, MonadIO m) => H.Component query Input output m
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
              , listings = mempty
              , otherModels = mempty
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
            {% if ps.unreachable %}
              <p class="warning assistant-unreachable" role="alert">Cannot reach {{ serviceName p ps }} from this network: the last request found no way to it. A network that blocks it, a firewall or a proxy, is the likely cause.</p>
            {% end %}
            {% if p == OpenAI %}
              <label class="field assistant-base-url-field">
                <span>Base URL</span>
                <input type="url" class="assistant-base-url" spellcheck="false" placeholder="https://api.openai.com/v1" value={{ fromMaybe "" ps.baseUrl }} disabled={{ st.busy }} onValueChange={{ TypedBaseUrl p }}>
              </label>
              <p class="account-note assistant-base-url-hint">Empty for OpenAI's own; or another service that speaks its API: GitHub Models (https://models.github.ai/inference, with a GitHub token as the key), OpenRouter (https://openrouter.ai/api/v1), or a server on this machine such as Ollama (http://localhost:11434/v1), which needs no key.</p>
              {% for url in maybeToList ps.baseUrl %}
                {% if insecureUrl url %}
                  <p class="warning assistant-insecure-base-url" role="alert">This address is plain HTTP to another machine: your key and your pages would cross the network unencrypted, for anyone on the way to read. Use an HTTPS address, or a server on this machine.</p>
                {% end %}
              {% end %}
            {% end %}
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
              {% if isNothing (baseUrlOf p ps) %}
                {% for url in maybeToList (keyPage p) %}
                  <p class="account-note">Make one at <a href={{ url }} target="_blank" rel="noopener noreferrer">{{ url }}</a>.</p>
                {% end %}
              {% end %}
              {% if usable p ps %}
                <div class="actions">
                  <button type="button" class="assistant-test" disabled={{ checking }} onClick={{ const (Test p) }}>Test the connection</button>
                </div>
              {% end %}
            {% end %}
          {% end %}
          <fieldset class="assistant-model" disabled={{ st.busy }}>
            <legend>Model</legend>
            <div class="assistant-model-row">
              <select class="assistant-model-choice" aria-label={{ "The model of " <> providerLabel p }} onValueChange={{ ChooseModel p }}>
                {% if not (null choices.recommended) %}
                  <optgroup label="Recommended">
                    {% for m in choices.recommended %}
                      {{ option m }}
                    {% end %}
                  </optgroup>
                {% end %}
                {% if not (null choices.others) %}
                  <optgroup label="All models">
                    {% for m in choices.others %}
                      {{ option m }}
                    {% end %}
                  </optgroup>
                {% end %}
                <option value="" selected={{ other }}>Other…</option>
              </select>
              {% if canList %}
                <button type="button" class="assistant-refresh" disabled={{ listing }} onClick={{ const (Refresh p) }}>Refresh the list</button>
              {% end %}
            </div>
            {% if other %}
              <input type="text" class="assistant-model-name" spellcheck="false" placeholder="A model's id" aria-label={{ "Another model of " <> providerLabel p }} value={{ if listed then typedModel else chosen }} onValueChange={{ TypedModel p }}>
            {% end %}
            {{ listingView }}
          </fieldset>
          {{ checkView }}
        </section>
      |]
      where
        ps = settingsOf p s
        choices = modelChoices p ps
        chosen = chosenModel p ps
        listed = chosen `elem` map (\m -> m.id) (choices.recommended <> choices.others)
        other = Set.member p st.otherModels || not listed
        option m = [hh|<option value={{ m.id }} selected={{ not other && chosen == m.id }}>{{ m.label }}</option>|]
        canList = usable p ps
        listing = case Map.lookup p st.listings of
          Just Listing -> True
          _ -> False
        listingView = case Map.lookup p st.listings of
          Nothing -> Nothing
          Just Listing -> Just [hh|<p class="assistant-listing" role="status">Fetching {{ providerLabel p }}'s models…</p>|]
          Just (Fetched n) -> Just [hh|<p class="assistant-listing assistant-listed" role="status">{{ show n :: Text }} models fetched from {{ providerLabel p }}, {{ show (length choices.recommended + length choices.others) :: Text }} of them offered for a chat.</p>|]
          Just (NotFetched why) -> Just [hh|<p class="error assistant-listing assistant-not-listed" role="alert">The list of models could not be fetched. {{ why }}</p>|]
        typedModel = Map.findWithDefault "" p st.typedModels
        checking = case Map.lookup p st.checks of
          Just Checking -> True
          _ -> False
        checkView = case Map.lookup p st.checks of
          Nothing -> Nothing
          Just Checking -> Just [hh|<p class="assistant-check" role="status">Asking {{ providerLabel p }}…</p>|]
          Just Works -> Just [hh|<p class="assistant-check assistant-check-works" role="status">The key works, and {{ chosen }} is there.</p>|]
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
          modify (\st -> st {settings = Nothing, typedKeys = mempty, typedModels = mempty, checks = mempty, listings = mempty, otherModels = mempty, problem = Nothing})
          load
      TypedKey p k -> modify (\st -> st {typedKeys = Map.insert p k st.typedKeys})
      KeepKey p -> do
        typed <- gets (\st -> Map.findWithDefault "" p st.typedKeys)
        unless (T.null (T.strip typed)) $ do
          change (withKey p (Just typed))
          -- The key is not kept in the page once it is kept in the browser.
          modify (\st -> st {typedKeys = Map.delete p st.typedKeys, checks = Map.delete p st.checks})
          fetchModels p
      Forget p -> do
        change (withKey p Nothing)
        modify (\st -> st {checks = Map.delete p st.checks, listings = Map.delete p st.listings})
      Choose p -> change (chooseProvider p)
      -- "Other…": its field, and the model typed there last, if one was.
      ChooseModel p "" -> do
        modify (\st -> st {otherModels = Set.insert p st.otherModels})
        typed <- gets (\st -> Map.findWithDefault "" p st.typedModels)
        unless (T.null (T.strip typed)) $ do
          change (withModel p typed)
          modify (\st -> st {checks = Map.delete p st.checks})
      ChooseModel p m -> do
        change (withModel p m)
        modify (\st -> st {checks = Map.delete p st.checks, otherModels = Set.delete p st.otherModels})
      TypedModel p m -> do
        modify (\st -> st {typedModels = Map.insert p m st.typedModels})
        unless (T.null (T.strip m)) $ do
          change (withModel p m)
          modify (\st -> st {checks = Map.delete p st.checks})
      Test p ->
        gets (\st -> st.settings) >>= \case
          Just (Right s) | Right r <- readyFor p s -> do
            modify (\st -> st {checks = Map.insert p Checking st.checks})
            result <- lift (checkKey r)
            modify (\st -> st {checks = Map.insert p (maybe Works (Fails . errorText (Just r.key)) result) st.checks})
            -- Whether the provider answered at all; and once the key is
            -- known to work, its list too.
            for_ result (\e -> change (withReached p (e.kind /= Unreachable)))
            when (isNothing result) (fetchModels p)
          _ -> pass
      Refresh p -> fetchModels p
      TypedBaseUrl p url -> do
        change (withBaseUrl p url)
        modify (\st -> st {checks = Map.delete p st.checks, listings = Map.delete p st.listings})
        -- The other service's own list, if it can be asked.
        gets (\st -> st.settings) >>= \case
          Just (Right s) | usable p (settingsOf p s) && isJust (baseUrlOf p (settingsOf p s)) -> fetchModels p
          _ -> pass

    -- Fetch a provider's list of models with its key, and keep it: which
    -- says too whether the provider can be reached from here.
    fetchModels :: Provider -> H.HalogenM State Action Empty output m ()
    fetchModels p =
      gets (\st -> st.settings) >>= \case
        Just (Right s) | Right r <- readyFor p s -> do
          modify (\st -> st {listings = Map.insert p Listing st.listings})
          now <- liftIO getCurrentTime
          result <- lift (listModels r)
          case result of
            Left e -> do
              change (withReached p (e.kind /= Unreachable))
              modify (\st -> st {listings = Map.insert p (NotFetched (errorText (Just r.key) e)) st.listings})
            Right listed -> do
              change (withModels p listed now)
              modify (\st -> st {listings = Map.insert p (Fetched (length listed)) st.listings})
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
