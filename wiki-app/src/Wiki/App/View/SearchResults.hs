{-# LANGUAGE QuasiQuotes #-}

-- | The page of all results of a search (the route 'Search'): what the box
-- in the header lists the best of, in full, each hit shown as the box shows
-- it. The search box is where a search is typed; this page is where Enter in
-- it leads, and an address a search can be kept and shared by.
module Wiki.App.View.SearchResults
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.App.View.Search (hitContents, spaceNamesOf)
import Wiki.Core.Search (SearchHit (..), SearchQuery (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))

data Input = Input
  { context :: Context
  , text :: Maybe Text
  , space :: Maybe [Slug]
  -- ^ The path of the space searched, or 'Nothing' for every space.
  , subspaces :: Bool
  }

-- | What the page shows for its input.
data Results
  = -- | Nothing typed to search for.
    NoQuery
  | -- | The space searched is not one the user can see.
    NoSpace
  | Hits [SearchHit]

data State = State
  { input :: Input
  , results :: Results
  }

data Action = Initialize | Receive Input | Followed (Follow Route)

-- | As many hits as a page of results lists: more than anyone reads through,
-- few enough that the page stays quick to render.
limitOf :: Int
limitOf = 200

component :: forall query m. (MonadWiki m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Searched at once rather than in 'Initialize', so that the first
        -- render is the page the prerender shows (see "Wiki.App.Shell").
        initialState = \input -> State input <$> search input
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
    render State {input, results} =
      [hh|
        <section class="search-view">
          <h1>Search</h1>
          {{ found }}
        </section>
      |]
      where
        found = case results of
          NoQuery -> [[hh|<p class="empty">Type what to look for in the search box at the top of the page, or press / to get there.</p>|]]
          NoSpace -> [[hh|<p class="empty">There is no such space to search in, or you may not see it.</p>|]]
          Hits hits ->
            [hhs|
              <p class="search-summary">{{ summary input (length hits) }}</p>
              {% if not (null hits) %}
                <ol class="search-hits">
                  {% for hit in hits %}
                    <li>{{ Router.link input.context.router Followed (Page hit.spacePath hit.pagePath) [HP.class_ "search-hit"] (hitContents input.context.spaces hit) }}</li>
                  {% end %}
                </ol>
              {% end %}
            |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      -- The results came with the initial state: the shell is told.
      Initialize -> H.raise Loaded
      Receive input -> do
        before <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (differs before input) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      results <- search input
      -- Unless the input has changed meanwhile, whose own load will come.
      now <- gets (\st -> st.input)
      unless (differs now input) $ do
        modify (\st -> st {results})
        H.raise Loaded

-- | The pages the input asks for, or why there are none to look for.
search :: (MonadWiki n) => Input -> n Results
search Input {context, text, space, subspaces} =
  case (T.strip <$> text, traverse (findSpace context.spaces) space) of
    (Nothing, _) -> pure NoQuery
    (Just "", _) -> pure NoQuery
    (_, Nothing) -> pure NoSpace
    (Just wanted, Just chain)
      | Just sid <- (\c -> (\s -> s.id) <$> lastMay c) =<< chain
      , not (mayView context sid || subspaces) ->
          pure NoSpace
      | otherwise ->
          Hits
            <$> searchPages
              SearchQuery
                { text = wanted
                , space = (\c -> (\s -> s.id) <$> lastMay c) =<< chain
                , includeSubspaces = subspaces
                , limit = limitOf
                }

-- | Whether the page has to search again: for other words or another space,
-- or because who is asking or the wiki has changed. The tree of spaces counts
-- too: a space searched in is looked up there, and it changes when the shell
-- reloads the wiki.
differs :: Input -> Input -> Bool
differs a b =
  a.text /= b.text
    || a.space /= b.space
    || a.subspaces /= b.subspaces
    || a.context.session /= b.context.session
    || a.context.revision /= b.context.revision
    || a.context.spaces /= b.context.spaces

-- | How many pages match, and where they were looked for.
summary :: Input -> Int -> Text
summary input n =
  count <> " for “" <> maybe "" T.strip input.text <> "”" <> case input.space of
    Nothing -> " in every space."
    Just path ->
      " in "
        <> T.intercalate " / " (spaceNamesOf input.context.spaces path)
        <> (if input.subspaces then " and its subspaces." else ".")
  where
    count = case n of
      0 -> "No results"
      1 -> "One page"
      _ | n >= limitOf -> "The first " <> show n <> " pages"
      _ -> show n <> " pages"
