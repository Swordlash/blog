{-# LANGUAGE QuasiQuotes #-}

-- | The editor: a page's title and Markdown on the left, the page as it will
-- read on the right, and its attachments below.
--
-- It edits a page that exists ('Existing') or one that does not yet
-- ('New'), and holds the draft until it is saved: 'savePage' against the
-- version the edit started from, so that a save over someone else's newer
-- one is refused as a 'Conflict' and shown in place, with the draft kept;
-- or 'createPage'. Once saved it tells the shell, which goes to the page.
--
-- The preview ("Wiki.App.View.Preview") follows the draft about
-- 'previewDelay' after the typing stops: each change forks a wait, killing
-- the one before, and the wait that is not killed hands the draft on. The
-- preview is a child component, so a keystroke re-renders the textarea and
-- nothing of the preview; its islands keep their slots, keyed by their
-- source, and only one whose source changed is drawn again.
--
-- Files dropped onto the editor, or chosen with its file input, are read
-- into bytes in the browser ("Wiki.App.Editor.Browser"), uploaded to the
-- page ('uploadAttachment'), and referred to at the textarea's cursor
-- ('Wiki.Core.Markdown.attachmentReference'). A new page has nothing to
-- attach them to until it is saved, so it takes no files until then.
--
-- The title and the textarea are not controlled: the component never sets
-- their text while the reader types, only when it loads the page (the first
-- time, and again after a conflict). Halogen writes a rendered @value@ back
-- to its element on every patch where the two differ, and a render can come
-- between a key and the handling of its input event (the preview's turn to
-- follow the draft re-renders the editor around the textarea), which would
-- put the text back as it was before that key and lose it. So the title is
-- rendered as the input's @value@ attribute, the Markdown as the textarea's
-- content, both what was loaded and so the same on every render, and both
-- keyed by how many times the page has been loaded ('loads'), so that a
-- reload makes new elements with the new text. The draft follows the
-- elements through their input events, and 'insertAtCursor' changes the
-- textarea's text the way typing does.
--
-- Leaving with unsaved changes is guarded twice: the shell asks this
-- component ('IsDirty') before it follows a route away, and the browser
-- warns before a reload or a close while the draft differs from what was
-- loaded ('guardUnload').
module Wiki.App.View.Editor
  ( Input (..)
  , Target (..)
  , Query (..)
  , component
  , previewDelay
  )
where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as Map
import Data.Row (type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event, preventDefault)
import Web.HTML.Event.DragEvent (DragEvent)
import Web.HTML.Event.DragEvent qualified as DragEvent
import Web.UIEvent.KeyboardEvent (KeyboardEvent)
import Web.UIEvent.KeyboardEvent qualified as KeyboardEvent
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.App.Editor.Browser (EditorKey (..), PickedFile (..), editorKey, guardUnload, insertAtCursor, readPickedFile, takeFiles)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Preview qualified as Preview
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (AttachmentId, PageId)
import Wiki.Core.Markdown (attachmentReference)
import Wiki.Core.Page (Page)
-- Qualified, so that its fields (read with a dot) are not confused with the
-- draft's of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Slug (Slug, mkSlug, slugify)
import Wiki.Core.Space (Space (id, name))

-- | Which page is edited.
data Target
  = -- | The page at this path in the space.
    Existing [Slug]
  | -- | A new page, under the page at this path, or at the space's top level.
    New (Maybe [Slug])
  deriving stock (Eq, Ord, Show)

-- | The space the shell has loaded, with its pages, and the page to edit.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , target :: Target
  }

-- | Whether the draft has changes that are not saved: what the shell asks
-- before it leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots = ("preview" .== H.Slot (Const Void) Void ())

-- | What is being written, and what it started from.
data Draft = Draft
  { page :: Maybe Page
  -- ^ The page as the edit started from it (its 'updatedAt' is the version
  -- a save is made against); 'Nothing' for a new page.
  , title :: Text
  , body :: Text
  , savedTitle :: Text
  , savedBody :: Text
  -- ^ The title and body as loaded or last saved, which the draft is
  -- compared with to know whether it has changed.
  , shownTitle :: Text
  , shownBody :: Text
  -- ^ What the preview shows: the draft as it was when the typing stopped.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  }

