{-# LANGUAGE QuasiQuotes #-}

-- | The "Export" menu of a page and of a space (WP4.16 of docs/PLAN.md): a
-- link for each document format the backend exports them to
-- ("Wiki.Api.Export"), which the browser downloads by itself, as it does an
-- attachment; a PDF opens in a new tab instead ('opensInline'), since a
-- browser may refuse a download from a wiki served over plain HTTP. The menu is a @\<details>@ element, so it opens and closes
-- without the program, in a page the server prerendered as well as in the
-- application. A backend that exports nothing (the demo, which has no
-- pandoc) shows no menu.
module Wiki.App.View.Export
  ( exportMenu
  )
where

import Halogen.HTML qualified as HH
import Halogen.TH (hh)
import Protolude
import Wiki.Api.Export (ExportFormat, exportFileName, formatLabel, formatName, opensInline)

-- | The menu for these formats, with each one's URL, for a document with
-- this title; nothing when there are no formats.
exportMenu :: [ExportFormat] -> (ExportFormat -> Text) -> Text -> [HH.HTML w i]
exportMenu formats url title
  | null formats = []
  | otherwise =
      [ [hh|
          <details class="export-menu">
            <summary class="button">Export</summary>
            <ul class="export-formats">
              {% for f in formats %}
                {% if opensInline f %}
                  <li><a class="export-{{ formatName f }}" href={{ url f }} target="_blank" rel="noopener">{{ formatLabel f <> " (opens in a tab)" }}</a></li>
                {% else %}
                  <li><a class="export-{{ formatName f }}" href={{ url f }} download={{ exportFileName title f }}>{{ formatLabel f }}</a></li>
                {% end %}
              {% end %}
            </ul>
          </details>
        |]
      ]
