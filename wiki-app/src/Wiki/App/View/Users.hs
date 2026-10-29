{-# LANGUAGE QuasiQuotes #-}

-- | The administration's section on the wiki's users (WP5.25 of
-- docs/PLAN.md): a table of the users, one page at a time, read from the
-- backend a page at a time ('userPage'), so that a wiki of thousands of
-- users is never read whole. Above the table are a search box (over the
-- login and the display name), a filter (everyone, the administrators, the
-- disabled accounts) and the form for a new user; under it the count
-- ("1–25 of 312"), the pages, and how many users a page holds.
--
-- The search, the filter and the page are in the address (the route's
-- 'UserListing'), so that a page of users can be kept and shared: the box
-- writes the words into the address after a pause in typing, and the page
-- links are ordinary links. How many users a page holds (25, 50 or 100) is
-- the reader's own choice, kept in the browser's local storage.
--
-- Each row shows the user's name and login, how they sign in, their badges
-- (administrator, creates spaces, second factor, disabled), and one button,
-- "Manage", which opens the dialog that holds every operation on the user
-- ("Wiki.App.View.UserDialog"). The dialog's changes are saved at once; the
-- table then tells the shell ('Changed'), which reloads who is signed in
-- and increments the context's revision, and the table fetches its page
-- again, which gives the open dialog the user as they are now.
--
-- The page is read as every view reads its data: at once where the backend
-- answers at once, and otherwise in the initializer. While a later page is
-- fetched, the table shows the page before it, dimmed, so that nothing
-- moves until the new rows arrive.
module Wiki.App.View.Users
  ( Input (..)
  , component
  , pageWindow
  , countText
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.List (nub)
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.JSBits (inBrowser)
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Api.Account (Account (..), NewAccount (..))
import Wiki.Api.Admin (UserPage (..), UserQuery (..), UserSummary (..), userPageSizes)
import Wiki.App.Backend (MonadLoad (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Route (AdminSection (Users), Route (..), UserFilter (..), UserListing (..))
import Wiki.App.View.Common
import Wiki.App.View.UserDialog qualified as UserDialog
import Wiki.Core.Id (UserId)
import Wiki.Core.User (Login (..), Password (..), User (..))

-- | The section's input: the shell's context, and which users the address
-- asks for.
data Input = Input
  { context :: Context
  , listing :: UserListing
  }

-- | The dialog, by the user it is open for.
type Slots = ("dialog" .== H.Slot (Const Void) UserDialog.Output UserId)

data Loaded
  = Loading
  | Failed WikiError
  | Ready UserPage

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
  , size :: Int
  -- ^ How many users a page holds.
  , loaded :: Loaded
  , fetching :: Bool
  -- ^ Another page is being fetched while 'loaded' is shown.
  , typed :: Text
  -- ^ What the search box holds.
  , pending :: Maybe H.ForkId
  -- ^ The thread that writes the typed words into the address after a
  -- pause in typing.
  , managing :: Maybe UserSummary
  -- ^ The user the dialog is open for, as last fetched.
  , creating :: Bool
  -- ^ Whether the form for a new user is open.
  , newUser :: NewUser
  , busy :: Bool
  , problem :: Maybe WikiError
  , told :: Maybe Text
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | Followed (Follow Route)
  | Typed Text
  | SearchNow
  | ChoseFilter Int
  | ChoseSize Int
  | Manage UserSummary
  | FromDialog UserDialog.Output
  | ToggleCreating
  | TypedLogin Text
  | TypedDisplayName Text
  | TypedPassword Text
  | TypedEmail Text
  | ChoseAdministrator Bool
  | CreateUser

component :: forall query m. (MonadAdmin m, MonadLoad m, MonadBrowserDOM m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          size <- readPageSize
          -- Read here when the backend answers at once, so that the first
          -- render is the page a prerender or the server shows; otherwise
          -- in 'Initialize'.
          loaded <- maybe Loading (either Failed Ready) <$> atOnce (userPage (queryOf size input.listing))
          pure
            State
              { input
              , size
              , loaded
              , fetching = False
              , typed = input.listing.search
              , pending = Nothing
              , managing = Nothing
              , creating = False
              , newUser = noNewUser
              , busy = False
              , problem = Nothing
              , told = Nothing
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
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <div class="admin-section admin-users">
          <p class="admin-intro">
            Everyone who can sign in. Manage a user to change what they may do, how they sign in
            and their groups.
          </p>
          <div class="users-toolbar">
            <form class="users-search" role="search" {{ HE.preventingDefault (HE.onSubmit (const SearchNow)) }}>
              <input
                type="search"
                class="users-search-input"
                placeholder="Search by name or login"
                aria-label="Search the users by name or login"
                autocomplete="off"
                spellcheck="false"
                value={{ st.typed }}
                onValueInput={{ Typed }}
              >
            </form>
            <select class="users-filter" aria-label="Which users to show" onSelectedIndexChange={{ ChoseFilter }}>
              {% for f in [minBound .. maxBound] %}
                <option selected={{ f == listing.only }}>{{ filterLabel f }}</option>
              {% end %}
            </select>
            {% if creates %}
              <button type="button" class="user-create-open" aria-expanded={{ ariaBool st.creating }} onClick={{ const ToggleCreating }}>New user</button>
            {% end %}
          </div>
          {% if st.creating && creates %}
            {{ newUserForm st }}
          {% end %}
          {% if not creates && isReady %}
            {{ consoleNote }}
          {% end %}
          {{ errorView <$> st.problem }}
          {% for t in maybeToList st.told %}
            <p class="admin-told" role="status">{{ t }}</p>
          {% end %}
          {{ body }}
          {{ dialog }}
        </div>
      |]
      where
        listing = st.input.listing
        (creates, isReady) = case st.loaded of
          Ready p -> (p.adminCreatesPasswordAccounts, True)
          _ -> (False, False)
        body = case st.loaded of
          Loading -> [hh|<div class="users-list users-loading"><p class="loading">Loading…</p></div>|]
          Failed e -> failureView e Retry
          Ready p -> pageView st p
        dialog = case (st.managing, st.loaded) of
          (Just u, Ready p) ->
            Just (HH.slot "dialog" u.user.id UserDialog.component UserDialog.Input {context = st.input.context, user = u, groups = p.groups, mailing = p.mailing} FromDialog)
          _ -> Nothing

    pageView :: State -> UserPage -> H.ComponentHTML Action Slots m
    pageView st p =
      [hh|
        <div class="users-list{% if st.fetching %} users-fetching{% end %}" aria-busy={{ ariaBool st.fetching }}>
          {% if null p.users %}
            <p class="empty users-empty">{{ emptyText }}</p>
          {% else %}
            <div class="table-scroll">
              <table class="user-table">
                <thead>
                  <tr>
                    <th scope="col">User</th>
                    <th scope="col">Signs in</th>
                    <th scope="col"><span class="visually-hidden">Badges</span></th>
                    <th scope="col"><span class="visually-hidden">Actions</span></th>
                  </tr>
                </thead>
                <tbody>
                  {% for u in p.users %}
                    {{ row st u }}
                  {% end %}
                </tbody>
              </table>
            </div>
          {% end %}
          <div class="users-paging">
            <p class="users-count" role="status">{{ countText p }}</p>
            {{ pager st p }}
            <label class="users-page-size">
              <span>Per page</span>
              <select class="users-page-size-select" onSelectedIndexChange={{ ChoseSize }}>
                {% for n in userPageSizes %}
                  <option selected={{ n == st.size }}>{{ show n :: Text }}</option>
                {% end %}
              </select>
            </label>
          </div>
        </div>
      |]
      where
        listing = st.input.listing
        emptyText :: Text
        emptyText
          | not (T.null (T.strip listing.search)) || listing.only /= Everyone = "No user matches."
          | otherwise = "There are no users yet."

    row :: State -> UserSummary -> H.ComponentHTML Action Slots m
    row st u =
      [hh|
        <tr class="user-row{% if u.disabled %} user-disabled{% end %}" data-login={{ u.user.login.text }}>
          <td class="user-who">
            <span class="user-display-name">{{ u.user.displayName }}</span>
            <span class="user-login">{{ u.user.login.text }}</span>
          </td>
          <td class="user-sign-in">{{ UserDialog.signInText st.input.context.session.providers u }}</td>
          <td class="user-badges-cell">{{ UserDialog.userBadges u }}</td>
          <td class="user-actions">
            <button type="button" class="user-manage" aria-haspopup="dialog" aria-label={{ "Manage " <> u.user.displayName }} onClick={{ const (Manage u) }}>Manage</button>
          </td>
        </tr>
      |]

    -- The page links: the first, the one before, a few numbers around the
    -- current one with the first and the last, the one after, and the
    -- last. A link that would lead nowhere is shown disabled.
    pager :: State -> UserPage -> Maybe (H.ComponentHTML Action Slots m)
    pager st p =
      guard (pages > 1)
        $> [hh|
          <nav class="pager" aria-label="Pages of users">
            <ul>
              <li>{{ step "First" "«" 1 }}</li>
              <li>{{ step "Previous" "‹" (current - 1) }}</li>
              {% for n in pageWindow current pages %}
                {% if n == 0 %}
                  <li class="pager-gap" aria-hidden="true">…</li>
                {% elif n == current %}
                  <li><a class="pager-page" aria-current="page" {{ toPage n }}>{{ show n :: Text }}</a></li>
                {% else %}
                  <li><a class="pager-page" {{ toPage n }}>{{ show n :: Text }}</a></li>
                {% end %}
              {% end %}
              <li>{{ step "Next" "›" (current + 1) }}</li>
              <li>{{ step "Last" "»" pages }}</li>
            </ul>
          </nav>
        |]
      where
        listing = st.input.listing
        pages = max 1 ((p.total + st.size - 1) `div` st.size)
        current = min pages (max 1 listing.page)
        toPage n = Router.linkProps st.input.context.router Followed (Admin (Users (UserListing {search = listing.search, page = n, only = listing.only})))
        step :: Text -> Text -> Int -> H.ComponentHTML Action Slots m
        step label arrow n
          | n < 1 || n > pages || n == current =
              [hh|<span class="pager-step" aria-disabled="true" title={{ label }}><span aria-hidden="true">{{ arrow }}</span><span class="visually-hidden">{{ label }}</span></span>|]
          | otherwise =
              [hh|<a class="pager-step" title={{ label }} {{ toPage n }}><span aria-hidden="true">{{ arrow }}</span><span class="visually-hidden">{{ label }}</span></a>|]

    newUserForm :: State -> H.ComponentHTML Action Slots m
    newUserForm st =
      [hh|
        <form class="user-create" aria-label="New user" {{ HE.preventingDefault (HE.onSubmit (const CreateUser)) }}>
          <h2>New user</h2>
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
                placeholder={{ if mailing then "Optional: a link to verify it is mailed there" else "" :: Text }}
                disabled={{ not mailing }}
                value={{ st.newUser.typedEmail }}
                onValueInput={{ TypedEmail }}
              >
              {% if not mailing %}
                <span class="admin-note user-create-email-note">This wiki sends no mail, so an address could not be verified: set up mail in the Server section first.</span>
              {% end %}
            </label>
            <label class="check user-create-administrator">
              <input type="checkbox" checked={{ st.newUser.asAdministrator }} onChecked={{ ChoseAdministrator }}>
              <span>Administrator</span>
            </label>
          </div>
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Create user</button>
            <button type="button" onClick={{ const ToggleCreating }}>Cancel</button>
          </div>
        </form>
      |]
      where
        mailing = case st.loaded of
          Ready p -> p.mailing
          _ -> False

    -- Shown in place of "New user" when the wiki's settings leave
    -- accounts with a password to the server's console. The backend would
    -- refuse the form, so the section says where such accounts are made
    -- instead. The text before the @code@ element ends on the element's
    -- line, so that its space stays (hh drops the spaces at a line break,
    -- as JSX does).
    consoleNote :: H.ComponentHTML Action Slots m
    consoleNote =
      [hh|
        <p class="admin-note user-create-console" role="note">
          Accounts with a password are made on the server's console, with <code>wiki-server users add</code>,
          as this wiki's settings say (under Permissions). Invitations and sign-in providers still make accounts.
        </p>
      |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          Ready p -> checkInRange p
          _ -> pass
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      -- The address asks for other users, or the shell has reloaded the
      -- wiki after a change: fetch the page again. Words typed and not yet
      -- in the address stay in the box.
      Receive input -> do
        old <- gets (\st -> st.input)
        modify $ \st ->
          st
            { input
            , typed = if isNothing st.pending && old.listing.search /= input.listing.search then input.listing.search else st.typed
            }
        when (old.listing /= input.listing || old.context.revision /= input.context.revision) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Typed t -> do
        gets (\st -> st.pending) >>= traverse_ H.kill
        waiting <- H.fork $ do
          liftIO (threadDelay searchPause)
          modify (\st -> st {pending = Nothing})
          handleAction SearchNow
        modify (\st -> st {typed = t, pending = Just waiting})
      -- The words typed, into the address, from the first page. The address
      -- is replaced rather than added to the history: each pause in typing
      -- is not a place to go back to.
      SearchNow -> do
        gets (\st -> st.pending) >>= traverse_ H.kill
        st <- get
        modify (\s -> s {pending = Nothing})
        let listing = st.input.listing
            search = T.strip st.typed
        when (search /= listing.search) $
          Router.redirect st.input.context.router (Admin (Users UserListing {search, page = 1, only = listing.only}))
      ChoseFilter n -> do
        st <- get
        for_ (atMay [minBound .. maxBound] n) $ \only ->
          Router.navigate st.input.context.router (Admin (Users UserListing {search = st.input.listing.search, page = 1, only}))
      ChoseSize n -> for_ (atMay userPageSizes n) $ \size -> do
        H.liftEffect (writePageSize size)
        modify (\st -> st {size})
        st <- get
        if st.input.listing.page /= 1
          then Router.navigate st.input.context.router (Admin (Users UserListing {search = st.input.listing.search, page = 1, only = st.input.listing.only}))
          else load
      Manage u -> modify (\st -> st {managing = Just u, told = Nothing, problem = Nothing})
      FromDialog UserDialog.Closed -> modify (\st -> st {managing = Nothing})
      FromDialog UserDialog.Saved -> H.raise (Changed Nothing)
      ToggleCreating -> modify (\st -> st {creating = not st.creating, problem = Nothing, told = Nothing})
      TypedLogin t -> modify (\st -> st {newUser = st.newUser {typedLogin = t}})
      TypedDisplayName t -> modify (\st -> st {newUser = st.newUser {typedName = t}})
      TypedPassword t -> modify (\st -> st {newUser = st.newUser {typedPassword = t}})
      TypedEmail t -> modify (\st -> st {newUser = st.newUser {typedEmail = t}})
      ChoseAdministrator b -> modify (\st -> st {newUser = st.newUser {asAdministrator = b}})
      CreateUser -> do
        form <- gets (\st -> st.newUser)
        modify (\st -> st {busy = True, problem = Nothing, told = Nothing})
        let email = mfilter (not . T.null) (Just (T.strip form.typedEmail))
        createUser NewAccount {login = form.typedLogin, displayName = form.typedName, password = Password form.typedPassword, email} >>= \case
          Left e -> modify (\st -> st {busy = False, problem = Just e})
          Right account -> do
            -- Created: whatever the result of making them an
            -- administrator, the form is done, and the page is fetched
            -- again.
            made <- if form.asAdministrator then setAdministrator account.user.id True else pure (Right ())
            modify $ \st ->
              st
                { newUser = noNewUser
                , creating = False
                , problem = leftToMaybe made
                , told =
                    Just
                      ( account.user.displayName
                          <> " ("
                          <> account.user.login.text
                          <> ") can sign in now."
                          <> maybe "" (\e -> " A link to verify " <> e <> " is sent to it.") email
                      )
                }
            H.raise (Changed Nothing)

    -- Fetch the page the address asks for. The page shown stays, dimmed,
    -- until the new one arrives. The open dialog gets its user as they are
    -- now, if they are on the new page.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      st <- get
      modify (\s -> s {fetching = True})
      result <- userPage (queryOf st.size st.input.listing)
      modify $ \s ->
        s
          { loaded = either Failed Ready result
          , fetching = False
          , busy = False
          , managing = case result of
              Right p -> (\m -> fromMaybe m (find (\u -> u.user.id == m.user.id) p.users)) <$> s.managing
              Left _ -> s.managing
          }
      either (const pass) checkInRange result

    -- A page past the last (the users were fewer when the address was
    -- written) is replaced by the last page.
    checkInRange :: UserPage -> H.HalogenM State Action Slots ViewOutput m ()
    checkInRange p = do
      st <- get
      let pages = max 1 ((p.total + st.size - 1) `div` st.size)
      when (null p.users && p.total > 0 && st.input.listing.page > pages) $
        Router.redirect st.input.context.router (Admin (Users UserListing {search = st.input.listing.search, page = pages, only = st.input.listing.only}))

-- | The query for a listing, at a page size.
queryOf :: Int -> UserListing -> UserQuery
queryOf size l =
  UserQuery
    { offset = (max 1 l.page - 1) * size
    , limit = size
    , search = l.search
    , administrators = l.only == OnlyAdministrators
    , disabled = l.only == OnlyDisabled
    }

-- | The page numbers the pager shows around the current page, with 0
-- where numbers are left out: the first and the last, and two on each side
-- of the current one.
--
-- > pageWindow 6 12 == [1, 0, 4, 5, 6, 7, 8, 0, 12]
pageWindow :: Int -> Int -> [Int]
pageWindow current pages = gaps (nub (sort ([1, pages] <> [n | n <- [current - 2 .. current + 2], n >= 1, n <= pages])))
  where
    gaps (a : b : rest)
      | b - a == 2 = a : (a + 1) : gaps (b : rest)
      | b - a > 2 = a : 0 : gaps (b : rest)
      | otherwise = a : gaps (b : rest)
    gaps rest = rest

-- | The users a page shows, of how many: "1–25 of 312", or "No users".
countText :: UserPage -> Text
countText p
  | null p.users = if p.total == 0 then "No users" else "None on this page, of " <> show p.total
  | otherwise = show (p.offset + 1) <> "–" <> show (p.offset + length p.users) <> " of " <> show p.total

-- | A filter, as the select names it.
filterLabel :: UserFilter -> Text
filterLabel = \case
  Everyone -> "Everyone"
  OnlyAdministrators -> "Administrators"
  OnlyDisabled -> "Disabled accounts"

-- | How long a pause in typing writes the words into the address: 300
-- milliseconds.
searchPause :: Int
searchPause = 300_000

-- | The local storage key the page size is kept under.
pageSizeKey :: Text
pageSizeKey = "admin-users-page-size"

-- | The page size this browser keeps, if it is one the section offers;
-- the first otherwise.
readPageSize :: (MonadBrowserDOM m) => m Int
readPageSize
  | inBrowser = do
      kept <- (>>= rightToMaybe) <$> Storage.getItem LocalStorage pageSizeKey
      pure (fromMaybe defaultSize (mfilter (`elem` userPageSizes) kept))
  | otherwise = pure defaultSize
  where
    defaultSize = fromMaybe 25 (head userPageSizes)

writePageSize :: (MonadBrowserDOM m) => Int -> m ()
writePageSize n = when inBrowser (Storage.setItem LocalStorage pageSizeKey n)
