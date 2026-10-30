{-# LANGUAGE QuasiQuotes #-}

-- | The history view: a page's history, in place of the page, for anyone
-- who may read the page. It lists the page's versions, the latest first,
-- and for the chosen one shows what it changed (a diff against the version
-- before it) or what has changed since (against the current page), with a
-- link back to the page. Someone who may edit the page may restore a
-- version, which saves its title and body as the page's latest version,
-- after confirming in place.
--
-- It fetches the page from the backend as the page view does ('getPage'),
-- so it is refused where the page is, and for the same reasons. Then it
-- fetches the page's history and the versions it compares; the latest
-- needs no request, since it is the page.
--
-- The history is fetched a page of versions at a time, the latest first
-- ('Wiki.Core.Version.VersionsQuery'): the first page, and further pages
-- only until the version shown and the one before it, which it is
-- compared with, are there. "Older…" under the list fetches the next
-- page. Each version carries its number, so the list numbers its
-- versions without the rest of the history.
--
-- The diff comes from "Wiki.Core.Diff", worked out once when the versions
-- are loaded, and rendered here as Halogen HTML. It is a table of lines
-- with their numbers in the old and the new text, with removed and added
-- lines marked, and, within a line that was changed rather than replaced,
-- the words that changed. Unchanged lines away from a change are left out
-- and counted.
module Wiki.App.View.History
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.View.Common
import Wiki.App.View.Diff (diffView, titleChange)
import Wiki.Core.Diff (Diff (..), diffText)
import Wiki.Core.Page (Page (body, id, title, updatedAt))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..), VersionsQuery (..), latestVersions, versionsPageSize)

-- | The history view's input, from the route: a page of a space the shell
-- has loaded, the version of it to show, and what to compare it with.
data Input = Input
  { context :: Context
  , space :: Space
  , path :: [Slug]
  , version :: Maybe UTCTime
  -- ^ 'Nothing' for the latest.
  , against :: Against
  }

type Slots = ("time" .== H.Slot (Const Void) Void Text)

-- | A version as the history shows it: its number, counted from the first
-- (1), and what the history lists of it.
type Numbered = (Int, VersionInfo)

-- | The part of the history shown.
data Viewed = Viewed
  { page :: Page
  , versions :: [Numbered]
  -- ^ The versions fetched so far, the latest first; the latest is the
  -- current page. The older ones may not have been fetched yet.
  , chosen :: Numbered
  , version :: Version
  -- ^ The chosen version, whole.
  , comparison :: Comparison
  }

-- | What the chosen version is compared with, and what changed.
data Comparison
  = -- | The first version, which has nothing before it: its text is all
    -- new.
    FirstVersion Diff
  | -- | What the chosen version changed from the one before it.
    FromPrevious Numbered Version Diff
  | -- | What has changed since the chosen version, up to the current page.
    SinceThen Version Diff

data Loaded
  = Loading
  | Failed WikiError
  | Ready Viewed

