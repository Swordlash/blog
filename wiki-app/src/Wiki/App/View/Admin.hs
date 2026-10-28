{-# LANGUAGE QuasiQuotes #-}

-- | The administration's sections on the wiki's users and groups
-- (decision 11 of the plan). Users are listed with switches for whether
-- each is an administrator and whether they may create spaces, with their
-- account controls (whether they have a password, a new password, their
-- login disabled or enabled), and with a form for a new user. Groups are
-- listed with their members; they can be created, renamed and deleted,
-- and users can be added to them and removed from them. It is one
-- component over the administration's backend ("Wiki.App.Backend.Admin"),
-- the same on the demo's wiki, on the server's admin listener and on its
-- public listener: only who is asking differs. The shell shows it only to
-- someone who may administer the wiki.
--
-- Everything it shows comes from one read ('directory'): at once where
-- the backend can answer at once, and otherwise in its initializer, which
-- shows a loading state meanwhile (decision 18 of the plan). After a
-- change it tells the shell ('Changed'), which reloads who is signed in (a
-- change of membership may change what they may do) and increments the
-- context's revision, which makes this view fetch the directory again.
-- Until then its controls stay disabled, so that nothing is requested
-- twice before the change is visible.
--
-- An administrator is not offered to remove their own administrator
-- status: the switch on their own row is disabled, with a note why. The
-- backend would allow it (the operator on the server's admin listener can
-- always give it back), but from the panel it would lock the user out of
-- the panel at once, which is more likely a slip than intended. The
-- operator on the admin listener is not a user of the wiki and has no row,
-- so they may change every row. For the same reason, an administrator is
-- not offered to disable their own login, which would sign them out at
-- once.
--
-- An administrator may create spaces whatever their own create-spaces
-- grant says, since administering the wiki includes it
-- ("Wiki.Core.Permission"). So their switch shows the effective permission,
-- on, and is disabled, with a note why, rather than showing a grant they
-- do not need as missing. A grant they hold anyway is kept, and shown and
-- toggled again if they stop being an administrator.
--
-- A password is typed into its own form, in place, and never shown back:
-- the field is emptied once it is saved. Where the server sends mail and
-- the user has a verified address, no password is typed for them. Instead,
-- after asking for confirmation, the panel mails them the same link that
-- "Forgot your password?" mails (WP5.6 of docs/PLAN.md), with which they
-- choose a password themselves. The panel offers typing a password only
-- where a link is impossible, and says why under the button. A user who
-- signs in with one of the server's providers and has no password has none
-- to set, and is offered neither ('passwordControl').
--
-- Deleting a group asks for confirmation first, in place, as deleting a
-- space does.
--
-- A user who signs in with a provider's account (WP3.6 of docs/PLAN.md)
-- is shown as such ("Signs in with GitHub"), and each such account may be
-- disconnected, which ends their sessions, except on one's own row. One's
-- own accounts are disconnected from one's own account panel, which
-- prevents disconnecting one's last way to sign in.
--
-- A user's e-mail address, if they gave one, is shown with whether it is
-- verified. A user who has a second factor is shown as having one, with
-- "Remove second factor" for someone who has lost theirs (WP4.11 of
-- docs/PLAN.md; not on one's own row, where the account panel removes it
-- with a code). A new user may be given an address, to which the server
-- mails a verification link; where it sends no mail (and in the demo) the
-- field is disabled, saying why. When the wiki's settings leave accounts
-- with a password to the server's console (WP5.18 of docs/PLAN.md), the
-- form for a new user is replaced by a note that names the console's
-- command.
module Wiki.App.View.Admin
  ( Input (..)
  , component

    -- * A user's password
  , PasswordControl (..)
  , NoLink (..)
  , passwordControl
  , noLinkText
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Account (Account (..), NewAccount (..))
import Wiki.Api.Admin (Directory (..))
import Wiki.Api.Security (AccountEmail (..), resetLifetime)
import Wiki.App.Backend (MonadLoad (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Common
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (GroupId, UserId)
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), Subject (..), canCreateSpaces, principal)
import Wiki.Core.User (Group (..), Login (..), SignInProvider (..), User (..))

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready Directory

-- | What is open in the groups section, besides the lists.
data Editing
  = Idle
  | -- | The form renaming a group, with the name typed so far.
    Renaming GroupId Text
  | -- | Asking for confirmation to delete a group.
    ConfirmingDelete GroupId

-- | The form for a new user, as typed so far.
data NewUser = NewUser
  { typedLogin :: Text
  , typedName :: Text
  , typedPassword :: Text
  , typedEmail :: Text
  , asAdministrator :: Bool
  }

noNewUser :: NewUser
noNewUser = NewUser {typedLogin = "", typedName = "", typedPassword = "", typedEmail = "", asAdministrator = False}

data State = State
  { input :: Input
  , loaded :: Loaded
  , newUser :: NewUser
  , settingPassword :: Maybe (UserId, Text)
  -- ^ The user whose new password is being typed, and what is typed.
  , confirmingLink :: Maybe UserId
  -- ^ The user for whom the panel asks whether to mail a link to choose a
  -- password.
  , usersTold :: Maybe Text
  -- ^ The result of the last account change, shown once it is done.
  , editing :: Editing
  , newGroup :: Text
  -- ^ The name typed for a new group.
  , chosen :: Map GroupId Int
  -- ^ For each group, which of the users not in it is selected to be
  -- added; the first unless another has been selected.
  , busy :: Bool
  -- ^ A change has been requested, and the directory not fetched again
  -- since.
  , usersProblem :: Maybe WikiError
  , groupsProblem :: Maybe WikiError
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | SetAdministrator UserId Bool
  | SetCreateSpaces UserId Bool
  | TypedLogin Text
  | TypedDisplayName Text
  | TypedPassword Text
  | TypedEmail Text
  | ChoseAdministrator Bool
  | CreateUser
  | AskPassword UserId
  | TypedNewPassword Text
  | SavePassword
  | CancelPassword
  | AskLink UserId
  | MailLink User Text
  | CancelLink
  | SetDisabled User Bool
  | Unlink User Text
  | RemoveSecondFactor User
  | TypedNewGroup Text
  | CreateGroup
  | StartRenaming Group
  | TypedName Text
  | Rename
  | AskDelete GroupId
  | Delete GroupId
  | CancelEditing
  | Choose GroupId Int
  | Add GroupId
  | Remove GroupId UserId

component :: forall query m. (MonadAdmin m, MonadLoad m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- Read here when the backend answers at once, so that the first
          -- render is the page a prerender or the server shows; otherwise
          -- in 'Initialize'.
          loaded <- maybe Loading (either Failed Ready) <$> atOnce directory
          pure
            State
              { input
              , loaded
              , newUser = noNewUser
              , settingPassword = Nothing
              , confirmingLink = Nothing
              , usersTold = Nothing
              , editing = Idle
              , newGroup = ""
              , chosen = mempty
              , busy = False
              , usersProblem = Nothing
              , groupsProblem = Nothing
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
        <div class="admin-people">
          <section class="admin-section admin-users">
            <h2>Users</h2>
            <p class="admin-intro">
              Everyone who can sign in. An administrator may do everything: see and change every
              space, and use this page.
            </p>
            {{ body (usersView st) }}
          </section>
          <section class="admin-section admin-groups">
            <h2>Groups</h2>
            <p class="admin-intro">
              Sets of users, to grant permissions on spaces to at once: a member of a group may
              do what the group may.
            </p>
            {{ body (groupsView st) }}
          </section>
        </div>
      |]
      where
        body shown = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready d -> shown d

    usersView :: State -> Directory -> H.ComponentHTML Action Empty m
    usersView st d =
      [hh|
        <div class="admin-users-list">
          {{ errorView <$> st.usersProblem }}
          {% for t in maybeToList st.usersTold %}
            <p class="admin-told" role="status">{{ t }}</p>
          {% end %}
          {% if null d.users %}
            <p class="empty">There are no users yet.</p>
          {% else %}
            <table class="user-table">
              <thead>
                <tr>
                  <th scope="col">Name</th>
                  <th scope="col">Login</th>
                  <th scope="col">Administrator</th>
                  <th scope="col">Creates spaces</th>
                  <th scope="col">Account</th>
                </tr>
              </thead>
              <tbody>
                {% for u in d.users %}
                  {{ userRow st d u }}
                {% end %}
              </tbody>
            </table>
          {% end %}
          {% if d.adminCreatesPasswordAccounts %}
            {{ newUserForm st d }}
          {% else %}
            {{ consoleNote }}
          {% end %}
        </div>
      |]

    userRow :: State -> Directory -> User -> H.ComponentHTML Action Empty m
    userRow st d u =
      [hh|
        <tr class="user-row{% if disabled %} user-disabled{% end %}" data-login={{ u.login.text }}>
          <td class="user-display-name">{{ u.displayName }}</td>
          <td class="user-login">{{ u.login.text }}</td>
          <td class="user-administrator">
            <button
              type="button"
              role="switch"
              class="switch administrator-switch"
              aria-checked={{ ariaBool administrator }}
              aria-label={{ u.displayName <> " is an administrator" }}
              disabled={{ st.busy || yourself }}
              onClick={{ const (SetAdministrator u.id (not administrator)) }}
            >
              {{ yesNo administrator }}
            </button>
            {% if yourself %}
              <span class="admin-note administrator-self">That is you: another administrator can change it.</span>
            {% end %}
          </td>
          <td class="user-creator">
            <button
              type="button"
              role="switch"
              class="switch creator-switch"
              aria-checked={{ ariaBool (creator || createsAnyway) }}
              aria-label={{ u.displayName <> " may create spaces" }}
              disabled={{ st.busy || createsAnyway }}
              onClick={{ const (SetCreateSpaces u.id (not creator)) }}
            >
              {{ yesNo (creator || createsAnyway) }}
            </button>
            {% if createsAnyway %}
              <span class="admin-note creator-administrator">An administrator creates spaces anyway.</span>
            {% end %}
          </td>
          <td class="user-account">
            <span class="account-state">{{ accountState }}</span>
            {% for e in maybeToList email %}
              <span class="account-email">{{ e.email <> (if e.verified then "" else " (not verified)") }}</span>
            {% end %}
            {% if secondFactor %}
              <span class="account-second-factor">With a second factor</span>
            {% end %}
            {% if settingThis %}
              <form class="inline-form password-form" {{ HE.preventingDefault (HE.onSubmit (const SavePassword)) }}>
                <label class="field">
                  <span>{{ "New password for " <> u.displayName }}</span>
                  <input type="password" class="password-new" autocomplete="new-password" value={{ typedPassword }} onValueInput={{ TypedNewPassword }} required>
                </label>
                <button type="submit" class="primary" disabled={{ st.busy }}>Save password</button>
                {{ button "Cancel" CancelPassword }}
              </form>
            {% else %}
              {{ passwordView }}
              <button
                type="button"
                class="disable-toggle"
                disabled={{ st.busy || (yourself && not disabled) }}
                onClick={{ const (SetDisabled u (not disabled)) }}
              >
                {{ if disabled then "Enable" else "Disable" :: Text }}
              </button>
              {% if yourself %}
                <span class="admin-note disable-self">You cannot disable your own login here.</span>
              {% end %}
              {% if secondFactor && not yourself %}
                <button type="button" class="second-factor-remove" disabled={{ st.busy }} onClick={{ const (RemoveSecondFactor u) }}>Remove second factor</button>
              {% end %}
              {% if not yourself %}
                {% for provider in providers %}
                  <button type="button" class="identity-unlink" disabled={{ st.busy }} onClick={{ const (Unlink u provider) }}>
                    {{ "Disconnect " <> labelOf provider }}
                  </button>
                {% end %}
              {% end %}
            {% end %}
          </td>
        </tr>
      |]
      where
        administrator = u.id `Set.member` d.administrators
        creator = u.id `Set.member` d.creators
        -- Whether the rules let them create spaces without their own
        -- create-spaces grant, because of what else they hold, as an
        -- administrator.
        createsAnyway =
          administrator
            && canCreateSpaces
              (Just (principal d.membership u.id))
              Grants {global = [GlobalGrant {subject = SubjectUser u.id, permission = Administer}], spaces = [], access = Open}
        disabled = u.id `Set.member` d.disabled
        hasPassword = u.id `Set.member` d.withPassword
        providerOnly = u.id `Set.member` d.providerOnly
        secondFactor = u.id `Set.member` d.secondFactor
        email = Map.lookup u.id d.emails
        yourself = Just u.id == ((\me -> me.id) <$> st.input.context.session.user)
        (settingThis, typedPassword) = case st.settingPassword of
          Just (uid, typed) | uid == u.id -> (True, typed)
          _ -> (False, "")
        providers = Map.findWithDefault [] u.id d.identities
        labelOf name = maybe name (\p -> p.label) (find (\p -> p.name == name) st.input.context.session.providers)
        others = T.intercalate " and " (map labelOf providers)
        accountState :: Text
        accountState
          | disabled = "Disabled"
          | hasPassword && null providers = "Signs in with a password"
          | hasPassword = "Signs in with a password and " <> others
          | providerOnly = "Signs in with " <> others
          | not (null providers) = "No way in: the server no longer signs in with " <> others
          | otherwise = "No password yet"
        -- The password button: a link to mail, after confirmation; or a
        -- password to type, with the reason there is no link; or nothing.
        passwordView :: Maybe (H.ComponentHTML Action Empty m)
        passwordView = case passwordControl d u.id of
          NoPasswordControl -> Nothing
          SendLink address
            | st.confirmingLink == Just u.id ->
                Just
                  [hh|
                  <div class="confirm password-link-confirm" role="alertdialog">
                    <p>
                      {{ "Mail " <> u.displayName <> " a link to choose a new password, at " <> address <> "?" }}
                      {{ " It works once, for " <> show (round (resetLifetime / 60) :: Int) <> " minutes, and signs them out everywhere when it is used." :: Text }}
                    </p>
                    <button type="button" class="primary password-link-send" disabled={{ st.busy }} onClick={{ const (MailLink u address) }}>Send the link</button>
                    {{ button "Cancel" CancelLink }}
                  </div>
                |]
            | otherwise ->
                Just
                  [hh|
                  <button type="button" class="password-link-ask" disabled={{ st.busy }} onClick={{ const (AskLink u.id) }}>Send a password link…</button>
                |]
          TypePassword why ->
            Just
              [hh|
              <span class="password-control">
                <button type="button" class="password-ask" disabled={{ st.busy }} onClick={{ const (AskPassword u.id) }}>
                  {{ if hasPassword then "Reset password…" else "Set password…" :: Text }}
                </button>
                <span class="admin-note password-hint">{{ noLinkText why }}</span>
              </span>
            |]

    -- 'consoleNote' is shown in place of the form for a new user when the
    -- wiki's settings leave accounts with a password to the server's
    -- console. The backend would refuse the form, so the panel says where
    -- such accounts are made instead. The text before the @code@ element
    -- ends on the element's line, so that its space stays (hh drops the
    -- spaces at a line break, as JSX does).
    consoleNote :: H.ComponentHTML Action Empty m
    consoleNote =
      [hh|
        <div class="user-create-console" role="note">
          <h3>New user</h3>
          <p class="admin-note">
            Accounts with a password are made on the server's console, with <code>wiki-server users add</code>,
            as this wiki's settings say. Invitations and sign-in providers still make accounts. To
            create accounts here, turn on "The administration may create accounts with a password"
            under "Who may come in".
          </p>
        </div>
      |]

    newUserForm :: State -> Directory -> H.ComponentHTML Action Empty m
    newUserForm st d =
      [hh|
        <form class="user-create" aria-label="New user" {{ HE.preventingDefault (HE.onSubmit (const CreateUser)) }}>
          <h3>New user</h3>
          <div class="user-create-fields">
            <label class="field">
              <span>Login</span>
              <input type="text" class="user-create-login" autocomplete="off" autocapitalize="none" spellcheck="false" value={{ st.newUser.typedLogin }} onValueInput={{ TypedLogin }} required>
            </label>
            <label class="field">
              <span>Display name</span>
              <input type="text" class="user-create-name" autocomplete="off" placeholder="The login, if left blank" value={{ st.newUser.typedName }} onValueInput={{ TypedDisplayName }}>
            </label>
            <label class="field">
              <span>Password</span>
              <input type="password" class="user-create-password" autocomplete="new-password" value={{ st.newUser.typedPassword }} onValueInput={{ TypedPassword }} required>
            </label>
            <label class="field">
              <span>E-mail</span>
              <input
                type="email"
                class="user-create-email"
                autocomplete="off"
                placeholder={{ if d.mailing then "Optional: a link to verify it is mailed there" else "" :: Text }}
                disabled={{ not d.mailing }}
                value={{ st.newUser.typedEmail }}
                onValueInput={{ TypedEmail }}
              >
              {% if not d.mailing %}
                <span class="admin-note user-create-email-note">This wiki sends no mail, so an address could not be verified: set up mail in the Server section first.</span>
              {% end %}
            </label>
            <label class="check user-create-administrator">
              <input type="checkbox" checked={{ st.newUser.asAdministrator }} onChecked={{ ChoseAdministrator }}>
              <span>Administrator</span>
            </label>
          </div>
          <button type="submit" class="primary" disabled={{ st.busy }}>Create user</button>
        </form>
      |]

    groupsView :: State -> Directory -> H.ComponentHTML Action Empty m
    groupsView st d =
      [hh|
        <div class="admin-groups-list">
          {{ errorView <$> st.groupsProblem }}
          {% if null d.groups %}
            <p class="empty">There are no groups yet.</p>
          {% else %}
            <ul class="group-list">
              {% for g in d.groups %}
                {{ groupView st d g }}
              {% end %}
            </ul>
          {% end %}
          <form class="inline-form group-create" {{ HE.preventingDefault (HE.onSubmit (const CreateGroup)) }}>
            <label class="field">
              <span>New group</span>
              <input type="text" class="group-create-name" value={{ st.newGroup }} onValueInput={{ TypedNewGroup }} required>
            </label>
            <button type="submit" class="primary" disabled={{ st.busy }}>Create group</button>
          </form>
        </div>
      |]

    groupView :: State -> Directory -> Group -> H.ComponentHTML Action Empty m
    groupView st d g =
      [hh|
        <li class="group" data-group={{ g.name }}>
          {{ heading }}
          {% if null members %}
            <p class="empty group-empty">Nobody is in this group.</p>
          {% else %}
            <ul class="group-members">
              {% for u in members %}
                <li class="group-member" data-login={{ u.login.text }}>
                  <span class="group-member-name">{{ u.displayName }}</span>
                  <span class="group-member-login">{{ u.login.text }}</span>
                  <button
                    type="button"
                    class="group-remove"
                    aria-label={{ "Remove " <> u.displayName <> " from " <> g.name }}
                    disabled={{ st.busy }}
                    onClick={{ const (Remove g.id u.id) }}
                  >
                    Remove
                  </button>
                </li>
              {% end %}
            </ul>
          {% end %}
          {% if not (null others) %}
            <div class="group-add">
              <select class="group-add-user" aria-label={{ "Who to add to " <> g.name }} onSelectedIndexChange={{ Choose g.id }}>
                {% for (n, u) in zip [0 :: Int ..] others %}
                  <option selected={{ n == pick }}>{{ userLabel u }}</option>
                {% end %}
              </select>
              <button type="button" class="group-add-button" disabled={{ st.busy }} onClick={{ const (Add g.id) }}>Add to the group</button>
            </div>
          {% end %}
        </li>
      |]
      where
        inGroup = Map.findWithDefault mempty g.id d.membership
        members = filter (\u -> u.id `Set.member` inGroup) d.users
        others = filter (\u -> not (u.id `Set.member` inGroup)) d.users
        pick = Map.findWithDefault 0 g.id st.chosen
        heading = case st.editing of
          Renaming gid name
            | gid == g.id ->
                [hh|
                  <form class="inline-form group-rename" {{ HE.preventingDefault (HE.onSubmit (const Rename)) }}>
                    {{ textField "New name" name TypedName }}
                    <button type="submit" class="primary" disabled={{ st.busy }}>Rename</button>
                    {{ button "Cancel" CancelEditing }}
                  </form>
                |]
          ConfirmingDelete gid
            | gid == g.id ->
                [hh|
                  <div class="confirm group-delete-confirm" role="alertdialog">
                    <p>
                      Delete the group {{ g.name }}? Its members stay users of the wiki, but lose
                      what was granted to the group.
                    </p>
                    <button type="button" class="danger" disabled={{ st.busy }} onClick={{ const (Delete g.id) }}>Delete</button>
                    {{ button "Cancel" CancelEditing }}
                  </div>
                |]
          _ ->
            [hh|
              <div class="group-row">
                <h3 class="group-name">{{ g.name }}</h3>
                <span class="group-count">{{ counted (length members) }}</span>
                <button type="button" class="group-rename-ask" disabled={{ st.busy }} onClick={{ const (StartRenaming g) }}>Rename</button>
                <button type="button" class="group-delete-ask" disabled={{ st.busy }} onClick={{ const (AskDelete g.id) }}>Delete…</button>
              </div>
            |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      -- The shell has reloaded the wiki after a change, by this panel or
      -- another view: fetch the directory again.
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      SetAdministrator u granted -> change usersDone usersFailed (setAdministrator u granted)
      SetCreateSpaces u granted -> change usersDone usersFailed (setCreateSpaces u granted)
      TypedLogin t -> modify (\st -> st {newUser = st.newUser {typedLogin = t}})
      TypedDisplayName t -> modify (\st -> st {newUser = st.newUser {typedName = t}})
      TypedPassword t -> modify (\st -> st {newUser = st.newUser {typedPassword = t}})
      TypedEmail t -> modify (\st -> st {newUser = st.newUser {typedEmail = t}})
      ChoseAdministrator b -> modify (\st -> st {newUser = st.newUser {asAdministrator = b}})
      CreateUser -> do
        form <- gets (\st -> st.newUser)
        modify (\st -> st {busy = True, usersProblem = Nothing, usersTold = Nothing})
        let email = mfilter (not . T.null) (Just (T.strip form.typedEmail))
        createUser NewAccount {login = form.typedLogin, displayName = form.typedName, password = form.typedPassword, email} >>= \case
          Left e -> modify (\st -> st {busy = False, usersProblem = Just e})
          Right account -> do
            -- Created: whatever the result of making them an
            -- administrator, the form is done, and the directory is fetched
            -- again.
            made <- if form.asAdministrator then setAdministrator account.user.id True else pure (Right ())
            modify $ \st ->
              st
                { newUser = noNewUser
                , usersProblem = leftToMaybe made
                , usersTold =
                    Just
                      ( account.user.displayName
                          <> " ("
                          <> account.user.login.text
                          <> ") can sign in now."
                          <> maybe "" (\e -> " A link to verify " <> e <> " is sent to it.") email
                      )
                }
            H.raise (Changed Nothing)
      AskPassword u -> modify (\st -> st {settingPassword = Just (u, ""), confirmingLink = Nothing, usersProblem = Nothing, usersTold = Nothing})
      AskLink u -> modify (\st -> st {confirmingLink = Just u, settingPassword = Nothing, usersProblem = Nothing, usersTold = Nothing})
      CancelLink -> modify (\st -> st {confirmingLink = Nothing})
      -- A mail changes nothing the directory shows, so it is not fetched
      -- again.
      MailLink u address -> do
        modify (\st -> st {busy = True, usersProblem = Nothing, usersTold = Nothing})
        sendPasswordLink u.id >>= \case
          Left e -> modify (\st -> st {busy = False, usersProblem = Just e})
          Right () ->
            modify $ \st ->
              st
                { busy = False
                , confirmingLink = Nothing
                , usersTold = Just ("A link to choose a new password was mailed to " <> u.displayName <> ", at " <> address <> ".")
                }
      TypedNewPassword t -> modify $ \st -> st {settingPassword = (\(u, _) -> (u, t)) <$> st.settingPassword}
      CancelPassword -> modify (\st -> st {settingPassword = Nothing})
      SavePassword ->
        get >>= \st -> for_ st.settingPassword $ \(u, typed) ->
          change
            (\s -> s {settingPassword = Nothing, usersProblem = Nothing, usersTold = Just (nameOf st u <> " has a new password: their sessions have ended.")})
            usersFailed
            (void <$> setPassword u typed)
      SetDisabled u off ->
        change
          (\st -> st {usersProblem = Nothing, usersTold = Just (if off then u.displayName <> " can no longer sign in: their sessions have ended." else u.displayName <> " can sign in again.")})
          usersFailed
          (void <$> setDisabled u.id off)
      Unlink u provider ->
        change
          (\st -> st {usersProblem = Nothing, usersTold = Just (u.displayName <> " no longer signs in with that account: their sessions have ended.")})
          usersFailed
          (unlinkUserIdentity u.id provider)
      RemoveSecondFactor u ->
        change
          (\st -> st {usersProblem = Nothing, usersTold = Just (u.displayName <> " signs in with their password alone now: they may set up a new second factor.")})
          usersFailed
          (removeSecondFactor u.id)
      TypedNewGroup t -> modify (\st -> st {newGroup = t})
      CreateGroup -> do
        name <- gets (\st -> st.newGroup)
        change (\st -> st {groupsProblem = Nothing, newGroup = ""}) groupsFailed (void <$> createGroup name)
      StartRenaming g -> modify (\st -> st {editing = Renaming g.id g.name, groupsProblem = Nothing})
      TypedName t -> modify $ \st -> case st.editing of
        Renaming gid _ -> st {editing = Renaming gid t}
        _ -> st
      Rename ->
        gets (\st -> st.editing) >>= \case
          Renaming gid name -> change (\st -> st {editing = Idle, groupsProblem = Nothing}) groupsFailed (void <$> renameGroup gid name)
          _ -> pass
      AskDelete gid -> modify (\st -> st {editing = ConfirmingDelete gid, groupsProblem = Nothing})
      Delete gid -> change (\st -> st {editing = Idle, groupsProblem = Nothing}) groupsFailed (deleteGroup gid)
      CancelEditing -> modify (\st -> st {editing = Idle})
      Choose gid n -> modify (\st -> st {chosen = Map.insert gid n st.chosen})
      Add gid ->
        get >>= \st -> case st.loaded of
          Ready d -> do
            let inGroup = Map.findWithDefault mempty gid d.membership
                others = filter (\u -> not (u.id `Set.member` inGroup)) d.users
            for_ (atMay others (Map.findWithDefault 0 gid st.chosen)) $ \u ->
              change (\s -> s {groupsProblem = Nothing}) groupsFailed (addMember gid u.id)
          _ -> pass
      Remove gid u -> change (\st -> st {groupsProblem = Nothing}) groupsFailed (removeMember gid u)
      where
        groupsFailed e st = st {groupsProblem = Just e}
        usersFailed e st = st {usersProblem = Just e}
        usersDone st = st {usersProblem = Nothing, usersTold = Nothing}
        -- A user's name, as the last fetched directory has it.
        nameOf st u = case st.loaded of
          Ready d | Just x <- find (\x -> x.id == u) d.users -> x.displayName
          _ -> "The user"

    -- Request a change. If it is made, the shell is told, and the controls
    -- stay disabled until the directory has been fetched again ('Receive').
    -- If it is refused, the reason is shown in place, and the controls are
    -- enabled again.
    change
      :: (State -> State)
      -> (WikiError -> State -> State)
      -> H.HalogenM State Action Empty ViewOutput m (Either WikiError ())
      -> H.HalogenM State Action Empty ViewOutput m ()
    change done failed request = do
      modify (\st -> st {busy = True})
      request >>= \case
        Left e -> modify (\st -> (failed e st) {busy = False})
        Right () -> do
          modify done
          H.raise (Changed Nothing)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      result <- directory
      modify $ \st ->
        st
          { loaded = either Failed Ready result
          , busy = False
          , -- The users not in each group have changed: the first is
            -- selected again.
            chosen = mempty
          }

yesNo :: Bool -> Text
yesNo b = if b then "Yes" else "No"

-- | What the account column offers for a user's password (WP5.6 of
-- docs/PLAN.md).
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

-- | What the panel offers for a user's password, from what the directory
-- says about them: nothing for a user who has no password to set; a link
-- to mail where the server sends mail and the user has a verified address
-- and may sign in; and a password to type otherwise.
passwordControl :: Directory -> UserId -> PasswordControl
passwordControl d u
  | u `Set.member` d.providerOnly = NoPasswordControl
  | not d.mailing = TypePassword NoMail
  | u `Set.member` d.disabled = TypePassword LoginDisabled
  | otherwise = case Map.lookup u d.emails of
      Just e | e.verified -> SendLink e.email
      _ -> TypePassword NoVerifiedAddress

-- | Why no link is mailed, as written under the button.
noLinkText :: NoLink -> Text
noLinkText = \case
  NoMail -> "The server sends no mail: type a password for them"
  LoginDisabled -> "Their login is disabled: type a password for them"
  NoVerifiedAddress -> "No verified address: type a password for them"

-- | A user as the list of users to add names them.
userLabel :: User -> Text
userLabel u = u.displayName <> " (" <> u.login.text <> ")"

-- | How many members a group has, in words for a person to read.
counted :: Int -> Text
counted = \case
  0 -> "no members"
  1 -> "1 member"
  n -> show n <> " members"
