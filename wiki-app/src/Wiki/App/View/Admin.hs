{-# LANGUAGE QuasiQuotes #-}

-- | The administration's sections on the wiki's people (decision 11 of the
-- plan): its users, with a switch for whether each is an administrator,
-- and its groups, with their members, to make, rename and delete, and to
-- put users in and take them out of. One component over the
-- administration's backend ("Wiki.App.Backend.Admin"), the same on the
-- demo's wiki, on the server's admin listener and on its public one: only
-- who is asking differs, and the shell shows it only to someone who may
-- administer the wiki.
--
-- What it shows it reads in one go ('directory'), at once where the
-- backend can answer at once, and otherwise in its initializer, saying
-- meanwhile that it is loading (decision 18). After a change it tells the
-- shell ('Changed'), which reloads who is signed in (a change of
-- membership may change what they may do) and counts up the context's
-- revision, on which the directory is read again; until then its controls
-- stay disabled, so that nothing is asked twice of a wiki that has not
-- been read back.
--
-- An administrator is not offered to take that from themself: the switch
-- on their own row is disabled, with a note why. The backend would allow
-- it (the operator on the server's admin listener can always give it
-- back), but from the panel it would lock its user out of the panel at
-- once, which is more likely a slip than a wish. The operator on the
-- admin listener is no user of the wiki and has no row, so they may change
-- every one.
--
-- Deleting a group asks first, in place, as deleting a space does.
module Wiki.App.View.Admin
  ( Input (..)
  , component
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Set qualified as Set
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Admin (Directory (..))
import Wiki.App.Backend (MonadLoad (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Common
import Wiki.Core.Id (GroupId, UserId)
import Wiki.Core.User (Group (..), User (..))

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready Directory

-- | What is open in the groups' section, besides the lists.
data Editing
  = Idle
  | -- | The form renaming a group, with the name typed so far.
    Renaming GroupId Text
  | -- | Asking whether to delete a group.
    ConfirmingDelete GroupId

data State = State
  { input :: Input
  , loaded :: Loaded
  , editing :: Editing
  , newGroup :: Text
  -- ^ The name typed for a new group.
  , chosen :: Map GroupId Int
  -- ^ For each group, which of the users who are not in it is chosen to
  -- add; the first unless another has been.
  , busy :: Bool
  -- ^ A change has been asked for and the directory not read again since.
  , usersProblem :: Maybe WikiError
  , groupsProblem :: Maybe WikiError
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | SetAdministrator UserId Bool
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
          {% if null d.users %}
            <p class="empty">There are no users yet.</p>
          {% else %}
            <table class="user-table">
              <thead>
                <tr>
                  <th scope="col">Name</th>
                  <th scope="col">Login</th>
                  <th scope="col">Administrator</th>
                </tr>
              </thead>
              <tbody>
                {% for u in d.users %}
                  {{ userRow st d u }}
                {% end %}
              </tbody>
            </table>
          {% end %}
        </div>
      |]

    userRow :: State -> Directory -> User -> H.ComponentHTML Action Empty m
    userRow st d u =
      [hh|
        <tr class="user-row" data-login={{ u.login }}>
          <td class="user-display-name">{{ u.displayName }}</td>
          <td class="user-login">{{ u.login }}</td>
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
              {{ if administrator then "Yes" else "No" :: Text }}
            </button>
            {% if yourself %}
              <span class="admin-note administrator-self">That is you: another administrator can change it.</span>
            {% end %}
          </td>
        </tr>
      |]
      where
        administrator = u.id `Set.member` d.administrators
        yourself = Just u.id == ((\me -> me.id) <$> st.input.context.session.user)

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
                <li class="group-member" data-login={{ u.login }}>
                  <span class="group-member-name">{{ u.displayName }}</span>
                  <span class="group-member-login">{{ u.login }}</span>
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
      -- The shell has reloaded the wiki after a change, this panel's or
      -- another view's: read the directory again.
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      SetAdministrator u granted -> change (\st -> st {usersProblem = Nothing}) (\e st -> st {usersProblem = Just e}) (setAdministrator u granted)
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

    -- Ask for a change. Done, the shell is told, and the controls stay
    -- disabled until the directory has been read again ('Receive'); refused,
    -- why is said in place, and the controls are given back.
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
          , -- Who is not in a group has changed: the first is chosen again.
            chosen = mempty
          }

-- | A user as the list of whom to add names them.
userLabel :: User -> Text
userLabel u = u.displayName <> " (" <> u.login <> ")"

-- | How many members a group has, for a person to read.
counted :: Int -> Text
counted = \case
  0 -> "no members"
  1 -> "1 member"
  n -> show n <> " members"
