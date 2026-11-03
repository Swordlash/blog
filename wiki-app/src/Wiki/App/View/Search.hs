{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The search box in the shell's header, and how a hit is shown, here and
-- on the search results page ("Wiki.App.View.SearchResults").
--
-- The box is an input and a space selector: every space, or one space and
-- (unless that is unticked) its subspaces. The text typed is searched for
-- ('Wiki.App.Backend.searchPages') once typing pauses for 'pause', and the
-- best hits are listed under the input while focus is anywhere in the box.
-- Each hit is a link to its page, with its space's path and a snippet of
-- its text, the matches highlighted.
--
-- From the keyboard: @/@ anywhere outside a field focuses the input (see
-- @jsbits/search.js@), the arrows move through the hits, Enter opens the
-- selected hit or, with none selected, the search results page, and
-- Escape closes the list, and so does a press anywhere outside the box,
-- even one that leaves the focus in the input (@jsbits/search.js@). Whatever
-- navigates away (a hit, the results
-- page) closes the list and takes focus out of the box, so that @/@ works
-- again wherever the reader lands.
module Wiki.App.View.Search
  ( Input (..)
  , component

    -- * Hits, as every list of them shows them
  , hitContents
  , snippetHtml
  , spaceNamesOf
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
import Halogen.Query.Event.Window qualified as WindowEvent
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.Subscription (Emitter)
import Halogen.Subscription qualified as HS
import Halogen.TH (hh, hhs)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.DOM.Element qualified as Element
import Web.DOM.Internal.Types (Element (..), HTMLElement (..), toNode)
import Web.Event.Event (Event (..), EventType (..), defaultPreventedNow, preventDefault)
import Web.Event.Event qualified as Event
import Web.HTML.HTMLInputElement qualified as HTMLInputElement
import Web.UIEvent.FocusEvent (FocusEvent)
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Web.UIEvent.KeyboardEvent qualified as KeyboardEvent
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session, WikiError)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Path (renderPath)
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name))

newtype Input = Input {context :: Context}

-- | The hits for the last search, or none if nothing was searched yet.
data Results
  = NotSearched
  | Found SearchQuery [SearchHit]
  | -- | The search failed: the backend could not be reached.
    Unanswered SearchQuery WikiError

data State = State
  { context :: Context
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
  , input :: H.RefLabel
  }

data Action
  = Initialize
  | Shortcut
  | Receive Input
  | Typed Text
  | Chose Text
  | Subspaces Bool
  | Run
  | Move Int
  | Pick
  | Close
  | FocusIn
  | FocusOut FocusEvent
  | KeepFocus
  | Followed (Follow Route)

-- | How long typing must pause before the text is searched for: long
-- enough not to search for every letter of a word typed quickly, short
-- enough that the list seems to follow the typing.
pause :: Int
pause = 150_000

-- | How many hits the list under the box shows; the results page shows
-- the rest.
shown :: Int
shown = 8

