{-# LANGUAGE QuasiQuotes #-}

-- | 'UserDialog' is the administration's "Manage" dialog for one user
-- (WP5.25 of docs/PLAN.md). It holds every operation on one user that the
-- administration has: whether they are an administrator and whether they
-- may create spaces, how they sign in (their address, their password, the
-- sign-in providers' accounts connected to them), the groups they are in,
-- and the account's dangerous actions (disabling their login, removing
-- their second factor, removing the account). The table of users ("Wiki.App.View.Users") opens
-- it from a row's "Manage" button, and the row keeps only the user's
-- badges.
--
-- It is a @\<dialog>@ element shown as a modal ('showDialog'): the browser
-- draws a backdrop, makes the rest of the page inert (so the focus stays in
-- the dialog), closes it on Escape, and gives the focus back to the
-- "Manage" button when it closes. A click on the backdrop closes it too,
-- one that starts there: not a selection let go outside.
-- The dialog tells the table when it has closed ('Closed').
--
-- Each change is saved as soon as it is made, and a short "Saved" says so.
-- The dialog then tells the table ('Saved'), which tells the shell: the
-- shell reloads who is signed in and increments the context's revision,
-- and the table fetches its page of users again and gives the dialog the
-- user as they are now (its input). Until then the dialog's controls stay
-- disabled, so that nothing is requested twice before the change is
-- visible. Disabling a login and removing a second factor ask for
-- confirmation first, in place; so does mailing a password link.
--
-- Removing the account is offered only once the login is disabled, so that
-- it is a second, deliberate step. It is confirmed by typing the user's
-- login. Once the account is removed the dialog closes and tells the table
-- ('Removed'), since there is no user left to show.
--
-- The rules of the old rows of buttons stay. An administrator is not
-- offered to remove their own administrator status, nor to disable their
-- own login, nor to remove their own second factor or account, or disconnect their own
-- providers' accounts: from the administration that would lock them out,
-- or belongs to their own account panel. The operator on the server's
-- admin listener is not a user and may change everyone. An administrator
-- creates spaces whatever their own grant says, so their switch shows the
-- permission on and is disabled. A password is typed into its own form and
-- never shown back. Where the server sends mail and the user has a
-- verified address, the dialog mails them a link to choose a password
-- instead ('passwordControl').
--
-- The dialog is one column of parts, each with a heading. A per-user
-- setting a later package adds (the wiki's assistant access, WP5.26) is
-- one more switch in the "Permissions" part ('permissionsPart').
module Wiki.App.View.UserDialog
  ( Input (..)
  , Output (..)
  , component

    -- * A user's password
  , PasswordControl (..)
  , NoLink (..)
  , passwordControl
  , noLinkText

    -- * How a user signs in, and their badges
  , signInText
  , userBadges
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.List (partition)
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.Api.Admin (UserSummary (..))
import Wiki.Api.Security (AccountEmail (..), resetLifetime)
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Browser (closeDialog, showDialog)
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.View.Common
import Wiki.Core.Id (GroupId)
import Wiki.Core.User (Email (..), Group (..), Login (..), Password (..), SignInProvider (..), User (..))

-- | What the dialog shows: the shell's context (who is asking, the
-- server's providers), the user, every group, and whether the server sends
-- mail; and how far the table's fetches have got, for the dialog to know
-- when the user it was given is the user after its own change.
data Input = Input
  { context :: Context
  , user :: UserSummary
  , groups :: [Group]
  , mailing :: Bool
  , asked :: Int
  -- ^ How many times the table has asked for its users.
  , shown :: Int
  -- ^ Which of those requests answered the users the table shows, 'user'
  -- among them.
  }

-- | What the dialog tells the table of users.
data Output
  = -- | The dialog has closed.
    Closed
  | -- | A change was saved: the users are fetched again.
    Saved
  | -- | The account was removed, and the dialog has closed. The text is
    -- what to tell the reader.
    Removed Text

-- | A question the dialog asks before it acts, or a form it shows in place
-- of a button.
data Asking
  = NotAsking
  | ConfirmingDisable
  | ConfirmingSecondFactor
  | -- | Mail a link to choose a password, to this address?
    ConfirmingLink Text
  | -- | The new password, as typed.
    TypingPassword Text
  | -- | Remove the account? With the login typed so far, which must be the
    -- user's login before the account can be removed.
    ConfirmingRemove Text

data State = State
  { input :: Input
  , element :: H.RefLabel
  , removeField :: H.RefLabel
  -- ^ The field the login is typed into to remove the account, focused
  -- when it appears, since the button that showed it is gone.
  , asking :: Asking
  , busy :: Bool
  -- ^ A change has been requested, and the user not received again since.
  , waitingFor :: Maybe Int
  -- ^ After a change: the first of the table's requests that was asked
  -- after it ('asked'). The controls stay disabled until the user that
  -- request answered is received ('shown'), so that they never show the
  -- user as they were before the change.
  , pressedOnBackdrop :: Bool
  -- ^ Whether the pointer went down on the backdrop, rather than in the
  -- dialog: only a click that starts there closes the dialog, so that
  -- selecting text and letting go outside closes nothing.
  , told :: Maybe Text
  -- ^ What the last change did, shown for a few seconds.
  , notice :: Maybe H.ForkId
  -- ^ The thread that takes 'told' away.
  , problem :: Maybe WikiError
  , chosenGroup :: Int
  -- ^ Which of the groups the user is not in is selected to be added to.
  }

data Action
  = Initialize
  | Receive Input
  | Close
  | ClickedDialog
  | Pressed Bool
  | Inside
  | ClosedByBrowser
  | SetAdministrator Bool
  | SetCreateSpaces Bool
  | AskDisable
  | SetDisabled Bool
  | AskSecondFactor
  | RemoveSecondFactor
  | AskPassword
  | TypedPassword Text
  | SavePassword
  | AskLink Text
  | MailLink Text
  | Unlink Text
  | Cancel
  | ChooseGroup Int
  | AddToGroup
  | RemoveFromGroup GroupId
  | AskRemove
  | TypedRemoval Text
  | RemoveAccount

component :: forall query m. (MonadAdmin m, MonadUUID m, MonadIO m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          element <- H.newRefLabel "user-dialog"
          removeField <- H.newRefLabel "user-remove-login"
          pure State {input, element, removeField, asking = NotAsking, busy = False, waitingFor = Nothing, pressedOnBackdrop = False, told = Nothing, notice = Nothing, problem = Nothing, chosenGroup = 0}
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
    -- The body stops the clicks and the pointer's presses inside it, so
    -- that one that reaches the dialog element itself is on the backdrop
    -- around the body.
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <dialog
          class="user-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="user-dialog-title"
          data-login={{ u.user.login.text }}
          onClick={{ const ClickedDialog }}
          {{ HP.ref st.element }}
          {{ [HE.handler (EventType "close") (const ClosedByBrowser), HE.onPointerDown (const (Pressed True))] }}
        >
          <div class="user-dialog-body" {{ [HE.stoppingPropagation (HE.onClick (const Inside)), HE.stoppingPropagation (HE.onPointerDown (const (Pressed False)))] }}>
            <header class="user-dialog-header">
              <div class="user-dialog-who">
                <h2 id="user-dialog-title">{{ u.user.displayName }}</h2>
                <p class="user-dialog-login"><span class="user-login">{{ u.user.login.text }}</span>{{ badges }}</p>
              </div>
              <button type="button" class="user-dialog-close" aria-label="Close" onClick={{ const Close }}>×</button>
            </header>
            <div class="user-dialog-status" aria-live="polite">
              {{ errorView <$> st.problem }}
              {% for t in maybeToList st.told %}
                <p class="user-dialog-saved" role="status">{{ t }}</p>
              {% end %}
            </div>
            {{ permissionsPart st }}
            {{ signInPart st }}
            {{ groupsPart st }}
            {{ accountPart st }}
            <footer class="user-dialog-footer">
              <button type="button" class="user-dialog-done" onClick={{ const Close }}>Done</button>
            </footer>
          </div>
        </dialog>
      |]
      where
        u = st.input.user
        badges = userBadges u

    -- Whether the user is an administrator, and whether they may create
    -- spaces. A later per-user setting goes here too.
    permissionsPart :: State -> H.ComponentHTML Action Empty m
    permissionsPart st =
      [hh|
        <section class="user-dialog-part user-dialog-permissions" aria-labelledby="user-dialog-permissions">
          <h3 id="user-dialog-permissions">Permissions</h3>
          <div class="setting">
            <div class="setting-text">
              <span class="setting-name">Administrator</span>
              <span class="setting-help">{{ adminHelp }}</span>
            </div>
            {{ switch "administrator-switch" (u.user.displayName <> " is an administrator") u.administrator (yourself st) (SetAdministrator (not u.administrator)) }}
          </div>
          <div class="setting">
            <div class="setting-text">
              <span class="setting-name">Creates spaces</span>
              <span class="setting-help">{{ creatorHelp }}</span>
            </div>
            {{ switch "creator-switch" (u.user.displayName <> " may create spaces") (u.createsSpaces || u.administrator) u.administrator (SetCreateSpaces (not u.createsSpaces)) }}
          </div>
        </section>
      |]
      where
        u = st.input.user
        adminHelp :: Text
        adminHelp
          | yourself st = "That is you: another administrator can change it."
          | otherwise = "May do everything: see and change every space, and use the administration."
        creatorHelp :: Text
        creatorHelp
          | u.administrator = "An administrator creates spaces anyway."
          | otherwise = "May create spaces at the top level of the wiki."
        switch :: Text -> Text -> Bool -> Bool -> Action -> H.ComponentHTML Action Empty m
        switch cls label checked fixed act =
          [hh|
            <button
              type="button"
              role="switch"
              class="switch {{ cls }}"
              aria-checked={{ ariaBool checked }}
              aria-label={{ label }}
              disabled={{ st.busy || fixed }}
              onClick={{ const act }}
            >
              {{ if checked then "On" else "Off" :: Text }}
            </button>
          |]

    -- How the user signs in: their address, their password, and the
    -- providers' accounts connected to them.
    signInPart :: State -> H.ComponentHTML Action Empty m
    signInPart st =
      [hh|
        <section class="user-dialog-part user-dialog-sign-in" aria-labelledby="user-dialog-sign-in">
          <h3 id="user-dialog-sign-in">Signing in</h3>
          <dl class="user-dialog-facts">
            <dt>Signs in</dt>
            <dd class="account-state">{{ signInText providers u }}</dd>
            <dt>E-mail</dt>
            <dd class="account-email">{{ emailText }}</dd>
          </dl>
          {{ passwordView }}
          {% if not (null u.identities) && not (yourself st) %}
            <ul class="user-dialog-identities">
              {% for provider in u.identities %}
                <li class="user-dialog-identity">
                  <span>{{ "Account at " <> labelOf providers provider }}</span>
                  <button type="button" class="identity-unlink" disabled={{ st.busy }} onClick={{ const (Unlink provider) }}>
                    {{ "Disconnect " <> labelOf providers provider }}
                  </button>
                </li>
              {% end %}
            </ul>
          {% end %}
        </section>
      |]
      where
        u = st.input.user
        providers = st.input.context.session.providers
        emailText :: Text
        emailText = case u.email of
          Nothing -> "None given"
          Just e -> e.email.text <> (if e.verified then " (verified)" else " (not verified)")
        -- The password's control: a link to mail, after confirmation; or a
        -- password to type, with the reason there is no link; or nothing.
        passwordView :: Maybe (H.ComponentHTML Action Empty m)
        passwordView = case (st.asking, passwordControl st.input.mailing u) of
          (_, NoPasswordControl) -> Nothing
          (TypingPassword typed, _) ->
            Just
              [hh|
                <form class="inline-form password-form" {{ HE.preventingDefault (HE.onSubmit (const SavePassword)) }}>
                  <label class="field">
                    <span>{{ "New password for " <> u.user.displayName }}</span>
                    <input type="password" class="password-new" autocomplete="new-password" value={{ typed }} onValueInput={{ TypedPassword }} required autofocus>
                  </label>
                  <div class="actions">
                    <button type="submit" class="primary" disabled={{ st.busy }}>Save password</button>
                    {{ button "Cancel" Cancel }}
                  </div>
                </form>
              |]
          (ConfirmingLink address, SendLink _) ->
            Just
              [hh|
                <div class="confirm password-link-confirm" role="alertdialog">
                  <p>
                    {{ "Mail " <> u.user.displayName <> " a link to choose a new password, at " <> address <> "?" }}
                    {{ " It works once, for " <> show (round (resetLifetime / 60) :: Int) <> " minutes, and signs them out everywhere when it is used." :: Text }}
                  </p>
                  <div class="actions">
                    <button type="button" class="primary password-link-send" disabled={{ st.busy }} onClick={{ const (MailLink address) }}>Send the link</button>
                    {{ button "Cancel" Cancel }}
                  </div>
                </div>
              |]
          (_, SendLink address) ->
            Just
              [hh|
                <div class="actions">
                  <button type="button" class="password-link-ask" disabled={{ st.busy }} onClick={{ const (AskLink address) }}>Send a password link…</button>
                </div>
              |]
          (_, TypePassword why) ->
            Just
              [hh|
                <div class="password-control">
                  <button type="button" class="password-ask" disabled={{ st.busy }} onClick={{ const AskPassword }}>
                    {{ if u.hasPassword then "Reset password…" else "Set password…" :: Text }}
                  </button>
                  <span class="admin-note password-hint">{{ noLinkText why }}</span>
                </div>
              |]

    -- The groups the user is in, each to take them out of, and the others
    -- to put them in.
    groupsPart :: State -> H.ComponentHTML Action Empty m
    groupsPart st =
      [hh|
        <section class="user-dialog-part user-dialog-groups" aria-labelledby="user-dialog-groups">
          <h3 id="user-dialog-groups">Groups</h3>
          {% if null member %}
            <p class="empty">{{ if null st.input.groups then "The wiki has no groups." else "In no group." :: Text }}</p>
          {% else %}
            <ul class="user-dialog-group-list">
              {% for g in member %}
                <li class="user-dialog-group" data-group={{ g.name }}>
                  <span>{{ g.name }}</span>
                  <button
                    type="button"
                    class="user-group-remove"
                    aria-label={{ "Remove " <> u.user.displayName <> " from " <> g.name }}
                    disabled={{ st.busy }}
                    onClick={{ const (RemoveFromGroup g.id) }}
                  >
                    Remove
                  </button>
                </li>
              {% end %}
            </ul>
          {% end %}
          {% if not (null others) %}
            <div class="user-dialog-group-add">
              <select class="user-group-choice" aria-label={{ "A group to add " <> u.user.displayName <> " to" }} onSelectedIndexChange={{ ChooseGroup }}>
                {% for (n, g) in zip [0 :: Int ..] others %}
                  <option selected={{ n == st.chosenGroup }}>{{ g.name }}</option>
                {% end %}
              </select>
              <button type="button" class="user-group-add" disabled={{ st.busy }} onClick={{ const AddToGroup }}>Add to the group</button>
            </div>
          {% end %}
        </section>
      |]
      where
        u = st.input.user
        (member, others) = partition (\g -> g.id `elem` u.groups) st.input.groups

    -- What cannot be undone without the user's help, or that ends their
    -- sessions: apart from the rest, in the danger style, each asked once.
    accountPart :: State -> H.ComponentHTML Action Empty m
    accountPart st =
      [hh|
        <section class="user-dialog-part user-dialog-account" aria-labelledby="user-dialog-account">
          <h3 id="user-dialog-account">Account</h3>
          {% if confirmingDisable %}
              <div class="confirm disable-confirm" role="alertdialog">
                <p>{{ "Disable " <> u.user.displayName <> "'s login? They are signed out everywhere and cannot sign in until it is enabled again. Their pages and permissions stay." }}</p>
                <div class="actions">
                  <button type="button" class="danger disable-confirm-button" disabled={{ st.busy }} onClick={{ const (SetDisabled True) }}>Disable</button>
                  {{ button "Cancel" Cancel }}
                </div>
              </div>
          {% elif confirmingFactor %}
              <div class="confirm second-factor-confirm" role="alertdialog">
                <p>{{ "Remove " <> u.user.displayName <> "'s second factor? They sign in with their password alone until they set up a new one." }}</p>
                <div class="actions">
                  <button type="button" class="danger second-factor-confirm-button" disabled={{ st.busy }} onClick={{ const RemoveSecondFactor }}>Remove</button>
                  {{ button "Cancel" Cancel }}
                </div>
              </div>
          {% elif yourself st %}
                <p class="admin-note disable-self">You cannot disable your own login, nor remove your own second factor or your own account, here.</p>
          {% elif confirmingRemove %}
              {{ removeConfirm }}
          {% else %}
                <div class="actions user-dialog-dangers">
                  {% if u.secondFactor %}
                    <button type="button" class="danger-outline second-factor-remove" disabled={{ st.busy }} onClick={{ const AskSecondFactor }}>Remove second factor…</button>
                  {% end %}
                  {% if u.disabled %}
                    <button type="button" class="disable-toggle" disabled={{ st.busy }} onClick={{ const (SetDisabled False) }}>Enable login</button>
                    <button type="button" class="danger-outline user-remove" disabled={{ st.busy }} onClick={{ const AskRemove }}>Remove the account…</button>
                  {% else %}
                    <button type="button" class="danger-outline disable-toggle" disabled={{ st.busy }} onClick={{ const AskDisable }}>Disable login…</button>
                  {% end %}
                </div>
                {% if not u.disabled %}
                  <p class="admin-note user-remove-hint">To remove the account, disable the login first.</p>
                {% end %}
          {% end %}
        </section>
      |]
      where
        u = st.input.user
        (confirmingDisable, confirmingFactor) = case st.asking of
          ConfirmingDisable -> (True, False)
          ConfirmingSecondFactor -> (False, True)
          _ -> (False, False)
        (confirmingRemove, typedLogin) = case st.asking of
          ConfirmingRemove typed | u.disabled -> (True, typed)
          _ -> (False, "")
        login = u.user.login.text
        -- The button stays disabled until the login is typed exactly, so
        -- that the account removed is the one the reader means.
        removeConfirm =
          [hh|
            <form class="confirm remove-confirm" role="alertdialog" aria-labelledby="user-remove-question" {{ HE.preventingDefault (HE.onSubmit (const RemoveAccount)) }}>
              <p id="user-remove-question"><strong>{{ "Remove " <> u.user.displayName <> "'s account?" }}</strong>{{ " This cannot be undone." :: Text }}</p>
              <p>{{ "Their sessions end, and their groups, permissions, passkeys, drafts, watches and notifications are deleted. The pages, versions and comments they wrote stay, under the login " <> login <> ", which a new account may then take." }}</p>
              <label class="field">
                <span>{{ "Type " :: Text }}<span class="user-login">{{ login }}</span>{{ " to confirm" :: Text }}</span>
                <input type="text" class="remove-confirm-login" autocomplete="off" autocapitalize="none" spellcheck="false" value={{ typedLogin }} onValueInput={{ TypedRemoval }} required {{ HP.ref st.removeField }}>
              </label>
              <div class="actions">
                <button type="submit" class="danger remove-confirm-button" disabled={{ st.busy || typedLogin /= login }}>Remove the account</button>
                {{ button "Cancel" Cancel }}
              </div>
            </form>
          |]

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Initialize -> gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . showDialog)
      -- The user as the table fetched them again: after a change of this
      -- dialog's, once the request asked after it has answered, the
      -- controls are enabled again.
      Receive input -> modify $ \st -> case st.waitingFor of
        Just n | input.shown >= n -> st {input, busy = False, waitingFor = Nothing}
        _ -> st {input}
      Close -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
        H.raise Closed
      Inside -> pass
      Pressed onBackdrop -> modify (\st -> st {pressedOnBackdrop = onBackdrop})
      ClickedDialog -> do
        onBackdrop <- gets (\st -> st.pressedOnBackdrop)
        modify (\st -> st {pressedOnBackdrop = False})
        when onBackdrop (handleAction Close)
      ClosedByBrowser -> H.raise Closed
      SetAdministrator granted -> withUser (\u -> setAdministrator u.user.id granted) "Saved."
      SetCreateSpaces granted -> withUser (\u -> setCreateSpaces u.user.id granted) "Saved."
      AskDisable -> open ConfirmingDisable
      SetDisabled off -> do
        name <- gets (\st -> st.input.user.user.displayName)
        withUser
          (\u -> void <$> setDisabled u.user.id off)
          (if off then "Saved: " <> name <> " can no longer sign in, and their sessions have ended." else "Saved: " <> name <> " can sign in again.")
      AskSecondFactor -> open ConfirmingSecondFactor
      RemoveSecondFactor -> do
        name <- gets (\st -> st.input.user.user.displayName)
        withUser (\u -> removeSecondFactor u.user.id) ("Saved: " <> name <> " signs in with their password alone now.")
      AskPassword -> open (TypingPassword "")
      TypedPassword t -> modify $ \st -> case st.asking of
        TypingPassword _ -> st {asking = TypingPassword t}
        _ -> st
      SavePassword ->
        gets (\st -> st.asking) >>= \case
          TypingPassword typed -> do
            name <- gets (\st -> st.input.user.user.displayName)
            withUser (\u -> void <$> setPassword u.user.id (Password typed)) ("Saved: " <> name <> " has a new password, and their sessions have ended.")
          _ -> pass
      AskLink address -> open (ConfirmingLink address)
      -- A mail changes nothing the table shows, so the users are not
      -- fetched again.
      MailLink address -> do
        st <- get
        modify (\s -> s {busy = True, problem = Nothing})
        sendPasswordLink st.input.user.user.id >>= \case
          Left e -> modify (\s -> s {busy = False, problem = Just e})
          Right () -> do
            modify (\s -> s {busy = False, asking = NotAsking})
            tell ("Sent: a link to choose a new password was mailed to " <> address <> ".")
      Unlink provider -> do
        name <- gets (\st -> st.input.user.user.displayName)
        withUser (\u -> unlinkUserIdentity u.user.id provider) ("Saved: " <> name <> " no longer signs in with that account, and their sessions have ended.")
      Cancel -> modify (\st -> st {asking = NotAsking})
      ChooseGroup n -> modify (\st -> st {chosenGroup = n})
      AddToGroup -> do
        st <- get
        let others = filter (\g -> g.id `notElem` st.input.user.groups) st.input.groups
        for_ (atMay others st.chosenGroup) $ \g -> do
          modify (\s -> s {chosenGroup = 0})
          withUser (\u -> addMember g.id u.user.id) ("Saved: in " <> g.name <> " now.")
      RemoveFromGroup g -> withUser (\u -> removeMember g u.user.id) "Saved."
      AskRemove -> do
        open (ConfirmingRemove "")
        gets (\st -> st.removeField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      TypedRemoval t -> modify $ \st -> case st.asking of
        ConfirmingRemove _ -> st {asking = ConfirmingRemove t}
        _ -> st
      -- The login typed is checked again here, since a form can be
      -- submitted with Enter whatever its button shows.
      RemoveAccount -> do
        st <- get
        let u = st.input.user
        case st.asking of
          ConfirmingRemove typed | typed == u.user.login.text && u.disabled && not st.busy -> do
            modify (\s -> s {busy = True, problem = Nothing})
            removeUser u.user.id >>= \case
              Left e -> modify (\s -> s {busy = False, problem = Just e})
              Right () -> do
                H.getRef st.element >>= traverse_ (H.liftEffect . closeDialog)
                H.raise (Removed (u.user.displayName <> "'s account (" <> u.user.login.text <> ") is removed. What they wrote stays, under their login."))
          _ -> pass
      where
        open a = modify (\st -> st {asking = a, problem = Nothing})

    -- Request a change to the user. If it is made, the table is told, and
    -- the controls stay disabled until the user is received again. If it
    -- is refused, the reason is shown, and the controls are enabled again.
    withUser :: (UserSummary -> H.HalogenM State Action Empty Output m (Either WikiError ())) -> Text -> H.HalogenM State Action Empty Output m ()
    withUser request saying = do
      u <- gets (\st -> st.input.user)
      modify (\st -> st {busy = True, problem = Nothing})
      request u >>= \case
        Left e -> modify (\st -> st {busy = False, problem = Just e})
        Right () -> do
          modify (\st -> st {asking = NotAsking, waitingFor = Just (st.input.asked + 1)})
          tell saying
          H.raise Saved

    -- Say what was done, for a few seconds.
    tell :: Text -> H.HalogenM State Action Empty Output m ()
    tell saying = do
      gets (\st -> st.notice) >>= traverse_ H.kill
      waiting <- H.fork $ do
        liftIO (threadDelay savedNoticeTime)
        modify (\st -> st {told = Nothing, notice = Nothing})
      modify (\st -> st {told = Just saying, notice = Just waiting})

    yourself :: State -> Bool
    yourself st = Just st.input.user.user.id == ((\me -> me.id) <$> st.input.context.session.user)

-- | How long "Saved" stays: five seconds.
savedNoticeTime :: Int
savedNoticeTime = 5_000_000

-- | The badges of a user: administrator, creates spaces, second factor,
-- disabled. The table's rows show the same.
userBadges :: UserSummary -> HH.HTML w i
userBadges u =
  [hh|
    <span class="user-badges">
      {% if u.administrator %}<span class="badge badge-administrator">Administrator</span>{% end %}
      {% if u.createsSpaces && not u.administrator %}<span class="badge badge-creator">Creates spaces</span>{% end %}
      {% if u.secondFactor %}<span class="badge badge-second-factor">Second factor</span>{% end %}
      {% if u.disabled %}<span class="badge badge-disabled">Disabled</span>{% end %}
    </span>
  |]

-- | How a user signs in, in a few words: with a password, with providers'
-- accounts (by the providers' labels), both, or in no way yet.
signInText :: [SignInProvider] -> UserSummary -> Text
signInText providers u
  | u.hasPassword && null u.identities = "With a password"
  | u.hasPassword = "With a password and " <> others
  | u.providerOnly = "With " <> others
  | not (null u.identities) = "No way in: the server no longer signs in with " <> others
  | otherwise = "No password yet"
  where
    others = T.intercalate " and " (map (labelOf providers) u.identities)

-- | A provider's label, as its button has it, by its name.
labelOf :: [SignInProvider] -> Text -> Text
labelOf providers name = maybe name (\p -> p.label) (find (\p -> p.name == name) providers)

-- | What the dialog offers for a user's password (WP5.6 of docs/PLAN.md).
data PasswordControl
  = -- | Nothing: they sign in with one of the server's providers, and have
    -- no password to set.
    NoPasswordControl
  | -- | "Send a password link…": mail the same link to choose a password
    -- that "Forgot your password?" mails, to this verified address.
    SendLink Text
  | -- | "Set password…" or "Reset password…": type one for them, since no
    -- link can be mailed, for this reason.
    TypePassword NoLink
  deriving stock (Eq, Show)

-- | Why no link to choose a password can be mailed to a user.
data NoLink
  = -- | The server sends no mail.
    NoMail
  | -- | Their login is disabled, and a link does not work for it.
    LoginDisabled
  | -- | They have no address, or have not verified the one they have.
    NoVerifiedAddress
  deriving stock (Eq, Show)

-- | What the dialog offers for a user's password, given whether the server
-- sends mail: nothing for a user who has no password to set; a link to
-- mail where the server sends mail and the user has a verified address and
-- may sign in; and a password to type otherwise.
passwordControl :: Bool -> UserSummary -> PasswordControl
passwordControl mailing u
  | u.providerOnly = NoPasswordControl
  | not mailing = TypePassword NoMail
  | u.disabled = TypePassword LoginDisabled
  | otherwise = case u.email of
      Just e | e.verified -> SendLink e.email.text
      _ -> TypePassword NoVerifiedAddress

-- | Why no link is mailed, as written beside the button.
noLinkText :: NoLink -> Text
noLinkText = \case
  NoMail -> "The server sends no mail: type a password for them"
  LoginDisabled -> "Their login is disabled: type a password for them"
  NoVerifiedAddress -> "No verified address: type a password for them"