data Loaded = Loading | Failed WikiError | Ready Draft

-- | Which pane a narrow screen shows; a wide one shows both.
data Pane = SourcePane | PreviewPane
  deriving stock (Eq)

data State = State
  { input :: Input
  , loaded :: Loaded
  , pending :: Maybe H.ForkId
  -- ^ The wait before the preview follows the draft, if one is running.
  , problem :: Maybe WikiError
  , saving :: Bool
  , uploading :: Int
  -- ^ How many files are being read or uploaded.
  , dropping :: Bool
  -- ^ Whether files are being dragged over the editor.
  , pane :: Pane
  , textarea :: H.RefLabel
  , loads :: Int
  -- ^ How many times the page has been loaded: the key of the title and the
  -- textarea, which a reload replaces.
  }

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Followed (Follow Route)
  | TypedTitle Text
  | Typed Text
  | Key KeyboardEvent
  | Submit Event
  | Reload
  | Picked Event
  | DragOver DragEvent
  | DragLeave DragEvent
  | Dropped DragEvent
  | Insert Attachment
  | Show Pane

-- | How long the typing has to stop for before the preview follows: long
-- enough not to re-render a long page on every keystroke, short enough to
-- feel live.
previewDelay :: Int
previewDelay = 200_000

component
  :: forall m
   . (MonadWiki m, MonadIslands m, MonadUUID m, MonadIO m)
  => H.Component Query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          textarea <- H.newRefLabel "editor-text"
          pure
            State
              { input
              , loaded = Loading
              , pending = Nothing
              , problem = Nothing
              , saving = False
              , uploading = 0
              , dropping = False
              , pane = SourcePane
              , textarea
              , loads = 0
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <section class="editor">
          <h1 class="editor-heading">{{ headingOf st }}</h1>
          {{ body }}
        </section>
      |]
      where
        ctx = st.input.context
        body = case st.loaded of
          _ | isNothing ctx.session.user -> [signInHint]
          _ | not (mayEdit ctx st.input.space.id) -> [errorView Forbidden]
          Loading -> [[hh|<p class="loading">Loading…</p>|]]
          Failed e -> [errorView e]
          Ready draft -> [editing st draft]

    signInHint :: H.ComponentHTML Action Slots m
    signInHint = [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To edit pages, choose who you are at the top right.</p>|]

    editing :: State -> Draft -> H.ComponentHTML Action Slots m
    editing st draft =
      [hh|
        <form class="editor-form" onSubmit={{ Submit }} onKeyDown={{ Key }}>
          <div class="editor-bar">
            {{ titleField st draft }}
            <div class="editor-actions">
              <button type="submit" class="primary" disabled={{ st.saving }}>{{ if st.saving then "Saving…" else "Save" :: Text }}</button>
              {{ Router.link st.input.context.router Followed (leaving st.input) [HP.classes ["button", "editor-cancel"]] [HH.text "Cancel"] }}
              <label class="button editor-attach{% if isNothing draft.page %} disabled{% end %}">
                Attach files
                <input type="file" multiple disabled={{ isNothing draft.page }} onChange={{ Picked }}>
              </label>
              <div class="editor-panes-switch" role="group" aria-label="Show">{{ paneButton st SourcePane "Markdown" }}{{ paneButton st PreviewPane "Preview" }}</div>
            </div>
          </div>
          {{ problemView st }}
          <div
            class="editor-panes{% if st.dropping %} dropping{% end %}{% if st.pane == PreviewPane %} showing-preview{% end %}"
            onDragOver={{ DragOver }}
            onDragLeave={{ DragLeave }}
            onDrop={{ Dropped }}
          >
            {{ source st draft }}
            <div class="editor-preview" aria-label="Preview">
              {{ HH.slot_ "preview" () Preview.component Preview.Input {place = placeOf st.input draft, title = draft.shownTitle, body = draft.shownBody} }}
            </div>
          </div>
          {{ attachmentList draft }}
        </form>
      |]

    -- The title's input, keyed by the load (see the module's comment). Its
    -- text is the @value@ attribute, what the input starts with, rather than
    -- the property, which a quote's @value={{ … }}@ would set: so it is
    -- written as an attribute among the others.
    titleField :: State -> Draft -> H.ComponentHTML Action Slots m
    titleField st draft =
      HH.keyed
        @I.HTMLlabel
        (HH.ElemName "label")
        [HP.class_ "field editor-title"]
        [ ("caption", [hh|<span>Title</span>|])
        ,
          ( loadKey st
          , [hh|<input type="text" {{ attr "value" draft.savedTitle }} onValueInput={{ TypedTitle }} required autofocus={{ isNothing draft.page }}>|]
          )
        ]

    -- The Markdown's textarea, keyed by the load like the title, with the
    -- text it starts with as its content rather than its value (see the
    -- module's comment). Neither a keyed element nor a textarea with content
    -- can be written in a quote.
    source :: State -> Draft -> H.ComponentHTML Action Slots m
    source st draft =
      HH.keyed
        @I.HTMLdiv
        (HH.ElemName "div")
        [HP.class_ "editor-source"]
        [
          ( loadKey st
          , HH.element
              @I.HTMLtextarea
              (HH.ElemName "textarea")
              [ HP.ref st.textarea
              , HP.class_ "editor-text"
              , attr "aria-label" "The page's Markdown"
              , HE.onValueInput Typed
              , HP.readOnly st.saving
              , HP.autofocus (isJust draft.page)
              ]
              [HH.text draft.savedBody]
          )
        , ("hint", [hh|<p class="editor-hint">{{ hint st draft }}</p>|])
        ]

    loadKey :: State -> Text
    loadKey st = "load-" <> show st.loads

    paneButton :: State -> Pane -> Text -> H.ComponentHTML Action Slots m
    paneButton st pane label =
      [hh|<button type="button" aria-pressed={{ ariaBool (st.pane == pane) }} onClick={{ const (Show pane) }}>{{ label }}</button>|]

    problemView :: State -> Maybe (H.ComponentHTML Action Slots m)
    problemView st = case st.problem of
      Nothing -> Nothing
      Just (Conflict why) ->
        Just
          [hh|
            <div class="error error-conflict" role="alert">
              <p>{{ why }}</p>
              <p>Your changes are still here. Copy what you want to keep before you reload the page as it is now.</p>
              <button type="button" class="danger" onClick={{ const Reload }}>Reload and lose my changes</button>
            </div>
          |]
      Just e -> Just (errorView e)

    hint :: State -> Draft -> Text
    hint st draft
      | st.uploading > 0 = "Uploading " <> show st.uploading <> (if st.uploading == 1 then " file…" else " files…")
      | isNothing draft.page = "Save the page first; then files can be attached to it."
      | otherwise = "Drop files here to attach them. Ctrl+S saves; Tab indents."

    attachmentList :: Draft -> H.ComponentHTML Action Slots m
    attachmentList draft =
      [hh|
        <section class="editor-attachments">
          <h2>Attachments</h2>
          {% if null draft.attachments %}
            <p class="empty">None yet.</p>
          {% else %}
            <ul>
              {% for a in draft.attachments %}
                <li>
                  <a href={{ Map.findWithDefault "" a.id draft.urls }} download={{ a.name }}>{{ a.name }}</a>
                  <span class="attachment-meta">{{ a.mediaType }}, {{ fileSize a.size }}</span>
                  <button type="button" class="attachment-insert" onClick={{ const (Insert a) }}>Insert</button>
                </li>
              {% end %}
            </ul>
          {% end %}
        </section>
      |]

    handleQuery :: Query a -> H.HalogenM State Action Slots ViewOutput m (Maybe a)
    handleQuery (IsDirty reply) = Just . reply . isDirty <$> get

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize -> load
      -- A pending wait is killed with the component; the browser's warning
      -- is not, so it is let go here.
      Finalize -> H.liftEffect (guardUnload False)
      -- The draft is the editor's own: a reload of the wiki around it (after
      -- a change elsewhere, or someone else signing in) leaves it alone.
      Receive input -> modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      TypedTitle t -> edit (\d -> d {title = t})
      Typed t -> edit (\d -> d {body = t})
      Key ev -> do
        let event = KeyboardEvent.toEvent ev
        H.liftEffect (editorKey event) >>= \case
          SaveKey -> H.liftEffect (preventDefault event) >> save
          IndentKey -> do
            H.liftEffect (preventDefault event)
            insert "  "
          OtherKey -> pass
      Submit ev -> H.liftEffect (preventDefault ev) >> save
      Reload -> do
        cancelPreview
        modify (\st -> st {problem = Nothing})
        load
      Picked ev -> H.liftEffect (takeFiles ev) >>= upload
      DragOver ev -> do
        -- Without this the browser would not let the files be dropped here.
        H.liftEffect (preventDefault (DragEvent.toEvent ev))
        unlessM (gets (\st -> st.dropping)) $ modify (\st -> st {dropping = True})
      DragLeave _ -> modify (\st -> st {dropping = False})
      Dropped ev -> do
        -- Otherwise the browser would open the file in place of the page.
        H.liftEffect (preventDefault (DragEvent.toEvent ev))
        files <- H.liftEffect (takeFiles (DragEvent.toEvent ev))
        modify (\st -> st {dropping = False})
        upload files
      Insert a -> insert (attachmentReference a.name a.mediaType)
      Show pane -> modify (\st -> st {pane})

    -- The page as it is now, or a new one's empty draft.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- case input.target of
        Existing path ->
          getPage input.space.id path >>= \case
            Left e -> pure (Failed e)
            Right page -> do
              urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
              pure (Ready (draftOf (Just page) page.title page.body page.attachments urls))
        New parent -> pure $ case parentOf input parent of
          Left e -> Failed e
          Right _ -> Ready (draftOf Nothing "" "" [] mempty)
      modify (\st -> st {loaded, loads = st.loads + 1})
      syncGuard
      H.raise Loaded

    edit :: (Draft -> Draft) -> H.HalogenM State Action Slots ViewOutput m ()
    edit f = do
      modifyDraft f
      syncGuard
      schedulePreview

    -- Hand the draft to the preview once the typing has stopped for
    -- 'previewDelay': a wait of its own, which the next change kills.
    schedulePreview :: H.HalogenM State Action Slots ViewOutput m ()
    schedulePreview = do
      cancelPreview
      waiting <- H.fork $ do
        liftIO (threadDelay previewDelay)
        modify (\st -> st {pending = Nothing})
        modifyDraft (\d -> d {shownTitle = d.title, shownBody = d.body})
      modify (\st -> st {pending = Just waiting})

    cancelPreview :: H.HalogenM State Action Slots ViewOutput m ()
    cancelPreview = do
      gets (\st -> st.pending) >>= traverse_ H.kill
      modify (\st -> st {pending = Nothing})

    save :: H.HalogenM State Action Slots ViewOutput m ()
    save = do
      st <- get
      case st.loaded of
        Ready draft | not st.saving -> do
          modify (\s -> s {saving = True, problem = Nothing})
          let input = st.input
              spacePath = spacePathOf input.context.spaces input.space.id
          result <- case (draft.page, input.target) of
            (Just page, Existing path) ->
              fmap (const (Page spacePath path)) <$> savePage page.id page.updatedAt draft.title draft.body
            (_, New parent) -> case parentOf input parent of
              Left e -> pure (Left e)
              Right under ->
                fmap (\new -> Page spacePath (fromMaybe [] parent <> [new.slug]))
                  <$> createPage input.space.id under draft.title draft.body
            (Nothing, Existing _) -> pure (Left NotFound)
          modify (\s -> s {saving = False})
          case result of
            Left e -> modify (\s -> s {problem = Just e})
            Right route -> do
              -- Saved: nothing is left to lose, so the shell leaves without
              -- asking, and the browser without warning.
              modifyDraft (\d -> d {savedTitle = draft.title, savedBody = draft.body})
              syncGuard
              H.raise (Changed (Just route))
        _ -> pass

    upload :: [PickedFile] -> H.HalogenM State Action Slots ViewOutput m ()
    upload files =
      gets (\st -> st.loaded) >>= \case
        Ready Draft {page = Just page} -> for_ files (uploadTo page.id)
        Ready _ | not (null files) -> modify (\st -> st {problem = Just (Invalid "Save the page first; then files can be attached to it.")})
        _ -> pass

    uploadTo :: PageId -> PickedFile -> H.HalogenM State Action Slots ViewOutput m ()
    uploadTo pid file
      | file.size > maxAttachmentSize =
          modify (\st -> st {problem = Just (Invalid (file.name <> " is " <> fileSize file.size <> ": an attachment can be at most " <> fileSize maxAttachmentSize <> "."))})
      | otherwise = do
          modify (\st -> st {uploading = st.uploading + 1})
          -- Reading the file waits for the browser, off the component's loop.
          bytesRead <- liftIO (try (readPickedFile file))
          result <- case bytesRead of
            Left (e :: SomeException) -> pure (Left (Invalid ("The browser could not read " <> file.name <> ": " <> show e)))
            Right bytes -> uploadAttachment pid file.name file.mediaType bytes
          modify (\st -> st {uploading = st.uploading - 1})
          case result of
            Left e -> modify (\st -> st {problem = Just e})
            Right a -> do
              url <- attachmentUrl a
              -- An upload under a name the page already has replaces that
              -- attachment.
              modifyDraft $ \d ->
                d
                  { attachments = filter (\b -> b.name /= a.name) d.attachments <> [a]
                  , urls = Map.insert a.id url d.urls
                  }
              insert (attachmentReference a.name a.mediaType)

    -- Text in at the textarea's cursor; the input event that puts it in the
    -- draft is handled before this returns, like a keystroke.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = do
      ref <- gets (\st -> st.textarea)
      H.getRef ref >>= traverse_ (\element -> H.liftEffect (insertAtCursor element text))

    modifyDraft :: (Draft -> Draft) -> H.HalogenM State Action Slots ViewOutput m ()
    modifyDraft f = modify $ \st -> case st.loaded of
      Ready d -> st {loaded = Ready (f d)}
      _ -> st

    syncGuard :: H.HalogenM State Action Slots ViewOutput m ()
    syncGuard = gets isDirty >>= H.liftEffect . guardUnload