component :: forall query output m. (MonadLoad m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \Input {context} -> do
          box <- H.newRefLabel "search-box"
          input <- H.newRefLabel "search-input"
          pure
            State
              { context
              , text = ""
              , space = Nothing
              , subspaces = True
              , results = NotSearched
              , open = False
              , selected = Nothing
              , pending = Nothing
              , box
              , input
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
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div
          ref={{ st.box }}
          class="wiki-search{% if listShown st %} open{% end %}"
          role="search"
          onFocusIn={{ const FocusIn }}
          onFocusOut={{ FocusOut }}
          {{ HE.handler' (EventType "wiki-search-outside") (const (Just Close)) }}
          {{ HE.handler' (EventType "keydown") closeKey }}
        >
          <div class="search-bar">
            {# No value: the box never sets the text itself, and a rendered
               value is put back on every render (Halogen compares it with the
               element's), which would undo a key typed between a render and
               the handling of the key before it, such as the first one after
               "/". #}
            <input
              ref={{ st.input }}
              type="search"
              class="search-input"
              placeholder="Search pages… (/)"
              aria-label="Search pages"
              aria-expanded={{ ariaBool (listShown st) }}
              aria-controls="wiki-search-results"
              autocomplete="off"
              spellcheck={{ False }}
              onValueInput={{ Typed }}
              {{ HE.preventingDefault (HE.handler' (EventType "keydown") listKey) }}
            >
            <select class="search-space" aria-label="Space to search" onValueChange={{ Chose }}>
              <option value="" selected={{ isNothing st.space }}>All spaces</option>
              {% for (sid, label) in choices st.context %}
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

    -- The keys that move through the list and pick from it, recognised in
    -- the input's listener, which stops the browser's own action for them
    -- (moving the cursor, submitting) while it dispatches the key, whatever
    -- the component is busy with. Any other key makes no action and is left
    -- to the browser.
    listKey :: Event -> Maybe Action
    listKey event = case (KeyboardEvent event).key of
      "ArrowDown" -> Just (Move 1)
      "ArrowUp" -> Just (Move (-1))
      "Enter" -> Just Pick
      _ -> Nothing

    -- Escape, anywhere in the box, closes the list, and the browser also
    -- does its own action (a search input clears its text).
    closeKey :: Event -> Maybe Action
    closeKey event = case (KeyboardEvent event).key of
      "Escape" -> Just Close
      _ -> Nothing

    -- The list under the input. A mouse press on it would take focus from
    -- the input before the click lands, closing the list under the pointer,
    -- so the press is stopped from doing that in its listener ('KeepFocus'
    -- itself does nothing).
    dropdown :: State -> H.ComponentHTML Action Empty m
    dropdown st =
      [hh|
        <div class="search-results" id="wiki-search-results" {{ HE.preventingDefault (HE.onMouseDown (const KeepFocus)) }}>
          {{ status }}{{ allResults }}
        </div>
      |]
      where
        allResults = Router.link st.context.router Followed (resultsRoute st) [HP.class_ "search-all"] [HH.text ("All results for “" <> T.strip st.text <> "”")]
        status = case st.results of
          NotSearched -> [hh|<p class="search-status">Searching…</p>|]
          Found _ [] -> [hh|<p class="search-status search-empty">No results</p>|]
          Unanswered _ e -> [hh|<p class="search-status search-failed">{{ errorMessage e }}</p>|]
          Found _ hits ->
            [hh|
              <ul class="search-hits" role="listbox">
                {% for (i, hit) in zip [0 ..] (take shown hits) %}{% let chosen = Just i == st.selected %}
                  <li role="option" aria-selected={{ ariaBool chosen }}>
                    {{ Router.link st.context.router Followed (Page hit.spacePath hit.pagePath) [HP.classes ("search-hit" : ["selected" | chosen])] (hitContents st.context.spaces hit) }}
                  </li>
                {% end %}
              </ul>
            |]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      -- The "/" shortcut and the press outside the box are heard for as
      -- long as the box is shown: the subscriptions end with it.
      Initialize -> do
        ref <- gets (\st -> st.input)
        found <- H.getRef ref
        for_ found $ \element -> do
          slashes <- H.liftEffect (slashPressed element)
          void (H.subscribe (Shortcut <$ slashes))
          presses <- H.liftEffect (pressedOutside element)
          void (H.subscribe (Close <$ presses))
      -- The browser was kept from typing the "/" in the listener; the box
      -- takes the focus now, with its text selected, to be typed over.
      Shortcut -> do
        ref <- gets (\st -> st.input)
        found <- H.getRef ref
        for_ found $ \element -> H.liftEffect . liftIO $ do
          (coerce element :: HTMLElement).focus
          for_ (HTMLInputElement.fromElement element) (.select)
      Receive Input {context} -> do
        before <- gets (\st -> st.context)
        -- A space that no longer exists, or is no longer visible, is
        -- deselected.
        modify (\st -> st {context, space = mfilter (mayView context) st.space})
        -- Someone else signed in, or the wiki changed: what they may find
        -- has changed too.
        when (changed before context) (schedule False)
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
      Close -> modify (\st -> st {open = False, selected = Nothing})
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
      Followed f -> do
        router <- gets (\st -> st.context.router)
        Router.follow router f
        leave

    -- Search for the typed text: after a pause in typing, or at once for a
    -- change of the space or the session. Blank text clears the list.
    schedule :: Bool -> H.HalogenM State Action Empty output m ()
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

    move :: Int -> H.HalogenM State Action Empty output m ()
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

    pick :: H.HalogenM State Action Empty output m ()
    pick = do
      st <- get
      let chosen = case (st.selected, st.results) of
            (Just i, Found _ hits) -> (\hit -> Page hit.spacePath hit.pagePath) <$> atMay hits i
            _ -> Nothing
      case chosen of
        Just r -> go r
        Nothing -> unless (T.null (T.strip st.text)) (go (resultsRoute st))
      where
        go r = do
          router <- gets (\st -> st.context.router)
          H.liftEffect (Router.navigate router r)
          leave

    -- Close the list and take focus out of the box, wherever the reader is
    -- going.
    leave :: H.HalogenM State Action Empty output m ()
    leave = do
      modify (\st -> st {open = False, selected = Nothing})
      ref <- gets (\st -> st.input)
      H.getRef ref >>= traverse_ (\element -> H.liftEffect (liftIO (coerce element :: HTMLElement).blur))

-- | The "/" shortcut: "/" pressed anywhere but in a field (where it is a
-- character to type), as GitHub and others have it. Whether a key is the
-- shortcut is decided in the window's listener, while the browser
-- dispatches the key, and the browser is told there not to type it; a key
-- an element has handled already, and kept from the browser, is left to
-- it. A page shown as slides covers the box, and takes its keys itself.
slashPressed :: (MonadBrowserDOM n, MonadUnliftIO n) => Element -> n (Emitter IO ())
slashPressed input = do
  HS.Emitter register <- WindowEvent.keyDown
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \pressed -> do
      connected <- input.isConnected
      when (connected && isShortcut pressed) $ do
        preventDefault (KeyboardEvent.toEvent pressed)
        push ()
    pure stop
  where
    isShortcut pressed =
      pressed.key == "/"
        && not (defaultPreventedNow (KeyboardEvent.toEvent pressed))
        && not (pressed.ctrlKey || pressed.metaKey || pressed.altKey)
        && isNothing (Event.target (KeyboardEvent.toEvent pressed) >>= Element.fromEventTarget >>= (`Element.closestNow` "input, textarea, select, [contenteditable], .slides-view"))

-- | A press anywhere outside the box, heard on the document, which closes
-- the list: the box's focusout does too, but a press on something that
-- keeps the focus where it is (a toolbar button that prevents its
-- mousedown's default) takes no focus from the input.
pressedOutside :: (MonadBrowserDOM n, MonadUnliftIO n) => Element -> n (Emitter IO ())
pressedOutside input = do
  HS.Emitter register <- WindowEvent.documentEvent (EventType "pointerdown") Just
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \press -> do
      connected <- input.isConnected
      box <- input.closest "[role=\"search\"]"
      case (box, Event.target press >>= Element.fromEventTarget) of
        (Just around, Just target) | connected -> do
          inside <- around.contains (toNode target)
          unless inside (push ())
        _ -> pass
    pure stop

-- | Whether the list under the input is shown: while focus is in the box
-- and there is typed text to list hits for.
listShown :: State -> Bool
listShown st = st.open && not (T.null (T.strip st.text))

-- | The query for the box's contents.
queryOf :: State -> SearchQuery
queryOf st = SearchQuery {text = st.text, space = st.space, includeSubspaces = st.subspaces, limit = shown, templates = False}

-- | The search results page for the box's contents.
resultsRoute :: State -> Route
resultsRoute st =
  Search
    (Just (T.strip st.text))
    ((\sid -> spacePathOf st.context.spaces sid) <$> st.space)
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

-- | The names of the spaces on a path, from the top level; the path's
-- slugs for spaces the given list does not have.
spaceNamesOf :: [Space] -> [Slug] -> [Text]
spaceNamesOf spaces path = case findSpace spaces path of
  Just chain -> map (\s -> s.name) chain
  Nothing -> [renderPath path]

-- | The contents of a link to a hit: its title, its space's path and its
-- snippet, with the matches highlighted in both.
hitContents :: [Space] -> SearchHit -> [HH.HTML w i]
hitContents spaces hit =
  [hhs|
    <span class="search-hit-title">{{ snippetHtml hit.title }}</span>
    <span class="search-hit-space">{{ T.intercalate " / " (spaceNamesOf spaces hit.spacePath) }}</span>
    <span class="search-hit-snippet">{{ snippetHtml hit.snippet }}</span>
  |]

-- | A snippet's text, with its matches in @\<mark>@.
snippetHtml :: Snippet -> [HH.HTML w i]
snippetHtml (Snippet pieces) = [if p.match then HH.mark_ [HH.text p.text] else HH.text p.text | p <- pieces]
