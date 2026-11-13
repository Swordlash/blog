-- | What the smoke suites allow a program to change on a page it adopts,
-- and the adoption check they run.
--
-- A suite holds the program's request (@app.wasm@), marks every node of
-- the page the server sent, lets the program go, and counts every change
-- since as a 'Repair': HTML that a page rendered ahead got wrong. The
-- marking and the comparing are haskell-halogen-playwright's
-- ('markServed', 'repairsSinceMarked'). This module says what is not a
-- repair: the attributes the page's scripts write ('scriptAttributes'),
-- the inside of the islands, which their libraries fill ('islands'), and
-- the height the islands' script gives an html fence's frame
-- ('adoptionMayChange'). The demo has one more thing of its own: an
-- attachment uploaded as bytes, served from an object URL ('objectUrl').
--
-- It also says which pages a page embeds as presentations
-- ('presentationsEmbedded'), and whether a request is a presentation
-- viewer's ('viewerAsks'): the server's suite checks that a page's
-- program asks for nothing else while it starts.
module Wiki.Smoke.Adoption
  ( -- * What adoption may change
    scriptAttributes
  , islands
  , fittedFrame
  , adoptionMayChange
  , adoptionOptions
  , serverAdoptionOptions

    -- * Loading a page and checking its adoption
  , Shown (..)
  , shown
  , Adopted (..)
  , adoptedAfter
  , markPrerendered
  , markPrerenderedWith
  , framesFitted
  , sortRepairs
  , stillPrerendered

    -- * Presentations embedded in a page
  , presentationsEmbedded
  , viewerAsks
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.Char (isDigit, isSpace)
import Data.List (nub, partition)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Network.HTTP.Types.URI (urlDecode)

-- | The attributes the page's scripts set, whatever the server sent:
-- @data-prerendered@ the suites' own mark on the shell ('markPrerendered');
-- @data-stuck@ the layout's, on a bar that sticks under the header once
-- the window scrolls (@wiki-app/jsbits/layout.js@); @data-current@ the
-- contents', on the link to the section being read
-- (@wiki-app/jsbits/toc.js@); and @data-unseen@ the shell's, on the link to
-- \"What's new?\", from what this browser has seen.
scriptAttributes :: [Text]
scriptAttributes = ["data-prerendered", "data-stuck", "data-current", "data-unseen"]

-- | The islands: elements the program keeps as the server sent them, with
-- their attributes, while a library fills them (KaTeX, Mermaid, TikZJax,
-- highlight.js) or the browser writes a time in the reader's zone. The
-- prerender writes an island's source in it, so that a page reads before
-- the libraries have loaded; the program takes the source out as it adopts
-- the island. What is in an island is not compared.
islands :: [Text]
islands = [".wiki-math", ".wiki-mermaid", ".wiki-tikz", ".wiki-code", ".wiki-time"]

-- | An html fence's frame that the islands' script fits to its content
-- (@wiki-app/jsbits/islands.js@, @wiki_islands_fit_frame@): every frame but
-- one whose fence gives a height, which has @data-height@ and its height
-- in the prerendered style, and which the script leaves alone.
fittedFrame :: Text
fittedFrame = "iframe.wiki-html:not([data-height])"

-- | Whether a change of one attribute of an adopted element is one the
-- program may make: the attribute named, changed from one value to
-- another ('Nothing' when absent), on an element that is a fitted frame or
-- not (one matching 'fittedFrame'). A fitted frame's height is measured
-- once its document has loaded, so the prerender has no style on such a
-- frame and cannot have one; the fitter then gives it its height. Nothing
-- else of the frame may change: a style the frame had, a style with more
-- than a height, its @srcdoc@, @sandbox@, class or title is still a repair.
adoptionMayChange :: Bool -> Text -> Maybe Text -> Maybe Text -> Bool
adoptionMayChange fitted name before after =
  name `elem` scriptAttributes
    || (fitted && name == "style" && isNothing before && maybe False fittedHeight after)

-- | The style the fitter writes on a fitted frame, its height alone, in
-- whole pixels, as the browser writes back @frame.style.height@:
-- @height: 412px;@.
fittedHeight :: Text -> Bool
fittedHeight style = case Text.stripPrefix "height: " style >>= Text.stripSuffix "px;" of
  Just digits -> not (Text.null digits) && Text.all isDigit digits
  Nothing -> False

-- | What the suites compare: under @#app@, with the islands' insides left
-- out and the scripts' attributes ignored.
adoptionOptions :: AdoptionOptions
adoptionOptions = defaultAdoptionOptions {leaveOutContents = islands, ignoredAttributes = scriptAttributes}

-- | What the server's suite compares: as 'adoptionOptions', and the
-- inside of the editor's host too, where CodeMirror goes in place of the
-- textarea; and not at all what the browser fills in from what it keeps
-- itself after the first render, whatever the server sent: the
-- directory's spaces visited last, which this browser's local storage
-- holds ("Wiki.App.Recent"), and the editor's bubbles of the writing
-- assistant, which come with the settings this browser's IndexedDB keeps
-- for the user ("Wiki.App.Assistant").
serverAdoptionOptions :: AdoptionOptions
serverAdoptionOptions =
  adoptionOptions
    { leaveOut = [".recent-spaces", ".editor-providers"]
    , leaveOutContents = islands <> [".editor-cm"]
    }

-- | What a page shows of its route: the document's title, the heading of
-- the content, the view it is in, and the error shown in its place, if
-- any.
data Shown = Shown
  { title :: Text
  , heading :: Maybe Text
  , view :: Maybe Text
  , failure :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON Shown where
  parseJSON = withObject "Shown" $ \o -> Shown <$> o .: "title" <*> o .:? "heading" <*> o .:? "view" <*> o .:? "error"

-- | What the page shows of its route now.
shown :: Page -> IO Shown
shown page =
  evaluate
    page
    "(() => {\
    \  const content = document.querySelector('#app .wiki-content');\
    \  const view = content?.querySelector(':scope > *:not(.leave-confirm)');\
    \  return {\
    \    title: document.title,\
    \    heading: content?.querySelector('h1')?.textContent.trim() ?? null,\
    \    view: view ? view.className.split(' ')[0] : null,\
    \    error: content?.querySelector('.error')?.className ?? null,\
    \  };\
    \})()"

-- | A page as its program adopted it: what it showed as the server sent
-- it, before the program ran; the repairs adopting it made; and the
-- demo's attachments served from object URLs ('sortRepairs'), which are
-- not repairs.
data Adopted = Adopted
  { before :: Shown
  , repairs :: [Repair]
  , objectUrls :: [Repair]
  }

-- | Load a page (a 'goto' or a 'reload', the navigation given) with the
-- program held back by the page's gate, which is armed again for it
-- ('rearm'; one gate per page, never taken away while the page loads),
-- and say what adopting it changed: the page as the server sent it is
-- read and marked ('markPrerendered'), the program let go, and the page
-- compared once the program has started and is quiet (it reads the demo's
-- content from IndexedDB once started, and a page whose content differs
-- from the prerender is repaired then) and every fitted frame has its
-- height ('framesFitted').
adoptedAfter :: (HasCallStack) => Gate -> Page -> IO () -> IO Adopted
adoptedAfter gate page navigate = do
  rearm gate
  navigate
  waitHeld gate
  before <- shown page
  markPrerendered page
  release gate
  waitStarted page
  waitQuiet page
  framesFitted page
  settle page
  (repairs, objectUrls) <- repairsSinceMarked page >>= sortRepairs page
  stillPrerendered page
  pure Adopted {before, repairs, objectUrls}

-- | Mark the page as the server sent it, before its program runs: every
-- node under @#app@ ('markServed' with 'adoptionOptions'), and then the
-- shell's element, with @data-prerendered@. The program leaves that
-- attribute alone, as it does every attribute it does not render, so a
-- shell still carrying it is the one the page arrived with
-- ('stillPrerendered').
markPrerendered :: Page -> IO ()
markPrerendered = markPrerenderedWith adoptionOptions

-- | 'markPrerendered', with the options given.
markPrerenderedWith :: AdoptionOptions -> Page -> IO ()
markPrerenderedWith options page = do
  markServed options page
  _ :: Bool <- evaluate page "(() => { document.querySelector('#app .wiki').dataset.prerendered = 'true'; return true; })()"
  pure ()

-- | The shell the page arrived with is the one on the page, and the only
-- one.
stillPrerendered :: (HasCallStack) => Page -> IO ()
stillPrerendered page = do
  shells <- count (locator page "#app .wiki")
  unless (shells == 1) $ expectationFailure ("the page has " <> show shells <> " shells")
  marked <- count (locator page "#app > .wiki[data-prerendered]")
  unless (marked == 1) $ expectationFailure "the prerendered shell was replaced"

-- | Wait until every fitted frame of the page has the height the islands'
-- script gives it, once the frame's document has loaded: the frame's own
-- load, not the program's work, so a condition. Without it, the height was
-- there or not when the page was compared, depending on whether the
-- frame's document had loaded in time. Asked with 'evaluateWith' until it
-- holds rather than with 'waitForFunctionWith', whose function the page
-- evaluates from text, which a server's page refuses: its Content
-- Security Policy allows no @unsafe-eval@.
framesFitted :: Page -> IO ()
framesFitted page =
  eventually page $ do
    unfitted :: Int <- evaluateWith page "(frame) => document.querySelectorAll(`#app ${frame}:not([style])`).length" fittedFrame
    unless (unfitted == 0) $ expectationFailure (show unfitted <> " html fences' frames without their height")

-- | Repairs, and the changes that are the demo's attachments, apart; the
-- changes 'adoptionMayChange' allows are dropped. An attachment uploaded
-- as bytes is served from an object URL, which exists in the browser only.
-- The prerender has a @data:@ URL there instead, which a page's Markdown
-- may not embed, so its image is prerendered as its description; the
-- program then builds the image, and gives the attachment's link its
-- object URL. So these are the demo's own: a @data:@ attribute that became
-- a @blob:@ one, an image of a @blob:@ address built (in place of its
-- description, or beside it), and a description gone whose image is on
-- the page.
sortRepairs :: Page -> [Repair] -> IO ([Repair], [Repair])
sortRepairs page found = do
  let candidates = [path | AttributeChanged {path, attribute = "style", before = Nothing} <- found]
  fitted <- if null candidates then pure [] else evaluateWith page fittedScript (candidates, fittedFrame)
  described :: [Text] <- evaluate page "[...document.querySelectorAll('#app img[src^=\"blob:\"]')].map((image) => image.alt)"
  let allowed = \case
        AttributeChanged {path, attribute, before, after} -> adoptionMayChange (path `elem` fitted) attribute before after
        _ -> False
      objectUrl = \case
        AttributeChanged {before = Just was, after = Just now} -> "data:" `Text.isPrefixOf` was && "blob:" `Text.isPrefixOf` now
        Replaced {was, now} -> blobImage now && was `elem` described
        Built {now} -> blobImage now
        Removed {was} -> was `elem` described
        _ -> False
  pure (partition (not . objectUrl) (filter (not . allowed) found))
  where
    blobImage html = "<img" `Text.isPrefixOf` html && "src=\"blob:" `Text.isInfixOf` html
    -- Which of the paths name an element that matches the selector now. A
    -- path is the library's, a CSS selector of tags, ids, classes and
    -- places; one the browser cannot read names no fitted frame.
    fittedScript =
      "([paths, selector]) => paths.filter((path) => {\
      \  try { return document.querySelector(path)?.matches(selector) ?? false; } catch { return false; }\
      \})"

-- | The pages a page embeds as presentations (WP5.97 of docs/PLAN.md):
-- each embed @![Caption](destination){.presentation}@ in its Markdown, its
-- destination read as the page's links are, as a path in the page's
-- space: from the space's top (@\/s\/\<space\>\/p\/\<path\>\/@) or, without a
-- leading slash, from the page's parent. Each as its path, with no slash
-- at either end, once; an embed shown as code in a fence is none. A page's
-- address of another form (its permanent one) is left out, and a request
-- for it is not a viewer's.
presentationsEmbedded :: Text -> Text -> [Text]
presentationsEmbedded markdown pagePath = nub (concatMap target (embeds (withoutFences (Text.lines markdown))))
  where
    target (destination, braces)
      | ".presentation" `notElem` Text.words braces = []
      | Just path <- absolute destination = [path]
      | not ("/" `Text.isPrefixOf` destination) && not (":" `Text.isInfixOf` destination) =
          [Text.intercalate "/" (parent <> segments destination)]
      | otherwise = []
    parent = case segments pagePath of
      [] -> []
      parts -> init parts
    segments = filter (not . Text.null) . Text.splitOn "/"
    -- /s/<space>/p/<path>/, the path without its last slash.
    absolute destination = do
      rest <- Text.stripPrefix "/s/" destination
      let (space, afterSpace) = Text.breakOn "/" rest
      path <- Text.stripPrefix "/p/" afterSpace
      let trimmed = fromMaybe path (Text.stripSuffix "/" path)
      if Text.null space || Text.null trimmed then Nothing else Just trimmed

-- | The Markdown without its fenced code blocks: from a line that starts
-- with three backticks or tildes to the next line that starts with the
-- same three, both included. A fence that is never closed is kept.
withoutFences :: [Text] -> Text
withoutFences = Text.intercalate "\n" . go
  where
    go [] = []
    go (line : rest)
      | Just marker <- fence line
      , (_, _ : after) <- break (marker `Text.isPrefixOf`) rest =
          go after
      | otherwise = line : go rest
    fence line = case Text.take 3 line of
      m | m == "```" || m == "~~~" -> Just m
      _ -> Nothing

-- | Every embed in the text, as its destination and what its braces hold:
-- @![caption](destination){braces}@, where the caption holds no @]@, the
-- destination no @)@ and no space, and the braces no @}@.
embeds :: Text -> [(Text, Text)]
embeds text = case Text.breakOn "![" text of
  (_, rest) | Text.null rest -> []
  (_, rest) -> case embedAt (Text.drop 2 rest) of
    Just (found, after) -> found : embeds after
    Nothing -> embeds (Text.drop 1 rest)
  where
    embedAt t = do
      let (_, captionEnd) = Text.break (== ']') t
      afterCaption <- Text.stripPrefix "](" captionEnd
      let (destination, destinationEnd) = Text.break (\c -> c == ')' || isSpace c) afterCaption
      afterDestination <- Text.stripPrefix "){" destinationEnd
      let (braces, bracesEnd) = Text.break (== '}') afterDestination
      after <- Text.stripPrefix "}" bracesEnd
      if Text.null destination then Nothing else Just ((destination, braces), after)

