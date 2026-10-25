{-# LANGUAGE QuasiQuotes #-}

-- | Who may do what on a space (decision 9 of the plan), shown in the
-- space's view to whoever may administer it, when they open it: whether
-- the space is public, the grants on it, which can be revoked, the grants
-- it inherits from the spaces above it, shown with the space they are on
-- and changed there, and a form that grants a user or a group a permission
-- on it.
--
-- What it shows it reads in one go ('spaceAccess'), at once where the
-- backend can answer at once, and otherwise in its initializer, saying
-- meanwhile that it is loading (decision 18). After a change it tells the
-- space's view, which tells the shell ('Changed'): the shell reloads who is
-- signed in (whose own grants may be the ones changed, and with them what
-- the rules let them see and do) and counts up the context's revision, on
-- which this reads the space's grants again; until then its controls stay
-- disabled, so that nothing is asked twice of a wiki that has not been read
-- back.
--
-- A grant whose revocation would leave the current user unable to
-- administer the space is not offered to revoke, with a note why
-- ('keepsAdministering'): the backend would allow it, but it would close
-- this section on them at once, which is more likely a slip than a wish;
-- another administrator of the space, or of the wiki, can do it. The
-- wiki's administrators, who may administer every space whatever its
-- grants, may revoke every one.
module Wiki.App.View.Permissions
  ( Input (..)
  , component
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (GroupId (..), UserId (..))
import Wiki.Core.Permission (SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..), keepsAdministering)
import Wiki.Core.Space (Space (id, name, public))
import Wiki.Core.User (Group (..), User (..))

-- | The space, as the space's view has it.
data Input = Input
  { context :: Context
  , space :: Space
  }

data Loaded
  = Loading
  | Failed WikiError
  | Ready SpaceAccess

data State = State
  { input :: Input
  , loaded :: Loaded
  , who :: Int
  -- ^ Which of the users and groups ('candidates') is chosen to grant to.
  , what :: SpacePermission
  -- ^ What is chosen to grant them.
  , busy :: Bool
  -- ^ A change has been asked for and the grants not read again since.
  , problem :: Maybe WikiError
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | Followed (Follow Route)
  | TogglePublic
  | ChooseWho Int
  | ChooseWhat Int
  | Grant
  | Revoke SpaceGrant

component :: forall query m. (MonadLoad m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- Read here when the backend answers at once, as the other views
          -- read what they show; otherwise in 'Initialize'.
          loaded <- maybe Loading (either Failed Ready) <$> atOnce (spaceAccess input.space.id)
          pure State {input, loaded, who = 0, what = View, busy = False, problem = Nothing}
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
        <section class="space-permissions" aria-label="Permissions">
          <h2>Permissions</h2>
          <div class="permissions-public">
            <button
              type="button"
              role="switch"
              class="switch public-switch"
              aria-checked={{ ariaBool space.public }}
              aria-label={{ space.name <> " is public" }}
              disabled={{ st.busy }}
              onClick={{ const TogglePublic }}
            >
              {{ if space.public then "Public" else "Private" :: Text }}
            </button>
            <p class="permissions-intro">{{ publicText }}</p>
          </div>
          {{ errorView <$> st.problem }}
          {{ body }}
        </section>
      |]
      where
        space = st.input.space
        publicText :: Text
        publicText
          | space.public = "Anyone may read this space and its subspaces, signed in or not. The grants below say who may do more."
          | otherwise = "Only the wiki's administrators, and those granted it below, may read this space."
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready access -> accessView st access

    accessView :: State -> SpaceAccess -> H.ComponentHTML Action Empty m
    accessView st access =
      [hh|
        <div class="permissions-grants">
          {% if null access.grants %}
            <p class="empty">Nobody is granted anything on this space, nor on a space above it.</p>
          {% else %}
            <table class="grant-table">
              <thead>
                <tr>
                  <th scope="col">Who</th>
                  <th scope="col">May</th>
                  <th scope="col">Granted on</th>
                  <th scope="col"><span class="visually-hidden">Revoke</span></th>
                </tr>
              </thead>
              <tbody>
                {% for g in access.grants %}
                  {{ grantRow st access g }}
                {% end %}
              </tbody>
            </table>
          {% end %}
          {{ grantForm st access }}
        </div>
      |]

    grantRow :: State -> SpaceAccess -> SpaceGrant -> H.ComponentHTML Action Empty m
    grantRow st access g =
      [hh|
        <tr class="grant-row{% if inherited %} grant-inherited{% end %}" data-subject={{ subjectKey access g.subject }} data-permission={{ permissionKey g.permission }}>
          <td class="grant-who">{{ subjectName access g.subject }}</td>
          <td class="grant-what">{{ permissionName g.permission }}</td>
          <td class="grant-where">{{ origin }}</td>
          <td class="grant-revoke-cell">
            {% if inherited %}
              <span class="admin-note">Inherited: changed there.</span>
            {% elif locks %}
              <span class="admin-note grant-self">That is how you administer this space: another administrator can change it.</span>
            {% else %}
              <button
                type="button"
                class="grant-revoke"
                aria-label={{ "Revoke " <> permissionName g.permission <> " from " <> subjectName access g.subject }}
                disabled={{ st.busy }}
                onClick={{ const (Revoke g) }}
              >
                Revoke
              </button>
            {% end %}
          </td>
        </tr>
      |]
      where
        ctx = st.input.context
        space = st.input.space
        inherited = g.space /= space.id
        locks = not (keepsAdministering (principalOf ctx) (grantsOf ctx) (chainOf ctx space.id) g)
        origin = case find (\s -> s.id == g.space) (chainOf ctx space.id) of
          Just s
            | s.id == space.id -> [hh|<span>This space</span>|]
            | mayView ctx s.id -> Router.link ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) [] [HH.text s.name]
            | otherwise -> HH.text s.name
          Nothing -> HH.text "A space above this one"

    grantForm :: State -> SpaceAccess -> H.ComponentHTML Action Empty m
    grantForm st access =
      [hh|
        <form class="inline-form grant-form" {{ HE.preventingDefault (HE.onSubmit (const Grant)) }}>
          <label class="field">
            <span>Grant</span>
            <select class="grant-who-choice" onSelectedIndexChange={{ ChooseWho }}>
              {% for (n, c) in zip [0 :: Int ..] (candidates access) %}
                <option selected={{ n == st.who }}>{{ subjectName access c }}</option>
              {% end %}
            </select>
          </label>
          <label class="field">
            <span>Permission</span>
            <select class="grant-what-choice" onSelectedIndexChange={{ ChooseWhat }}>
              {% for p in permissions %}
                <option selected={{ p == st.what }}>{{ permissionChoice p }}</option>
              {% end %}
            </select>
          </label>
          <button type="submit" class="primary" disabled={{ st.busy || null (candidates access) }}>Grant</button>
        </form>
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
      -- The shell has reloaded the wiki after a change, this section's or
      -- another's: read the grants again.
      Receive input -> do
        old <- gets (\st -> (st.input.context.revision, st.input.space.id))
        modify (\st -> st {input})
        when (old /= (input.context.revision, input.space.id)) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      TogglePublic -> do
        space <- gets (\st -> st.input.space)
        change (void <$> setSpacePublic space.id (not space.public))
      ChooseWho n -> modify (\st -> st {who = n})
      ChooseWhat n -> for_ (atMay permissions n) $ \p -> modify (\st -> st {what = p})
      Grant ->
        get >>= \st -> case st.loaded of
          Ready access -> for_ (atMay (candidates access) st.who) $ \subject ->
            change (setSpaceGrant st.input.space.id subject st.what True)
          _ -> pass
      Revoke g -> change (setSpaceGrant g.space g.subject g.permission False)

    -- Ask for a change. Done, the space's view is told, and the controls
    -- stay disabled until the grants have been read again ('Receive');
    -- refused, why is said in place, and the controls are given back.
    change :: H.HalogenM State Action Empty ViewOutput m (Either WikiError ()) -> H.HalogenM State Action Empty ViewOutput m ()
    change request = do
      modify (\st -> st {busy = True, problem = Nothing})
      request >>= \case
        Left e -> modify (\st -> st {busy = False, problem = Just e})
        Right () -> H.raise (Changed Nothing)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      sid <- gets (\st -> st.input.space.id)
      result <- spaceAccess sid
      modify (\st -> st {loaded = either Failed Ready result, busy = False})

-- | Whom a permission may be granted to: every user, then every group.
candidates :: SpaceAccess -> [Subject]
candidates access = map (\u -> SubjectUser u.id) access.users <> map (\g -> SubjectGroup g.id) access.groups

-- | Every permission on a space, as the form offers them.
permissions :: [SpacePermission]
permissions = [minBound .. maxBound]

-- | Whom a grant is for, for a person to read: a user by name and login, a
-- group by name, and one that is no longer there by its id.
subjectName :: SpaceAccess -> Subject -> Text
subjectName access = \case
  SubjectUser u -> maybe u.text (\x -> x.displayName <> " (" <> x.login <> ")") (findUser access u)
  SubjectGroup g -> maybe g.text (\x -> "Group " <> x.name) (findGroup access g)

-- | Whom a grant is for, as a test or a stylesheet picks it out: a user's
-- login, a group's name.
subjectKey :: SpaceAccess -> Subject -> Text
subjectKey access = \case
  SubjectUser u -> maybe u.text (\x -> x.login) (findUser access u)
  SubjectGroup g -> maybe g.text (\x -> x.name) (findGroup access g)

findUser :: SpaceAccess -> UserId -> Maybe User
findUser access u = Map.lookup u (Map.fromList [(x.id, x) | x <- access.users])

findGroup :: SpaceAccess -> GroupId -> Maybe Group
findGroup access g = find (\x -> x.id == g) access.groups

permissionName :: SpacePermission -> Text
permissionName = \case
  View -> "View"
  Edit -> "Edit"
  AdministerSpace -> "Administer"

-- | A permission as the form offers it, with what it brings with it.
permissionChoice :: SpacePermission -> Text
permissionChoice = \case
  View -> "View: read its pages"
  Edit -> "Edit: also write its pages"
  AdministerSpace -> "Administer: also its permissions, moving and deleting it"

permissionKey :: SpacePermission -> Text
permissionKey = \case
  View -> "view"
  Edit -> "edit"
  AdministerSpace -> "administer"
