{-# LANGUAGE QuasiQuotes #-}

-- | The administration's section on whom the wiki lets in (WP3.5 of
-- docs/PLAN.md): whether the wiki is open or closed ("Wiki.Core.Access"),
-- whether every new account (created by its owner, by invitation, or by
-- signing in with a provider) may create spaces, whether the
-- administration may create accounts with a password or leaves them to
-- the server's console (WP5.18 of docs/PLAN.md), and, in a closed wiki,
-- the invitations, with a form to invite an e-mail address. It is one
-- component over the administration's backend ("Wiki.App.Backend.Admin"),
-- the same on the demo's wiki and the server's, and the shell shows it to
-- administrators only.
--
-- Everything it shows comes from one read, as in the users section
-- ("Wiki.App.View.Admin"): at once where the backend answers at once, and
-- otherwise in its initializer. After a change it tells the shell, which
-- reloads who is asking (closing the wiki changes what their session
-- says) and increments the context's revision, which makes this view
-- fetch again.
--
-- An invitation's link carries a secret that the backend returns only
-- when the invitation is made, and only if it was not mailed. The link is
-- shown then, under the form, to copy and pass on, and never again.
-- Inviting the same address again gives a new link, which is how to
-- replace a lost one.
module Wiki.App.View.Access
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Data.Time (defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Admin (Invitation (..), Invitations (..), Invited (..), WikiSettings (..))
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Browser (absoluteUrl, copyText)
import Wiki.App.Route qualified as Route
import Wiki.App.View.Common
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (InvitationId)
import Wiki.Core.User (Email (..))

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready WikiSettings Invitations

-- | An invitation just made, as the panel reports it: to whom, whether it
-- was mailed, and its link if it was not.
data Made = Made
  { email :: Email
  , link :: Maybe Text
  , mailError :: Maybe Text
  }

data State = State
  { input :: Input
  , loaded :: Loaded
  , typedEmail :: Text
  , made :: Maybe Made
  , copied :: Bool
  , busy :: Bool
  , problem :: Maybe WikiError
  , linkField :: H.RefLabel
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | SetAccess Access
  | SetCreateSpaces Bool
  | SetPasswordAccounts Bool
  | TypedEmail Text
  | MakeInvitation
  | Revoke InvitationId
  | CopyLink Text

component :: forall query m. (MonadAdmin m, MonadLoad m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading fromRead <$> atOnce readBoth
          linkField <- H.newRefLabel "invitation-link"
          pure State {input, loaded, typedEmail = "", made = Nothing, copied = False, busy = False, problem = Nothing, linkField}
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
        <section class="admin-section admin-access">
          <h2>Who may come in</h2>
          <p class="admin-intro">
            An open wiki lets anyone read its public spaces and make themself an account. A closed
            one shows nothing to anyone who has not signed in, public spaces included, and takes
            new people by invitation only.
          </p>
          {{ body }}
        </section>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready settings listed -> settingsView st settings listed

    settingsView :: State -> WikiSettings -> Invitations -> H.ComponentHTML Action Empty m
    settingsView st settings listed =
      [hh|
        <div class="admin-access-settings">
          {{ errorView <$> st.problem }}
          <fieldset class="access-choice">
            <legend>This wiki is</legend>
            <label class="check">
              <input type="radio" name="access" value="open" checked={{ settings.access == Open }} disabled={{ st.busy }} onChange={{ const (SetAccess Open) }}>
              <span><strong>Open</strong>: anyone may read the public spaces and create an account.</span>
            </label>
            <label class="check">
              <input type="radio" name="access" value="closed" checked={{ settings.access == Closed }} disabled={{ st.busy }} onChange={{ const (SetAccess Closed) }}>
              <span><strong>Closed</strong>: only those signed in see anything, and accounts come by invitation.</span>
            </label>
          </fieldset>
          <label class="check new-accounts-create-spaces">
            <input type="checkbox" checked={{ settings.newAccountsCreateSpaces }} disabled={{ st.busy }} onChange={{ const (SetCreateSpaces (not settings.newAccountsCreateSpaces)) }}>
            <span>
              Let every new account create spaces
              <small class="check-help">Applies to accounts people make themselves, by invitation or by signing in with a provider. You can also grant it per user in Users.</small>
            </span>
          </label>
          <label class="check admin-creates-password-accounts">
            <input type="checkbox" checked={{ settings.adminCreatesPasswordAccounts }} disabled={{ st.busy }} onChange={{ const (SetPasswordAccounts (not settings.adminCreatesPasswordAccounts)) }}>
            <span>
              The administration may create accounts with a password
              <small class="check-help">When this is off, accounts with a password are made on the server's console, with wiki-server users add. Sign-in providers and invitations are unaffected.</small>
            </span>
          </label>
          {% if settings.access == Closed %}
            {{ invitationsView st listed }}
          {% end %}
        </div>
      |]

    invitationsView :: State -> Invitations -> H.ComponentHTML Action Empty m
    invitationsView st listed =
      [hh|
        <div class="admin-invitations">
          <h3>Invitations</h3>
          <p class="admin-intro">{{ mailNote }}</p>
          <form class="invite-form" aria-label="Invite someone" {{ HE.preventingDefault (HE.onSubmit (const MakeInvitation)) }}>
            <label class="field">
              <span>E-mail address</span>
              <input type="email" name="email" autocomplete="off" required value={{ st.typedEmail }} onValueInput={{ TypedEmail }}>
            </label>
            <div class="actions">
              <button type="submit" class="primary" disabled={{ st.busy }}>Invite</button>
            </div>
          </form>
          {% for m in maybeToList st.made %}
            {{ madeView st m }}
          {% end %}
          {% if null listed.invitations %}
            <p class="empty">Nobody is invited.</p>
          {% else %}
            <table class="invitations">
              <thead>
                <tr><th scope="col">E-mail address</th><th scope="col">Expires</th><th scope="col"></th></tr>
              </thead>
              <tbody>
                {% for i in listed.invitations %}
                  <tr class="invitation-row{% if i.expired %} expired{% end %}" data-email={{ i.email.text }}>
                    <td>{{ i.email.text }}</td>
                    <td>{{ expiry i }}</td>
                    <td><button type="button" class="invitation-revoke" disabled={{ st.busy }} onClick={{ const (Revoke i.id) }}>Revoke</button></td>
                  </tr>
                {% end %}
              </tbody>
            </table>
          {% end %}
        </div>
      |]
      where
        mailNote :: Text
        mailNote
          | listed.mailing = "An invitation is mailed to its address with a link that makes one account, once, within a week."
          | otherwise = "This wiki mails nothing: an invitation's link is shown when it is made, to pass on yourself, and not again. It makes one account, once, within a week."
        expiry :: Invitation -> Text
        expiry i
          | i.expired = "Expired"
          | otherwise = toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" i.expiresAt)

    madeView :: State -> Made -> H.ComponentHTML Action Empty m
    madeView st m =
      [hh|
        <div class="invitation-made" role="status">
          {% if isNothing m.link %}
            <p>{{ m.email.text }} is invited: the link is in their mail.</p>
          {% end %}
          {% for url in maybeToList m.link %}
            <p>{{ m.email.text }} is invited. {{ notMailed }}</p>
            <div class="invitation-link-row">
              <input type="text" class="invitation-link" readonly value={{ url }} aria-label="The invitation's link" {{ HP.ref st.linkField }}>
              <button type="button" class="invitation-copy" onClick={{ const (CopyLink url) }}>{{ if st.copied then "Copied" else "Copy link" :: Text }}</button>
            </div>
          {% end %}
        </div>
      |]
      where
        notMailed :: Text
        notMailed = case m.mailError of
          Just why -> "The mail could not be sent (" <> why <> "): pass this link on yourself, it is not shown again."
          Nothing -> "Pass this link on to them: it is not shown again."

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
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
      SetAccess access -> withSettings (\s -> s {access})
      SetCreateSpaces granted -> withSettings (\s -> s {newAccountsCreateSpaces = granted})
      SetPasswordAccounts allowed -> withSettings (\s -> s {adminCreatesPasswordAccounts = allowed})
      TypedEmail typedEmail -> modify (\st -> st {typedEmail})
      MakeInvitation -> do
        email <- gets (\st -> st.typedEmail)
        modify (\st -> st {busy = True, problem = Nothing, made = Nothing, copied = False})
        lift (invite email) >>= \case
          Left e -> modify (\st -> st {busy = False, problem = Just e})
          Right invited -> do
            router <- gets (\st -> st.input.context.router)
            url <- for invited.token $ \t -> absoluteUrl (Router.href router (Route.Invite t))
            modify (\st -> st {typedEmail = "", made = Just Made {email = invited.invitation.email, link = url, mailError = invited.mailError}})
            H.raise (Changed Nothing)
      Revoke i -> change (revokeInvitation i)
      CopyLink url ->
        gets (\st -> st.linkField)
          >>= H.getRef
          >>= traverse_
            ( \element -> do
                ok <- liftIO (copyText element url)
                modify (\st -> st {copied = ok})
            )

    withSettings :: (WikiSettings -> WikiSettings) -> H.HalogenM State Action Empty ViewOutput m ()
    withSettings f =
      gets (\st -> st.loaded) >>= \case
        Ready settings _ -> change (void <$> setWikiSettings (f settings))
        _ -> pass

    -- Request a change. If it is made, the shell is told, and the controls
    -- stay disabled until the settings have been fetched again
    -- ('Receive'). If it is refused, the reason is shown in place.
    change :: H.HalogenM State Action Empty ViewOutput m (Either WikiError ()) -> H.HalogenM State Action Empty ViewOutput m ()
    change request = do
      modify (\st -> st {busy = True, problem = Nothing})
      request >>= \case
        Left e -> modify (\st -> st {busy = False, problem = Just e})
        Right () -> H.raise (Changed Nothing)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      result <- lift readBoth
      modify (\st -> st {loaded = fromRead result, busy = False})

-- | Fetch the settings and the invitations together.
readBoth :: (MonadAdmin n) => n (Either WikiError (WikiSettings, Invitations))
readBoth = runExceptT ((,) <$> ExceptT wikiSettings <*> ExceptT invitations)

fromRead :: Either WikiError (WikiSettings, Invitations) -> Loaded
fromRead = either Failed (uncurry Ready)