draftOf :: Maybe Page -> Text -> Text -> [Attachment] -> Map AttachmentId Text -> Draft
draftOf page title body attachments urls =
  Draft
    { page
    , title
    , body
    , savedTitle = title
    , savedBody = body
    , shownTitle = title
    , shownBody = body
    , attachments
    , urls
    }

isDirty :: State -> Bool
isDirty st = case st.loaded of
  Ready d -> d.title /= d.savedTitle || d.body /= d.savedBody
  _ -> False

headingOf :: State -> Text
headingOf st = case (st.input.target, st.loaded) of
  (Existing _, Ready Draft {savedTitle}) -> "Editing " <> savedTitle
  (Existing _, _) -> "Editing a page"
  (New Nothing, _) -> "New page in " <> st.input.space.name
  (New (Just parent), _) -> "New page under " <> maybe "a page" (\p -> p.title) (pageAt st.input.pages parent)

-- | Where Cancel goes: the page, or for a new page where it would have
-- been made.
leaving :: Input -> Route
leaving input = case input.target of
  Existing path -> Page spacePath path
  New (Just parent) -> Page spacePath parent
  New Nothing -> Space spacePath
  where
    spacePath = spacePathOf input.context.spaces input.space.id

-- | The page a new one goes under, if the path names one; 'Nothing' for the
-- space's top level.
parentOf :: Input -> Maybe [Slug] -> Either WikiError (Maybe PageId)
parentOf input = \case
  Nothing -> Right Nothing
  Just path -> maybe (Left NotFound) (Right . Just . (\p -> p.id)) (pageAt input.pages path)

pageAt :: [Page] -> [Slug] -> Maybe Page
pageAt pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

-- | Where the draft is read, for its links: a new page as if it already
-- were where it will be, under the slug its title suggests.
placeOf :: Input -> Draft -> Body.Place
placeOf input draft =
  Body.Place
    { Body.context = input.context
    , Body.space = input.space
    , Body.pages = input.pages
    , Body.path = case input.target of
        Existing path -> path
        New parent -> fromMaybe [] parent <> [fromMaybe placeholder (slugify draft.title)]
    , Body.attachments = draft.attachments
    , Body.urls = draft.urls
    }
  where
    placeholder = either (panic . show) identity (mkSlug "new-page")
