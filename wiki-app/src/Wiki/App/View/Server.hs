{-# LANGUAGE QuasiQuotes #-}

-- | The administration's section on the server itself (WP4.4 of
-- docs/PLAN.md, "Wiki.Api.ServerSettings"): the wiki's public address,
-- the mail server invitations are sent through, and the sign-in
-- providers; and, not a setting but a property of the server's machine,
-- whether it exports PDFs. This is the only place they are set (the
-- owner's decision of 2026-10-25): the server's admin listener serves it
-- before anyone can sign in, and a change takes effect with the next
-- request, without a restart. It is one component over the
-- administration's backend ("Wiki.App.Backend.Admin"), which the shell
-- shows beside "Who may come in".
--
-- Everything it shows comes from one read, as in the other sections: at
-- once where the backend answers at once (the demo, and a page the server
-- prerendered, which carries the settings), and otherwise in its
-- initializer.
--
-- One thing is edited at a time (the address, the mail server, or one
-- provider), in a form that replaces what it edits. Saving writes all the
-- settings at once, with everything not being edited as it was read. A
-- secret (the mail account's password, a provider's client secret) is
-- typed once into a password field and never shown again, not even to
-- this page: the backend says only whether it is set. A form for something
-- that has a secret offers "Replace…" (a field for a new one; left empty,
-- it keeps the old) and "Clear"; saving without either keeps it.
--
-- A provider can be checked ("Check"): the server asks it how to sign in,
-- with its saved settings or, from its form, as typed, and reports where
-- it found the provider's endpoints, or why it could not. Each provider
-- shows the redirect URI to register with it, under the wiki's public
-- address. Its form explains under each field what goes there and where
-- it comes from, in the README's words ('providerHints'), and what to do
-- with the redirect URI ('providerRedirect'). A test mail goes to a typed
-- address, through the saved mail server. The demo stores the settings
-- for the tab's life and does neither, which it says.
module Wiki.App.View.Server
  ( Input (..)
  , component

    -- * The provider form's help
  , ProviderHints (..)
  , providerHints
  , providerRedirect
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (type (.+), type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Export (ExportFormat, formatLabel, needsTeX)
import Wiki.Api.ServerSettings
import Wiki.App.Backend (MonadLoad (..), Session (exports), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Backups qualified as Backups
import Wiki.App.View.Common
import Wiki.App.View.Status qualified as Status

newtype Input = Input {context :: Context}

-- | The parts of the section that are components of their own: the
-- backups ("Wiki.App.View.Backups") and the server's status
-- ("Wiki.App.View.Status").
type Slots = ("backups" .== H.Slot (Const Void) Void ()) .+ ("status" .== H.Slot (Const Void) Void ())

data Loaded
  = Loading
  | Failed WikiError
  | Ready ServerSettings

-- | What is being edited.
data Editing
  = NotEditing
  | -- | The public address, as typed.
    EditingUrl Text
  | EditingMail MailForm
  | -- | A provider, by the name it had ('Nothing' for a new one).
    EditingProvider (Maybe Text) ProviderForm

-- | The mail server's form, as typed.
data MailForm = MailForm
  { typedHost :: Text
  , typedPort :: Text
  , chosenSecurity :: Security
  , typedUser :: Text
  , typedPassword :: Text
  , passwordSet :: Bool
  -- ^ Whether the server has a password already: if so, the field is
  -- offered only once "Replace…" is chosen.
  , replacingPassword :: Bool
  , clearingPassword :: Bool
  , typedFrom :: Text
  }

-- | A provider's form, as typed.
data ProviderForm = ProviderForm
  { typedName :: Text
  , chosenKind :: ProviderKind
  , typedClientId :: Text
  , typedIssuer :: Text
  , typedSecret :: Text
  , secretSet :: Bool
  , replacingSecret :: Bool
  , formCheck :: Maybe Checked
  }

-- | The result of checking a provider.
data Checked
  = Checking
  | CheckedAs (Either WikiError ProviderCheck)

data State = State
  { input :: Input
  , loaded :: Loaded
  , editing :: Editing
  , busy :: Bool
  , refusal :: Maybe WikiError
  , checks :: Map Text Checked
  -- ^ The result of checking each saved provider.
  , testTo :: Text
  , tested :: Maybe (Either WikiError MailTestResult)
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | EditUrl
  | TypedUrl Text
  | SaveUrl
  | EditMail
  | RemoveMail
  | TypedHost Text
  | TypedPort Text
  | ChoseSecurity Text
  | TypedUser Text
  | TypedPassword Text
  | ReplacePassword
  | ClearPassword
  | TypedFrom Text
  | SaveMail
  | AddProvider
  | EditProvider Text
  | RemoveProvider Text
  | TypedName Text
  | ChoseKind Text
  | TypedClientId Text
  | TypedIssuer Text
  | TypedSecret Text
  | ReplaceSecret
  | CheckForm
  | SaveProvider
  | CheckProvider Text
  | Cancel
  | TypedTestTo Text
  | SendTest

component :: forall query m. (MonadAdmin m, MonadLoad m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce serverSettings
          pure State {input, loaded, editing = NotEditing, busy = False, refusal = Nothing, checks = mempty, testTo = "", tested = Nothing}
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
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <section class="admin-section admin-server">
          <h2>Server</h2>
          <p class="admin-intro">
            The wiki's public address, the mail server invitations are sent through, and the
            providers people may sign in with. They are set here and nowhere else, and take effect
            at once. Passwords and client secrets are typed once and never shown again.
          </p>
          {{ HH.slot_ "status" () Status.component Status.Input {context = st.input.context} }}
          {{ body }}
          {{ HH.slot_ "backups" () Backups.component Backups.Input {context = st.input.context} }}
        </section>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready settings -> settingsView st settings

    settingsView :: State -> ServerSettings -> H.ComponentHTML Action Slots m
    settingsView st settings =
      [hh|
        <div class="server-settings">
          {{ errorView <$> st.refusal }}
          {{ urlView st settings }}
          {{ mailView st settings }}
          {{ providersView st settings }}
          {{ exportView st.input.context.session.exports }}
        </div>
      |]

    -- The formats pages and spaces export to (WP4.16 of docs/PLAN.md),
    -- and above all whether PDF is among them: it needs a TeX engine on the
    -- server's machine, which the server looks for at each request, so
    -- that installing one takes effect without a restart.
    exportView :: [ExportFormat] -> H.ComponentHTML Action Slots m
    exportView formats =
      [hh|
        <div class="server-part server-export">
          <h3>Export</h3>
          {% if null formats %}
            <p class="server-export-none">This wiki exports nothing: documents are made by the server, with pandoc.</p>
          {% else %}
            <p class="server-export-formats">Pages and spaces export as {{ T.intercalate ", " (map formatLabel formats) }}.</p>
            {% if any needsTeX formats %}
              <p class="server-export-tex">xelatex was found: PDFs are made with it.</p>
            {% else %}
              <p class="server-export-tex server-export-no-tex">xelatex was not found, so nothing exports as PDF. Install it on the server's machine (<code>apt install texlive-xetex</code>) and the PDFs are offered at once.</p>
            {% end %}
          {% end %}
        </div>
      |]

    -- The public address.
    urlView :: State -> ServerSettings -> H.ComponentHTML Action Slots m
    urlView st settings =
      [hh|
        <div class="server-part server-url">
          <h3>Public address</h3>
          {{ inside }}
        </div>
      |]
      where
        inside = case st.editing of
          EditingUrl typed ->
            [hh|
              <form class="server-url-form" aria-label="The wiki's public address" {{ HE.preventingDefault (HE.onSubmit (const SaveUrl)) }}>
                <label class="field">
                  <span>The address its readers reach it at</span>
                  <input type="url" name="url" placeholder="https://wiki.example.org/" value={{ typed }} onValueInput={{ TypedUrl }}>
                </label>
                <div class="actions">
                  <button type="submit" class="primary" disabled={{ st.busy }}>Save</button>
                  <button type="button" class="server-cancel" onClick={{ const Cancel }}>Cancel</button>
                </div>
              </form>
            |]
          _ ->
            [hh|
              <div class="server-url-shown">
                <p class="server-url-value">{{ fromMaybe "Not set: invitations cannot be mailed, nor providers set up, until it is." settings.publicUrl }}</p>
                <p class="admin-intro">Mailed links and the providers' redirect URIs start with it.</p>
                <div class="actions">
                  <button type="button" class="server-url-edit" disabled={{ editingSomething st }} onClick={{ const EditUrl }}>Change</button>
                </div>
              </div>
            |]

    -- The mail server, and the test mail.
    mailView :: State -> ServerSettings -> H.ComponentHTML Action Slots m
    mailView st settings =
      [hh|
        <div class="server-part server-mail">
          <h3>Mail</h3>
          {{ inside }}
        </div>
      |]
      where
        inside = case (st.editing, settings.mail) of
          (EditingMail form, _) -> mailForm st form
          (_, Nothing) ->
            [hh|
              <div class="server-mail-shown">
                <p class="server-mail-none">No mail server: the administration shows an invitation's link to pass on instead.</p>
                <div class="actions">
                  <button type="button" class="server-mail-edit" disabled={{ editingSomething st }} onClick={{ const EditMail }}>Set up mail</button>
                </div>
              </div>
            |]
          (_, Just m) ->
            [hh|
              <div class="server-mail-shown">
                <dl class="server-mail-summary">
                  <dt>Server</dt><dd class="server-mail-host">{{ m.host <> ":" <> show m.port }} ({{ securityText m.security }})</dd>
                  <dt>Sender</dt><dd>{{ m.from }}</dd>
                  <dt>Account</dt><dd>{{ fromMaybe "none" m.user }}</dd>
                  <dt>Password</dt><dd class="server-mail-password">{{ secretText m.password }}</dd>
                </dl>
                <div class="actions">
                  <button type="button" class="server-mail-edit" disabled={{ editingSomething st }} onClick={{ const EditMail }}>Change</button>
                  <button type="button" class="server-mail-remove" disabled={{ editingSomething st || st.busy }} onClick={{ const RemoveMail }}>Remove</button>
                </div>
                <form class="server-mail-test" aria-label="Send a test mail" {{ HE.preventingDefault (HE.onSubmit (const SendTest)) }}>
                  <label class="field">
                    <span>Send a test mail to</span>
                    <input type="email" name="to" autocomplete="email" required value={{ st.testTo }} onValueInput={{ TypedTestTo }}>
                  </label>
                  <div class="actions">
                    <button type="submit" disabled={{ st.busy }}>Send a test mail</button>
                  </div>
                  {{ testedView <$> st.tested }}
                </form>
              </div>
            |]

    testedView :: Either WikiError MailTestResult -> H.ComponentHTML Action Slots m
    testedView = \case
      Left e -> errorView e
      Right r -> case r.failure of
        Nothing -> [hh|<p class="server-mail-tested" role="status">Sent: check that it arrived.</p>|]
        Just why -> [hh|<p class="server-mail-tested error" role="alert">Not sent: {{ why }}</p>|]

    mailForm :: State -> MailForm -> H.ComponentHTML Action Slots m
    mailForm st form =
      [hh|
        <form class="server-mail-form" aria-label="The mail server" {{ HE.preventingDefault (HE.onSubmit (const SaveMail)) }}>
          <label class="field">
            <span>Host</span>
            <input type="text" name="host" autocomplete="off" required placeholder="mail.example.org" value={{ form.typedHost }} onValueInput={{ TypedHost }}>
          </label>
          <label class="field">
            <span>Port</span>
            <input type="number" name="port" min="1" max="65535" required value={{ form.typedPort }} onValueInput={{ TypedPort }}>
          </label>
          <label class="field">
            <span>Security</span>
            <select name="security" onValueChange={{ ChoseSecurity }}>
              {% for s in [minBound .. maxBound :: Security] %}
                <option value={{ securityName s }} selected={{ s == form.chosenSecurity }}>{{ securityText s }}</option>
              {% end %}
            </select>
          </label>
          <label class="field">
            <span>Sender</span>
            <input type="text" name="from" required placeholder={{ "Wiki <wiki@example.org>" :: Text }} value={{ form.typedFrom }} onValueInput={{ TypedFrom }}>
          </label>
          <label class="field">
            <span>Account (if the server wants one)</span>
            <input type="text" name="user" autocomplete="off" value={{ form.typedUser }} onValueInput={{ TypedUser }}>
          </label>
          {{ secretField "Password" "password" form.passwordSet form.replacingPassword form.clearingPassword form.typedPassword TypedPassword ReplacePassword (Just ClearPassword) }}
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Save</button>
            <button type="button" class="server-cancel" onClick={{ const Cancel }}>Cancel</button>
          </div>
        </form>
      |]

    -- The providers, one row each, and the form of the one being edited.
    providersView :: State -> ServerSettings -> H.ComponentHTML Action Slots m
    providersView st settings =
      [hh|
        <div class="server-part server-providers">
          <h3>Sign-in providers</h3>
          <p class="admin-intro">
            People may sign in with an account at each provider here, as well as with a password.
            Register the wiki with the provider first, with the redirect URI shown, and copy the
            client id and secret it gives you here.
          </p>
          {% if null settings.providers %}
            <p class="empty">No provider: people sign in with passwords only.</p>
          {% else %}
            <ul class="server-provider-list">
              {% for p in settings.providers %}
                <li class="server-provider" data-name={{ p.name }}>
                  {% if editedName st == Just p.name %}
                    {{ providerForm st settings <$> providerFormOf st }}
                  {% else %}
                    {{ providerRow st settings p }}
                  {% end %}
                </li>
              {% end %}
            </ul>
          {% end %}
          {{ adding }}
        </div>
      |]
      where
        adding = case st.editing of
          EditingProvider Nothing form -> [hh|<div class="server-provider-new">{{ providerForm st settings form }}</div>|]
          _ ->
            [hh|
              <div class="actions">
                <button type="button" class="server-provider-add" disabled={{ editingSomething st }} onClick={{ const AddProvider }}>Add a provider</button>
              </div>
            |]

    providerRow :: State -> ServerSettings -> ProviderSettings -> H.ComponentHTML Action Slots m
    providerRow st settings p =
      [hh|
        <div class="server-provider-row">
          <strong class="server-provider-name">{{ p.name }}</strong>
          <span class="server-provider-kind">{{ providerLabel p.kind p.name }} ({{ kindName p.kind }})</span>
          <dl>
            <dt>Client id</dt><dd>{{ p.clientId }}</dd>
            {% for i in maybeToList p.issuer %}<dt>Address</dt><dd>{{ i }}</dd>{% end %}
            <dt>Client secret</dt><dd class="server-provider-secret">{{ secretText p.secret }}</dd>
            <dt>Redirect URI</dt><dd class="server-provider-redirect">{{ redirectText settings p.name }}</dd>
          </dl>
          <div class="actions">
            <button type="button" class="server-provider-check" disabled={{ st.busy || Map.member p.name (Map.filter isChecking st.checks) }} onClick={{ const (CheckProvider p.name) }}>Check</button>
            <button type="button" class="server-provider-edit" disabled={{ editingSomething st }} onClick={{ const (EditProvider p.name) }}>Change</button>
            <button type="button" class="server-provider-remove" disabled={{ editingSomething st || st.busy }} onClick={{ const (RemoveProvider p.name) }}>Remove</button>
          </div>
          {% for c in maybeToList (Map.lookup p.name st.checks) %}
            {{ checkedView c }}
          {% end %}
        </div>
      |]

    providerForm :: State -> ServerSettings -> ProviderForm -> H.ComponentHTML Action Slots m
    providerForm st settings form =
      [hh|
        <form class="server-provider-form" aria-label="A provider" {{ HE.preventingDefault (HE.onSubmit (const SaveProvider)) }}>
          <label class="field">
            <span>Name, in its addresses</span>
            <input type="text" name="name" autocomplete="off" required pattern={{ "[a-z][a-z0-9\\-]*" :: Text }} placeholder="google" readonly={{ isJust (editedName st) }} value={{ form.typedName }} onValueInput={{ TypedName }}>
          </label>
          <p class="field-hint server-provider-hint-name">{{ hints.name }}</p>
          <label class="field">
            <span>Kind</span>
            <select name="kind" onValueChange={{ ChoseKind }}>
              {% for k in [minBound .. maxBound :: ProviderKind] %}
                <option value={{ kindName k }} selected={{ k == form.chosenKind }}>{{ kindText k }}</option>
              {% end %}
            </select>
          </label>
          <p class="field-hint server-provider-hint-kind">{{ hints.kind }}</p>
          <label class="field">
            <span>Client id</span>
            <input type="text" name="client-id" autocomplete="off" required value={{ form.typedClientId }} onValueInput={{ TypedClientId }}>
          </label>
          <p class="field-hint server-provider-hint-client-id">{{ hints.clientId }}</p>
          <label class="field">
            <span>{{ issuerLabel form.chosenKind }}</span>
            <input type="url" name="issuer" autocomplete="off" required={{ form.chosenKind == Generic }} value={{ form.typedIssuer }} onValueInput={{ TypedIssuer }}>
          </label>
          <p class="field-hint server-provider-hint-address">{{ hints.address }}</p>
          {{ secretField "Client secret" "secret" form.secretSet form.replacingSecret False form.typedSecret TypedSecret ReplaceSecret Nothing }}
          <p class="field-hint server-provider-hint-secret">{{ hints.secret }}</p>
          {{ providerRedirect settings.publicUrl (T.strip form.typedName) }}
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Save</button>
            <button type="button" class="server-provider-form-check" disabled={{ st.busy || T.null (T.strip form.typedName) }} onClick={{ const CheckForm }}>Check</button>
            <button type="button" class="server-cancel" onClick={{ const Cancel }}>Cancel</button>
          </div>
          {% for c in maybeToList form.formCheck %}
            {{ checkedView c }}
          {% end %}
        </form>
      |]
      where
        hints = providerHints form.chosenKind

    checkedView :: Checked -> H.ComponentHTML Action Slots m
    checkedView = \case
      Checking -> [hh|<p class="server-provider-checked loading" role="status">Asking it how to sign in…</p>|]
      CheckedAs (Left e) -> errorView e
      CheckedAs (Right c) -> case (c.discovered, c.problem) of
        (Just d, _) ->
          [hh|
            <div class="server-provider-checked" role="status">
              <p>It answered: people can sign in with it{{ if c.clientSecret == Set then "." else ", once its client secret is set." :: Text }}</p>
              <dl>
                <dt>Issuer</dt><dd>{{ d.issuer }}</dd>
                <dt>Sign-in page</dt><dd>{{ d.authorization }}</dd>
                <dt>Token endpoint</dt><dd>{{ d.token }}</dd>
              </dl>
            </div>
          |]
        (Nothing, why) -> [hh|<p class="server-provider-checked error" role="alert">{{ fromMaybe "It could not be asked." why }}</p>|]

    -- A secret's field: typed once, never shown. Where a secret is set,
    -- the field is offered only to replace it, and it may be cleared.
    secretField :: Text -> Text -> Bool -> Bool -> Bool -> Text -> (Text -> Action) -> Action -> Maybe Action -> H.ComponentHTML Action Slots m
    secretField label name isSet replacing clearing typed onTyped onReplace onClear
      | isSet && not replacing =
          [hh|
            <div class="field server-secret">
              <span>{{ label }}</span>
              <span class="server-secret-state">{{ if clearing then "Cleared when saved" else "Set" :: Text }}</span>
              <button type="button" class="server-secret-replace" onClick={{ const onReplace }}>Replace…</button>
              {% for clear in maybeToList onClear %}
                <button type="button" class="server-secret-clear" disabled={{ clearing }} onClick={{ const clear }}>Clear</button>
              {% end %}
            </div>
          |]
      | otherwise =
          [hh|
            <label class="field server-secret">
              <span>{{ label <> (if isSet then " (a new one; left empty, the old one stays)" else "") }}</span>
              <input type="password" name={{ name }} autocomplete="new-password" value={{ typed }} onValueInput={{ onTyped }}>
            </label>
          |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      Cancel -> modify (\st -> st {editing = NotEditing, refusal = Nothing})
      EditUrl -> withSettings $ \s -> modify (\st -> st {editing = EditingUrl (fromMaybe "" s.publicUrl), refusal = Nothing})
      TypedUrl t -> modify (\st -> st {editing = EditingUrl t})
      SaveUrl ->
        gets (\st -> st.editing) >>= \case
          EditingUrl typed -> save (\s -> (unchanged s) {publicUrl = mfilter (not . T.null) (Just (T.strip typed))})
          _ -> pass
      EditMail -> withSettings $ \s ->
        modify (\st -> st {editing = EditingMail (maybe newMail mailFormOf s.mail), refusal = Nothing})
      RemoveMail -> save (\s -> (unchanged s) {mail = Nothing})
      TypedHost t -> onMail (\f -> f {typedHost = t})
      TypedPort t -> onMail (\f -> f {typedPort = t})
      ChoseSecurity t -> onMail (\f -> f {chosenSecurity = fromMaybe f.chosenSecurity (readSecurity t)})
      TypedUser t -> onMail (\f -> f {typedUser = t})
      TypedPassword t -> onMail (\f -> f {typedPassword = t})
      ReplacePassword -> onMail (\f -> f {replacingPassword = True, clearingPassword = False})
      ClearPassword -> onMail (\f -> f {clearingPassword = True})
      TypedFrom t -> onMail (\f -> f {typedFrom = t})
      SaveMail ->
        gets (\st -> st.editing) >>= \case
          EditingMail form -> case mailChangeOf form of
            Left why -> modify (\st -> st {refusal = Just (Invalid why)})
            Right m -> save (\s -> (unchanged s) {mail = Just m})
          _ -> pass
      AddProvider -> modify (\st -> st {editing = EditingProvider Nothing newProvider, refusal = Nothing})
      EditProvider name -> withSettings $ \s ->
        for_ (find (\p -> p.name == name) s.providers) $ \p ->
          modify (\st -> st {editing = EditingProvider (Just name) (providerFormOf' p), refusal = Nothing})
      RemoveProvider name -> save (\s -> (unchanged s) {providers = filter (\p -> p.name /= name) (unchanged s).providers})
      TypedName t -> onProvider (\f -> f {typedName = T.toLower t})
      ChoseKind t -> onProvider (\f -> f {chosenKind = fromMaybe f.chosenKind (readKind t)})
      TypedClientId t -> onProvider (\f -> f {typedClientId = t})
      TypedIssuer t -> onProvider (\f -> f {typedIssuer = t})
      TypedSecret t -> onProvider (\f -> f {typedSecret = t})
      ReplaceSecret -> onProvider (\f -> f {replacingSecret = True})
      CheckForm ->
        gets (\st -> st.editing) >>= \case
          EditingProvider _ form -> do
            onProvider (\f -> f {formCheck = Just Checking})
            let change = providerChangeOf form
            result <- lift (checkProvider change.name (Just change))
            onProvider (\f -> f {formCheck = Just (CheckedAs result)})
          _ -> pass
      SaveProvider ->
        gets (\st -> st.editing) >>= \case
          EditingProvider was form -> do
            let change = providerChangeOf form
                replaced s = case was of
                  Just name -> [if p.name == name then change else p | p <- (unchanged s).providers]
                  Nothing -> (unchanged s).providers <> [change]
            save (\s -> (unchanged s) {providers = replaced s})
          _ -> pass
      CheckProvider name -> do
        modify (\st -> st {checks = Map.insert name Checking st.checks})
        result <- lift (checkProvider name Nothing)
        modify (\st -> st {checks = Map.insert name (CheckedAs result) st.checks})
      TypedTestTo t -> modify (\st -> st {testTo = t})
      SendTest -> do
        to' <- gets (\st -> st.testTo)
        modify (\st -> st {busy = True, tested = Nothing})
        result <- lift (sendTestMail (T.strip to'))
        modify (\st -> st {busy = False, tested = Just result})

    withSettings :: (ServerSettings -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withSettings f =
      gets (\st -> st.loaded) >>= \case
        Ready s -> f s
        _ -> pass

    onMail :: (MailForm -> MailForm) -> H.HalogenM State Action Slots ViewOutput m ()
    onMail f = modify $ \st -> case st.editing of
      EditingMail form -> st {editing = EditingMail (f form)}
      _ -> st

    onProvider :: (ProviderForm -> ProviderForm) -> H.HalogenM State Action Slots ViewOutput m ()
    onProvider f = modify $ \st -> case st.editing of
      EditingProvider was form -> st {editing = EditingProvider was (f form)}
      _ -> st

    -- Write the settings as read, with this change. If it succeeds, the
    -- form closes, the shell is told (who may sign in with what has
    -- changed), and the settings are fetched again. If it is refused, the
    -- reason is shown in place, and the form stays open.
    save :: (ServerSettings -> ServerSettingsChange) -> H.HalogenM State Action Slots ViewOutput m ()
    save change = withSettings $ \s -> do
      modify (\st -> st {busy = True, refusal = Nothing})
      lift (setServerSettings (change s)) >>= \case
        Left e -> modify (\st -> st {busy = False, refusal = Just e})
        Right new -> do
          modify (\st -> st {busy = False, loaded = Ready new, editing = NotEditing, checks = mempty, tested = Nothing})
          H.raise (Changed Nothing)

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      result <- lift serverSettings
      modify (\st -> st {loaded = either Failed Ready result, busy = False})

-- | The settings as read, as a change that changes nothing: every secret
-- kept.
unchanged :: ServerSettings -> ServerSettingsChange
unchanged = fmap (const Nothing)

-- | Whether something is being edited; the other "Change" buttons wait
-- until it is not.
editingSomething :: State -> Bool
editingSomething st = case st.editing of
  NotEditing -> False
  _ -> True

-- | The name of the provider being changed, if one is.
editedName :: State -> Maybe Text
editedName st = case st.editing of
  EditingProvider (Just name) _ -> Just name
  _ -> Nothing

providerFormOf :: State -> Maybe ProviderForm
providerFormOf st = case st.editing of
  EditingProvider (Just _) form -> Just form
  _ -> Nothing

isChecking :: Checked -> Bool
isChecking = \case
  Checking -> True
  _ -> False

newMail :: MailForm
newMail =
  MailForm
    { typedHost = ""
    , typedPort = show defaultMailPort
    , chosenSecurity = securityFor defaultMailPort
    , typedUser = ""
    , typedPassword = ""
    , passwordSet = False
    , replacingPassword = False
    , clearingPassword = False
    , typedFrom = ""
    }

mailFormOf :: MailSettings -> MailForm
mailFormOf m =
  MailForm
    { typedHost = m.host
    , typedPort = show m.port
    , chosenSecurity = m.security
    , typedUser = fromMaybe "" m.user
    , typedPassword = ""
    , passwordSet = m.password == Set
    , replacingPassword = False
    , clearingPassword = False
    , typedFrom = m.from
    }

-- | The mail server as the form describes it, or why it cannot be one.
-- The password is kept unless one is typed, or it is cleared.
mailChangeOf :: MailForm -> Either Text MailChange
mailChangeOf f = do
  port <- case readMaybe (T.strip f.typedPort) :: Maybe Integer of
    Just n | n >= 1 && n <= 65535 -> Right (fromIntegral n)
    _ -> Left "The mail server's port is a number from 1 to 65535."
  pure
    MailSettings
      { host = T.strip f.typedHost
      , port
      , security = f.chosenSecurity
      , user = mfilter (not . T.null) (Just (T.strip f.typedUser))
      , password =
          if f.clearingPassword
            then Just ""
            else mfilter (not . T.null) (Just f.typedPassword)
      , from = T.strip f.typedFrom
      }

newProvider :: ProviderForm
newProvider =
  ProviderForm
    { typedName = ""
    , chosenKind = Google
    , typedClientId = ""
    , typedIssuer = ""
    , typedSecret = ""
    , secretSet = False
    , replacingSecret = False
    , formCheck = Nothing
    }

providerFormOf' :: ProviderSettings -> ProviderForm
providerFormOf' p =
  ProviderForm
    { typedName = p.name
    , chosenKind = p.kind
    , typedClientId = p.clientId
    , typedIssuer = fromMaybe "" p.issuer
    , typedSecret = ""
    , secretSet = p.secret == Set
    , replacingSecret = False
    , formCheck = Nothing
    }

-- | The provider as the form describes it: its secret kept unless one is
-- typed.
providerChangeOf :: ProviderForm -> ProviderChange
providerChangeOf f =
  ProviderSettings
    { name = T.strip f.typedName
    , kind = f.chosenKind
    , clientId = T.strip f.typedClientId
    , issuer = mfilter (not . T.null) (Just (T.strip f.typedIssuer))
    , secret = mfilter (not . T.null) (Just f.typedSecret)
    }

secretText :: SecretState -> Text
secretText = \case
  Set -> "set"
  NotSet -> "not set"

securityText :: Security -> Text
securityText = \case
  ImplicitTls -> "TLS (port 465)"
  StartTls -> "STARTTLS (port 587)"
  Plain -> "none: on this machine or network only"

kindText :: ProviderKind -> Text
kindText = \case
  Google -> "Google"
  Apple -> "Apple"
  GitHub -> "GitHub"
  Generic -> "Any OpenID Connect provider"

issuerLabel :: ProviderKind -> Text
issuerLabel = \case
  Generic -> "Issuer (its discovery is below it)"
  GitHub -> "Address, for GitHub Enterprise (left empty, github.com)"
  _ -> "Address in place of its own (left empty, its own)"

-- | The provider form's hints under each of its fields, for the kind of
-- provider chosen, in the README's words (its "Signing in with Google,
-- GitHub, Apple or another provider"): what the field is, and where its
-- value comes from when the wiki is registered with the provider.
data ProviderHints = ProviderHints
  { name :: Text
  , kind :: Text
  , clientId :: Text
  , address :: Text
  -- ^ The hint for the fourth field: an OpenID Connect provider's issuer,
  -- a GitHub Enterprise server, or a proxy in place of Google's or Apple's
  -- own.
  , secret :: Text
  }

providerHints :: ProviderKind -> ProviderHints
providerHints k =
  ProviderHints
    { name =
        "A name you choose, in lower-case letters, digits and dashes: it goes into the redirect URI"
          <> case k of
            Generic -> ", and onto the sign-in button with a capital letter."
            _ -> ", and the sign-in button says “Sign in with " <> kindText k <> "”."
    , kind = "The kind decides whether the wiki knows the provider's addresses: it knows Google's, Apple's and GitHub's, and finds any other provider's from its issuer."
    , clientId = case k of
        Google -> "From registering the wiki with Google: Google Cloud console, APIs & Services, Credentials, “Create credentials”, an OAuth client ID of type “Web application”."
        GitHub -> "From registering the wiki with GitHub: Settings, Developer settings, OAuth Apps, “New OAuth App”; the client ID is on the app's page."
        Apple -> "From registering the wiki with Apple: the Services ID, with “Sign in with Apple” enabled, from Certificates, Identifiers & Profiles."
        Generic -> "From registering the wiki with the provider as a confidential client, with the scopes openid, email and profile."
    , address = case k of
        Generic -> "The address under which the provider serves /.well-known/openid-configuration, such as a Keycloak realm's."
        GitHub -> "A GitHub Enterprise server's address; empty for github.com."
        _ -> "Empty, unless a proxy stands in for " <> kindText k <> "'s own addresses."
    , secret = case k of
        Google -> "Shown beside the client ID in the Google Cloud console, once the OAuth consent screen is configured."
        GitHub -> "Made on the app's page, with “Generate a new client secret”."
        Apple -> "A JWT you sign with a “Sign in with Apple” key, valid for at most six months: make a new one before it expires."
        Generic -> "The confidential client's secret, from the same registration."
    }

-- | The redirect URI the provider form says to register, given the wiki's
-- public address and the name typed: nothing until both are there, and
-- then the URI, with what to do with it.
providerRedirect :: Maybe Text -> Text -> HH.HTML w i
providerRedirect publicUrl name = case publicUrl of
  Nothing ->
    [hh|
      <div class="server-provider-redirect-to">
        <p class="field-hint">The wiki's public address must be set first, above: the redirect URI to register starts with it.</p>
      </div>
    |]
  Just url
    | T.null name ->
        [hh|
          <div class="server-provider-redirect-to">
            <p class="field-hint">Type the name above and the redirect URI to register appears here.</p>
          </div>
        |]
    | otherwise ->
        [hh|
          <div class="server-provider-redirect-to">
            <p>Redirect URI to register: <code class="server-provider-redirect">{{ redirectUri url name }}</code></p>
            <p class="field-hint">Register it with the provider as its redirect (callback) URI; Google's “Authorized JavaScript origins” may stay empty.</p>
          </div>
        |]

-- | A provider's redirect URI, once the wiki has a public address.
redirectText :: ServerSettings -> Text -> Text
redirectText settings name = case settings.publicUrl of
  Just url | not (T.null name) -> redirectUri url name
  Just _ -> "below the public address, once it has a name"
  Nothing -> "none until the wiki's public address is set"
