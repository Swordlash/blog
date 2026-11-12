{-# LANGUAGE QuasiQuotes #-}

-- | The permissions view: who may do what on a space (decision 9 of the
-- plan). The space's view shows it, when opened, to someone who may
-- administer the space. It shows whether the space is public; for a
-- subspace, whether it is private from the space above it
-- ('Wiki.Core.Space.sealed'), in which case the grants it inherits are
-- shown as not counting in it; the grants
-- on it, which can be revoked; the grants it inherits from the spaces
-- above it, with the space they are on, where they are changed; and a
-- form that grants a user or a group a permission on it.
--
-- Everything it shows comes from one read ('spaceAccess'): at once where
-- the backend can answer at once, and otherwise in its initializer, which
-- shows a loading state meanwhile (decision 18 of the plan). After a
-- change it tells the space's view, which tells the shell ('Changed'). The
-- shell reloads who is signed in (their own grants may be the ones
-- changed, and with them what the rules let them see and do) and
-- increments the context's revision, which makes this view fetch the
-- space's grants again. Until then its controls stay disabled, so that
-- nothing is requested twice before the change is visible.
--
-- A grant whose revocation would leave the current user unable to
-- administer the space is not offered for revocation, with a note why
-- ('keepsAdministering'). The backend would allow it, but it would lock
-- them out of this section at once, which is more likely a slip than
-- intended; another administrator of the space, or of the wiki, can do it.
-- The wiki's administrators, who may administer every space whatever its
-- grants, may revoke every grant.
--
-- It also encrypts a space, and turns an encrypted space's encryption off
-- ("Wiki.Core.Space"'s 'Conversion'): a space with nothing written in it
-- at once, a space that has pages page by page in this browser
-- ('convertNext'), showing how many pages are left. A conversion that
-- stopped (the tab closed, a refusal) is continued from here, by an
-- administrator of the space who holds its key. What cannot be converted
-- is said before anything starts ('conversionOf').
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
import Wiki.Api.Encrypted (ConversionInfo (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError (..))
import Wiki.App.Backend.Encrypted (MonadEncryption (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (GroupId (..), UserId (..))
import Wiki.Core.Permission (SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..), keepsAdministering, sealedChain)
import Wiki.Core.Space (Conversion (..), Entry (..), Space (conversion, encryption, entry, id, name, parent, public, sealed), gateOf)
import Wiki.Core.User (Group (..), Login (..), User (..))

-- | The permissions view's input: the space, as the space's view has it.
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
  -- ^ Which of the users and groups ('candidates') is selected to be
  -- granted.
  , what :: SpacePermission
  -- ^ The permission selected to grant them.
  , busy :: Bool
  -- ^ A change has been requested, and the grants not fetched again
  -- since.
  , problem :: Maybe WikiError
  , confirming :: Bool
  -- ^ "Encrypt this space…" was pressed, and waits for its confirmation.
  , stopping :: Bool
  -- ^ "Stop" was pressed while this browser converts the space's pages:
  -- it stops once the page it is on is done.
  , confirmingOff :: Bool
  -- ^ "Turn encryption off…" was pressed, and waits for its confirmation.
  , conversionInfo :: Maybe ConversionInfo
  -- ^ The space's conversion, or what keeps one from starting.
  , converting :: Maybe Int
  -- ^ While this browser converts the space's pages, how many are left.
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | Followed (Follow Route)
  | TogglePublic
  | ToggleSealed
  | ToggleEntry
  | AskEncrypt Bool
  | Encrypt
  | AskDecrypt Bool
  | Decrypt
  | Continue
  | Stop
  | TurnBack
  | ChooseWho Int
  | ChooseWhat Int
  | Grant
  | Revoke SpaceGrant

component :: forall query m. (MonadLoad m, MonadEncryption m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- Read here when the backend answers at once, as the other views
          -- read their data; otherwise in 'Initialize'.
          loaded <- maybe Loading (either Failed Ready) <$> atOnce (spaceAccess input.space.id)
          pure State {input, loaded, who = 0, what = View, busy = False, problem = Nothing, confirming = False, stopping = False, confirmingOff = False, conversionInfo = Nothing, converting = Nothing}
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
          {% if isNothing space.encryption %}
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
          {% end %}
          {% if isJust space.parent %}
            <div class="permissions-sealed">
              <button
                type="button"
                role="switch"
                class="switch sealed-switch"
                aria-checked={{ ariaBool space.sealed }}
                aria-label={{ space.name <> " is private from the space above it" }}
                disabled={{ st.busy }}
                onClick={{ const ToggleSealed }}
              >
                Make private
              </button>
              <p class="permissions-intro">{{ sealedText }}</p>
            </div>
          {% end %}
          {% if isJust space.conversion %}
            <div class="permissions-conversion">
              {% for n in toList st.converting %}
                <p class="permissions-intro conversion-progress" role="status">{{ conversionWord }}: {{ pagesLeft n }} left. Keep this page open until it is done.</p>
                <button type="button" class="conversion-stop" disabled={{ st.stopping }} onClick={{ const Stop }}>Stop</button>
              {% end %}
              {% if isNothing st.converting %}
                <p class="permissions-intro conversion-stopped">{{ conversionWord }} stopped, with {{ pagesLeft leftNow }} left: nothing else can be written in this space until it is done. An administrator of the space who holds its key continues it here, or turns it back.</p>
                <p class="permissions-intro conversion-back-explained">Turning it back converts the pages done so far back, and leaves the others as they are: the space ends as it began. Pages encrypted so far keep the new addresses they got; their links by id keep working.</p>
                <button type="button" class="primary conversion-continue" disabled={{ st.busy }} onClick={{ const Continue }}>Continue</button>
                <button type="button" class="conversion-reverse" disabled={{ st.busy }} onClick={{ const TurnBack }}>Stop and turn back</button>
              {% end %}
            </div>
          {% end %}
          {% if isJust space.encryption && isNothing space.conversion %}
            <div class="permissions-encrypted">
              <p class="permissions-intro encrypted-note">Encrypted: the titles and texts of this space's pages, and their histories, are encrypted in its members' browsers, and the server cannot read them. Its name stays readable, to whoever sees it in the list of spaces. Each reader granted here gets the space's key from a member's browser, the next time a member opens the space.</p>
              <p class="permissions-intro encrypted-removal">Removing someone here gives the space a new key: your browser makes it at once if you hold the key, or another administrator's does when they next open the space, and until then nothing more can be written in it. Whoever was removed and kept the old key can still read what was written before, with a copy of what the server stores, but nothing written after.</p>
              <div class="permissions-entry">
                <button
                  type="button"
                  role="switch"
                  class="switch entry-switch"
                  aria-checked={{ ariaBool (space.entry == ConfirmEach) }}
                  aria-label={{ space.name <> " asks for a passkey or your password each time it is opened" }}
                  disabled={{ st.busy }}
                  onClick={{ const ToggleEntry }}
                >
                  Ask for a passkey or your password each time this space is opened.
                </button>
                <p class="permissions-intro entry-explained">This guards against someone using your unlocked computer. It does not stop someone who opens the browser's developer tools on a device where your keys are unlocked. It covers the spaces below this one too.</p>
                {% if askedAbove %}
                  <p class="permissions-intro entry-above">A space above this one asks already, for this one too.</p>
                {% end %}
              </div>
              {% if st.confirmingOff %}
                <p class="permissions-intro decrypt-explained">Turning encryption off decrypts this space's pages and those of the spaces below it in your browser, one by one, with their histories, comments and attachments, and gives them to the server as plain text: it can then read, search and export them, as any space's. Until it is done nothing else can be written in these spaces; if it stops, an administrator who holds the key continues it here. At the end the spaces' keys are deleted.</p>
                {{ refusalsView cannotDecrypt }}
                <button type="button" class="primary decrypt-confirm" disabled={{ st.busy || not (null cannotDecrypt) }} onClick={{ const Decrypt }}>Turn encryption off</button>
                <button type="button" class="decrypt-cancel" disabled={{ st.busy }} onClick={{ const (AskDecrypt False) }}>Cancel</button>
              {% else %}
                <button type="button" class="decrypt-space" disabled={{ st.busy }} onClick={{ const (AskDecrypt True) }}>Turn encryption off…</button>
              {% end %}
            </div>
          {% end %}
          {% if encryptable %}
            <div class="permissions-encrypt">
              {% if st.confirming %}
                <p class="permissions-intro encrypt-explained">Encrypting this space encrypts the titles and texts of its pages, and their histories, in its members' browsers: the server cannot read them, search them, export them, or show them in feeds or previews. Their comments and attachments are encrypted too, and so are the spaces below it, each with a key of its own. The space's name stays readable. Its members need the wiki's HTTPS address and their keys (your account's security) to read it. Its encryption can be turned off again here.</p>
                <p class="permissions-intro encrypt-pages">A space that has pages is encrypted in your browser, page by page: until it is done nothing else can be written in it, and if it stops, an administrator who holds the key continues it here. Each page gets a new address (its link by id keeps working). What was plain is then gone from the wiki's database, but not from the backups made before: they keep the plain text, and the files of the attachments they name, until they are pruned. Nothing deletes a backup.</p>
                {{ refusalsView cannotEncrypt }}
                <button type="button" class="primary encrypt-confirm" disabled={{ st.busy || not (null cannotEncrypt) }} onClick={{ const Encrypt }}>Encrypt</button>
                <button type="button" class="encrypt-cancel" disabled={{ st.busy }} onClick={{ const (AskEncrypt False) }}>Cancel</button>
              {% else %}
                <button type="button" class="encrypt-space" disabled={{ st.busy }} onClick={{ const (AskEncrypt True) }}>Encrypt this space…</button>
                <p class="permissions-intro">Only a private space can be encrypted.</p>
              {% end %}
            </div>
          {% end %}
          {{ errorView <$> st.problem }}
          {{ body }}
        </section>
      |]
      where
        space = st.input.space
        -- A private space that is not public may be encrypted: a top-level
        -- space, or a subspace made private from its parent. The server
        -- says why one with pages written in it may not.
        encryptable = isNothing space.encryption && isNothing space.conversion && not space.public && (space.sealed || isNothing space.parent)
        -- Whether a space above this one asks each time, which covers it.
        askedAbove = maybe False (/= space.id) (gateOf st.input.context.spaces space.id)
        cannotEncrypt = maybe [] (\i -> i.cannotEncrypt) st.conversionInfo
        cannotDecrypt = maybe [] (\i -> i.cannotDecrypt) st.conversionInfo
        leftNow = maybe 0 (\i -> length i.left) st.conversionInfo
        conversionWord :: Text
        conversionWord = case space.conversion of
          Just Decrypting -> "Turning its encryption off"
          _ -> "Encrypting its pages"
        pagesLeft :: Int -> Text
        pagesLeft n = show n <> (if n == 1 then " page" else " pages")
        publicText :: Text
        publicText
          | space.public = "Anyone may read this space and its subspaces, signed in or not. The grants below say who may do more."
          | otherwise = "Only the wiki's administrators, and those granted it below, may read this space."
        sealedText :: Text
        sealedText
          | space.sealed = "Private: readers of the parent space do not see this space, only those granted here. The grants above do not count in it."
          | otherwise = "Make private: readers of the parent space do not see this space, only those granted here."
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready access -> accessView st access

    -- Why a conversion cannot start now, as the server says.
    refusalsView :: [Text] -> H.ComponentHTML Action Empty m
    refusalsView = \case
      [] -> HH.text ""
      why -> [hh|<ul class="conversion-refusals" role="alert">{% for w in why %}<li>{{ w }}</li>{% end %}</ul>|]

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
        <tr class="grant-row{% if inherited %} grant-inherited{% end %}{% if cut %} grant-cut{% end %}" data-subject={{ subjectKey access g.subject }} data-permission={{ permissionKey g.permission }}>
          <td class="grant-who">{{ subjectName access g.subject }}</td>
          <td class="grant-what">{{ permissionName g.permission }}</td>
          <td class="grant-where">{{ origin }}</td>
          <td class="grant-revoke-cell">
            {% if cut %}
              <span class="admin-note grant-cut-note">Does not count here: this space is private from the spaces above it.</span>
            {% elif inherited %}
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
        -- A grant above the last sealed space of the chain does not count
        -- in this space ('sealedChain').
        cut = g.space `notElem` map (\s -> s.id) (sealedChain (chainOf ctx space.id))
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
      -- The shell has reloaded the wiki after a change, by this section or
      -- another: fetch the grants again.
      Receive input -> do
        old <- gets (\st -> (st.input.context.revision, st.input.space.id))
        modify (\st -> st {input})
        when (old /= (input.context.revision, input.space.id)) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      TogglePublic -> do
        space <- gets (\st -> st.input.space)
        change (void <$> setSpacePublic space.id (not space.public))
      ToggleSealed -> do
        space <- gets (\st -> st.input.space)
        change (void <$> setSpaceSealed space.id (not space.sealed))
      ToggleEntry -> do
        space <- gets (\st -> st.input.space)
        change (void <$> setEntry space.id (if space.entry == ConfirmEach then EnterAtOnce else ConfirmEach))
      AskEncrypt asking -> modify (\st -> st {confirming = asking})
      -- A space with nothing written in it is encrypted at once; one that
      -- has pages, page by page. The server says which it is
      -- ('ConversionInfo''s @nothingWritten@).
      Encrypt -> do
        space <- gets (\st -> st.input.space)
        untouched <- gets (\st -> maybe False (\i -> i.nothingWritten) st.conversionInfo)
        modify (\st -> st {busy = True, problem = Nothing})
        if untouched
          then
            encryptSpace space.id >>= \case
              Right _ -> modify (\st -> st {confirming = False}) >> H.raise (Changed Nothing)
              Left e -> modify (\st -> st {busy = False, problem = Just e})
          else
            startConversion space.id Encrypting >>= \case
              Left e -> modify (\st -> st {busy = False, problem = Just e})
              Right info -> modify (\st -> st {confirming = False}) >> convertAll (length info.left)
      AskDecrypt asking -> modify (\st -> st {confirmingOff = asking})
      Decrypt -> do
        space <- gets (\st -> st.input.space)
        modify (\st -> st {busy = True, problem = Nothing})
        startConversion space.id Decrypting >>= \case
          Left e -> modify (\st -> st {busy = False, problem = Just e})
          Right info -> modify (\st -> st {confirmingOff = False}) >> convertAll (length info.left)
      Continue -> do
        modify (\st -> st {busy = True, problem = Nothing})
        convertAll =<< gets (\st -> maybe 0 (\i -> length i.left) st.conversionInfo)
      Stop -> modify (\st -> st {stopping = True})
      -- The conversion goes the other way over the pages done so far.
      TurnBack -> do
        space <- gets (\st -> st.input.space)
        modify (\st -> st {busy = True, problem = Nothing})
        reverseConversion space.id >>= \case
          Left e -> modify (\st -> st {busy = False, problem = Just e})
          Right info
            | isNothing info.running -> H.raise (Changed Nothing)
            | otherwise -> convertAll (length info.left)
      ChooseWho n -> modify (\st -> st {who = n})
      ChooseWhat n -> for_ (atMay permissions n) $ \p -> modify (\st -> st {what = p})
      Grant ->
        get >>= \st -> case st.loaded of
          Ready access -> for_ (atMay (candidates access) st.who) $ \subject ->
            change (setSpaceGrant st.input.space.id subject st.what True)
          _ -> pass
      Revoke g -> change (setSpaceGrant g.space g.subject g.permission False)

    -- Request a change. If it is made, the space's view is told, and the
    -- controls stay disabled until the grants have been fetched again
    -- ('Receive'). If it is refused, the reason is shown in place, and the
    -- controls are enabled again.
    change :: H.HalogenM State Action Empty ViewOutput m (Either WikiError ()) -> H.HalogenM State Action Empty ViewOutput m ()
    change request = do
      modify (\st -> st {busy = True, problem = Nothing})
      request >>= \case
        Left e -> modify (\st -> st {busy = False, problem = Just e})
        Right () -> H.raise (Changed Nothing)

    -- Convert the space's pages one by one, saying how many are left, until
    -- none is or one is refused; then the shell reads the space again.
    convertAll :: Int -> H.HalogenM State Action Empty ViewOutput m ()
    convertAll left = do
      modify (\st -> st {converting = Just left})
      sid <- gets (\st -> st.input.space.id)
      convertNext sid >>= \case
        Right 0 -> modify (\st -> st {converting = Nothing}) >> H.raise (Changed Nothing)
        Right n ->
          gets (\st -> st.stopping) >>= \case
            True -> modify (\st -> st {converting = Nothing, stopping = False}) >> H.raise (Changed Nothing)
            False -> convertAll n
        Left e -> do
          modify (\st -> st {converting = Nothing, busy = False, problem = Just e})
          H.raise (Changed Nothing)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      sid <- gets (\st -> st.input.space.id)
      result <- spaceAccess sid
      info <- rightToMaybe <$> conversionOf sid
      modify (\st -> st {loaded = either Failed Ready result, busy = isJust st.converting, conversionInfo = info})

-- | Who a permission may be granted to: every user, then every group.
candidates :: SpaceAccess -> [Subject]
candidates access = map (\u -> SubjectUser u.id) access.users <> map (\g -> SubjectGroup g.id) access.groups

-- | Every permission on a space, as the form offers them.
permissions :: [SpacePermission]
permissions = [minBound .. maxBound]

-- | Who a grant is for, in words for a person to read: a user by name and
-- login, a group by name, and one that no longer exists by its id.
subjectName :: SpaceAccess -> Subject -> Text
subjectName access = \case
  SubjectUser u -> maybe u.text (\x -> x.displayName <> " (" <> x.login.text <> ")") (findUser access u)
  SubjectGroup g -> maybe g.text (\x -> "Group " <> x.name) (findGroup access g)

-- | Who a grant is for, as a test or a stylesheet identifies it: a user's
-- login, a group's name.
subjectKey :: SpaceAccess -> Subject -> Text
subjectKey access = \case
  SubjectUser u -> maybe u.text (\x -> x.login.text) (findUser access u)
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

-- | A permission as the form offers it, with what it includes.
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
