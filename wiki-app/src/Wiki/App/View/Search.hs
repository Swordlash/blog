{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The search box in the shell's header, and how a hit is shown, here and
-- on the page of all results ("Wiki.App.View.SearchResults").
--
-- The box is an input and a space selector: every space, or one space and
-- (unless that is unticked) its subspaces. What is typed is searched for
-- ('Wiki.App.Backend.searchPages') once typing pauses for 'pause', and the
-- best hits are listed under the input while focus is anywhere in the box.
-- Each hit is a link to its page, with its space's path and a snippet of its
-- text, the matches marked.
--
-- From the keyboard: @/@ anywhere outside a field focuses the input (see
-- @jsbits/search.js@), the arrows move through the hits, Enter opens the one
-- selected or, with none selected, the page of all results, and Escape closes
-- the list. Whatever leads away (a hit, the page of results) closes the list
-- and takes focus out of the box, so that @/@ works again where the reader
-- lands.
module Wiki.App.View.Search
  ( Input (..)
  , component

    -- * Hits, as every list of them shows them
  , hitContents
  , snippetHtml
  , spaceNamesOf
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..), preventDefault)
import Web.UIEvent.FocusEvent (FocusEvent)
import Web.UIEvent.FocusEvent qualified as FE
import Web.UIEvent.KeyboardEvent (KeyboardEvent)
import Web.UIEvent.KeyboardEvent qualified as KE
import Web.UIEvent.MouseEvent (MouseEvent)
import Web.UIEvent.MouseEvent qualified as ME
import Wiki.App.Backend (MonadWiki (..), Session)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Path (renderPath)
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name))

$( browserJS
     ["jsbits/search.js"]
     [ ("js_search_key", "wiki_search_key", Unsafe, [t|Event -> IO JSText|])
     , ("js_search_focus_leaves", "wiki_search_focus_leaves", Unsafe, [t|Element -> Event -> IO Bool|])
     , ("js_search_blur", "wiki_search_blur", Unsafe, [t|Element -> IO ()|])
     , ("js_search_bind_shortcut", "wiki_search_bind_shortcut", Unsafe, [t|Element -> IO ()|])
     , ("js_search_unbind_shortcut", "wiki_search_unbind_shortcut", Unsafe, [t|Element -> IO ()|])
     ]
 )

newtype Input = Input {context :: Context}

-- | The hits for what was last searched for, or none searched for yet.
data Results
  = NotSearched
  | Found SearchQuery [SearchHit]

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
  -- ^ The search waiting for typing to pause.
  , box :: H.RefLabel
  , input :: H.RefLabel
  , bound :: Maybe Element
  -- ^ The input the @/@ shortcut focuses, once it is bound.
  }

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Typed Text
  | Chose Text
  | Subspaces Bool
  | Run
  | Key KeyboardEvent
  | FocusIn
  | FocusOut FocusEvent
  | KeepFocus MouseEvent
  | Followed (Follow Route)

-- | How long typing has to pause before what is typed is searched for: long
-- enough not to search for every letter of a word typed quickly, short
-- enough that the list seems to follow the typing.
pause :: Int
pause = 150_000

-- | How many hits the list under the box shows; the page of all results
-- shows the rest.
shown :: Int
shown = 8

