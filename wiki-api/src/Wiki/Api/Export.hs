{-# LANGUAGE DeriveAnyClass #-}

-- | Export formats (WP4.16 of docs/PLAN.md): the document formats a page
-- or a space can be exported in, as the API names them in its paths
-- (@pages\/\<id>\/export\/\<format>@, @spaces\/\<id>\/export\/\<format>@)
-- and as the application offers them.
--
-- The server produces every format with pandoc, linked into it as a
-- library, so most formats need nothing else installed. The two PDF
-- formats are the exception: pandoc writes LaTeX and a TeX engine,
-- @xelatex@, turns it into a PDF, so a server offers them only where it
-- finds one ('needsTeX'). A backend reports the formats it offers in the
-- session (@Wiki.App.Backend.Session@'s @exports@), so that the
-- application shows only those. The demo, which has no pandoc, offers
-- none.
module Wiki.Api.Export
  ( ExportFormat (..)
  , formatName
  , formatLabel
  , formatExtension
  , formatMediaType
  , needsTeX
  , forDecks
  , pageFormats
  , spaceFormats
  , exportFileName
  , opensInline
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Protolude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))
import Wiki.Core.Slug (slugText, slugify)

-- | 'ExportFormat': a document format a page or a space is exported in.
data ExportFormat
  = -- | A Word document, its formulas as Word's own equations.
    Docx
  | -- | One self-contained web page, with its images embedded and its
    -- formulas as MathML.
    Html
  | -- | An e-book.
    Epub
  | -- | A PDF typeset by LaTeX: needs @xelatex@ on the server.
    Pdf
  | -- | A deck as a PowerPoint presentation.
    Pptx
  | -- | A deck as the LaTeX source of a Beamer presentation.
    BeamerTex
  | -- | A deck as a Beamer presentation, typeset: needs @xelatex@.
    BeamerPdf
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Its name in a path, such as @docx@ or @beamer-pdf@.
formatName :: ExportFormat -> Text
formatName = \case
  Docx -> "docx"
  Html -> "html"
  Epub -> "epub"
  Pdf -> "pdf"
  Pptx -> "pptx"
  BeamerTex -> "beamer-tex"
  BeamerPdf -> "beamer-pdf"

-- | Its label in a menu.
formatLabel :: ExportFormat -> Text
formatLabel = \case
  Docx -> "Word (.docx)"
  Html -> "Web page (.html)"
  Epub -> "E-book (.epub)"
  Pdf -> "PDF"
  Pptx -> "PowerPoint (.pptx)"
  BeamerTex -> "Beamer source (.tex)"
  BeamerPdf -> "Beamer PDF"

-- | Whether an exported document opens in a tab of the browser rather than
-- downloading: the PDFs. Chromium's browsers block a download over plain
-- HTTP (and Edge offers no way past it), while a PDF shown in a tab is a
-- navigation, which they let through; so on a wiki served over HTTP a PDF
-- can still be exported, and saved from the browser's viewer under its
-- file name. The server answers with @Content-Disposition: inline@ for
-- these and @attachment@ for the rest, and the export menu links to these
-- without @download@, in a new tab: both ask this function, so that they
-- cannot disagree.
opensInline :: ExportFormat -> Bool
opensInline = \case
  Pdf -> True
  BeamerPdf -> True
  _ -> False

-- | Its file extension, without the dot.
formatExtension :: ExportFormat -> Text
formatExtension = \case
  Docx -> "docx"
  Html -> "html"
  Epub -> "epub"
  Pdf -> "pdf"
  Pptx -> "pptx"
  BeamerTex -> "tex"
  BeamerPdf -> "pdf"

-- | The media type its file is served with.
formatMediaType :: ExportFormat -> Text
formatMediaType = \case
  Docx -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  Html -> "text/html; charset=utf-8"
  Epub -> "application/epub+zip"
  Pdf -> "application/pdf"
  Pptx -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  BeamerTex -> "application/x-tex; charset=utf-8"
  BeamerPdf -> "application/pdf"

-- | Whether a TeX engine typesets it, which the server must have.
needsTeX :: ExportFormat -> Bool
needsTeX = \case
  Pdf -> True
  BeamerPdf -> True
  _ -> False

-- | Whether it is a presentation format, which only a page written as a
-- deck ("Wiki.Core.Slides") is exported in.
forDecks :: ExportFormat -> Bool
forDecks = \case
  Pptx -> True
  BeamerTex -> True
  BeamerPdf -> True
  _ -> False

-- | The formats a page is offered in, among those a backend produces: the
-- presentation formats only for a deck.
pageFormats :: Bool -> [ExportFormat] -> [ExportFormat]
pageFormats deck = filter (\f -> deck || not (forDecks f))

-- | The formats a space is offered in, among those a backend produces: one
-- document of all its pages, never a presentation.
spaceFormats :: [ExportFormat] -> [ExportFormat]
spaceFormats = filter (not . forDecks)

-- | The file name an export is saved as: its title as a slug (so plain
-- ASCII that a header can carry unescaped), and the format's extension.
exportFileName :: Text -> ExportFormat -> Text
exportFileName title format = base <> "." <> formatExtension format
  where
    base = maybe "export" slugText (slugify (T.take 80 title))

instance ToHttpApiData ExportFormat where
  toUrlPiece = formatName

instance FromHttpApiData ExportFormat where
  parseUrlPiece t = case find (\f -> formatName f == T.toLower t) [minBound .. maxBound] of
    Just f -> Right f
    Nothing -> Left ("No such format: " <> t <> ". The formats are " <> T.intercalate ", " (map formatName [minBound .. maxBound]) <> ".")