-- | Whether a request the program made once it had started on an adopted
-- page is a presentation viewer's ("Wiki.App.View.DeckViewer"): a read of
-- a page the adopted page embeds with the class presentation
-- ('presentationsEmbedded'), at the API's address of a page at a path,
-- @...\/spaces\/\<space\>\/pages\/at\/\<path\>@. The page an embed names is
-- not carried by the page that embeds it, and must not be, so the viewer
-- reads it once it is near the window. A request for the adopted page
-- itself, its space's list of pages, or anything else the page carries,
-- is not a viewer's.
viewerAsks :: Text -> [Text] -> Bool
viewerAsks requestUrl embedded = case Text.breakOnEnd "/api/v1/spaces/" (pathOf requestUrl) of
  (prefix, rest) | not (Text.null prefix) -> case Text.breakOn "/pages/at/" rest of
    (space, at)
      | not (Text.null space) && not ("/" `Text.isInfixOf` space)
      , Just path <- Text.stripPrefix "/pages/at/" at
      , not (Text.null path) ->
          let decoded = decode path
           in fromMaybe decoded (Text.stripSuffix "/" decoded) `elem` embedded
    _ -> False
  _ -> False
  where
    -- The address's path: what follows the scheme and the host, before
    -- the query and the fragment.
    pathOf address =
      let afterScheme = maybe address snd (splitOnce "://" address)
       in Text.takeWhile (\c -> c /= '?' && c /= '#') (Text.dropWhile (/= '/') afterScheme)
    splitOnce sep t = case Text.breakOn sep t of
      (a, b) | not (Text.null b) -> Just (a, Text.drop (Text.length sep) b)
      _ -> Nothing
    decode :: Text -> Text
    decode = Text.decodeUtf8With Text.lenientDecode . urlDecode False . (Text.encodeUtf8 :: Text -> ByteString)
