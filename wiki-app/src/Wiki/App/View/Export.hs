{-# LANGUAGE QuasiQuotes #-}

-- | The "Export" menu a page and a space show (WP4.16 of docs/PLAN.md): a
-- link for each document the backend exports them as ("Wiki.Api.Export"),
-- which the browser downloads by itself, as it does an attachment. The
-- menu is a @\<details>@, so it opens and closes with no program, in a page
-- the server rendered as much as in the application; a backend that
-- exports nothing (the demo, which has no pandoc) shows none.
module Wiki.App.View.Export
  ( exportMenu
  )
where

import Halogen.HTML qualified as HH
import Halogen.TH (hh)
import Protolude
import Wiki.Api.Export (ExportFormat, exportFileName, formatLabel, formatName)

-- | The menu for these formats, with each one's address, for a document
-- titled so: nothing when there are none.
exportMenu :: [ExportFormat] -> (ExportFormat -> Text) -> Text -> [HH.HTML w i]
exportMenu formats url title
  | null formats = []
  | otherwise =
      [ [hh|
          <details class="export-menu">
            <summary class="button">Export</summary>
            <ul class="export-formats">
              {% for f in formats %}
                <li><a class="export-{{ formatName f }}" href={{ url f }} download={{ exportFileName title f }}>{{ formatLabel f }}</a></li>
              {% end %}
            </ul>
          </details>
        |]
      ]
