{-# LANGUAGE QuasiQuotes #-}

-- | The editor's search panel (WP5.103b of docs/PLAN.md): one search over
-- a page's whole text, in the raw Markdown and in a presentation's rows
-- alike, above the text or above the rows. It holds the text to find, the
-- three toggles (case, regular expression, whole word), what the search
-- found ("3 of 12"), Previous and Next, the replacement with Replace and
-- Replace all, and Close. The editor ("Wiki.App.View.Editor") runs the
-- search on its CodeMirror ('Wiki.App.Editor.Browser.searchIn') and tells
-- the panel what it found; the panel tells the editor what was asked.
--
-- Keys: Enter in the text to find goes to the next match and Shift+Enter
-- to the previous one, the focus staying in the field, so that Enter goes
-- on stepping; Enter in the replacement replaces. Escape is the editor's,
-- from anywhere in its form, the panel's fields included
-- ('Wiki.App.View.Editor''s keys): it closes the search. Enter with another modifier does nothing: in a field of
-- the editor's form it would submit the form, which saves the page. Ctrl+F
-- and F3 are the editor's own keys ('Wiki.App.Editor.Browser.editorKey').
--
-- The fields are not controlled: Halogen writes a rendered @value@ back to
-- its element at every patch where the two differ, which would put back a
-- text typed since. The panel sets them itself when it opens ('Open').
module Wiki.App.View.SearchPanel
  ( Input (..)
  , Query (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event, EventType (..))
import Web.HTML.HTMLInputElement qualified as HTMLInputElement
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Wiki.App.Editor.Browser (Find (..), focusElement)
import Wiki.App.View.Common (ariaBool)

-- | The panel's input: the search, the editor's ('Wiki.App.View.Editor'
-- holds it, and gives it to CodeMirror), which the panel shows as it is
-- mounted; what the search found, as the panel says it ("3 of 12", "No
-- matches"); and whether the text to find is a regular expression that is
-- not one.
data Input = Input
  { find :: Find
  , said :: Text
  , invalid :: Bool
  }

-- | Open the panel on a search: its fields filled with it, and the text to
-- find focused, all of it selected, so that typing replaces it.
data Query a = Open Find a

-- | What the panel asks of the editor: search for this, go to the next
-- match ('True') or the previous one, replace the match selected, replace
-- them all, or close.
data Output
  = Changed Find
  | Step Bool
  | Replace
  | ReplaceAll
  | Closed

data State = State
  { input :: Input
  , search :: Find
  -- ^ The search as the fields and toggles say it now.
  , findField :: H.RefLabel
  , replaceField :: H.RefLabel
  }

data Toggle = CaseToggle | RegexpToggle | WordToggle

data Action
  = Initialize
  | Receive Input
  | TypedFind Text
  | TypedReplacement Text
  | Toggled Toggle
  | Ask Output
  | Ignore

component :: forall m. (MonadIO m, MonadUUID m) => H.Component Query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          findField <- H.newRefLabel "search-find"
          replaceField <- H.newRefLabel "search-replace"
          pure State {input, search = Find {query = "", replacement = "", caseSensitive = False, regexp = False, wholeWord = False}, findField, replaceField}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.handleQuery = handleQuery, H.receive = Just . Receive, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="editor-search" role="search" aria-label="Find and replace">
          <div class="editor-search-line">
            <input
              type="text"
              class="editor-search-find"
              aria-label="Find"
              placeholder="Find"
              spellcheck="false"
              autocomplete="off"
              aria-invalid={{ ariaBool st.input.invalid }}
              onValueInput={{ TypedFind }}
              {{ HE.preventingDefault (HE.handler' (EventType "keydown") (fieldKey True)) }}
              {{ HP.ref st.findField }}
            >
            <span class="editor-search-toggles">
              <button type="button" class="editor-search-toggle editor-search-case" aria-pressed={{ ariaBool st.search.caseSensitive }} aria-label="Match case" title="Match case" onClick={{ const (Toggled CaseToggle) }}>Aa</button>
              <button type="button" class="editor-search-toggle editor-search-regexp" aria-pressed={{ ariaBool st.search.regexp }} aria-label="Regular expression" title="Regular expression" onClick={{ const (Toggled RegexpToggle) }}>.*</button>
              <button type="button" class="editor-search-toggle editor-search-word" aria-pressed={{ ariaBool st.search.wholeWord }} aria-label="Whole word" title="Whole word" onClick={{ const (Toggled WordToggle) }}>W</button>
            </span>
            <span class="editor-search-count" role="status">{{ st.input.said }}</span>
            <span class="editor-search-moves">
              <button type="button" class="editor-search-previous" aria-label="Previous match" title="Previous match (Shift+Enter, Shift+F3)" onClick={{ const (Ask (Step False)) }}>↑</button>
              <button type="button" class="editor-search-next" aria-label="Next match" title="Next match (Enter, F3)" onClick={{ const (Ask (Step True)) }}>↓</button>
              <button type="button" class="editor-search-close" aria-label="Close the search" title="Close (Escape)" onClick={{ const (Ask Closed) }}>×</button>
            </span>
          </div>
          <div class="editor-search-line">
            <input
              type="text"
              class="editor-search-replacement"
              aria-label="Replace with"
              placeholder="Replace with"
              spellcheck="false"
              autocomplete="off"
              onValueInput={{ TypedReplacement }}
              {{ HE.preventingDefault (HE.handler' (EventType "keydown") (fieldKey False)) }}
              {{ HP.ref st.replaceField }}
            >
            <span class="editor-search-replaces">
              <button type="button" class="editor-search-replace" title="Replace this match and go to the next (Enter in the field)" onClick={{ const (Ask Replace) }}>Replace</button>
              <button type="button" class="editor-search-replace-all" title="Replace every match, as one step that Ctrl+Z takes back" onClick={{ const (Ask ReplaceAll) }}>Replace all</button>
            </span>
          </div>
        </div>
      |]

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      -- Mounted (opened, or drawn again after CodeMirror was put in place
      -- again): the editor's search in the fields and the toggles.
      Initialize -> do
        found <- gets (\st -> st.input.find)
        modify (\st -> st {search = found})
        st <- get
        fill st.findField found.query
        fill st.replaceField found.replacement
      Receive input -> modify (\st -> st {input})
      TypedFind t -> change (\s -> s {query = t})
      TypedReplacement t -> change (\s -> s {replacement = t})
      Toggled CaseToggle -> change (\s -> s {caseSensitive = not s.caseSensitive})
      Toggled RegexpToggle -> change (\s -> s {regexp = not s.regexp})
      Toggled WordToggle -> change (\s -> s {wholeWord = not s.wholeWord})
      Ask out -> H.raise out
      Ignore -> pass

    change :: (Find -> Find) -> H.HalogenM State Action Empty Output m ()
    change f = do
      modify (\st -> st {search = f st.search})
      gets (\st -> st.search) >>= H.raise . Changed

    handleQuery :: forall a. Query a -> H.HalogenM State Action Empty Output m (Maybe a)
    handleQuery (Open s next) = do
      modify (\st -> st {search = s})
      st <- get
      fill st.replaceField s.replacement
      fill st.findField s.query
      H.getRef st.findField >>= traverse_ (\e -> H.liftEffect (liftIO (focusElement e >> for_ (HTMLInputElement.fromElement e) (.select))))
      pure (Just next)

    -- Put a text in one of the fields.
    fill :: H.RefLabel -> Text -> H.HalogenM State Action Empty Output m ()
    fill label text = H.getRef label >>= traverse_ (\e -> H.liftEffect (liftIO (for_ (HTMLInputElement.fromElement e) (\i -> i.value_set text))))

-- | A key in one of the fields: Enter in the text to find ('True') steps,
-- forward or, with Shift, back; Enter in the replacement replaces; Enter
-- with another modifier does nothing. Read in the keydown's listener,
-- which stops the browser from submitting the editor's form. A key an
-- input method composes with is the input method's.
fieldKey :: Bool -> Event -> Maybe Action
fieldKey inFind event
  | pressed.isComposing || pressed.key /= "Enter" = Nothing
  | pressed.ctrlKey || pressed.metaKey || pressed.altKey = Just Ignore
  | inFind = Just (Ask (Step (not pressed.shiftKey)))
  | pressed.shiftKey = Just Ignore
  | otherwise = Just (Ask Replace)
  where
    pressed = KeyboardEvent event
