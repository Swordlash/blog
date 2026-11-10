{-# LANGUAGE QuasiQuotes #-}

-- | 'PagePicker' is the part of the search box that finds a page: an
-- input, a space selector (every space, or one space and, unless that is
-- unticked, its subspaces), and the best hits for what is typed, each with
-- its space's path and a snippet of its text, the matches highlighted.
-- Two places use it: the search box in the shell's header
-- ("Wiki.App.View.Search"), which opens the page picked, and the editor's
-- "Link to a page" dialog ("Wiki.App.View.LinkDialog"), which writes a
-- link to it (WP5.53 of docs/PLAN.md). Picking a hit is told to the
-- component that holds the picker ('Picked'); the picker itself never
-- navigates.
--
-- The text typed is searched for ('Wiki.App.Backend.searchPages') once
-- typing pauses for 'pause'. From the keyboard, the arrows move through
-- the hits and Enter picks the selected one. With no hit selected, Enter
-- in the header asks for the page of all results ('AllResults'), and in
-- the dialog picks the first hit. Each hit is a link to its page, so a
-- click with a modifier key opens it in another tab as any link does; a
-- plain click picks it.
--
-- In the header the hits are listed only while the focus is in the box,
-- and the list ends with a link to the page of all results; Escape closes
-- the list. In the dialog the hits are listed whenever there is text to
-- search for.
module Wiki.App.View.PagePicker
  ( Input (..)
  , Place (..)
  , Query (..)
  , Output (..)
  , component
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Coerce (coerce)
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow (..))
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.DOM.Element qualified as Element
import Web.DOM.Internal.Types (Element (..), HTMLElement (..), toNode)
import Web.Event.Event (Event (..), EventType (..))
import Web.HTML.HTMLInputElement qualified as HTMLInputElement
import Web.UIEvent.FocusEvent (FocusEvent)
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session, WikiError)
import Wiki.App.Route (Route (..), pageRoute)
import Wiki.App.View.Common
import Wiki.App.View.SearchHit (hitContents, spaceNamesOf)
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..))
import Wiki.Core.Space (Space (id))

-- | The picker's input: the shell's context, and where it is.
data Input = Input
  { context :: Context
  , place :: Place
  }

-- | Where the picker is: in the shell's header, or in the editor's "Link
-- to a page" dialog.
data Place = InHeader | InDialog
  deriving stock (Eq)

-- | What the component that holds the picker asks of it.
data Query a
  = -- | Give the input the focus, with its text selected to be typed over.
    Focus a
  | -- | Close the list, leaving the focus where it is.
    Close a
  | -- | Close the list and take the focus out of the box, wherever the
    -- reader is going.
    Leave a

-- | What the picker tells the component that holds it.
data Output
  = -- | This hit was picked: with Enter, or a plain click.
    Picked SearchHit
  | -- | The page of all results for what is typed, asked for with Enter
    -- and no hit selected, or with the link at the end of the list (in
    -- the header).
    AllResults Route

-- | The hits for the last search, or none if nothing was searched yet.
data Results
  = NotSearched
  | Found SearchQuery [SearchHit]
  | -- | The search failed: the backend could not be reached.
    Unanswered SearchQuery WikiError

data State = State
  { input :: Input
  , text :: Text
  , space :: Maybe SpaceId
  -- ^ The space chosen in the selector, or 'Nothing' for every space.
  , subspaces :: Bool
  , results :: Results
  , open :: Bool
  -- ^ Whether focus is in the box, and the list has not been closed since.
  , selected :: Maybe Int
  , pending :: Maybe H.ForkId
  -- ^ The search waiting for the typing to pause.
  , box :: H.RefLabel
  , field :: H.RefLabel
  }

data Action
  = Receive Input
  | Typed Text
  | Chose Text
  | Subspaces Bool
  | Run
  | Move Int
  | Pick
  | Clicked SearchHit
  | ToResults (Follow Route)
  | CloseList
  | FocusIn
  | FocusOut FocusEvent
  | KeepFocus

-- | How long typing must pause before the text is searched for: long
-- enough not to search for every letter of a word typed quickly, short
-- enough that the list seems to follow the typing.
pause :: Int
pause = 150_000

-- | How many hits the list shows; the results page shows the rest.
shown :: Int
shown = 8