data State = State
  { input :: Input
  , loaded :: Loaded
  , confirming :: Bool
  -- ^ Whether "Restore this version" is asking for confirmation.
  , problem :: Maybe WikiError
  -- ^ Why the last restore failed.
  , olderProblem :: Maybe WikiError
  -- ^ Why fetching older versions failed.
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | AskRestore
  | CancelRestore
  | Restore
  | Retry
  | Older

component :: forall query m. (MonadLoad m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- Loaded at once rather than in 'Initialize', when the backend
          -- can ('atOnce'), so that the first render is the page the server
          -- or the prerender shows (see "Wiki.App.Shell"); otherwise loaded
          -- in 'Initialize'.
          loaded <- fromMaybe Loading <$> atOnce (fetch 0 input)
          pure State {input, loaded, confirming = False, problem = Nothing, olderProblem = Nothing}
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
    render st = case st.loaded of
      Loading -> [hh|<p class="loading">Loading…</p>|]
      Failed e -> failureView e Retry
      Ready shown ->
        [hh|
          <div class="history-view">
            <header class="view-header">
              <h1>{{ shown.page.title }}</h1>
              <span class="badge">History</span>
            </header>
            <div class="actions">{{ back st.input }}</div>
            <div class="history">
              {{ versionList st.input st.olderProblem shown }}
              {{ detail st shown }}
            </div>
          </div>
        |]

    back :: Input -> H.ComponentHTML Action Slots m
    back input =
      Router.link input.context.router Followed (documentRoute input.context input.space.id (Page (spacePathOf input.context.spaces input.space.id) input.path)) [HP.class_ "button history-back"] [HH.text "Back"]

    versionList :: Input -> Maybe WikiError -> Viewed -> H.ComponentHTML Action Slots m
    versionList input olderProblem shown =
      [hh|
        <nav class="version-list" aria-label="Versions">
          <ol>
            {% for (n, v) in shown.versions %}{% let here = n == fst shown.chosen %}
              <li class="version{% if here %} chosen{% end %}">
                <a {{ [attr "aria-current" "true" | here] }} {{ Router.linkProps input.context.router Followed (versionRoute input shown (n, v) AgainstPrevious) }}>{{ versionName shown n }}</a>
                <span class="version-meta">{{ time ("list-" <> stamp v.updatedAt) v.updatedAt }} · {{ authorName v.author }}</span>
              </li>
            {% end %}
          </ol>
          {% if maybe False (\(n, _) -> n > 1) (lastMay shown.versions) %}
            <button type="button" class="versions-older" onClick={{ const Older }}>Older…</button>
          {% end %}
          {{ toList (errorView <$> olderProblem) }}
        </nav>
      |]

    detail :: State -> Viewed -> H.ComponentHTML Action Slots m
    detail st shown =
      [hh|
        <section class="version-detail" aria-label={{ versionName shown n }}>
          <h2>{{ versionName shown n }}</h2>
          <p class="version-meta">Saved {{ time "chosen" chosen.updatedAt }} by {{ authorName chosen.author }}</p>
          {{ compareChoice st.input shown }}
          {{ restoreView st shown }}
          {{ comparisonView shown }}
        </section>
      |]
      where
        (n, chosen) = shown.chosen

    -- Compare with the version before, or with the current page: a choice
    -- only for a version that is not the latest, which is the page.
    compareChoice :: Input -> Viewed -> [H.ComponentHTML Action Slots m]
    compareChoice input shown
      | isLatest shown shown.chosen = []
      | otherwise =
          [ [hh|
              <p class="diff-against">
                Compared with
                {{ choice AgainstPrevious "the version before" }}
                {{ choice AgainstCurrent "the current version" }}
              </p>
            |]
          ]
      where
        current = case shown.comparison of
          SinceThen {} -> AgainstCurrent
          _ -> AgainstPrevious
        choice against label
          | against == current = [hh|<strong class="diff-against-chosen" aria-current="true">{{ label :: Text }}</strong>|]
          | otherwise = Router.link input.context.router Followed (versionRoute input shown shown.chosen against) [] [HH.text label]

    -- Restoring, for someone who may edit the page, of any version except
    -- the latest, which the page already is; confirmed in place first, as
    -- the editor's Cancel asks.
    restoreView :: State -> Viewed -> [H.ComponentHTML Action Slots m]
    restoreView st shown
      | isLatest shown shown.chosen || not (mayEdit st.input.context st.input.space.id) = []
      | st.confirming =
          [ [hh|
              <div class="confirm restore-confirm" role="alertdialog">
                <p>Make this version the page again? Its title and text are saved as the page's latest version; the versions in between are kept.</p>
                <button type="button" class="primary" onClick={{ const Restore }}>Restore</button>
                <button type="button" onClick={{ const CancelRestore }}>Cancel</button>
              </div>
            |]
          ]
            <> problemView
      | otherwise = [hh|<div class="actions"><button type="button" class="restore" onClick={{ const AskRestore }}>Restore this version</button></div>|] : problemView
      where
        problemView = toList (errorView <$> st.problem)

    comparisonView :: Viewed -> [H.ComponentHTML Action Slots m]
    comparisonView shown = case shown.comparison of
      FirstVersion d -> [explained "The first version: all of its text is new." d] <> diffView d
      FromPrevious (n, _) before d ->
        [explained ("What it changed from version " <> show n <> ".") d] <> titleChange before.title shown.version.title <> diffView d
      SinceThen this d ->
        [explained "What has changed since, up to the current version." d] <> titleChange this.title shown.page.title <> diffView d
      where
        explained :: Text -> Diff -> H.ComponentHTML Action Slots m
        explained what d
          | d.gaveUp = [hh|<p class="diff-summary">{{ what }} The two differ in too many lines to compare them line by line, so the whole text is shown as replaced.</p>|]
          | otherwise = [hh|<p class="diff-summary">{{ what }}</p>|]

    time :: Text -> UTCTime -> H.ComponentHTML Action Slots m
    time key at = HH.slot_ "time" key Islands.component (Islands.LocalTime at)

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> H.raise Loaded
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path
            otherVersion = old.version /= input.version || old.against /= input.against
        when elsewhere $ modify (\st -> st {loaded = Loading})
        when (elsewhere || otherVersion || old.context.revision /= input.context.revision) $ do
          modify (\st -> st {confirming = False, problem = Nothing})
          load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      AskRestore -> modify (\st -> st {confirming = True, problem = Nothing})
      CancelRestore -> modify (\st -> st {confirming = False})
      -- The next page of the history, added under the versions listed.
      Older ->
        gets (\st -> st.loaded) >>= \case
          Ready shown
            | Just (n, oldest) <- lastMay shown.versions
            , n > 1 ->
                listVersions shown.page.id VersionsQuery {before = Just oldest.updatedAt, limit = versionsPageSize} >>= \case
                  Left e -> modify (\st -> st {olderProblem = Just e})
                  Right more ->
                    -- Only if the same history is still shown, with the
                    -- same oldest version: another load may have
                    -- overtaken this one.
                    modify $ \st -> case st.loaded of
                      Ready now
                        | now.page.id == shown.page.id
                        , fmap fst (lastMay now.versions) == Just n ->
                            st {loaded = Ready now {versions = now.versions <> numbered more}, olderProblem = Nothing}
                      _ -> st
          _ -> pass
      Restore ->
        get >>= \st -> case st.loaded of
          Ready shown -> do
            modify (\s -> s {confirming = False})
            restoreVersion shown.page.id (snd shown.chosen).updatedAt shown.page.updatedAt >>= \case
              -- The page as it now is: the shell reloads and navigates
              -- there.
              Right _ -> H.raise (Changed (Just (documentRoute st.input.context st.input.space.id (Page (spacePathOf st.input.context.spaces st.input.space.id) st.input.path))))
              -- Perhaps saved since: what is shown is loaded again, so that
              -- the newer version can be seen.
              Left e -> do
                modify (\s -> s {problem = Just e})
                load
          _ -> pass

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      -- As many versions as are listed now, so that a list made longer
      -- with "Older…" stays as long when another version is chosen.
      shownBefore <- gets $ \st -> case st.loaded of
        Ready shown -> length shown.versions
        _ -> 0
      loaded <- fetch shownBefore input
      -- Only if the requested history is still what to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path && now.version == input.version && now.against == input.against) $ do
        modify (\st -> st {loaded})
        H.raise Loaded

-- | Fetch the history the input asks for, with the versions compared and
-- their diff, or the reason it cannot be shown. A version the history does
-- not have is 'NotFound'. The history is fetched a page at a time until
-- the chosen version and the one before it are there, and at least as
-- many versions as given (all there are, if fewer).
fetch :: (MonadWiki n) => Int -> Input -> n Loaded
fetch atLeast input = either Failed Ready <$> runExceptT go
  where
    go = do
      page <- ExceptT (getPage input.space.id input.path)
      listed <- olderUntilEnough page.id =<< ExceptT (listVersions page.id latestVersions)
      let versions = numbered listed
      chosen <- case input.version of
        Nothing -> maybe (throwError NotFound) pure (head versions)
        Just at -> maybe (throwError NotFound) pure (find (\(_, v) -> v.updatedAt == at) versions)
      let latest = maybe True (\(n, _) -> n == fst chosen) (head versions)
          whole (_, v)
            | v.updatedAt == page.updatedAt = pure Version {page = page.id, updatedAt = page.updatedAt, title = page.title, body = page.body, author = v.author}
            | otherwise = ExceptT (getVersion page.id v.updatedAt)
      this <- whole chosen
      comparison <-
        if input.against == AgainstCurrent && not latest
          then pure (SinceThen this (diffText this.body page.body))
          else case find (\(n, _) -> n == fst chosen - 1) versions of
            Nothing -> pure (FirstVersion (diffText "" this.body))
            Just before -> (\v -> FromPrevious before v (diffText v.body this.body)) <$> whole before
      pure Viewed {page, versions, chosen, version = this, comparison}
    olderUntilEnough pid listed
      | enough listed = pure listed
      | otherwise = case lastMay listed of
          Just oldest | oldest.number > 1 -> do
            more <- ExceptT (listVersions pid VersionsQuery {before = Just oldest.updatedAt, limit = versionsPageSize})
            if null more then pure listed else olderUntilEnough pid (listed <> more)
          _ -> pure listed
    -- Enough when the chosen version is there with the one before it (or
    -- is the first), or when the versions fetched went past the time
    -- asked for without it, which then is no version of the page.
    enough listed =
      length listed >= atLeast && case chosenIn listed of
        Just v -> v.number == 1 || any (\w -> w.number == v.number - 1) listed
        Nothing -> maybe True (\at -> any (\v -> v.updatedAt < at) listed) input.version
    chosenIn listed = case input.version of
      Nothing -> head listed
      Just at -> find (\v -> v.updatedAt == at) listed

-- | Versions with their numbers, as the list shows them.
numbered :: [VersionInfo] -> [Numbered]
numbered = map (\v -> (v.number, v))

-- | The route of a version of the page, compared as given; the latest is
-- the history's own address.
versionRoute :: Input -> Viewed -> Numbered -> Against -> Route
versionRoute input shown v against =
  documentRoute input.context input.space.id $
    PageHistory
      (spacePathOf input.context.spaces input.space.id)
      input.path
      (if isLatest shown v then Nothing else Just (snd v).updatedAt)
      (if isLatest shown v then AgainstPrevious else against)

-- | Whether a version is the latest: the current page.
isLatest :: Viewed -> Numbered -> Bool
isLatest shown (n, _) = n == latestNumber shown

-- | The number of the latest version, which is how many versions there
-- are.
latestNumber :: Viewed -> Int
latestNumber shown = maybe 0 fst (head shown.versions)

versionName :: Viewed -> Int -> Text
versionName shown n = "Version " <> show n <> (if n == latestNumber shown then " (current)" else "")

-- | Who saved a version, in words for a person to read.
authorName :: Maybe Author -> Text
authorName = maybe "someone unknown" (\a -> a.name)

-- | A time as a key for its slot.
stamp :: UTCTime -> Text
stamp = toS . iso8601Show