component :: forall query output m. (MonadWiki m, MonadUUID m, MonadIO m) => H.Component query Input output m
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
              , bound = Nothing
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
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
              onKeyDown={{ Key }}
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

    -- The list under the input. A press on it would take focus from the
    -- input before the click it starts lands, closing the list under the
    -- pointer, so the press is kept from doing that ('KeepFocus').
    dropdown :: State -> H.ComponentHTML Action Empty m
    dropdown st =
      [hh|
        <div class="search-results" id="wiki-search-results" onMouseDown={{ KeepFocus }}>
          {{ status }}{{ allResults }}
        </div>
      |]
      where
        allResults = Router.link st.context.router Followed (resultsRoute st) [HP.class_ "search-all"] [HH.text ("All results for “" <> T.strip st.text <> "”")]
        status = case st.results of
          NotSearched -> [hh|<p class="search-status">Searching…</p>|]
          Found _ [] -> [hh|<p class="search-status search-empty">No results</p>|]
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
      Initialize -> do
        ref <- gets (\st -> st.input)
        element' <- H.getRef ref
        for_ element' $ \element -> do
          H.liftEffect (liftIO (js_search_bind_shortcut element))
          modify (\st -> st {bound = Just element})
      Finalize -> gets (\st -> st.bound) >>= traverse_ (H.liftEffect . liftIO . js_search_unbind_shortcut)
      Receive Input {context} -> do
        before <- gets (\st -> st.context)
        -- A space that is gone, or no longer visible, is no longer chosen.
        modify (\st -> st {context, space = mfilter (mayView context) st.space})
        -- Someone else signed in, or the wiki changed: what they may find has
        -- changed with it.
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
          hits <- searchPages q
          -- Unless something else has been typed or chosen meanwhile, whose
          -- own search will come.
          current <- gets queryOf
          when (current == q) $ modify (\st -> st {results = Found q hits, selected = Nothing})
      Key ev -> do
        let event = KE.toEvent ev
        key <- H.liftEffect . liftIO $ do
          k <- fromJSText <$> js_search_key event
          when (k `elem` ["ArrowDown", "ArrowUp", "Enter"]) (preventDefault event)
          pure k
        case key of
          "ArrowDown" -> move 1
          "ArrowUp" -> move (-1)
          "Enter" -> pick
          "Escape" -> modify (\st -> st {open = False, selected = Nothing})
          _ -> pass
      FocusIn -> modify (\st -> st {open = True})
      FocusOut ev -> do
        ref <- gets (\st -> st.box)
        container' <- H.getRef ref
        for_ container' $ \container -> do
          leaving <- H.liftEffect (liftIO (js_search_focus_leaves container (FE.toEvent ev)))
          when leaving $ modify (\st -> st {open = False, selected = Nothing})
      KeepFocus ev -> H.liftEffect (liftIO (preventDefault (ME.toEvent ev)))
      Followed f -> do
        router <- gets (\st -> st.context.router)
        Router.follow router f
        leave

    -- Search for what is typed: after a pause in typing, or at once for a
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

    -- Close the list and take focus out of the box, for wherever the reader
    -- is going.
    leave :: H.HalogenM State Action Empty output m ()
    leave = do
      modify (\st -> st {open = False, selected = Nothing})
      ref <- gets (\st -> st.input)
      H.getRef ref >>= traverse_ (H.liftEffect . liftIO . js_search_blur)

-- | Whether the list under the input is shown: while focus is in the box and
-- there is something typed to list hits for.
listShown :: State -> Bool
listShown st = st.open && not (T.null (T.strip st.text))

-- | The query for what the box holds.
queryOf :: State -> SearchQuery
queryOf st = SearchQuery {text = st.text, space = st.space, includeSubspaces = st.subspaces, limit = shown}

-- | The page of all results for what the box holds.
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
-- of names, in the order of those.
choices :: Context -> [(SpaceId, Text)]
choices ctx =
  sortOn
    (T.toCaseFold . snd)
    [(s.id, T.intercalate " / " (spaceNamesOf ctx.spaces (spacePathOf ctx.spaces s.id))) | s <- ctx.spaces, mayView ctx s.id]

-- | The names of the spaces on a path, from the top level; the slugs of a
-- path the spaces given do not have.
spaceNamesOf :: [Space] -> [Slug] -> [Text]
spaceNamesOf spaces path = case findSpace spaces path of
  Just chain -> map (\s -> s.name) chain
  Nothing -> [renderPath path]

-- | What a link to a hit holds: its title, its space's path and its
-- snippet, the matches marked in both.
hitContents :: [Space] -> SearchHit -> [HH.HTML w i]
hitContents spaces hit =
  [hhs|
    <span class="search-hit-title">{{ snippetHtml hit.title }}</span>
    <span class="search-hit-space">{{ T.intercalate " / " (spaceNamesOf spaces hit.spacePath) }}</span>
    <span class="search-hit-snippet">{{ snippetHtml hit.snippet }}</span>
  |]

-- | A snippet's text, its matches in @\<mark>@.
snippetHtml :: Snippet -> [HH.HTML w i]
snippetHtml (Snippet pieces) = [if p.match then HH.mark_ [HH.text p.text] else HH.text p.text | p <- pieces]
