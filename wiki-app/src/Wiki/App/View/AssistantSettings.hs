{-# LANGUAGE QuasiQuotes #-}

-- | The assistant settings page: the writing assistant's settings, a page
-- of the signed-in user's own ("Assistant" in the account menu; WP4.19 of
-- docs/PLAN.md). It holds an API key per provider, the provider the
-- assistant uses, the model to use, and the effort a new conversation
-- starts with. The model is one from the provider's own list, or any
-- other id typed in. The list is fetched with the key when the key is
-- saved or tested and on "Refresh the list", and grouped into the
-- recommended models and all the others
-- ('Wiki.Core.Assistant.modelChoices'). Until there is a key, the list is
-- the wiki's short list. The effort ("Effort") is medium unless the user
-- chooses another ('Wiki.Core.Assistant.defaultEffort'). The chat's own
-- picker changes the effort for one conversation only.
--
-- The assistant is bring-your-own-key (decision 21). A key belongs to the
-- user and is billed by its provider. It stays in this browser, stored
-- under the user's id ("Wiki.App.Assistant"), and the browser sends it
-- only to its provider, never to the wiki's server. The page says so, and
-- also that every request sends the wiki's Markdown reference, which the
-- providers cache where they can. A typed key is kept only once it works
-- (WP5.59): "Test and keep the key" (or Enter in the key's field) fetches
-- the model list with the typed key, then makes the smallest possible
-- request with it (looking up the model, which is free), and keeps the
-- key and the model only when the provider accepts both. A refused key is
-- not kept: the page shows why, and the key stays in the field to be
-- corrected. "Test the key" checks a kept key with that small request.
-- "Forget" deletes the key. Once kept, a key is never shown again; the
-- page only shows that one is set.
--
-- Over plain HTTP (anywhere except the local machine's address) the page
-- warns that it is not secure. The key is still sent to the provider over
-- TLS, but anyone who can modify this page in transit could read what is
-- typed into it.
--
-- Each provider's settings choose the service its requests go to
-- ("Service", WP5.60): the provider's own, or one of the services that
-- speak its API which the wiki's administrator lists (Administration,
-- Server, The assistant's services), as the session carries them. For
-- OpenAI's API that may be GitHub Models, OpenRouter, or a server of
-- Ollama or LM Studio, which needs no key. For Anthropic's it is a
-- gateway, such as an organisation's own in front of Anthropic (WP5.57).
-- The SDK sends the key as @Authorization: Bearer@, which such a gateway
-- takes. Choosing a service sets the base URL the settings keep
-- ('withBaseUrl'), so nothing else changes. There is no field to type an
-- address in: the page's Content Security Policy (WP5.21 of
-- docs/PLAN.md) lets the browser reach only the administrator's services,
-- and a typed address would be refused with an error that explains
-- nothing. A base URL kept from before, which no service offers any
-- more, is shown as such until another service is chosen. A service over
-- plain HTTP to another machine gets the same warning as the page: the key
-- would cross the network unencrypted. A provider that could not be
-- reached on the last attempt (because a network blocks it) is marked as
-- unreachable.
--
-- Everything is read in the initializer, in the browser. A page rendered
-- ahead of the program (by the prerender or the server), which has no
-- access to the settings, says that the settings are being read, and the
-- program adopts that page unchanged.
module Wiki.App.View.AssistantSettings
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.ServerSettings (AssistantApi (..), AssistantService (..))
import Wiki.Api.Vault (PasskeyInfo (..))
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Assistant.Keys (Keys (..), addPasskey, changeKeys, loadKeys, readKeys, removePasskey, setAskEachTime, turnOffSync, turnOnSync, unlockKeys)
import Wiki.App.Assistant.Sync (MonadVault (..))
import Wiki.App.Backend (Session (..))
import Wiki.App.Editor.Browser (clearField)
import Wiki.App.View.Common (Context (..), attr)
import Wiki.Core.Assistant
  ( AssistantError (..)
  , ErrorKind (BadKey, Unreachable)
  , Model (..)
  , ModelChoices (..)
  , ModelName (..)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (..)
  , Settings (..)
  , baseUrlOf
  , chooseProvider
  , chosenModel
  , defaultEffort
  , effortOf
  , efforts
  , errorText
  , insecureUrl
  , keyPage
  , modelChoices
  , providerKey
  , providerLabel
  , providers
  , readyFor
  , readyWith
  , serviceName
  , serviceOf
  , settingsOf
  , usable
  , withBaseUrl
  , withEffort
  , withKey
  , withModel
  , withModels
  , withReached
  )
import Wiki.Core.Assistant.Vault (CredentialId)
import Wiki.Core.Id (UserId)
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Password (..), User (id))