component :: forall m. (MonadLoad m, MonadUUID m, MonadUnliftIO m) => H.Component Query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          box <- H.newRefLabel "page-picker"
          field <- H.newRefLabel "page-picker-input"
          pure
            State
              { input
              , text = ""
              , space = Nothing
              , subspaces = True
              , results = NotSearched
              , open = False
              , selected = Nothing
              , pending = Nothing
              , box
              , field
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div
          ref={{ st.box }}
          class="page-picker{% if listShown st %} open{% end %}"
          onFocusIn={{ const FocusIn }}
          onFocusOut={{ FocusOut }}
          {{ [HE.handler' (EventType "keydown") closeKey | header] }}
        >
          <div class="search-bar">
            {# No value: the box never sets the text itself, and a rendered
               value is put back on every render (Halogen compares it with the
               element's), which would undo a key typed between a render and
               the handling of the key before it, such as the first one after
               "/". #}
            <input
              ref={{ st.field }}
              type="search"
              class="search-input"
              placeholder={{ if header then "Search pages… (/)" else "Find a page by its title or its text…" :: Text }}
              aria-label={{ if header then "Search pages" else "Find a page" :: Text }}
              aria-expanded={{ ariaBool (listShown st) }}
              aria-controls={{ listId st }}
              autocomplete="off"
              spellcheck={{ False }}
              onValueInput={{ Typed }}
              {{ HE.preventingDefault (HE.handler' (EventType "keydown") listKey) }}
            >
            <select class="search-space" aria-label="Space to search" onValueChange={{ Chose }}>
              <option value="" selected={{ isNothing st.space }}>All spaces</option>
              {% for (sid, label) in choices ctx %}
                <option value={{ sid.text }} selected={{ st.space == Just sid }}>{{ label }}</option>
              {% end %}
            </select>
            {% if isJust st.space %}
              <label class="search-subspaces"><input type="checkbox" checked={{ st.subspaces }} onChecked={{ Subspaces }}> and subspaces</label>
            {% end %}
          </div>
          {% if listShown st %}{{ dropdown st }}{% end %}
        </div>
      |]
      where
        ctx = st.input.context
        header = st.input.place == InHeader

    -- The keys that move through the list and pick from it, recognised in
    -- the input's listener, which stops the browser's own action for them
    -- (moving the cursor, submitting the form the dialog is in) while it
    -- dispatches the key, whatever the component is busy with. Any other
    -- key makes no action and is left to the browser.
    listKey :: Event -> Maybe Action
    listKey event = case (KeyboardEvent event).key of
      "ArrowDown" -> Just (Move 1)
      "ArrowUp" -> Just (Move (-1))
      "Enter" -> Just Pick
      _ -> Nothing

    -- Escape, anywhere in the header's box, closes the list, and the
    -- browser also does its own action (a search input clears its text).
    -- In the dialog, Escape is the dialog's: it closes it.
    closeKey :: Event -> Maybe Action
    closeKey event = case (KeyboardEvent event).key of
      "Escape" -> Just CloseList
      _ -> Nothing

    -- The list under the input. A mouse press on it would take focus from
    -- the input before the click lands, closing the header's list under
    -- the pointer, so the press is stopped from doing that in its listener
    -- ('KeepFocus' itself does nothing).
    dropdown :: State -> H.ComponentHTML Action Empty m
    dropdown st =
      [hh|
        <div class="search-results" id={{ listId st }} {{ HE.preventingDefault (HE.onMouseDown (const KeepFocus)) }}>
          {{ status }}{% if st.input.place == InHeader %}{{ allResults }}{% end %}
        </div>
      |]
      where
        ctx = st.input.context
        allResults = Router.link ctx.router ToResults (resultsRoute st) [HP.class_ "search-all"] [HH.text ("All results for “" <> T.strip st.text <> "”")]
        status = case st.results of
          NotSearched -> [hh|<p class="search-status">Searching…</p>|]
          Found _ [] -> [hh|<p class="search-status search-empty">No results</p>|]
          Unanswered _ e -> [hh|<p class="search-status search-failed">{{ errorMessage e }}</p>|]
          Found _ hits ->
            [hh|
              <ul class="search-hits" role="listbox">
                {% for (i, hit) in zip [0 ..] (take shown hits) %}{% let chosen = Just i == st.selected %}
                  <li role="option" aria-selected={{ ariaBool chosen }}>
                    {{ Router.link ctx.router (const (Clicked hit)) (pageRoute hit.spacePath hit.pagePath) [HP.classes ("search-hit" : ["selected" | chosen])] (hitContents ctx.spaces hit) }}
                  </li>
                {% end %}
              </ul>
            |]

    handleQuery :: forall a. Query a -> H.HalogenM State Action Empty Output m (Maybe a)
    handleQuery = \case
      Focus a -> do
        ref <- gets (\st -> st.field)
        found <- H.getRef ref
        for_ found $ \element -> H.liftEffect . liftIO $ do
          (coerce element :: HTMLElement).focus
          for_ (HTMLInputElement.fromElement element) (.select)
        pure (Just a)
      Close a -> Just a <$ handleAction CloseList
      Leave a -> do
        handleAction CloseList
        ref <- gets (\st -> st.field)
        H.getRef ref >>= traverse_ (\element -> H.liftEffect (liftIO (coerce element :: HTMLElement).blur))
        pure (Just a)

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Receive input -> do
        before <- gets (\st -> st.input.context)
        -- A space that no longer exists, or is no longer visible, is
        -- deselected.
        modify (\st -> st {input, space = mfilter (mayView input.context) st.space})
        -- Someone else signed in, or the wiki changed: what they may find
        -- has changed too.
        when (changed before input.context) (schedule False)
      Typed text -> do
        modify (\st -> st {text, open = True, selected = Nothing})
        schedule True
      Chose value -> do
        modify (\st -> st {space = if T.null value then Nothing else Just (SpaceId value), selected = Nothing})
        schedule False
      Subspaces subspaces -> do
        modify (\st -> st {subspaces, selected = Nothing})
        schedule False
      Run -> do
        modify (\st -> st {pending = Nothing})
        q <- gets queryOf
        unless (T.null (T.strip q.text)) $ do
          -- On a worker thread, where the backend's failure to answer is
          -- caught.
          found <- lift (attempt (searchPages q))
          -- Unless something else has been typed or chosen meanwhile, which
          -- will get its own search.
          current <- gets queryOf
          when (current == q) $ modify (\st -> st {results = either (Unanswered q) (Found q) found, selected = Nothing})
      Move step -> move step
      Pick -> pick
      -- The link's listener has kept the browser from following it.
      Clicked hit -> H.raise (Picked hit)
      ToResults (Follow r _) -> H.raise (AllResults r)
      CloseList -> modify (\st -> st {open = False, selected = Nothing})
      FocusIn -> modify (\st -> st {open = True})
      FocusOut ev -> do
        ref <- gets (\st -> st.box)
        container' <- H.getRef ref
        for_ container' $ \container -> do
          leaving <- case ev.relatedTarget >>= Element.fromEventTarget of
            Nothing -> pure True
            Just next -> H.liftEffect (liftIO (not <$> container.contains (toNode next)))
          when leaving $ modify (\st -> st {open = False, selected = Nothing})
      KeepFocus -> pass

    -- Search for the typed text: after a pause in typing, or at once for a
    -- change of the space or the session. Blank text clears the list.
    schedule :: Bool -> H.HalogenM State Action Empty Output m ()
    schedule afterPause = do
      gets (\st -> st.pending) >>= traverse_ H.kill
      blank <- gets (\st -> T.null (T.strip st.text))
      if blank
        then modify (\st -> st {pending = Nothing, results = NotSearched})
        else
          if afterPause
            then do
              fid <- H.fork (liftIO (threadDelay pause) >> handleAction Run)
              modify (\st -> st {pending = Just fid})
            else handleAction Run

    move :: Int -> H.HalogenM State Action Empty Output m ()
    move step = do
      st <- get
      case st.results of
        Found _ hits@(_ : _) | not (T.null (T.strip st.text)) -> do
          let n = min shown (length hits)
              next = case st.selected of
                Nothing -> if step > 0 then 0 else n - 1
                Just i -> (i + step) `mod` n
          put st {open = True, selected = Just next}
        _ -> pass

    pick :: H.HalogenM State Action Empty Output m ()
    pick = do
      st <- get
      let hits = case st.results of
            Found _ found -> found
            _ -> []
      case (st.selected, st.input.place) of
        (Just i, _) -> traverse_ (H.raise . Picked) (atMay hits i)
        (Nothing, InHeader) -> unless (T.null (T.strip st.text)) (H.raise (AllResults (resultsRoute st)))
        (Nothing, InDialog) -> unless (T.null (T.strip st.text)) (traverse_ (H.raise . Picked) (head hits))

-- | The id of the list of hits, which the input names as what it
-- controls: one for each place, since the header's box is on the page
-- while the dialog is open.
listId :: State -> Text
listId st = case st.input.place of
  InHeader -> "wiki-search-results"
  InDialog -> "page-picker-results"

-- | Whether the list under the input is shown: while there is typed text
-- to list hits for, and, in the header, while focus is in the box.
listShown :: State -> Bool
listShown st = (st.open || st.input.place == InDialog) && not (T.null (T.strip st.text))

-- | The query for the box's contents.
queryOf :: State -> SearchQuery
queryOf st = SearchQuery {text = st.text, space = st.space, includeSubspaces = st.subspaces, limit = shown, templates = False}

-- | The search results page for the box's contents.
resultsRoute :: State -> Route
resultsRoute st =
  Search
    (Just (T.strip st.text))
    ((\sid -> spacePathOf st.input.context.spaces sid) <$> st.space)
    (isNothing st.space || st.subspaces)

-- | Whether what someone may find has changed.
changed :: Context -> Context -> Bool
changed a b = sessionOf a /= sessionOf b || a.revision /= b.revision
  where
    sessionOf :: Context -> Session
    sessionOf c = c.session

-- | The spaces the selector offers: those the user may view, by their path
-- of names, sorted by it.
choices :: Context -> [(SpaceId, Text)]
choices ctx =
  sortOn
    (T.toCaseFold . snd)
    [(s.id, T.intercalate " / " (spaceNamesOf ctx.spaces (spacePathOf ctx.spaces s.id))) | s <- ctx.spaces, mayView ctx s.id]
