{-# LANGUAGE QuasiQuotes #-}

-- | The safety of one's account, in the account panel (WP4.11 of
-- docs/PLAN.md, "Wiki.App.Security"): where one is signed in, a second
-- factor, and an e-mail address.
--
-- * __Sessions.__ Each session of the user's, with when it began, when and
--   from where it was last used, and "Sign out" on every one but this
--   browser's, which is marked; "Sign out everywhere" ends them all but
--   this one.
-- * __Second factor.__ Off, it is set up in two steps: "Set up a second
--   factor…" asks the server for a secret, shown as a QR code drawn here,
--   an @\<svg>@ of @\<rect>@s ('qrRuns'), and as text to type, and one code
--   the application then shows turns it on. The recovery codes come with
--   it, shown this once, until "I have kept them". On, it says how many
--   recovery codes are left and is taken away with a code.
-- * __E-mail.__ The address, whether it is verified, a form to give
--   another (a link to verify it is mailed there), "Send the link again"
--   while it is not verified, and "Remove". Without mail it is disabled,
--   saying why.
--
-- Giving another address, removing it, and beginning a second factor ask
-- for the user's current password, where they have one (the states say,
-- @asksPassword@), so that a browser left signed in does not give the
-- account away: each opens a form with its field first.
--
-- In the demo there is one session, this browser's, and the second factor
-- and the e-mail are shown disabled with a note, since only a server has
-- them ('securityAvailable').
--
-- Everything is read when the panel opens (in the initializer: the server
-- never renders it), and each part reads back what it changed.
module Wiki.App.View.Security
  ( component
  , qrRuns
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
import Wiki.App.Account (codeErrorText, passwordErrorText)
import Wiki.App.Backend (WikiError)
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.App.View.Common (attr, errorMessage)

data State = State
  { available :: Bool
  , sessions :: Maybe (Either WikiError [SessionSummary])
  , factor :: Maybe (Either WikiError SecondFactorState)
  , enrolment :: Maybe TotpEnrolment
  -- ^ A second factor being set up: its secret, until it is confirmed.
  , recovery :: Maybe [Text]
  -- ^ The recovery codes of a second factor just turned on, shown once.
  , removing :: Bool
  -- ^ Whether the form that takes the second factor away is open.
  , typedCode :: Text
  , mailbox :: Maybe (Either WikiError EmailState)
  , emailForm :: EmailForm
  , typedEmail :: Text
  , askingPassword :: Bool
  -- ^ Whether the form for the password that begins a second factor is
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
  }

-- | Which form of the address's is open.
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

component :: forall query input output m. (MonadSecurity m, MonadUUID m, MonadIO m) => H.Component query input output m
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
                    <p class="second-factor-off">Off: your password alone signs you in.</p>
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

    -- A code typed into a form of its own, its field focused when it
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
        current e = case e.email of
          Nothing -> "None: a forgotten password can then only be reset by an administrator."
          Just address
            | e.verified -> address <> ", verified: a forgotten password can be reset by mail."
            | otherwise -> address <> ", not verified yet: follow the link mailed to it."
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
      EndSession ref -> sessionsChange (endOwnSession ref)
      EndOthers -> sessionsChange endOtherSessions
      StartTotp ->
        gets (\st -> st.factor) >>= \case
          Just (Right f) | f.asksPassword -> do
            modify (\st -> st {askingPassword = True, typedPassword = "", factorProblem = Nothing})
            focusPassword
          _ -> enrol Nothing
      SubmitTotpPassword -> gets (\st -> st.typedPassword) >>= enrol . Just
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
      -- The address one has: its link again, which asks nothing.
      ResendEmail ->
        gets (\st -> st.mailbox) >>= \case
          Just (Right EmailState {email = Just address}) -> emailChange address Nothing
          _ -> pass
      ClearEmail ->
        gets (\st -> st.mailbox) >>= \case
          Just (Right e) | e.asksPassword -> do
            modify (\st -> st {emailForm = RemovingEmail, typedPassword = "", emailProblem = Nothing, emailTold = Nothing})
            focusPassword
          _ -> emailChange "" Nothing
      ConfirmClear -> gets (\st -> st.typedPassword) >>= emailChange "" . Just

    -- Something done while nothing else may be.
    busily :: H.HalogenM State Action Empty output m () -> H.HalogenM State Action Empty output m ()
    busily act =
      gets (\st -> st.busy) >>= \busy -> unless busy $ do
        modify (\st -> st {busy = True})
        act
        modify (\st -> st {busy = False})

    -- Begin a second factor, with the password if it was asked for.
    enrol :: Maybe Text -> H.HalogenM State Action Empty output m ()
    enrol password = busily $ do
      modify (\st -> st {factorProblem = Nothing})
      lift (enrolTotp password) >>= \case
        Left e -> modify (\st -> st {factorProblem = Just (passwordErrorText e)})
        Right e -> do
          modify (\st -> st {enrolment = Just e, askingPassword = False, typedPassword = "", typedCode = ""})
          focusCode

    -- The password typed, where the address's state says it is asked.
    passwordIfAsked :: State -> Maybe Text
    passwordIfAsked st = case st.mailbox of
      Just (Right e) | e.asksPassword -> Just st.typedPassword
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

    emailChange :: Text -> Maybe Text -> H.HalogenM State Action Empty output m ()
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
                  (Just a, Nothing) | not e.verified -> Just ("A link to verify it has been mailed to " <> a <> ".")
                  (Nothing, Nothing) -> Just "Your address is removed."
                  _ -> Nothing
              }

    codesLeft :: Int -> Text
    codesLeft = \case
      0 -> "You have no recovery codes left: if you lose your authenticator, an administrator must remove it."
      1 -> "You have one recovery code left."
      n -> "You have " <> show n <> " recovery codes left."

-- | A time, for a person to read.
stamped :: UTCTime -> Text
stamped = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

-- | A secret in groups of four, to type.
grouped :: Text -> Text
grouped = T.unwords . T.chunksOf 4

-- | A QR code's dark modules, row by row, as runs to draw: each run of
-- dark modules in a row is one rectangle, (column, row, width), so that a
-- code of some fifty modules a side is a few hundred @\<rect>@s, not a
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

-- | A QR code as an @\<svg>@ of rectangles, with the quiet zone of four
-- modules around it that a reader needs, light on dark whatever the page's
-- colours are; nothing when there is no code.
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