newtype Input = Input {context :: Context}

-- | 'Check': the result of "Test the key", "Test the connection (no
-- key)" or "Test and keep the key". 'Kept' is a typed key that worked and
-- is now kept.
data Check = Checking | Works | Kept | Fails Text

-- | 'Listing': the state of fetching a provider's model list.
data Listing = Listing | Fetched Int | NotFetched Text

-- | 'Offer': whether this page can sync the keys across devices.
data Offer
  = -- | No server keeps a vault: the demo.
    NoServer
  | -- | A server does, but this page is not served over HTTPS, and a
    -- browser offers passkeys only on a secure page.
    NotSecure
  | Offered

-- | 'Sync': the keys across devices, as the page shows them.
data Sync = Sync
  { offer :: Offer
  , synced :: Bool
  , locked :: Bool
  , askEachTime :: Bool
  , passkeys :: [PasskeyInfo]
  , working :: Maybe Text
  -- ^ What is being done, while it is: the browser's passkey dialog may
  -- be open.
  , trouble :: Maybe Text
  -- ^ Why the last step failed, if it did.
  }

data State = State
  { input :: Input
  , user :: Maybe UserId
  , settings :: Maybe (Either Text Settings)
  , secure :: Bool
  , sealing :: Bool
  -- ^ Whether the browser can seal the keys here ('sealingHere').
  , scripted :: Bool
  , typedKeys :: Map Provider Text
  , typedModels :: Map Provider Text
  -- ^ A model typed in the "Another" field, kept while another model is chosen.
  , checks :: Map Provider Check
  , listings :: Map Provider Listing
  , otherModels :: Set Provider
  -- ^ The providers for which "Other…" is chosen, which shows its text field.
  , problem :: Maybe Text
  , busy :: Bool
  , sync :: Sync
  , syncPassword :: Text
  , syncPasswordField :: H.RefLabel
  -- ^ The password typed to make a passkey, which signs the user in, so
  -- that the server asks for it ("Wiki.Api.Vault").
  }

data Action
  = Initialize
  | Receive Input
  | TypedKey Provider Text
  | TestAndKeep Provider
  | Forget Provider
  | Choose Provider
  | ChooseModel Provider Text
  | TypedModel Provider Text
  | Test Provider
  | Refresh Provider
  | ChooseService Provider Text
  | ChooseEffort Provider Text
  | TurnOn
  | TypedSyncPassword Text
  | Unlock
  | AddPasskey
  | RemovePasskey CredentialId
  | TurnOff
  | AskEachTime Bool

