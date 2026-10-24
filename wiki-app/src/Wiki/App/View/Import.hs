{-# LANGUAGE QuasiQuotes #-}

-- | Bringing a wiki into the server's: the import in the administration's
-- section on the wiki's data, over a backend that merges an archive into
-- what it has (the server's, "Wiki.Api.Import"), where the demo's own
-- import replaces everything instead.
--
-- It takes the wiki from one of two sources: a zip file of an export
-- ("Wiki.Core.Export"), chosen from the computer, or the wiki the demo left
-- in this browser, which is offered only when there is one here (IndexedDB
-- keeps a database per origin, so there is one when the demo was served
-- from the address the server now has). Either goes to the server for a
-- preview, which answers with what importing it would do, and the dialog
-- "What to migrate" shows that as a tree of the source's spaces and their
-- pages, each with a box, all checked, marked against the server's content
-- as new, as already there (a space, merged), or in conflict (a page at the
-- same path), with the choice between keeping the server's page, the
-- default, and taking the imported one. What it does with the boxes and the
-- choices is "Wiki.App.Import"'s. "Import" sends the same archive again
-- with the choices; the server works the plan out once more, against its
-- content as it is then, and answers with what it did, which is shown
-- afterwards, and the shell reloads the wiki ('Changed').
--
-- Every request waits for the server (an archive goes up as an upload does,
-- for up to six minutes), so it is made in a handler, never in an effect,
-- and meanwhile the section says what it is waiting for and offers nothing
-- that would start another. One that gets no answer says so, with "Try
-- again".
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

-- | What the import needs of its monad: the server's two steps, and the
-- demo's wiki in this browser as a source.
data Migration m = Migration
  { previewImport :: ByteString -> m (Either WikiError ImportPlan)
  -- ^ What importing this zip file would do.
  , applyImport :: ByteString -> ImportChoices -> m (Either WikiError ImportSummary)
  -- ^ Import this zip file, as chosen.
  , findDemoData :: m Bool
  -- ^ Whether the demo has left a wiki in this browser, asked without
  -- making one.
  , readDemoData :: m (Either Text ByteString)
  -- ^ That wiki, as a zip file of an export, or why it cannot be read.
  }

newtype Input m = Input {migration :: Migration m}

-- | A wiki to import: what to call it, and its zip file.
data Source = Source
  { name :: Text
  , zipped :: ByteString
  }

-- | Where the import is.
data Step
  = -- | Offering the sources, under what the last import did, if anything.
    Start (Maybe Outcome)
  | -- | Reading the demo's wiki from this browser.
    ReadingDemo
  | -- | Waiting for the server's preview.
    Previewing Source
  | -- | The preview failed.
    PreviewFailed Source WikiError
  | -- | The dialog, and why the import failed if it did.
    Choosing Source ImportPlan Selection (Maybe WikiError)
  | -- | Waiting for the server to import.
    Applying Source ImportPlan Selection

-- | What the last import did, or why there was nothing to import.
data Outcome
  = Imported Text ImportSummary
  | Refused Text

data State m = State
  { migration :: Migration m
  , demoHere :: Maybe Bool
  -- ^ Whether the demo's wiki is in this browser; 'Nothing' until known.
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

component :: forall query m. (MonadIO m) => H.Component query (Input m) ViewOutput m
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
            {% for here in maybeToList st.demoHere %}
              <div class="actions import-sources">
                <label class="button import-file">
                  Import a zip export…
                  <input type="file" accept=".zip,application/zip" onChange={{ FileChosen }}>
                </label>
                {% if here %}
                  <button type="button" class="import-demo" onClick={{ const UseDemoData }}>Import this browser's demo data…</button>
                {% end %}
              </div>
              <p class="admin-note">{{ sourcesNote here }}</p>
            {% end %}
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
    -- and a choice for each conflict; while the import is being made,
    -- the same, with nothing to change.
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
      -- Asked once, in a fiber: a browser answers at once, but it is
      -- asked of the browser's storage, which may wait.
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
        -- A refusal says why the file is not one to import; trying again
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

-- | A path of slugs as it reads in an address.
pathText :: [Slug] -> Text
pathText = T.intercalate "/" . map slugText

-- | When a page was saved, as the server says it, in UTC: the dialog's
-- reader may be anywhere, and says which.
savedAt :: UTCTime -> Text
savedAt = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

sizeOf :: Source -> Text
sizeOf source = fileSize (fromIntegral (BS.length source.zipped))
