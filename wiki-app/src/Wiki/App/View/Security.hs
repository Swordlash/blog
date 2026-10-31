{-# LANGUAGE QuasiQuotes #-}

-- | The account security section of the account panel (WP4.11 of
-- docs/PLAN.md, "Wiki.App.Security"): where one is signed in, a second
-- factor, and an e-mail address.
--
-- * __Sessions.__ Each of the user's sessions, with when it began, and
--   when and from where it was last used. Every session except this
--   browser's, which is marked, has "Sign out"; "Sign out everywhere" ends
--   all of them except this one.
-- * __Second factor.__ When it is off, it is set up in two steps. "Set up
--   a second factor…" asks the server for a secret, shown as a QR code
--   drawn here (an @\<svg>@ of @\<rect>@s, 'qrRuns') and as text to type.
--   Then one code from the authenticator application turns it on. The
--   recovery codes come with it, shown this once, until "I have kept
--   them". When it is on, the section says how many recovery codes are
--   left, and it is turned off with a code.
-- * __Passkeys.__ The user's passkeys (WP5.30 of docs/PLAN.md), each
--   with its name, when it was added and when it was last used, and
--   "Remove"; "Add a passkey" makes one with the name typed beside it.
--   Each signs the user in; those the writing assistant's vault has a key
--   for also unlock it, which the list says. A browser offers passkeys only
--   to a secure page, so over plain HTTP the section says that instead.
-- * __E-mail.__ The address, whether it is verified, a form to set another
--   one (a verification link is mailed there), "Send the link again" while
--   it is not verified, and "Remove". Without mail it is disabled, saying
--   why.
--
-- Setting another address, removing it, and starting a second factor ask
-- for the user's current password, where they have one (the states'
-- @asksPassword@ says), so that someone at a browser left signed in cannot
-- take over the account. Each opens a form with the password field first.
--
-- What the second factor and the address are said to do depends on
-- whether the user has a password (the states' @asksPassword@). A user
-- without one signs in with a provider's account, which a second factor
-- follows as it follows a password, and has no password to reset (WP5.6 of
-- docs/PLAN.md); 'factorOffText' and 'addressText' word it accordingly.
--
-- In the demo there is one session, this browser's, and the second factor
-- and the e-mail are shown disabled with a note, since only a server has
-- them ('securityAvailable').
--
-- Everything is fetched when the panel opens (in the initializer: the
-- server never prerenders it), and each part fetches again what it
-- changed.
module Wiki.App.View.Security
  ( component
  , qrRuns
  , factorOffText
  , addressText
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.List qualified as L
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Security (EmailState (..), RecoveryCodes (..), SecondFactorState (..), SessionRef, SessionSummary (..), TotpEnrolment (..))
import Wiki.Api.Vault (PasskeyInfo (..), RegistrationOptions (..), RegistrationResponse (..))
import Wiki.App.Account (codeErrorText, passwordErrorText)
import Wiki.App.Assistant (Made (..), MonadAssistant (..), PasskeyRefusal (..))
import Wiki.App.Assistant.Sync (MonadVault (..))
import Wiki.App.Backend (WikiError)
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.App.View.Common (attr, errorMessage)
import Wiki.Core.Assistant.Vault (CredentialId)
import Wiki.Core.User (Email (..), Password (..))

data State = State
  { available :: Bool
  , sessions :: Maybe (Either WikiError [SessionSummary])
  , factor :: Maybe (Either WikiError SecondFactorState)
  , enrolment :: Maybe TotpEnrolment
  -- ^ A second factor being set up: its secret, until it is confirmed.
  , recovery :: Maybe [Text]
  -- ^ The recovery codes of a second factor just turned on, shown once.
  , removing :: Bool
  -- ^ Whether the form that turns the second factor off is open.
  , typedCode :: Text
  , mailbox :: Maybe (Either WikiError EmailState)
  , emailForm :: EmailForm
  , typedEmail :: Text
  , askingPassword :: Bool
  -- ^ Whether the form for the password that starts a second factor is
  -- open.
  , typedPassword :: Text
  , passwordField :: H.RefLabel
  , sessionsProblem :: Maybe Text
  , factorProblem :: Maybe Text
  , emailProblem :: Maybe Text
  , emailTold :: Maybe Text
  , busy :: Bool
  , codeField :: H.RefLabel
  , emailField :: H.RefLabel
  , keysKept :: Bool
  -- ^ Whether a server keeps passkeys: not in the demo.
  , keysHere :: Bool
  -- ^ Whether the browser offers passkeys to this page.
  , keys :: Maybe (Either WikiError [PasskeyInfo])
  , typedKeyName :: Text
  , typedKeyPassword :: Text
  -- ^ The current password, which making a passkey asks for, since a
  -- passkey signs the user in.
  , keysProblem :: Maybe Text
  }

-- | Which of the address's forms is open.
data EmailForm
  = NoEmailForm
  | ChangingEmail
  | RemovingEmail
  deriving stock (Eq)

data Action
  = Initialize
  | EndSession SessionRef
  | EndOthers
  | StartTotp
  | SubmitTotpPassword
  | CancelTotpPassword
  | TypedPassword Text
  | ConfirmClear
  | CancelTotp
  | TypedCode Text
  | ConfirmTotp
  | KeptCodes
  | AskRemove
  | CancelRemove
  | RemoveFactor
  | EditEmail
  | CancelEmail
  | TypedEmail Text
  | SaveEmail
  | ResendEmail
  | ClearEmail
  | TypedKeyName Text
  | TypedKeyPassword Text
  | AddKey
  | RemoveKey CredentialId

component :: forall query input output m. (MonadSecurity m, MonadVault m, MonadAssistant m, MonadUUID m, MonadIO m) => H.Component query input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> do
          codeField <- H.newRefLabel "second-factor-code"
          emailField <- H.newRefLabel "account-email"
          passwordField <- H.newRefLabel "account-current-password"
          pure
            State
              { available = True
              , sessions = Nothing
              , factor = Nothing
              , enrolment = Nothing
              , recovery = Nothing
              , removing = False
              , typedCode = ""
              , mailbox = Nothing
              , emailForm = NoEmailForm
              , typedEmail = ""
              , askingPassword = False
              , typedPassword = ""
              , passwordField
              , sessionsProblem = Nothing
              , factorProblem = Nothing
              , emailProblem = Nothing
              , emailTold = Nothing
              , busy = False
              , codeField
              , emailField
              , keysKept = False
              , keysHere = False
              , keys = Nothing
              , typedKeyName = ""
              , typedKeyPassword = ""
              , keysProblem = Nothing
              }
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="account-security">
          <section class="account-sessions" aria-label="Where you are signed in">
            <h3>Where you are signed in</h3>
            {{ sessionsView st }}
          </section>
          <section class="account-second-factor" aria-label="Second factor">
            <h3>Second factor</h3>
            {{ factorView st }}
          </section>
          <section class="account-passkeys" aria-label="Passkeys">
            <h3>Passkeys</h3>
            {{ keysView st }}
          </section>
          <section class="account-email" aria-label="E-mail address">
            <h3>E-mail address</h3>
            {{ emailView st }}
          </section>
        </div>
      |]

    sessionsView :: State -> H.ComponentHTML Action Empty m
    sessionsView st = case st.sessions of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
      Just (Right ss) ->
        [hh|
          <div>
            <ul class="session-list">
              {% for s in ss %}
                <li class="session-item{% if s.current %} session-current{% end %}">
                  <span class="session-address">{{ if T.null s.address then "Address not known" else s.address }}</span>
                  <span class="session-times">{{ "Signed in " <> stamped s.createdAt <> ", last seen " <> stamped s.lastSeenAt }}</span>
                  {% if s.current %}
                    <span class="session-this">This browser</span>
                  {% else %}
                    <button type="button" class="session-end" disabled={{ st.busy }} onClick={{ const (EndSession s.id) }}>Sign out</button>
                  {% end %}
                </li>
              {% end %}
            </ul>
            <button type="button" class="sessions-end-others" disabled={{ st.busy || all (\s -> s.current) ss }} onClick={{ const EndOthers }}>Sign out everywhere</button>
            <p class="account-note">Signs out every session above but this browser's.</p>
            {% for p in maybeToList st.sessionsProblem %}
              <p class="error sessions-error" role="alert">{{ p }}</p>
            {% end %}
          </div>
        |]

    keysView :: State -> H.ComponentHTML Action Empty m
    keysView st
      | not st.keysKept = [hh|<p class="account-note">Passkeys are kept by a wiki on a server; this one has none.</p>|]
      | not st.keysHere = [hh|<p class="account-note passkeys-unavailable">A browser offers passkeys only on a page served over HTTPS: open this wiki at its HTTPS address to add one or sign in with one.</p>|]
      | otherwise = case st.keys of
          Nothing -> [hh|<p class="loading">Loading…</p>|]
          Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
          Just (Right ks) ->
            [hh|
              <div>
                <p class="account-note">A passkey signs you in without your password or a code, with your device's fingerprint, face or PIN.</p>
                <ul class="passkey-list">
                  {% for k in ks %}
                    <li class="passkey-item">
                      <span class="passkey-name">{{ k.name }}</span>
                      <span class="passkey-times">{{ "Added " <> stamped k.createdAt <> maybe ", never used" (\t -> ", last used " <> stamped t) k.lastUsedAt }}</span>
                      {% if k.unlocks %}
                        <span class="passkey-unlocks">Also unlocks your assistant's keys</span>
                      {% end %}
                      <button type="button" class="passkey-remove" disabled={{ st.busy }} onClick={{ const (RemoveKey k.id) }}>Remove</button>
                    </li>
                  {% end %}
                </ul>
                <form class="passkey-add" aria-label="Add a passkey" {{ HE.preventingDefault (HE.onSubmit (const AddKey)) }}>
                  <label class="field">
                    <span>Name</span>
                    <input type="text" name="passkey-name" maxlength="100" placeholder="This device" onValueInput={{ TypedKeyName }}>
                  </label>
                  {% if asksPassword %}
                    <label class="field">
                      <span>Current password</span>
                      <input type="password" name="passkey-password" autocomplete="current-password" required onValueInput={{ TypedKeyPassword }}>
                    </label>
                  {% end %}
                  <button type="submit" disabled={{ st.busy }}>Add a passkey</button>
                </form>
                <div class="sign-in-told">
                  {% for p in maybeToList st.keysProblem %}
                    <p class="error passkeys-error" role="alert">{{ p }}</p>
                  {% end %}
                </div>
              </div>
            |]
      where
        -- A user without a password (one who signs in with a provider)
        -- has none to give; while the state is not known, the field shows.
        asksPassword = case st.factor of
          Just (Right f) -> f.asksPassword
          _ -> True

    factorView :: State -> H.ComponentHTML Action Empty m
    factorView st
      | not st.available =
          [hh|
            <div>
              <p class="account-note second-factor-unavailable">A second factor is a server's: this demo has none to set up.</p>
              <button type="button" class="second-factor-start" disabled>Set up a second factor…</button>
            </div>
          |]
      | Just codes <- st.recovery =
          [hh|
            <div class="recovery-codes">
              <p role="status">Your second factor is on. These are your recovery codes: each signs you in once if you lose your authenticator. They are shown only now, so keep them somewhere safe.</p>
              <ul class="recovery-code-list">
                {% for c in codes %}
                  <li><code>{{ c }}</code></li>
                {% end %}
              </ul>
              <button type="button" class="primary recovery-kept" onClick={{ const KeptCodes }}>I have kept them</button>
            </div>
          |]
      | Just e <- st.enrolment =
          [hh|
            <div class="totp-enrolment">
              <p>Scan this code with your authenticator application, or type the secret into it, then type the code it shows.</p>
              {{ qrCode e.qr }}
              <p class="totp-secret">Secret: <code>{{ grouped e.secret }}</code></p>
              {{ codeForm st "totp-confirm" "Turn on" ConfirmTotp CancelTotp }}
            </div>
          |]
      | otherwise = case st.factor of
          Nothing -> [hh|<p class="loading">Loading…</p>|]
          Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
          Just (Right f)
            | f.enabled ->
                [hh|
                  <div>
                    <p class="second-factor-on">On: a code from your authenticator application is asked for when you sign in. {{ codesLeft f.recoveryCodesLeft }}</p>
                    {% if st.removing %}
                      {{ codeForm st "second-factor-remove-form" "Remove second factor" RemoveFactor CancelRemove }}
                    {% else %}
                      <button type="button" class="second-factor-remove-ask" disabled={{ st.busy }} onClick={{ const AskRemove }}>Remove second factor…</button>
                    {% end %}
                  </div>
                |]
            | otherwise ->
                [hh|
                  <div>
                    <p class="second-factor-off">{{ factorOffText f.asksPassword }}</p>
                    {% if st.askingPassword %}
                      <form class="totp-password-form" aria-label="Set up a second factor" {{ HE.preventingDefault (HE.onSubmit (const SubmitTotpPassword)) }}>
                        {{ passwordInput st }}
                        <div class="actions">
                          <button type="submit" class="primary" disabled={{ st.busy }}>Continue</button>
                          <button type="button" onClick={{ const CancelTotpPassword }}>Cancel</button>
                        </div>
                      </form>
                    {% else %}
                      <button type="button" class="second-factor-start" disabled={{ st.busy }} onClick={{ const StartTotp }}>Set up a second factor…</button>
                    {% end %}
                    {{ factorProblemView st }}
                  </div>
                |]

    -- The user's current password, for what a session alone may not do.
    passwordInput :: State -> H.ComponentHTML Action Empty m
    passwordInput st =
      [hh|
        <label class="field">
          <span>Your current password</span>
          <input type="password" name="password" autocomplete="current-password" required onValueInput={{ TypedPassword }} {{ HP.ref st.passwordField }}>
        </label>
      |]

    -- A code typed into its own form, its field focused when the form
    -- opens.
    codeForm :: State -> Text -> Text -> Action -> Action -> H.ComponentHTML Action Empty m
    codeForm st cls verb submit back =
      [hh|
        <form class={{ "code-form " <> cls }} aria-label={{ verb }} {{ HE.preventingDefault (HE.onSubmit (const submit)) }}>
          <label class="field">
            <span>Code from your application, or a recovery code</span>
            <input type="text" name="code" class="code-input" autocomplete="one-time-code" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedCode }} {{ HP.ref st.codeField }}>
          </label>
          {{ factorProblemView st }}
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>{{ verb }}</button>
            <button type="button" onClick={{ const back }}>Cancel</button>
          </div>
        </form>
      |]

    factorProblemView :: State -> H.ComponentHTML Action Empty m
    factorProblemView st =
      [hh|
        <div class="account-told">
          {% for p in maybeToList st.factorProblem %}
            <p class="error second-factor-error" role="alert">{{ p }}</p>
          {% end %}
        </div>
      |]

    emailView :: State -> H.ComponentHTML Action Empty m
    emailView st = case st.mailbox of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
      Just (Right e) ->
        [hh|
          <div>
            <p class="email-current">{{ current e }}</p>
            {% if not e.mailing %}
              <p class="account-note email-unavailable">{{ unavailableNote }}</p>
            {% end %}
            {% if st.emailForm == RemovingEmail %}
              <form class="email-remove-form" aria-label="Remove your e-mail address" {{ HE.preventingDefault (HE.onSubmit (const ConfirmClear)) }}>
                {{ passwordInput st }}
                <div class="actions">
                  <button type="submit" class="primary" disabled={{ st.busy }}>Remove address</button>
                  <button type="button" onClick={{ const CancelEmail }}>Cancel</button>
                </div>
              </form>
            {% end %}
            {% if st.emailForm == ChangingEmail %}
              <form class="email-form" aria-label="Your e-mail address" {{ HE.preventingDefault (HE.onSubmit (const SaveEmail)) }}>
                <label class="field">
                  <span>E-mail address</span>
                  <input type="email" name="email" autocomplete="email" required onValueInput={{ TypedEmail }} {{ HP.ref st.emailField }}>
                </label>
                {% if e.asksPassword %}
                  {{ passwordInput st }}
                {% end %}
                <div class="actions">
                  <button type="submit" class="primary" disabled={{ st.busy }}>Save and send a link</button>
                  <button type="button" onClick={{ const CancelEmail }}>Cancel</button>
                </div>
              </form>
            {% end %}
            {% if st.emailForm == NoEmailForm %}
              <div class="actions">
                <button type="button" class="email-edit" disabled={{ st.busy || not e.mailing }} onClick={{ const EditEmail }}>
                  {{ if isJust e.email then "Change address…" else "Add an address…" :: Text }}
                </button>
                {% if isJust e.email && not e.verified %}
                  <button type="button" class="email-resend" disabled={{ st.busy || not e.mailing }} onClick={{ const ResendEmail }}>Send the link again</button>
                {% end %}
                {% if isJust e.email %}
                  <button type="button" class="email-clear" disabled={{ st.busy }} onClick={{ const ClearEmail }}>Remove</button>
                {% end %}
              </div>
            {% end %}
            <div class="account-told">
              {% for t in maybeToList st.emailTold %}
                <p class="email-told" role="status">{{ t }}</p>
              {% end %}
              {% for p in maybeToList st.emailProblem %}
                <p class="error email-error" role="alert">{{ p }}</p>
              {% end %}
            </div>
          </div>
        |]
      where
        current :: EmailState -> Text
        current = addressText
        unavailableNote :: Text
        unavailableNote
          | st.available = "This wiki sends no mail, so an address cannot be verified yet: ask an administrator to set up its mail server."
          | otherwise = "Mail is a server's: this demo sends none."

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> do
        available <- lift securityAvailable
        modify (\st -> st {available})
        sessions <- lift ownSessions
        modify (\st -> st {sessions = Just sessions})
        factor <- lift secondFactorState
        modify (\st -> st {factor = Just factor})
        mailbox <- lift ownEmail
        modify (\st -> st {mailbox = Just mailbox})
        keysKept <- lift vaultSync
        keysHere <- lift passkeysHere
        modify (\st -> st {keysKept, keysHere})
        when (keysKept && keysHere) $ do
          keys <- lift listPasskeys
          modify (\st -> st {keys = Just keys})
      TypedKeyName t -> modify (\st -> st {typedKeyName = t})
      TypedKeyPassword t -> modify (\st -> st {typedKeyPassword = t})
      AddKey -> busily $ do
        modify (\st -> st {keysProblem = Nothing})
        typed <- gets (\st -> st.typedKeyPassword)
        lift (beginRegistration (if T.null typed then Nothing else Just (Password typed))) >>= \case
          Left e -> modify (\st -> st {keysProblem = Just (passwordErrorText e)})
          Right options ->
            -- No salt: a passkey added here signs in, and wraps no vault
            -- key until the assistant asks it to.
            lift (createPasskey options "" "") >>= \case
              Left Cancelled -> pass
              Left (PasskeyFailed why) -> modify (\st -> st {keysProblem = Just why})
              Right made -> do
                name <- gets (\st -> T.strip st.typedKeyName)
                let r = made.response
                    named = RegistrationResponse {id = r.id, clientDataJSON = r.clientDataJSON, attestationObject = r.attestationObject, name = if T.null name then Nothing else Just name}
                lift (finishRegistration named) >>= \case
                  Left e -> do
                    lift (discardPasskey options.rpId made.response.id)
                    modify (\st -> st {keysProblem = Just (errorMessage e)})
                  Right _ -> do
                    keys <- lift listPasskeys
                    modify (\st -> st {keys = Just keys})
      RemoveKey i -> busily $ do
        modify (\st -> st {keysProblem = Nothing})
        lift (dropPasskey i) >>= \case
          Left e -> modify (\st -> st {keysProblem = Just (errorMessage e)})
          Right keys -> modify (\st -> st {keys = Just (Right keys)})
      EndSession ref -> sessionsChange (endOwnSession ref)
      EndOthers -> sessionsChange endOtherSessions
      StartTotp ->
        gets (\st -> st.factor) >>= \case
          Just (Right f) | f.asksPassword -> do
            modify (\st -> st {askingPassword = True, typedPassword = "", factorProblem = Nothing})
            focusPassword
          _ -> enrol Nothing
      SubmitTotpPassword -> gets (\st -> st.typedPassword) >>= enrol . Just . Password
      CancelTotpPassword -> modify (\st -> st {askingPassword = False, typedPassword = "", factorProblem = Nothing})
      TypedPassword t -> modify (\st -> st {typedPassword = t})
      CancelTotp -> modify (\st -> st {enrolment = Nothing, typedCode = "", factorProblem = Nothing})
      TypedCode t -> modify (\st -> st {typedCode = t})
      ConfirmTotp -> busily $ do
        code <- gets (\st -> st.typedCode)
        lift (confirmTotp code) >>= \case
          Left e -> modify (\st -> st {factorProblem = Just (codeErrorText e)})
          Right codes -> do
            modify (\st -> st {enrolment = Nothing, recovery = Just codes.codes, typedCode = "", factorProblem = Nothing})
            factor <- lift secondFactorState
            modify (\st -> st {factor = Just factor})
      KeptCodes -> modify (\st -> st {recovery = Nothing})
      AskRemove -> do
        modify (\st -> st {removing = True, typedCode = "", factorProblem = Nothing})
        focusCode
      CancelRemove -> modify (\st -> st {removing = False, typedCode = "", factorProblem = Nothing})
      RemoveFactor -> busily $ do
        code <- gets (\st -> st.typedCode)
        lift (removeOwnSecondFactor code) >>= \case
          Left e -> modify (\st -> st {factorProblem = Just (codeErrorText e)})
          Right f -> modify (\st -> st {factor = Just (Right f), removing = False, typedCode = "", factorProblem = Nothing})
      EditEmail -> do
        modify (\st -> st {emailForm = ChangingEmail, typedEmail = "", typedPassword = "", emailProblem = Nothing, emailTold = Nothing})
        gets (\st -> st.emailField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      CancelEmail -> modify (\st -> st {emailForm = NoEmailForm, typedEmail = "", typedPassword = "", emailProblem = Nothing})
      TypedEmail t -> modify (\st -> st {typedEmail = t})
      SaveEmail -> do
        st <- get
        emailChange st.typedEmail (passwordIfAsked st)
      -- The current address: send its link again, which needs no password.
      ResendEmail ->
        gets (\st -> st.mailbox) >>= \case
          Just (Right EmailState {email = Just address}) -> emailChange address.text Nothing
          _ -> pass
      ClearEmail ->
        gets (\st -> st.mailbox) >>= \case
          Just (Right e) | e.asksPassword -> do
            modify (\st -> st {emailForm = RemovingEmail, typedPassword = "", emailProblem = Nothing, emailTold = Nothing})
            focusPassword
          _ -> emailChange "" Nothing
      ConfirmClear -> gets (\st -> st.typedPassword) >>= emailChange "" . Just . Password

    -- Run something while nothing else may run.
    busily :: H.HalogenM State Action Empty output m () -> H.HalogenM State Action Empty output m ()
    busily act =
      gets (\st -> st.busy) >>= \busy -> unless busy $ do
        modify (\st -> st {busy = True})
        act
        modify (\st -> st {busy = False})

    -- Start setting up a second factor, with the password if it was asked
    -- for.
    enrol :: Maybe Password -> H.HalogenM State Action Empty output m ()
    enrol password = busily $ do
      modify (\st -> st {factorProblem = Nothing})
      lift (enrolTotp password) >>= \case
        Left e -> modify (\st -> st {factorProblem = Just (passwordErrorText e)})
        Right e -> do
          modify (\st -> st {enrolment = Just e, askingPassword = False, typedPassword = "", typedCode = ""})
          focusCode

    -- The typed password, where the address's state says it is asked for.
    passwordIfAsked :: State -> Maybe Password
    passwordIfAsked st = case st.mailbox of
      Just (Right e) | e.asksPassword -> Just (Password st.typedPassword)
      _ -> Nothing

    focusPassword :: H.HalogenM State Action Empty output m ()
    focusPassword = gets (\st -> st.passwordField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    focusCode :: H.HalogenM State Action Empty output m ()
    focusCode = gets (\st -> st.codeField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    sessionsChange :: m (Either WikiError [SessionSummary]) -> H.HalogenM State Action Empty output m ()
    sessionsChange act = busily $ do
      modify (\st -> st {sessionsProblem = Nothing})
      lift act >>= \case
        Left e -> modify (\st -> st {sessionsProblem = Just (errorMessage e)})
        Right ss -> modify (\st -> st {sessions = Just (Right ss)})

    emailChange :: Text -> Maybe Password -> H.HalogenM State Action Empty output m ()
    emailChange address password = busily $ do
      modify (\st -> st {emailProblem = Nothing, emailTold = Nothing})
      lift (setOwnEmail address password) >>= \case
        Left e -> modify (\st -> st {emailProblem = Just (passwordErrorText e)})
        Right e ->
          modify $ \st ->
            st
              { mailbox = Just (Right e)
              , emailForm = NoEmailForm
              , typedEmail = ""
              , typedPassword = ""
              , emailTold = case (e.email, e.mailError) of
                  (_, Just why) -> Just ("The link could not be mailed: " <> why)
                  (Just a, Nothing) | not e.verified -> Just ("A link to verify it has been mailed to " <> a.text <> ".")
                  (Nothing, Nothing) -> Just "Your address is removed."
                  _ -> Nothing
              }

    codesLeft :: Int -> Text
    codesLeft = \case
      0 -> "You have no recovery codes left: if you lose your authenticator, an administrator must remove it."
      1 -> "You have one recovery code left."
      n -> "You have " <> show n <> " recovery codes left."

-- | A time, in words for a person to read.
stamped :: UTCTime -> Text
stamped = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

-- | A secret in groups of four characters, to type.
grouped :: Text -> Text
grouped = T.unwords . T.chunksOf 4

-- | A QR code's dark modules, row by row, as runs to draw. Each run of dark
-- modules in a row is one rectangle (column, row, width), so that a code
-- of some fifty modules a side is a few hundred @\<rect>@s, not a
-- thousand.
qrRuns :: [Text] -> [(Int, Int, Int)]
qrRuns rows = concat (zipWith runsOf [0 ..] rows)
  where
    runsOf y row = go 0 (T.unpack row)
      where
        go _ [] = []
        go x cells@(c : _)
          | c == '1' = let (dark, rest) = L.span (== '1') cells in (x, y, length dark) : go (x + length dark) rest
          | otherwise = let (light, rest) = L.span (/= '1') cells in go (x + length light) rest

-- | A QR code as an @\<svg>@ of rectangles, with the four-module quiet zone
-- around it that a reader needs, light on dark whatever the page's colours
-- are; nothing when there is no code.
qrCode :: [Text] -> HH.HTML w i
qrCode [] = HH.text ""
qrCode rows =
  [hh|
    <svg class="totp-qr" role="img" aria-label="A QR code of the secret, for your authenticator application's camera" {{ attr "viewBox" box }} {{ attr "shape-rendering" "crispEdges" }}>
      <rect fill="#ffffff" {{ attr "x" "0" }} {{ attr "y" "0" }} {{ attr "width" (show outer) }} {{ attr "height" (show outer) }}></rect>
      {% for (x, y, w) in qrRuns rows %}
        <rect fill="#000000" {{ attr "x" (show (x + quiet)) }} {{ attr "y" (show (y + quiet)) }} {{ attr "width" (show w) }} {{ attr "height" "1" }}></rect>
      {% end %}
    </svg>
  |]
  where
    quiet = 4 :: Int
    outer = length rows + 2 * quiet
    box = "0 0 " <> show outer <> " " <> show outer

-- | What it means that the second factor is off, for a user with a
-- password or without one. A user without a password signs in with a
-- provider's account, which asks for a code once a second factor is on,
-- as a password does ("Wiki.Server.Auth").
factorOffText :: Bool -> Text
factorOffText hasPassword
  | hasPassword = "Off: your password alone signs you in."
  | otherwise = "Off: signing in with your provider's account asks for no code."

-- | What a user's address is used for, as things are. Only a user with a
-- password can forget one: a user without one signs in with a provider's
-- account, and is not mailed a link to set one (WP5.6 of docs/PLAN.md).
addressText :: EmailState -> Text
addressText e = case e.email of
  Nothing
    | e.asksPassword -> "None: a forgotten password can then only be reset by an administrator."
    | otherwise -> "None: you sign in with your provider's account, and have no password to reset."
  Just address
    | not e.verified -> address.text <> ", not verified yet: follow the link mailed to it."
    | e.asksPassword -> address.text <> ", verified: a forgotten password can be reset by mail."
    | otherwise -> address.text <> ", verified: the wiki's mail to you goes there."
