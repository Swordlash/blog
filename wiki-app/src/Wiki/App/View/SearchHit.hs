{-# LANGUAGE QuasiQuotes #-}

-- | How a search hit is shown, the same in every list of hits: the search
-- box's ("Wiki.App.View.PagePicker", in the header and in the editor's
-- "Link to a page" dialog) and the search results page's
-- ("Wiki.App.View.SearchResults").
module Wiki.App.View.SearchHit
  ( hitContents
  , snippetHtml
  , spaceNamesOf
  )
where

import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.TH (hhs)
import Protolude
import Wiki.App.View.Common
import Wiki.Core.Path (renderPath)
import Wiki.Core.Search (Piece (..), SearchHit (..), Snippet (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (name))

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
