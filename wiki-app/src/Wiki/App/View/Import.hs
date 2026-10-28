{-# LANGUAGE QuasiQuotes #-}

-- | The import of a wiki into the server's wiki, in the administration's
-- section on the wiki's data. It is offered on a backend that merges an
-- archive into its content (the HTTP backend, "Wiki.Api.Import"); the
-- demo's own import replaces everything instead.
--
-- It takes the wiki from one of two sources: a zip file of an export
-- ("Wiki.Core.Export"), chosen from the computer, or the wiki the demo
-- left in this browser. The latter is offered only when it exists here
-- (IndexedDB keeps one database per origin, so it exists when the demo was
-- served from the address the server now has). Either goes to the server
-- for a preview, which answers with what importing it would do. The
-- dialog "What to migrate" shows that as a tree of the source's spaces and
-- their pages, each with a checkbox, all checked, marked against the
-- server's content as new, as already there (a space, which is merged), or
-- in conflict (a page at the same path). A conflict offers the choice
-- between keeping the server's page, the default, and taking the imported
-- one. How the boxes and the choices work is in "Wiki.App.Import".
-- "Import" sends the same archive again with the choices. The server works
-- the plan out again, against its content at that moment, and answers with
-- what it did, which is then shown, and the shell reloads the wiki
-- ('Changed').
--
-- Every request waits for the server (an archive is uploaded like any
-- upload, for up to six minutes), so it is made in a handler, never in an
-- effect. Meanwhile the section says what it is waiting for and offers
-- nothing that would start another request. A request that gets no
-- response says so, with "Try again".
module Wiki.App.View.Import
  ( Migration (..)
  , Input (..)
  , component
  )
where

import Data.ByteString qualified as BS
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Wiki.Api.Import
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles, readPickedFile)
import Wiki.App.Import
import Wiki.App.View.Common
import Wiki.Core.Slug (Slug, slugText)

-- | What the import needs from its monad: the server's two steps, and the
-- demo's wiki in this browser as a source.
data Migration m = Migration
  { previewImport :: ByteString -> m (Either WikiError ImportPlan)
  -- ^ What importing this zip file would do.
  , applyImport :: ByteString -> ImportChoices -> m (Either WikiError ImportSummary)
  -- ^ Import this zip file, with these choices.
  , findDemoData :: m Bool
  -- ^ Whether the demo has left a wiki in this browser, checked without
  -- creating one.
  , readDemoData :: m (Either Text ByteString)
  -- ^ That wiki, as a zip file of an export, or the reason it cannot be
  -- read.
  }

newtype Input m = Input {migration :: Migration m}

-- | A wiki to import: its name to show, and its zip file.
data Source = Source
  { name :: Text
  , zipped :: ByteString
  }

-- | The import's current step.
data Step
  = -- | Offering the sources, under the result of the last import, if any.
    Start (Maybe Outcome)
  | -- | Reading the demo's wiki from this browser.
    ReadingDemo
  | -- | Waiting for the server's preview.
    Previewing Source
  | -- | The preview failed.
    PreviewFailed Source WikiError
  | -- | The dialog, and why the import failed, if it did.
    Choosing Source ImportPlan Selection (Maybe WikiError)
  | -- | Waiting for the server to import.
    Applying Source ImportPlan Selection

-- | The result of the last import, or why there was nothing to import.
data Outcome
  = Imported Text ImportSummary
  | Refused Text

data State m = State
  { migration :: Migration m
  , demoHere :: Maybe Bool
  -- ^ Whether the demo's wiki is in this browser; 'Nothing' until known,
  -- which is shown as absent. The server prerenders the administration
  -- without knowing what the reader's browser stores, and the program's
  -- first render must match that page. So the zip export is offered from
  -- the start, and the demo's data only once the browser has answered.
  , step :: Step
  }

