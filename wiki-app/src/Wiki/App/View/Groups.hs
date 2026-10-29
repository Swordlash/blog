{-# LANGUAGE QuasiQuotes #-}

-- | The administration's section on the wiki's groups (decision 11 of the
-- plan): sets of users, to grant permissions on spaces to at once. Each
-- group is listed with its members. Groups can be created, renamed and
-- deleted, and users can be added to them and removed from them. It is one
-- component over the administration's backend ("Wiki.App.Backend.Admin"),
-- the same on the demo's wiki and on the server's two listeners. The shell
-- shows it only to someone who may administer the wiki.
--
-- Everything it shows comes from one read ('directory'), since every group
-- offers every user who is not in it to add: at once where the backend can
-- answer at once, and otherwise in its initializer, which shows a loading
-- state meanwhile (decision 18 of the plan). After a change it tells the
-- shell ('Changed'), which reloads who is signed in (a change of
-- membership may change what they may do) and increments the context's
-- revision, which makes this view fetch the directory again. Until then
-- its controls stay disabled, so that nothing is requested twice before
-- the change is visible.
--
-- Deleting a group asks for confirmation first, in place, as deleting a
-- space does.
module Wiki.App.View.Groups
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
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Common
import Wiki.Core.Id (GroupId, UserId)
import Wiki.Core.User (Group (..), Login (..), User (..))

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready Directory

-- | What is open in the section, besides the list.
data Editing
  = Idle
  | -- | The form renaming a group, with the name typed so far.
    Renaming GroupId Text
  | -- | Asking for confirmation to delete a group.
    ConfirmingDelete GroupId

data State = State
  { input :: Input
  , loaded :: Loaded
  , editing :: Editing
  , newGroup :: Text
  -- ^ The name typed for a new group.
  , chosen :: Map GroupId Int
  -- ^ For each group, which of the users not in it is selected to be
  -- added; the first unless another has been selected.
  , busy :: Bool
  -- ^ A change has been requested, and the directory not fetched again
  -- since.
  , problem :: Maybe WikiError
  }

data Action
  = Initialize
  | Receive Input
  | Retry
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
          pure State {input, loaded, editing = Idle, newGroup = "", chosen = mempty, busy = False, problem = Nothing}
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
        <div class="admin-section admin-groups">
          <p class="admin-intro">
            Sets of users, to grant permissions on spaces to at once: a member of a group may
            do what the group may.
          </p>
          {{ body }}
        </div>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready d -> groupsView st d

    groupsView :: State -> Directory -> H.ComponentHTML Action Empty m
    groupsView st d =
      [hh|
        <div class="admin-groups-list">
          {{ errorView <$> st.problem }}
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
      -- The shell has reloaded the wiki after a change, by this section or
      -- another view: fetch the directory again.
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      TypedNewGroup t -> modify (\st -> st {newGroup = t})
      CreateGroup -> do
        name <- gets (\st -> st.newGroup)
        change (\st -> st {newGroup = ""}) (void <$> createGroup name)
      StartRenaming g -> modify (\st -> st {editing = Renaming g.id g.name, problem = Nothing})
      TypedName t -> modify $ \st -> case st.editing of
        Renaming gid _ -> st {editing = Renaming gid t}
        _ -> st
      Rename ->
        gets (\st -> st.editing) >>= \case
          Renaming gid name -> change (\st -> st {editing = Idle}) (void <$> renameGroup gid name)
          _ -> pass
      AskDelete gid -> modify (\st -> st {editing = ConfirmingDelete gid, problem = Nothing})
      Delete gid -> change (\st -> st {editing = Idle}) (deleteGroup gid)
      CancelEditing -> modify (\st -> st {editing = Idle})
      Choose gid n -> modify (\st -> st {chosen = Map.insert gid n st.chosen})
      Add gid ->
        get >>= \st -> case st.loaded of
          Ready d -> do
            let inGroup = Map.findWithDefault mempty gid d.membership
                others = filter (\u -> not (u.id `Set.member` inGroup)) d.users
            for_ (atMay others (Map.findWithDefault 0 gid st.chosen)) $ \u ->
              change identity (addMember gid u.id)
          _ -> pass
      Remove gid u -> change identity (removeMember gid u)

    -- Request a change. If it is made, the shell is told, and the controls
    -- stay disabled until the directory has been fetched again ('Receive').
    -- If it is refused, the reason is shown in place, and the controls are
    -- enabled again.
    change
      :: (State -> State)
      -> H.HalogenM State Action Empty ViewOutput m (Either WikiError ())
      -> H.HalogenM State Action Empty ViewOutput m ()
    change done request = do
      modify (\st -> st {busy = True, problem = Nothing})
      request >>= \case
        Left e -> modify (\st -> st {problem = Just e, busy = False})
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

-- | A user as the list of users to add names them.
userLabel :: User -> Text
userLabel u = u.displayName <> " (" <> u.login.text <> ")"

-- | How many members a group has, in words for a person to read.
counted :: Int -> Text
counted = \case
  0 -> "no members"
  1 -> "1 member"
  n -> show n <> " members"
