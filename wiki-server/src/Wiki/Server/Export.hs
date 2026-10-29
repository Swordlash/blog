{-# LANGUAGE TemplateHaskell #-}

-- | Export of pages and spaces as documents (WP4.16 of docs/PLAN.md),
-- with pandoc linked into the server as a library: no program is run
-- except the TeX engine that makes a PDF.
--
-- What a page becomes is decided in "Wiki.Server.Export.Document". Here
-- the page is read as its reader may read it, its images are put into
-- pandoc's media bag from the blob store, and the document is written in
-- the requested format ("Wiki.Api.Export"):
--
-- * DOCX, with its formulas as Word's own equations, which texmath makes;
-- * HTML, one standalone page with its images inside it (pandoc's
--   self-contained HTML) and its formulas as MathML, which a browser shows
--   without a script;
-- * EPUB;
-- * PDF, made by pandoc's LaTeX writer and @xelatex@, through pandoc's own
--   PDF path in a temporary directory it removes afterwards;
-- * for a deck ("Wiki.Core.Slides"): PowerPoint, and Beamer's LaTeX or its
--   PDF. The deck's aspect ratio becomes Beamer's @aspectratio@, and its
--   theme a Beamer theme ('beamerLook'). PowerPoint gets pandoc's own
--   reference presentation, which is 16:9, whatever the deck says.
--
-- A space is one document of its pages in its order, under a title page
-- (its name, its description, when it was exported) and a table of
-- contents.
--
-- The PDFs need @xelatex@, which is looked for on the server's @PATH@ each
-- time it matters ('texEngine'), so that installing it needs no restart.
-- The session tells the application which formats are offered
-- ('availableFormats'), and a PDF requested without it is refused, saying
-- so.
--
-- TeX is a programming language with access to files and a shell, and a
-- PDF gives it what authors wrote: a TikZ picture is LaTeX by design, and
-- texmath writes an unknown control sequence back out into a formula. So
-- @\\input{\/etc\/passwd}@ in a formula would put a file of the server's
-- into the PDF, and @\\openout@ would write one. So before the engine runs,
-- TeX's own limits are set in the server's environment, which pandoc
-- passes to the engine ('restrictTeX'): files are read and written only
-- under the directory it typesets in (and TeX's own trees), and no program
-- is run, not even the few TeX Live allows by default. Nothing here passes
-- the engine an option that would lift those limits.
--
-- An export takes time and memory, so each person has one at a time
-- ('Exports'), and none takes more than 'exportTimeout'; the TeX engine is
-- stopped with it.
module Wiki.Server.Export
  ( -- * Exporting
    Exports
  , newExports
  , Exported (..)
  , exportPage
  , exportSpace
  , exportTimeout
  , oneAtATime

    -- * What can be made
  , availableFormats
  , texEngine
  , restrictTeX
  , texLimits

    -- * Writing
  , writeDocument
  , beamerLook
  )
where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.FileEmbed (embedStringFile, makeRelativeToProject)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Protolude
import System.Directory (doesFileExist, findExecutable)
import System.Environment (setEnv)
import System.Timeout (timeout)
import Text.Pandoc (PandocError, PandocIO, Verbosity (..), WriterOptions (..), compileDefaultTemplate, def, renderError, runIO, setMediaBag, setVerbosity, writeBeamer, writeDocx, writeEPUB3, writeHtml5String, writeLaTeX, writePowerpoint)
import Text.Pandoc.Builder qualified as B
import Text.Pandoc.Definition qualified as P
import Text.Pandoc.MediaBag (MediaBag, insertMedia)
import Text.Pandoc.Options (MathMethod (..))
import Text.Pandoc.PDF (makePDF)
import Text.Pandoc.SelfContained (makeSelfContained)
import Text.Pandoc.Walk (query)
import Wiki.Api.Error (ApiError)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Export (ExportFormat (..), exportFileName, forDecks, formatLabel, needsTeX)
import Wiki.Api.Links (attachmentUrl)
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend (MonadWiki (listSpaces), WikiError (..))
import Wiki.App.View.Common (pagePathOf, spacePathOf)
import Wiki.Core.Attachment (Attachment (..), MediaKind (..), MimeType (..), Source (..), attachmentKind)
import Wiki.Core.Id
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Markdown.Box (BoxKind)
import Wiki.Core.Math (Macros (..), spaceMacros)
import Wiki.Core.Page (Page (..), pageTreeOrder)
import Wiki.Core.Slides (Aspect (..), Deck (..), DeckOptions (..), Theme (..), deckOf, isDeck)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Server.Export.Document
import Wiki.Server.Storage (Storage, Who (..), blobPath, exportedPage, readServerSettings, runStoredWiki, spacePages)

-- | Whose exports are in progress: at most one each.
newtype Exports = Exports (TVar (Set Text))

newExports :: IO Exports
newExports = Exports <$> newTVarIO Set.empty

-- | How long an export may take, TeX's run included: one that takes
-- longer is stopped and refused.
exportTimeout :: Int
exportTimeout = 60_000_000

-- | A finished document: the file name it is saved under, its format and
-- its bytes.
data Exported = Exported
  { fileName :: Text
  , format :: ExportFormat
  , bytes :: ByteString
  }

-- | The TeX engine the PDFs are made with, if the server's machine has one.
texEngine :: IO (Maybe FilePath)
texEngine = findExecutable "xelatex"

-- | What TeX may do, as kpathsea's variables, which override its
-- configuration from the environment: read and write files only under the
-- working directory and @TEXMFOUTPUT@ (the temporary directory pandoc
-- typesets in; @p@, paranoid, also refuses dot files and @..@), and run no
-- program at all (@f@; TeX Live's default, restricted, still runs a few).
texLimits :: [([Char], [Char])]
texLimits = [("openin_any", "p"), ("openout_any", "p"), ("shell_escape", "f")]

-- | Set 'texLimits' in the server's environment, which pandoc gives the
-- TeX engine it runs. This is process-wide, which is right: nothing else
-- the server runs reads them. It is done before every PDF, so that nothing
-- can have changed them since.
restrictTeX :: IO ()
restrictTeX = traverse_ (uncurry setEnv) texLimits

-- | The formats the server can make documents in: all of them where it has
-- a TeX engine, and all except the PDFs where it has not.
availableFormats :: IO [ExportFormat]
availableFormats = do
  tex <- isJust <$> texEngine
  pure [f | f <- [minBound .. maxBound], tex || not (needsTeX f)]

-- | Export a page as a document, for someone who may read it; only a deck
-- as a presentation. The key identifies whose export it is, for the limit
-- of one at a time.
exportPage :: Exports -> Text -> Storage -> Who -> PageId -> ExportFormat -> IO (Either ApiError Exported)
exportPage exports key storage who pid format = oneAtATime exports key . requiringTeX format $ do
  loaded <- runStoredWiki storage who $ runExceptT $ do
    page <- ExceptT (exportedPage pid)
    spaces <- lift listSpaces
    pages <- ExceptT (spacePages page.space)
    pure (page, spaces, pages)
  case loaded of
    Left e -> pure (Left (refusalOf e))
    Right (page, spaces, pages) -> do
      settings <- readServerSettings storage
      now <- getCurrentTime
      let deck = either (const False) isDeck (parseMarkdown page.body)
          looks = either (const (deckOf [])) deckOf (parseMarkdown page.body)
          output = outputOf format
          place = placeOf settings.publicUrl settings.boxes spaces pages page (\_ _ -> Nothing) ""
      if forDecks format && not deck
        then pure (Left (ApiError.Invalid "Only a page written as slides exports as a presentation."))
        else do
          (bag, stored) <- mediaOf storage [page]
          case pageBlocks output (place stored) page.body of
            Left e -> pure (Left (ApiError.Invalid ("The page could not be read: " <> renderError e)))
            Right blocks -> do
              let doc
                    | forDecks format = slidesDocument page.title (beamerLook looks.options) blocks
                    | otherwise = withDate now (pageDocument page.title blocks)
              written <- writeDocument format bag False doc
              pure (Exported (exportFileName page.title format) format <$> written)

-- | Export a space's pages as one document, for someone who may view the
-- space.
exportSpace :: Exports -> Text -> Storage -> Who -> SpaceId -> ExportFormat -> IO (Either ApiError Exported)
exportSpace exports key storage who sid format = oneAtATime exports key . requiringTeX format $ do
  loaded <- runStoredWiki storage who $ runExceptT $ do
    -- The pages first: fetching them says whether the space exists and
    -- may be read, as the API's own listing does.
    pages <- ExceptT (spacePages sid)
    spaces <- lift listSpaces
    space <- maybe (throwError NotFound) pure (find (\s -> s.id == sid) spaces)
    pure (space, spaces, pages)
  case loaded of
    Left e -> pure (Left (refusalOf e))
    Right (space, spaces, pages)
      | forDecks format -> pure (Left (ApiError.Invalid "A space exports as a document, not a presentation."))
      | otherwise -> do
          settings <- readServerSettings storage
          now <- getCurrentTime
          let ordered = pageTreeOrder space.pageOrder pages
              anchors = Map.fromList [(p.id, "page-" <> show n) | (n, p) <- zip [1 :: Int ..] ordered]
              spacePath = spacePathOf spaces space.id
              inDocument s path = if s == spacePath then head [a | p <- ordered, pagePathOf pages p.id == path, Just a <- [Map.lookup p.id anchors]] else Nothing
              output = outputOf format
          (bag, stored) <- mediaOf storage ordered
          let pageOf p =
                let anchor = Map.findWithDefault "" p.id anchors
                 in DocumentPage p (length (pagePathOf pages p.id) - 1) anchor
                      <$> pageBlocks output (placeOf settings.publicUrl settings.boxes spaces pages p inDocument (anchor <> "-") stored) p.body
          case traverse pageOf ordered of
            Left e -> pure (Left (ApiError.Invalid ("A page could not be read: " <> renderError e)))
            Right documentPages -> do
              let made = toS (formatTime defaultTimeLocale "%e %B %Y" now)
                  doc = spaceDocument space ("Exported from the wiki on " <> T.strip made) documentPages
              written <- writeDocument format bag True doc
              pure (Exported (exportFileName space.name format) format <$> written)

-- | What kind of document a format is, as far as reading a page cares.
outputOf :: ExportFormat -> Output
outputOf = \case
  BeamerTex -> ToBeamer
  BeamerPdf -> ToBeamer
  Pptx -> ToPowerPoint
  Pdf -> ToTeX
  Docx -> ToOther
  Html -> ToOther
  Epub -> ToOther

-- | Check the format before anything is read: a PDF needs a TeX engine.
requiringTeX :: ExportFormat -> IO (Either ApiError a) -> IO (Either ApiError a)
requiringTeX format go
  | needsTeX format =
      texEngine >>= \case
        Nothing -> pure (Left (ApiError.Invalid (formatLabel format <> " needs xelatex, which this server's machine does not have.")))
        Just _ -> go
  | otherwise = go

-- | Allow one export at a time per key, and none longer than
-- 'exportTimeout'.
oneAtATime :: Exports -> Text -> IO (Either ApiError a) -> IO (Either ApiError a)
oneAtATime (Exports busy) key go = do
  taken <- atomically $ do
    now <- readTVar busy
    if Set.member key now then pure False else True <$ writeTVar busy (Set.insert key now)
  if not taken
    then pure (Left (ApiError.TooManyRequests "An export of yours is still being made: try again when it is done."))
    else
      (timeout exportTimeout go <&> fromMaybe (Left (ApiError.Invalid ("The export took longer than " <> show (exportTimeout `div` 1_000_000) <> " seconds, and was stopped."))))
        `finally` atomically (modifyTVar' busy (Set.delete key))

refusalOf :: WikiError -> ApiError
refusalOf = \case
  NotFound -> ApiError.NotFound
  Forbidden -> ApiError.Forbidden
  Conflict t -> ApiError.Conflict t
  Invalid t -> ApiError.Invalid t
  Unreachable t -> ApiError.Invalid t

-- | Where a page is, for reading it.
placeOf :: Maybe Url -> [BoxKind] -> [Space] -> [Page] -> Page -> ([Slug] -> [Slug] -> Maybe Text) -> Text -> (AttachmentId -> Bool) -> Place
placeOf publicUrl boxes spaces pages page inDocument idPrefix stored =
  Place
    { spaces
    , spacePath = spacePathOf spaces page.space
    , pages
    , pagePath = pagePathOf pages page.id
    , attachments = page.attachments
    , stored
    , attachmentAddress = attachmentUrl
    , publicUrl
    , inDocument
    , idPrefix
    , macros = Macros [katexOwn, builtinMacros] <> spaceMacros spaces page.space
    , boxes
    }

-- | The macros every page has, before its space's: the wiki's built-in
-- ones, which KaTeX reads in the browser (@web/src/katex-macros.tex@,
-- embedded here as it is bundled there, so that the two cannot differ).
builtinMacros :: Text
builtinMacros = $(makeRelativeToProject "../web/src/katex-macros.tex" >>= embedStringFile)

-- | KaTeX's own commands that a page may use and LaTeX lacks, defined as
-- macros: the built-in macros leave them out for that reason.
katexOwn :: Text
katexOwn =
  T.unlines
    [ "\\newcommand{\\N}{\\mathbb{N}}"
    , "\\newcommand{\\R}{\\mathbb{R}}"
    , "\\newcommand{\\Z}{\\mathbb{Z}}"
    , "\\newcommand{\\Complex}{\\mathbb{C}}"
    , "\\newcommand{\\cnums}{\\mathbb{C}}"
    , "\\newcommand{\\bra}[1]{\\left\\langle #1 \\right|}"
    , "\\newcommand{\\ket}[1]{\\left| #1 \\right\\rangle}"
    , "\\newcommand{\\braket}[1]{\\left\\langle #1 \\right\\rangle}"
    ]

-- | The images of some pages, from the blob store, in a media bag at
-- their 'mediaPath'; and which attachments are in it.
mediaOf :: Storage -> [Page] -> IO (MediaBag, AttachmentId -> Bool)
mediaOf storage pages = do
  found <- fmap catMaybes . for [a | p <- pages, a <- p.attachments, attachmentKind a == MediaImage] $ \a -> case a.source of
    SourceBlob b | Just file <- blobPath storage b -> do
      present <- doesFileExist file
      if present then Just . (a,) <$> BS.readFile file else pure Nothing
    _ -> pure Nothing
  let bag = foldl' (\m (a, bytes) -> insertMedia (mediaPath a) (Just a.mediaType.text) (BSL.fromStrict bytes) m) mempty found
      ids = Set.fromList [a.id | (a, _) <- found]
  pure (bag, (`Set.member` ids))

-- | A page's document, with a date.
withDate :: UTCTime -> P.Pandoc -> P.Pandoc
withDate now (P.Pandoc (P.Meta meta) bs) =
  P.Pandoc (P.Meta (Map.insert "date" (P.MetaInlines (B.toList (B.text (T.strip (toS (formatTime defaultTimeLocale "%e %B %Y" now)))))) meta)) bs

-- | A deck's look in Beamer: its aspect ratio, and a theme close to the
-- wiki's. The wiki's @beamer@ look, a title bar and a footer with the
-- title and the slide number, is Beamer's Madrid; @light@ is Beamer's plain
-- default; @dark@ is the default theme, light on dark.
beamerLook :: DeckOptions -> [(Text, P.MetaValue)]
beamerLook o =
  [ ("aspectratio", P.MetaString (case o.aspect of Wide -> "169"; Standard -> "43"))
  ]
    <> case o.theme of
      Beamer -> [("theme", P.MetaString "Madrid")]
      Light -> []
      Dark ->
        [
          ( "header-includes"
          , P.MetaList
              [ P.MetaBlocks
                  [ P.RawBlock
                      (P.Format "latex")
                      "\\setbeamercolor{background canvas}{bg=black!90}\n\\setbeamercolor{normal text}{fg=white}\n\\setbeamercolor{frametitle}{fg=white}\n\\setbeamercolor{title}{fg=white}\n\\setbeamercolor{structure}{fg=cyan!70}\n\\usebeamercolor[fg]{normal text}"
                  ]
              ]
          )
        ]

-- | Write a document in a format, with its images from the media bag, and
-- with a table of contents when asked. What pandoc or TeX could not make
-- is refused with their reason.
writeDocument :: ExportFormat -> MediaBag -> Bool -> P.Pandoc -> IO (Either ApiError ByteString)
writeDocument format bag toc doc = do
  tex <- texEngine
  result <- runIO $ do
    -- What pandoc would warn about (a formula texmath cannot convert,
    -- which it then writes as TeX) is not a failure, and not the server's
    -- to log.
    setVerbosity ERROR
    setMediaBag bag
    write tex (withPreamble doc)
  -- Forced here, inside the caller's timeout, rather than when it is
  -- sent.
  case result of
    Left e -> pure (Left (failed e))
    Right (Left why) -> pure (Left (ApiError.Invalid why))
    Right (Right bytes) -> Right <$> evaluate (BS.copy bytes)
  where
    failed :: PandocError -> ApiError
    failed e = ApiError.Invalid ("The document could not be made: " <> renderError e)
    standalone name = do
      template <- compileDefaultTemplate name
      pure
        def
          { writerTemplate = Just template
          , writerTableOfContents = toc
          , writerTOCDepth = 3
          , writerMathMethod = MathML
          , writerSlideLevel = if forDecks format then Just 2 else Nothing
          }
    plain = def {writerTableOfContents = toc, writerTOCDepth = 3, writerSlideLevel = if forDecks format then Just 2 else Nothing}
    write :: Maybe FilePath -> P.Pandoc -> PandocIO (Either Text ByteString)
    write tex d = case format of
      Docx -> Right . BSL.toStrict <$> writeDocx plain d
      Pptx -> Right . BSL.toStrict <$> writePowerpoint plain d
      Epub -> do
        o <- standalone "epub3"
        Right . BSL.toStrict <$> writeEPUB3 o d
      Html -> do
        o <- standalone "html5"
        Right . encodeUtf8 <$> (makeSelfContained =<< writeHtml5String o d)
      BeamerTex -> do
        o <- standalone "beamer"
        Right . encodeUtf8 <$> writeBeamer o d
      Pdf -> pdf tex writeLaTeX "latex" d
      BeamerPdf -> pdf tex writeBeamer "beamer" d
    pdf tex writer name d = case tex of
      Nothing -> pure (Left (formatLabel format <> " needs xelatex, which this server's machine does not have."))
      Just engine -> do
        o <- standalone name
        liftIO restrictTeX
        makePDF engine [] writer o d <&> \case
          Left logged -> Left ("TeX could not make the PDF: " <> texError (decodeUtf8With lenientDecode (BSL.toStrict logged)))
          Right bytes -> Right (BSL.toStrict bytes)

-- | What a document's LaTeX needs in its preamble: the TikZ packages its
-- pictures load, and mhchem where a formula writes chemistry (@\\ce@,
-- @\\pu@), which KaTeX has built in and LaTeX lacks. LaTeX's mhchem has no
-- @\\pu@ (a quantity with its unit is KaTeX's own addition), so one is
-- defined beside it, typesetting the quantity as text, which keeps the
-- space between the number and its unit. Other formats ignore it.
withPreamble :: P.Pandoc -> P.Pandoc
withPreamble (P.Pandoc (P.Meta meta) bs) = case tikzPreamble bs <> chemistry of
  [] -> P.Pandoc (P.Meta meta) bs
  loaded ->
    let ours = P.MetaBlocks [P.RawBlock (P.Format "latex") (T.intercalate "\n" loaded)]
        included = case Map.lookup "header-includes" meta of
          Just (P.MetaList xs) -> P.MetaList (xs <> [ours])
          _ -> P.MetaList [ours]
     in P.Pandoc (P.Meta (Map.insert "header-includes" included meta)) bs
  where
    chemistry =
      ["\\usepackage[version=4]{mhchem}" | not (null (query (chemical ["\\ce{", "\\pu{"]) bs))]
        <> ["\\providecommand{\\pu}[1]{\\text{#1}}" | not (null (query (chemical ["\\pu{"]) bs))]
    chemical commands = \case
      P.Math _ tex | any (`T.isInfixOf` tex) commands -> [()]
      _ -> []

-- | The part of TeX's log that says what went wrong: its errors (the
-- lines that start with @!@ and the two after each), or its end.
texError :: Text -> Text
texError logged = case errorLines (T.lines logged) of
  [] -> T.unlines (reverse (take 8 (reverse (T.lines logged))))
  found -> T.unlines (take 12 found)
  where
    errorLines = \case
      [] -> []
      l : rest | "!" `T.isPrefixOf` l -> l : take 2 rest <> errorLines (drop 2 rest)
      _ : rest -> errorLines rest
