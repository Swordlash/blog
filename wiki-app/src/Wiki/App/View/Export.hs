{-# LANGUAGE QuasiQuotes #-}

-- | The "Export" menu of a page and of a space (WP4.16 of docs/PLAN.md):
-- an entry for each document format the backend exports them to
-- ("Wiki.Api.Export"). The menu is a @\<details>@ element, so it opens and
-- closes without the program. A backend that exports nothing (the demo,
-- which has no pandoc) shows no menu: the page and the space views leave
-- this component out.
--
-- An entry is a button, not a link (WP5.56 of docs/PLAN.md). The
-- component fetches the document from the backend ('fetchExport') and
-- only then gives it to the browser, from a @blob:@ URL made in the page:
-- saved under the file name the server gave it, or, for a PDF
-- ('opensInline'), opened in a new tab. A link with @download@ saved
-- whatever the server answered, its refusal too, as the document; and a
-- Chromium browser blocks a download over plain HTTP, but not one from a
-- @blob:@ URL. When the export is refused, the server's reason is shown in
-- a notice in the corner of the window, and nothing is saved. While a
-- document is made (a PDF takes seconds) its entry says so, and every
-- entry waits: the server makes one export at a time for each person.
--
-- A browser lets a page open a tab only shortly after the click that asked
-- for it (Chromium allows about five seconds). A PDF that took longer is
-- saved instead, and the notice says so.
module Wiki.App.View.Export
  ( Input (..)
  , component
  , makingLabel
  )
where

import Data.Row (Empty)
import Data.Time (NominalDiffTime)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Export (ExportFormat (..), formatLabel, formatName, opensInline)
import Wiki.App.Backend (Document (..), ExportTarget, MonadWiki (..))
import Wiki.App.Browser (download, openInTab)
import Wiki.App.View.Common (errorMessage)

-- | What the menu exports, and in which formats.
data Input = Input
  { formats :: [ExportFormat]
  , target :: ExportTarget
  }

-- | A notice in the corner of the window, about the last export.
data Notice = Notice
  { refused :: Bool
  -- ^ Whether the export was refused: the notice then says why, and stays
  -- until it is dismissed or for 'refusalTime'.
  , text :: Text
  }

data State = State
  { input :: Input
  , making :: Maybe ExportFormat
  -- ^ The format being made, while the backend makes it.
  , notice :: Maybe Notice
  , noticeWait :: Maybe H.ForkId
  -- ^ The fiber that removes the notice after a while.
  }

data Action
  = Receive Input
  | Export ExportFormat
  | Dismiss

component :: forall query output m. (MonadWiki m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, making = Nothing, notice = Nothing, noticeWait = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <span class="export">
          <details class="export-menu">
            <summary class="button">Export</summary>
            <ul class="export-formats">
              {% for f in st.input.formats %}
                <li>
                  <button type="button" class="export-{{ formatName f }}" disabled={{ isJust st.making }} aria-busy={{ ariaBusy (st.making == Just f) }} onClick={{ const (Export f) }}>{{ entryLabel st f }}</button>
                </li>
              {% end %}
            </ul>
          </details>
          <span class="export-notice{% if any (\n -> n.refused) st.notice %} export-refused{% end %}" role="status">
            {% for n in maybeToList st.notice %}
              <span class="export-notice-text">{{ n.text }}</span>
              <button type="button" class="export-notice-dismiss" aria-label="Dismiss" onClick={{ const Dismiss }}>×</button>
            {% end %}
          </span>
        </span>
      |]

    entryLabel :: State -> ExportFormat -> Text
    entryLabel st f
      | st.making == Just f = makingLabel f
      | opensInline f = formatLabel f <> " (opens in a tab)"
      | otherwise = formatLabel f

    ariaBusy :: Bool -> Text
    ariaBusy b = if b then "true" else "false"

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Receive input -> modify (\st -> st {input})
      Dismiss -> clearNotice
      Export format ->
        whenM (gets (\st -> isNothing st.making)) $ do
          clearNotice
          target <- gets (\st -> st.input.target)
          modify (\st -> st {making = Just format})
          result <- lift (fetchExport target format)
          modify (\st -> st {making = Nothing})
          case result of
            Left e -> say True (errorMessage e)
            Right document
              | opensInline format -> do
                  opened <- liftIO (openInTab document.mediaType document.bytes)
                  unless opened $ do
                    download document.fileName document.mediaType document.bytes
                    say False ("The browser opened no tab for the PDF, so it was saved as " <> document.fileName <> ".")
              | otherwise -> download document.fileName document.mediaType document.bytes

    -- Show a notice, and remove it after a while: a refusal after
    -- 'refusalTime', anything else after 'noticeTime'.
    say :: Bool -> Text -> H.HalogenM State Action Empty output m ()
    say refused text = do
      clearNotice
      waiting <- H.fork $ do
        H.delay (if refused then refusalTime else noticeTime)
        modify (\st -> st {notice = Nothing, noticeWait = Nothing})
      modify (\st -> st {notice = Just Notice {refused, text}, noticeWait = Just waiting})

    clearNotice :: H.HalogenM State Action Empty output m ()
    clearNotice = do
      gets (\st -> st.noticeWait) >>= traverse_ H.kill
      modify (\st -> st {notice = Nothing, noticeWait = Nothing})

-- | What a format's entry says while its document is made.
makingLabel :: ExportFormat -> Text
makingLabel f = "Making the " <> noun <> "…"
  where
    noun = case f of
      Docx -> "Word document"
      Html -> "web page"
      Epub -> "e-book"
      Pdf -> "PDF"
      Pptx -> "presentation"
      BeamerTex -> "Beamer source"
      BeamerPdf -> "PDF"

-- | How long a notice that is not a refusal stays, in seconds.
noticeTime :: NominalDiffTime
noticeTime = 6

-- | How long a refusal stays unless it is dismissed, in seconds: long
-- enough to read a reason of a few lines.
refusalTime :: NominalDiffTime
refusalTime = 15