component :: forall query output m. (MonadAssistant m, MonadVault m, MonadUUID m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          syncPasswordField <- H.newRefLabel "assistant-passkey-password"
          pure
            State
              { input
              , syncPasswordField
              , user = userOf input
              , settings = Nothing
              , secure = True
              , sealing = True
              , scripted = False
              , typedKeys = mempty
              , typedModels = mempty
              , checks = mempty
              , listings = mempty
              , otherModels = mempty
              , problem = Nothing
              , busy = False
              , sync = noSync
              , syncPassword = ""
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
          -- A page rendered ahead of the program shows this too: the
          -- settings belong to this browser, and no server has them.
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
            It stays in this browser, kept for you alone and sealed with a key the browser keeps, and goes from here to its provider only, never to this wiki's server in the clear: with syncing on, the server keeps your keys sealed, and cannot open them.
            Each request also sends the wiki's Markdown reference, about seven thousand tokens, which the provider caches where it can, so that a request soon after another costs less.
          </p>
          {% if not st.secure %}
            <p class="warning assistant-insecure" role="alert">
              This page was not served over HTTPS. Your key still goes to its provider over an encrypted connection, but anyone between you and this wiki could change this page to read what you type into it. Use the assistant from an HTTPS address of this wiki.
            </p>
          {% end %}
          {% if not st.sealing %}
            <p class="warning assistant-unsealed" role="alert">
              This browser offers no encryption to a page served over plain HTTP, so your keys are kept in this browser as text, not sealed. Open this wiki at its HTTPS address to have them sealed.
            </p>
          {% end %}
          {{ syncView st.syncPasswordField st.sync }}
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

    -- Sync across devices (WP5.21 of docs/PLAN.md, "Wiki.App.Assistant.Keys").
    syncView :: H.RefLabel -> Sync -> H.ComponentHTML Action Empty m
    syncView field sy = case sy.offer of
      NoServer -> [hh|<span class="assistant-sync-none"></span>|]
      NotSecure ->
        [hh|
          <section class="assistant-sync" aria-label="Sync across devices">
            <h2>Sync across devices</h2>
            <p class="account-note assistant-sync-unavailable">Syncing your keys across your devices needs a passkey, and a browser offers passkeys only on a page served over HTTPS: open this wiki at its HTTPS address to turn it on.</p>
          </section>
        |]
      Offered ->
        [hh|
          <section class="assistant-sync" aria-label="Sync across devices">
            <h2>Sync across devices</h2>
            {% if sy.synced && sy.locked %}
              <p class="assistant-sync-state assistant-sync-locked">Your keys sync from your other devices, and are locked in this browser.</p>
              <div class="actions">
                <button type="button" class="primary assistant-unlock" disabled={{ isJust sy.working }} onClick={{ const Unlock }}>Unlock with passkey</button>
                <button type="button" class="danger assistant-sync-off" disabled={{ isJust sy.working }} onClick={{ const TurnOff }}>Turn off</button>
              </div>
              <p class="account-note assistant-type-here">or type a key here, below: it stays in this browser, and joins your synced keys once you unlock them.</p>
              <p class="account-note assistant-locked-off">Lost every passkey? "Turn off" deletes the vault on the server, and needs no passkey; your passkeys stay, to sign in with. The keys in the vault are lost with it; keys typed in this browser stay here.</p>
            {% else %}
              {% if sy.synced %}
                <p class="assistant-sync-state assistant-sync-on">Sync across devices: on. Your keys are sealed in a vault this wiki's server keeps and cannot open; one of your passkeys opens it on your other devices, with one touch.</p>
                <ul class="assistant-passkeys">
                  {% for pk in sy.passkeys %}
                    <li class="assistant-passkey">
                      <span class="assistant-passkey-name">{{ pk.name }}</span>
                      {% if not pk.unlocks %}
                        <span class="account-note"> (cannot unlock the keys)</span>
                      {% end %}
                      <button type="button" class="danger assistant-remove-passkey" disabled={{ isJust sy.working }} onClick={{ const (RemovePasskey pk.id) }}>Remove</button>
                    </li>
                  {% end %}
                </ul>
                {{ passwordField }}
                <div class="actions">
                  <button type="button" class="assistant-add-passkey" disabled={{ isJust sy.working }} onClick={{ const AddPasskey }}>Add passkey</button>
                  <button type="button" class="danger assistant-sync-off" disabled={{ isJust sy.working }} onClick={{ const TurnOff }}>Turn off</button>
                </div>
                <label class="choice">
                  <input type="checkbox" class="assistant-ask-each-time" checked={{ sy.askEachTime }} disabled={{ isJust sy.working }} onChange={{ const (AskEachTime (not sy.askEachTime)) }}>
                  <span>Ask for the passkey each time the wiki opens</span>
                </label>
                <p class="account-note">Asked each time, this browser keeps no key that opens your settings, only the sealed vault. "Turn off" deletes the vault on the server, and needs no passkey; your keys stay in this browser.</p>
              {% else %}
                <p class="assistant-sync-state assistant-sync-off-state">Sync across devices: off. Your keys are sealed in this browser only.</p>
                {{ passwordField }}
                <div class="actions">
                  <button type="button" class="assistant-sync-on-button" disabled={{ isJust sy.working }} onClick={{ const TurnOn }}>Turn on with a passkey</button>
                </div>
                <p class="account-note">Your browser asks you to make a passkey for this wiki: Touch ID, Windows Hello, your phone or a security key. One touch of it unlocks your keys on your other devices. The wiki's server keeps them sealed, and cannot open them.</p>
              {% end %}
            {% end %}
            {% for doing in maybeToList sy.working %}
              <p class="assistant-sync-working" role="status">{{ doing }}</p>
            {% end %}
            {% for why in maybeToList sy.trouble %}
              <p class="error assistant-sync-problem" role="alert">{{ why }}</p>
            {% end %}
          </section>
        |]
      where
        -- A new passkey signs the user in, so the server asks for their
        -- password to make one. A passkey of theirs already, used instead,
        -- needs none; nor does a user who signs in only with a provider.
        passwordField =
          [hh|
            <label class="field">
              <span>Your password, to make a new passkey (none if you sign in with a provider)</span>
              <input type="password" class="assistant-passkey-password" autocomplete="current-password" disabled={{ isJust sy.working }} onValueInput={{ TypedSyncPassword }} {{ HP.ref field }}>
            </label>
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
              <p class="warning assistant-unreachable" role="alert">{{ cannotReach }}</p>
            {% end %}
            <label class="field assistant-service-field">
              <span>Service</span>
              <select class="assistant-service" disabled={{ st.busy || checking }} onValueChange={{ ChooseService p }}>
                <option value="" selected={{ isNothing ps.baseUrl }}>{{ ownService }}</option>
                {% for service in offered %}
                  <option value={{ service.baseUrl.text }} selected={{ ps.baseUrl == Just service.baseUrl }}>{{ service.name }} ({{ service.baseUrl.text }})</option>
                {% end %}
                {% for url in maybeToList stale %}
                  <option value={{ url.text }} selected>{{ url.text }} (no longer offered by this wiki)</option>
                {% end %}
              </select>
            </label>
            {% if isJust stale %}
              <p class="warning assistant-service-stale" role="alert">This address is no longer among the services this wiki offers, and the browser may be refused it: choose another service.</p>
            {% end %}
            <p class="account-note assistant-service-hint">{{ serviceHint }}</p>
            {% for url in maybeToList ps.baseUrl %}
              {% if insecureUrl url.text %}
                <p class="warning assistant-insecure-base-url" role="alert">This address is plain HTTP to another machine: your key and your pages would cross the network unencrypted, for anyone on the way to read. Use an HTTPS address, or a server on this machine.</p>
              {% end %}
            {% end %}
            {% if isJust ps.key %}
              <p class="assistant-key-kept">A key is kept for {{ providerLabel p }} in this browser.</p>
              <div class="actions">
                <button type="button" class="assistant-test" disabled={{ checking }} onClick={{ const (Test p) }}>Test the key</button>
                <button type="button" class="danger assistant-forget" disabled={{ st.busy }} onClick={{ const (Forget p) }}>Forget</button>
              </div>
            {% else %}
              <form class="assistant-key-form" {{ HE.preventingDefault (HE.onSubmit (const (TestAndKeep p))) }}>
                <label class="field">
                  <span>API key</span>
                  <input type="password" class="assistant-key" autocomplete="off" spellcheck="false" value={{ typedKey }} disabled={{ checking }} onValueInput={{ TypedKey p }}>
                </label>
                <button type="submit" class="primary assistant-test-keep" disabled={{ st.busy || checking || nothingTyped }}>{{ if checking then "Checking…" else "Test and keep the key" :: Text }}</button>
              </form>
              {% if isNothing (baseUrlOf p ps) %}
                {% for url in maybeToList (keyPage p) %}
                  <p class="account-note">Make one at <a href={{ url }} target="_blank" rel="noopener noreferrer">{{ url }}</a>.</p>
                {% end %}
              {% end %}
              {% if usable p ps && nothingTyped %}
                <div class="actions">
                  <button type="button" class="assistant-test" disabled={{ checking }} onClick={{ const (Test p) }}>Test the connection (no key)</button>
                </div>
              {% end %}
            {% end %}
          {% end %}
          <fieldset class="assistant-model" disabled={{ st.busy || checking }}>
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
              <input type="text" class="assistant-model-name" spellcheck="false" placeholder="A model's id" aria-label={{ "Another model of " <> providerLabel p }} value={{ if listed then typedModel else chosen.text }} onValueChange={{ TypedModel p }}>
            {% end %}
            {{ listingView }}
          </fieldset>
          <label class="field assistant-effort-field">
            <span>Effort</span>
            <select class="assistant-default-effort" disabled={{ st.busy || checking }} onValueChange={{ ChooseEffort p }}>
              {% for e in efforts p %}
                <option value={{ e }} selected={{ effortOf ps == e }}>{{ effortName e }}</option>
              {% end %}
            </select>
          </label>
          <p class="account-note assistant-effort-hint">How hard the model thinks before it answers, at the start of each conversation. A higher effort answers more carefully, more slowly, and costs more. The chat can change it for one conversation.</p>
          {{ checkView }}
        </section>
      |]
      where
        ps = settingsOf p s
        choices = modelChoices p ps
        chosen = chosenModel p ps
        -- At another service's address there are two more causes. The
        -- page's Content Security Policy may not allow the address
        -- (WP5.21), and the service may not answer a browser page's
        -- requests (CORS). The browser reports both as no connection.
        cannotReach :: Text
        cannotReach =
          "Cannot reach "
            <> serviceName p ps
            <> " from this network: the last request found no way to it. A network that blocks it, a firewall or a proxy, is the likely cause."
            <> if isJust (baseUrlOf p ps)
              then " Or the service does not answer requests from a browser page (CORS), or its address is no longer one this wiki offers (its administrator lists them in the server settings: Administration, Server, The assistant's services)."
              else ""
        -- The session's services that speak this provider's API, and the
        -- base URL kept if none of them is at it.
        offered = [service | service <- st.input.context.session.assistantServices, apiProvider service.api == p]
        stale = mfilter (\url -> url `notElem` map (\service -> service.baseUrl) offered) ps.baseUrl
        ownService = (if p == OpenAI then "OpenAI's own" else "Anthropic's own") :: Text
        serviceHint :: Text
        serviceHint
          | null offered = providerLabel p <> "'s own service is the only one this wiki offers. Its administrator can add others that speak its API, such as your organisation's gateway or a server of Ollama (Administration, Server, The assistant's services)."
          | otherwise = providerLabel p <> "'s own service, or another that speaks its API, as this wiki's administrator lists them (Administration, Server, The assistant's services). Some take a key of their own (GitHub Models a GitHub token), and a server of Ollama or LM Studio takes none."
        listed = chosen `elem` map (\m -> m.id) (choices.recommended <> choices.others)
        other = Set.member p st.otherModels || not listed
        option m = [hh|<option value={{ m.id.text }} selected={{ not other && chosen == m.id }}>{{ m.label }}</option>|]
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
        -- With a key typed, the only test offered is the one with that key:
        -- "Test the connection (no key)" is hidden.
        typedKey = Map.findWithDefault "" p st.typedKeys
        nothingTyped = T.null (T.strip typedKey)
        effortName e = if e == defaultEffort then e <> " (default)" else e
        checking = case Map.lookup p st.checks of
          Just Checking -> True
          _ -> False
        checkView = case Map.lookup p st.checks of
          Nothing -> Nothing
          Just Checking -> Just [hh|<p class="assistant-check" role="status">Asking {{ providerLabel p }}…</p>|]
          Just Works
            | p /= Scripted && isNothing ps.key -> Just [hh|<p class="assistant-check assistant-check-works" role="status">The connection works without a key, and {{ chosen.text }} is there.</p>|]
            | otherwise -> Just [hh|<p class="assistant-check assistant-check-works" role="status">The key works, and {{ chosen.text }} is there.</p>|]
          Just Kept -> Just [hh|<p class="assistant-check assistant-check-works assistant-check-kept" role="status">The key works and is kept.</p>|]
          Just (Fails why) -> Just [hh|<p class="error assistant-check assistant-check-fails" role="alert">{{ why }}</p>|]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      -- On a page rendered ahead of the program, the page stays as first
      -- rendered, and the program adopts it.
      Initialize -> whenM (H.liftEffect assistantHere) $ do
        secure <- H.liftEffect secureContext
        sealing <- H.liftEffect sealingHere
        scripted <- H.liftEffect scriptedInstalled
        modify (\st -> st {secure, sealing, scripted})
        load
      Receive input -> do
        before <- gets (\st -> st.user)
        modify (\st -> st {input, user = userOf input})
        -- Another user signed in: load their settings, not the previous user's.
        here <- H.liftEffect assistantHere
        when (here && userOf input /= before) $ do
          modify (\st -> st {settings = Nothing, typedKeys = mempty, typedModels = mempty, checks = mempty, listings = mempty, otherModels = mempty, problem = Nothing})
          load
      TypedKey p k -> modify (\st -> st {typedKeys = Map.insert p k st.typedKeys})
      -- "Test and keep the key" (the owner, 2026-11-04). The typed key is
      -- tried before it is kept, so that a wrong key is never kept, in two
      -- steps. First the model list is fetched with it: a refused key (a
      -- 401) stops there. Any other failure of the list goes on with the
      -- model chosen, since a gateway may have no list. Then the message
      -- test ('checkKey') runs with the model chosen if the list has it,
      -- else with the list's first model. Only when it passes are the key
      -- and that model kept. On a failure nothing is kept: the reason
      -- shows by the field, the key stays in it, and the list stays shown,
      -- so that another model can be chosen and the button pressed again.
      TestAndKeep p ->
        gets (\st -> (st.user, st.settings, Map.findWithDefault "" p st.typedKeys)) >>= \case
          (Just user, Just (Right s), typed) | Just asked <- readyWith typed p s -> do
            modify (\st -> st {checks = Map.insert p Checking st.checks, listings = Map.insert p Listing st.listings})
            -- The provider's other inputs are disabled while the key is
            -- tried, but the settings may still change meanwhile (another
            -- device's change, taken in by 'change'). An answer counts only
            -- for the same user and the same address: another user's
            -- settings are not the ones the key was typed into, and an
            -- answer from the old address says nothing of the new one. An
            -- answer from an address no longer set keeps nothing.
            let same = do
                  (user', address) <- gets (\st -> (st.user, fmap (baseUrlOf p . settingsOf p) <$> st.settings))
                  if user' /= Just user
                    then pure False
                    else
                      if address == Just (Right asked.baseUrl)
                        then pure True
                        else do
                          modify (\st -> st {checks = Map.insert p (Fails moved) st.checks})
                          pure False
                moved = "The base URL changed while the key was tested, so the key was not kept: test it again."
                refuse e = do
                  modify (\st -> st {checks = Map.insert p (Fails (errorText (serviceOf asked) (Just asked.key) e)) st.checks})
                  change (withReached p (e.kind /= Unreachable))
            now <- liftIO getCurrentTime
            listed <- lift (listModels asked)
            whenM same $ case listed of
              Left e | e.kind == BadKey -> do
                modify (\st -> st {listings = Map.delete p st.listings})
                refuse e
              Left e -> do
                modify (\st -> st {listings = Map.insert p (NotFetched (errorText (serviceOf asked) (Just asked.key) e)) st.listings})
                tryModel p user typed asked same refuse identity asked.model
              Right models -> do
                -- Shown at once, so that another model can be chosen if
                -- the message test fails with this one.
                change (withModels p models now)
                modify (\st -> st {listings = Map.insert p (Fetched (length models)) st.listings})
                listedSettings <- gets (\st -> either (const Nothing) Just =<< st.settings)
                let ps = maybe (settingsOf p s) (settingsOf p) listedSettings
                    choices = modelChoices p ps
                    offered = map (\m -> m.id) (choices.recommended <> choices.others)
                    chosen = chosenModel p ps
                    model = if chosen `elem` offered then chosen else fromMaybe chosen (head offered)
                tryModel p user typed asked same refuse (withModels p models now) model
          _ -> pass
      Forget p -> do
        change (withKey p Nothing)
        modify (\st -> st {checks = Map.delete p st.checks, listings = Map.delete p st.listings})
      Choose p -> change (chooseProvider p)
      -- "Other…": show its field, with the model typed there last, if any.
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
            modify (\st -> st {checks = Map.insert p (maybe Works (Fails . errorText (serviceOf r) (Just r.key)) result) st.checks})
            -- Record whether the provider responded at all; and once the
            -- key is known to work, fetch its model list too.
            for_ result (\e -> change (withReached p (e.kind /= Unreachable)))
            when (isNothing result) (fetchModels p)
          _ -> pass
      Refresh p -> fetchModels p
      TurnOn -> withSyncPassword (\p -> syncStep "Waiting for your passkey…" (`turnOnSync` p))
      TypedSyncPassword t -> modify (\st -> st {syncPassword = t})
      Unlock -> syncStep "Waiting for your passkey…" unlockKeys
      AddPasskey -> withSyncPassword (\p -> syncStep "Waiting for a passkey you have, then for the new one…" (`addPasskey` p))
      TurnOff -> syncStep "Turning syncing off…" turnOffSync
      AskEachTime asking -> syncStep "Changing how this browser keeps the key…" (`setAskEachTime` asking)
      RemovePasskey credential ->
        gets (\st -> st.user)
          >>= traverse_
            ( \user -> do
                modify (\st -> st {sync = st.sync {working = Just "Removing the passkey…", trouble = Nothing}})
                result <- lift (removePasskey user credential)
                modify $ \st -> case result of
                  Right left -> st {sync = st.sync {working = Nothing, passkeys = left}}
                  Left why -> st {sync = st.sync {working = Nothing, trouble = Just why}}
            )
      ChooseEffort p e -> change (withEffort p e)
      ChooseService p url -> do
        change (withBaseUrl p url)
        modify (\st -> st {checks = Map.delete p st.checks, listings = Map.delete p st.listings})
        -- Fetch the other service's own list, if it can be reached.
        gets (\st -> st.settings) >>= \case
          Just (Right s) | usable p (settingsOf p s) && isJust (baseUrlOf p (settingsOf p s)) -> fetchModels p
          _ -> pass

    -- The message test of "Test and keep the key", with a typed key and a
    -- model; then, if it passes, the key and the model kept. Keeping the
    -- key discards the model list stored before it ('withKey'), so the
    -- list fetched with the key is stored again with it ('relisted').
    -- Once the browser stores the key, the page's state no longer holds
    -- it. When storing fails, the key stays typed and the page shows why
    -- ('change').
    tryModel
      :: Provider
      -> UserId
      -> Text
      -> Ready
      -> H.HalogenM State Action Empty output m Bool
      -> (AssistantError -> H.HalogenM State Action Empty output m ())
      -> (Settings -> Settings)
      -> ModelName
      -> H.HalogenM State Action Empty output m ()
    tryModel p user typed asked same refuse relisted model = do
      let r = Ready {provider = asked.provider, model, key = asked.key, effort = asked.effort, baseUrl = asked.baseUrl}
      result <- lift (checkKey r)
      whenM same $ case result of
        Just e -> refuse e
        Nothing -> do
          let keepModel ns = if chosenModel p (settingsOf p ns) == model then ns else withModel p model.text ns
          change (keepModel . relisted . withKey p (Just typed))
          kept <- gets (\st -> st.user == Just user && either (const False) (\ns -> isJust (settingsOf p ns).key) (fromMaybe (Left "") st.settings))
          modify $ \st ->
            if kept
              then st {typedKeys = Map.delete p st.typedKeys, checks = Map.insert p Kept st.checks}
              else st {checks = Map.delete p st.checks}

    -- Fetch a provider's model list with its key, and store it. The fetch
    -- also tells whether the provider can be reached from here.
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
              modify (\st -> st {listings = Map.insert p (NotFetched (errorText (serviceOf r) (Just r.key) e)) st.listings})
            Right listed -> do
              change (withModels p listed now)
              modify (\st -> st {listings = Map.insert p (Fetched (length listed)) st.listings})
        _ -> pass

    load :: H.HalogenM State Action Empty output m ()
    load =
      gets (\st -> st.user)
        >>= traverse_
          ( \user -> do
              keys <- lift (loadKeys user)
              offer <- offerHere
              passkeys <- case keys of
                Right k | k.synced -> either (const []) identity <$> lift listPasskeys
                _ -> pure []
              -- Only if the same user is still signed in.
              whenM (gets (\st -> st.user == Just user)) $
                modify (\st -> st {settings = Just ((\k -> k.settings) <$> keys), sync = (syncOf keys st.sync) {offer, passkeys}})
          )

    -- Whether this page can sync the keys: a server keeps vaults, and the
    -- browser offers passkeys here.
    offerHere :: H.HalogenM State Action Empty output m Offer
    offerHere =
      lift vaultSync >>= \case
        False -> pure NoServer
        True -> bool NotSecure Offered <$> H.liftEffect passkeysHere

    -- A step of syncing, which may wait on the browser's passkey dialog:
    -- said while it runs, and then the settings and the passkeys as they
    -- are after it, with why it failed if it did. A step that fails may
    -- still have changed what this device keeps (turning on finds the
    -- vault another device made, and follows it, locked), so the keys are
    -- read again then.
    -- The password typed for a new passkey, if any (a user who signs in
    -- only with a provider has none), forgotten once used.
    withSyncPassword :: (Maybe Password -> H.HalogenM State Action Empty output m ()) -> H.HalogenM State Action Empty output m ()
    withSyncPassword act = do
      typed <- gets (\st -> st.syncPassword)
      -- The field is emptied with the state, so that what it shows is what
      -- a retry sends, and no password is left in it.
      modify (\st -> st {syncPassword = ""})
      gets (\st -> st.syncPasswordField) >>= H.getRef >>= traverse_ (H.liftEffect . clearField)
      act (if T.null typed then Nothing else Just (Password typed))

    syncStep :: Text -> (UserId -> m (Either Text Keys)) -> H.HalogenM State Action Empty output m ()
    syncStep saying step =
      gets (\st -> st.user)
        >>= traverse_
          ( \user -> do
              modify (\st -> st {sync = st.sync {working = Just saying, trouble = Nothing}})
              result <- lift (step user)
              keys <- either (const (lift (readKeys user))) (pure . Right) result
              passkeys <- case keys of
                Right k | k.synced -> either (const []) identity <$> lift listPasskeys
                _ -> pure []
              let trouble = either Just (const Nothing) result
              modify $ \st -> case keys of
                Right k -> st {settings = Just (Right k.settings), sync = (syncOf keys st.sync) {working = Nothing, passkeys, trouble}}
                Left _ -> st {sync = st.sync {working = Nothing, trouble}}
          )

    -- Change the settings, and store them immediately.
    change :: (Settings -> Settings) -> H.HalogenM State Action Empty output m ()
    change f =
      gets (\st -> (st.user, st.settings)) >>= \case
        (Just user, Just (Right _)) -> do
          modify (\st -> st {busy = True, problem = Nothing})
          -- The change itself, not the settings it gives: when another
          -- device changed the settings meanwhile, it is made again on
          -- theirs.
          result <- lift (changeKeys user f)
          modify $ \st -> case result of
            Right k -> st {busy = False, settings = Just (Right k.settings), sync = syncOf result st.sync}
            Left why -> st {busy = False, problem = Just why}
        _ -> pass

-- | The provider whose API a service speaks.
apiProvider :: AssistantApi -> Provider
apiProvider = \case
  AnthropicApi -> Anthropic
  OpenAiApi -> OpenAI

userOf :: Input -> Maybe UserId
userOf input = (\u -> u.id) <$> input.context.session.user

-- | Syncing before anything is known: not offered.
noSync :: Sync
noSync = Sync {offer = NoServer, synced = False, locked = False, askEachTime = False, passkeys = [], working = Nothing, trouble = Nothing}

-- | Syncing as the keys say it is, the rest as it was.
syncOf :: Either Text Keys -> Sync -> Sync
syncOf keys sy = case keys of
  Right k -> Sync {offer = sy.offer, synced = k.synced, locked = k.locked, askEachTime = k.askEachTime, passkeys = sy.passkeys, working = sy.working, trouble = sy.trouble}
  Left _ -> sy