data Action
  = Initialize
  | FileChosen Event
  | UseDemoData
  | Retry
  | Cancel
  | SpaceBox [Slug] Bool
  | PageBox PageRef Bool
  | Resolve PageRef Resolution
  | CheckAll
  | CheckNone
  | Apply

component :: forall query m. (Typeable m, MonadIO m) => H.Component query (Input m) ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \Input {migration} -> pure State {migration, demoHere = Nothing, step = Start Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize}
      }
  where
    render :: State m -> H.ComponentHTML Action Empty m
    render st = case st.step of
      Start outcome ->
        [hh|
          <div class="import">
            {{ outcomeView <$> outcome }}
            <div class="actions import-sources">
              <label class="button import-file">
                Import a zip export…
                <input type="file" accept=".zip,application/zip" onChange={{ FileChosen }}>
              </label>
              {% if st.demoHere == Just True %}
                <button type="button" class="import-demo" onClick={{ const UseDemoData }}>Import this browser's demo data…</button>
              {% end %}
            </div>
            <p class="admin-note">{{ sourcesNote (st.demoHere == Just True) }}</p>
          </div>
        |]
      ReadingDemo -> busy "Reading the demo's wiki from this browser…"
      Previewing source -> busy ("Sending " <> source.name <> " (" <> sizeOf source <> ") to the server, to see what importing it would do…")
      PreviewFailed source e ->
        [hh|
          <div class="import">
            <p>The server could not say what importing {{ source.name }} would do.</p>
            {{ failureView e Retry }}
            <div class="actions">
              <button type="button" class="import-cancel" onClick={{ const Cancel }}>Cancel</button>
            </div>
          </div>
        |]
      Choosing source plan sel problem -> dialog source plan sel False problem
      Applying source plan sel -> dialog source plan sel True Nothing

    busy :: Text -> H.ComponentHTML Action Empty m
    busy message = [hh|<div class="import"><p class="import-busy" role="status">{{ message }}</p></div>|]

    sourcesNote :: Bool -> Text
    sourcesNote here
      | here = "Bring pages into this wiki from an export of another, or from the demo, whose wiki this browser keeps for this address. Nothing is changed until you have chosen what to bring in."
      | otherwise = "Bring pages into this wiki from an export of another: the demo's \"Export the wiki\" makes one. Nothing is changed until you have chosen what to bring in."

    outcomeView :: Outcome -> H.ComponentHTML Action Empty m
    outcomeView = \case
      Refused why -> [hh|<p class="demo-told demo-refused import-refused" role="status">{{ why }}</p>|]
      Imported name summary ->
        [hh|
          <div class="import-summary" role="status">
            <p>Imported {{ name }}:</p>
            <ul>
              {% for line in importSummary summary %}
                <li>{{ line }}</li>
              {% end %}
            </ul>
          </div>
        |]

    -- What to migrate: the source's spaces and pages, each with its box,
    -- and a choice for each conflict; while the import is running, the
    -- same, but read-only.
    dialog :: Source -> ImportPlan -> Selection -> Bool -> Maybe WikiError -> H.ComponentHTML Action Empty m
    dialog source plan sel applying problem =
      [hh|
        <section class="import-dialog" role="dialog" aria-label="What to migrate">
          <h3>What to migrate</h3>
          <p class="import-from">From {{ source.name }}: {{ planSummary plan }}.</p>
          <p class="admin-note">
            A space this wiki has already, at the same path, is merged: its pages are added to it,
            and it keeps its own settings. A page it has already is in conflict: choose which of the
            two stays.
          </p>
          {% if null tree %}
            <p class="empty">It has no spaces.</p>
          {% else %}
            <div class="actions import-select">
              <button type="button" class="import-all" disabled={{ applying }} onClick={{ const CheckAll }}>Select all</button>
              <button type="button" class="import-none" disabled={{ applying }} onClick={{ const CheckNone }}>Select none</button>
            </div>
            <ul class="import-tree">{{ map (spaceView sel applying) tree }}</ul>
          {% end %}
          <p class="import-selected">{{ selectionSummary plan sel }}</p>
          {{ (\e -> failureView e Apply) <$> problem }}
          <div class="actions">
            <button type="button" class="primary import-apply" disabled={{ applying || nothingChecked }} onClick={{ const Apply }}>
              {{ if applying then "Importing…" else "Import" :: Text }}
            </button>
            <button type="button" class="import-cancel" disabled={{ applying }} onClick={{ const Cancel }}>Cancel</button>
          </div>
        </section>
      |]
      where
        tree = planTree plan
        nothingChecked = let t = tally plan sel in t.spacesNew + t.spacesMerged == 0

    spaceView :: Selection -> Bool -> SpaceNode -> H.ComponentHTML Action Empty m
    spaceView sel applying node =
      [hh|
        <li class="import-space import-{{ statusClass }}" data-path={{ pathText node.plan.path }}>
          <div class="import-row">
            <label>
              <input
                type="checkbox"
                class="import-check"
                checked={{ mark.checked }}
                disabled={{ applying || not mark.enabled }}
                onChecked={{ SpaceBox node.plan.path }}
              >
              <span class="import-name">{{ node.plan.name }}</span>
            </label>
            <span class="badge import-badge">{{ statusLabel }}</span>
          </div>
          {% if not (null node.pages) %}
            <ul class="import-pages">{{ map (pageView sel applying) node.pages }}</ul>
          {% end %}
          {% if not (null node.subspaces) %}
            <ul class="import-tree">{{ map (spaceView sel applying) node.subspaces }}</ul>
          {% end %}
        </li>
      |]
      where
        mark = spaceMark sel node.plan.path
        statusClass, statusLabel :: Text
        (statusClass, statusLabel) = case node.plan.status of
          SpaceNew -> ("new", "New")
          SpaceMerged -> ("merged", "Already here: merged")

    pageView :: Selection -> Bool -> PageNode -> H.ComponentHTML Action Empty m
    pageView sel applying node =
      [hh|
        <li class="import-page import-{{ statusClass }}" data-path={{ pathText node.plan.path }}>
          <div class="import-row">
            <label>
              <input
                type="checkbox"
                class="import-check"
                checked={{ mark.checked }}
                disabled={{ applying || not mark.enabled }}
                onChecked={{ PageBox ref }}
              >
              <span class="import-name">{{ node.plan.title }}</span>
            </label>
            <span class="badge import-badge">{{ statusLabel }}</span>
            {% if node.plan.attachments > 0 %}
              <span class="import-attachments">{{ counted node.plan.attachments "attachment" "attachments" }}</span>
            {% end %}
          </div>
          {% for c in maybeToList node.plan.conflict %}
            {% if not c.sameContent %}
              <div class="import-choice" role="radiogroup" aria-label={{ "Which " <> node.plan.title <> " stays" }}>
                <span class="import-theirs">This wiki has “{{ c.title }}”, saved {{ savedAt c.updatedAt }}.</span>
                <label>
                  <input
                    type="radio"
                    class="import-keep"
                    name={{ radioName }}
                    checked={{ chosen == KeepServer }}
                    disabled={{ applying || not mark.checked }}
                    onChange={{ const (Resolve ref KeepServer) }}
                  >
                  Keep the server's
                </label>
                <label>
                  <input
                    type="radio"
                    class="import-take"
                    name={{ radioName }}
                    checked={{ chosen == TakeImported }}
                    disabled={{ applying || not mark.checked }}
                    onChange={{ const (Resolve ref TakeImported) }}
                  >
                  Take the imported
                </label>
              </div>
            {% end %}
          {% end %}
          {% if not (null node.children) %}
            <ul class="import-pages">{{ map (pageView sel applying) node.children }}</ul>
          {% end %}
        </li>
      |]
      where
        ref = PageRef {space = node.space, page = node.plan.path}
        mark = pageMark sel ref
        chosen = resolutionOf sel ref
        radioName = "import-conflict:" <> pathText node.space <> ":" <> pathText node.plan.path
        statusClass, statusLabel :: Text
        (statusClass, statusLabel) = case node.plan.conflict of
          Nothing -> ("new", "New")
          Just c
            | c.sameContent -> ("same", "Already here, the same")
            | otherwise -> ("conflict", "In conflict")

    handleAction :: Action -> H.HalogenM (State m) Action Empty ViewOutput m ()
    handleAction = \case
      -- Checked once, in a fiber: a browser answers at once, but the check
      -- reads the browser's storage, which may wait.
      Initialize -> do
        migration <- gets (\st -> st.migration)
        here <- lift migration.findDemoData
        modify (\st -> st {demoHere = Just here})
      FileChosen ev -> do
        picked <- H.liftEffect (chosenFiles ev >>= pickedFiles)
        for_ (head picked) $ \file -> do
          bytes <- readPickedFile file
          preview Source {name = file.name, zipped = bytes}
      UseDemoData -> do
        modify (\st -> st {step = ReadingDemo})
        migration <- gets (\st -> st.migration)
        lift migration.readDemoData >>= \case
          Left why -> modify (\st -> st {step = Start (Just (Refused ("The demo's wiki in this browser could not be read: " <> why <> ".")))})
          Right zipped -> preview Source {name = "this browser's demo data", zipped}
      Retry ->
        gets (\st -> st.step) >>= \case
          PreviewFailed source _ -> preview source
          Choosing {} -> apply
          _ -> pass
      Cancel -> modify (\st -> st {step = Start Nothing})
      SpaceBox path checked -> choosing (setSpace path checked)
      PageBox ref checked -> choosing (setPage ref checked)
      Resolve ref r -> choosing (setResolution ref r)
      CheckAll -> choosing selectAll
      CheckNone ->
        gets (\st -> st.step) >>= \case
          Choosing _ plan _ _ -> choosing (selectNone plan)
          _ -> pass
      Apply -> apply

    -- Change what is checked, while the dialog is open.
    choosing :: (Selection -> Selection) -> H.HalogenM (State m) Action Empty ViewOutput m ()
    choosing f = modify $ \st -> case st.step of
      Choosing source plan sel _ -> st {step = Choosing source plan (f sel) Nothing}
      _ -> st

    preview :: Source -> H.HalogenM (State m) Action Empty ViewOutput m ()
    preview source = do
      modify (\st -> st {step = Previewing source})
      migration <- gets (\st -> st.migration)
      lift (migration.previewImport source.zipped) >>= \case
        Right plan -> modify (\st -> st {step = Choosing source plan everything Nothing})
        -- A refusal says why the file cannot be imported; trying again
        -- would be refused again.
        Left e@(Unreachable _) -> modify (\st -> st {step = PreviewFailed source e})
        Left e -> modify (\st -> st {step = Start (Just (Refused ("Not imported: " <> source.name <> ". " <> errorMessage e)))})

    apply :: H.HalogenM (State m) Action Empty ViewOutput m ()
    apply =
      gets (\st -> st.step) >>= \case
        Choosing source plan sel _ -> do
          modify (\st -> st {step = Applying source plan sel})
          migration <- gets (\st -> st.migration)
          lift (migration.applyImport source.zipped (choicesOf plan sel)) >>= \case
            Right summary -> do
              modify (\st -> st {step = Start (Just (Imported source.name summary))})
              H.raise (Changed Nothing)
            Left e -> modify (\st -> st {step = Choosing source plan sel (Just e)})
        _ -> pass

-- | A path of slugs as written in an address.
pathText :: [Slug] -> Text
pathText = T.intercalate "/" . map slugText

-- | When a page was saved, as the server reports it, in UTC: the dialog's
-- reader may be anywhere, so the time says which zone it is in.
savedAt :: UTCTime -> Text
savedAt = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

sizeOf :: Source -> Text
sizeOf source = fileSize (fromIntegral (BS.length source.zipped))
