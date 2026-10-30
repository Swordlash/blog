{-# LANGUAGE QuasiQuotes #-}

-- | The shared wiki front page, with administrator-written Markdown and
-- optional directory and recent sections. The editor reuses CodeMirror and
-- the page renderer. Its draft stays mounted through preview and is kept
-- when a save fails. The editor is inert while its save is in flight.
-- The directory has a card for each
-- top-level space (its icon, name and description, how many pages it has,
-- and whether it is public), the spaces this browser visited last
-- ("Recently visited", "Wiki.App.Recent"), and a link to create a new
-- space for someone who may.
--
-- The cards come from the tree of spaces the shell has loaded. The number
-- of pages in each comes from the backend ('pageCounts'), loaded as every
-- view loads its data: in the initial state on a backend that answers at
-- once, and otherwise in the initializer, with the cards shown meanwhile
-- without their counts. The recently visited spaces are read from the
-- browser after the first render, so that render matches the page the
-- prerender or the server wrote.
--
-- A top-level space the user may not view, listed because they may view a
-- subspace of it, is a card without a link, naming the subspaces they may
-- open.
module Wiki.App.View.Directory
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.Api.ServerSettings (HomePage (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (homePage), WikiError)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Editor.Browser (applyCommand, attachEditor, detachEditor, typedText)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Recent (readRecent)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body (IslandSlots)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Markdown.Edit (Command (..))
import Wiki.Core.Path (childrenOf)
import Wiki.Core.Permission (GlobalPermission (Administer), hasGlobalPermission, mayCreateSpace)
import Wiki.Core.Space (Space (description, id, name, public, slug), subspacesOf)

-- | The directory's input: the shell's context, and a route a newcomer is
-- invited to (the demo's tour), if there is one.
data Input = Input
  { context :: Context
  , welcome :: Maybe Route
  }

data State = State
  { input :: Input
  , draft :: Maybe HomePage
  , original :: HomePage
  , preview :: Bool
  , saving :: Bool
  , problem :: Maybe WikiError
  , host :: H.RefLabel
  , counts :: Maybe (Map SpaceId Int)
  -- ^ The number of pages in each space, once loaded.
  , recent :: [SpaceId]
  -- ^ The spaces this browser visited last, once read.
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | EditHome
  | Cancel
  | Title Text
  | Typed Text
  | Spaces Bool
  | Recent Bool
  | Preview Bool
  | Format Command
  | Save
  | FollowLink ArticleLink
  | Finalize

component :: forall query m. (MonadLoad m, MonadAdmin m, MonadIslands m, MonadUUID m, MonadBrowserDOM m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- At once on a backend that can, so that the first render is the
          -- page the prerender shows; otherwise in 'Initialize'.
          counts <- join <$> atOnce (rightToMaybe <$> attempt pageCounts)
          host <- H.newRefLabel "home-editor"
          pure State {input, counts, recent = [], draft = Nothing, original = input.context.session.homePage, preview = False, saving = False, problem = Nothing, host}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              , H.finalize = Just Finalize
              }
      }
  where
    render :: State -> H.ComponentHTML Action IslandSlots m
    render st =
      [hh|
        <section class="directory">
          {% if isJust st.draft %}
            {{ editor st }}
          {% else %}
          <header class="view-header directory-header">
            <h1>{{ home.title }}</h1>
            <div class="actions">
              {% if hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer %}
                <button type="button" class="edit-home" onClick={{ const EditHome }}>Edit home page</button>
              {% end %}
              {% if home.showSpaces %}{{ newSpace ctx }}{% end %}
            </div>
          </header>
          {% if not (T.null home.body) %}{{ Body.homeArticle FollowLink ctx home.body }}{% end %}
          {% if home.showSpaces && T.null home.body %}
          <p class="directory-intro">
            Spaces hold pages written in Markdown, and spaces can hold other spaces. Who may
            read, edit or administer a space is up to its permissions; a public space is open to
            everyone.
          </p>
          {% end %}
          {% if home.showSpaces %}
          {% for r in maybeToList st.input.welcome %}
            <p class="welcome">New here? <a {{ Router.linkProps ctx.router Followed r }}>Take the tour</a>.</p>
          {% end %}
          {% end %}
          {% if home.showRecent %}{{ recentSection st }}{% end %}
          {% if home.showSpaces %}{{ cards st }}{% end %}
          {% end %}
        </section>
      |]
      where
        ctx = st.input.context
        home = ctx.session.homePage

    recentSection :: State -> H.ComponentHTML Action IslandSlots m
    recentSection st =
      [hh|
        <section class="recent-spaces" aria-label="Recently visited" hidden={{ null shown }}>
          <h2>Recently visited</h2>
          <ul class="recent-list">
            {% for s in shown %}
              <li>
                <a class="recent-space" {{ Router.linkProps ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) }}>
                  {{ spaceIcon ctx.icons s }}<span class="recent-space-name">{{ pathName ctx s }}</span>
                </a>
              </li>
            {% end %}
          </ul>
        </section>
      |]
      where
        ctx = st.input.context
        -- Present from the first render, empty and hidden, so that what the
        -- browser remembers fills it in place rather than moving what
        -- follows it.
        shown = [s | sid <- st.recent, Just s <- [find (\x -> x.id == sid) ctx.spaces], mayView ctx s.id]

    cards :: State -> H.ComponentHTML Action IslandSlots m
    cards st = case subspacesOf ctx.spaces Nothing of
      [] -> [hh|<p class="empty">There are no spaces you can see.</p>|]
      roots ->
        [hh|
          <section class="all-spaces" aria-label="All spaces">
            <h2>All spaces</h2>
            <ul class="space-cards">{{ map (card st) roots }}</ul>
          </section>
        |]
      where
        ctx = st.input.context

    editor :: State -> H.ComponentHTML Action IslandSlots m
    editor st = case st.draft of
      Nothing -> HH.text ""
      Just draft ->
        [hh|
          <section class="home-editor" {{ [attr "inert" "" | st.saving] }}>
            <header class="view-header"><h1>Edit home page</h1></header>
            <p>This content is shared with everyone who can open the wiki's front page.</p>
            <div class="home-editor-actions actions">
              <button type="button" class="save-home" disabled={{ st.saving }} onClick={{ const Save }}>{{ if st.saving then "Saving…" else "Save" :: Text }}</button>
              <button type="button" class="cancel-home" disabled={{ st.saving }} onClick={{ const Cancel }}>Cancel</button>
              <button type="button" class="preview-home" onClick={{ const (Preview (not st.preview)) }}>{{ if st.preview then "Back to editing" else "Show preview" :: Text }}</button>
            </div>
            <div class="home-editor-error">{% for e in maybeToList st.problem %}{{ errorView e }}{% end %}</div>
            <div hidden={{ st.preview }}>
              <label>Title<input class="home-title" type="text" {{ HP.attr (HH.AttrName "value") st.original.title }} onValueInput={{ Title }}/></label>
              <label><input class="home-spaces" type="checkbox" checked={{ draft.showSpaces }} onChecked={{ Spaces }}/> Show Spaces</label>
              <label><input class="home-recent" type="checkbox" checked={{ draft.showRecent }} onChecked={{ Recent }}/> Show Recently visited</label>
              <div class="editor-toolbar" role="toolbar" aria-label="Formatting">
                <button type="button" onClick={{ const (Format Bold) }}>Bold</button>
                <button type="button" onClick={{ const (Format Italic) }}>Italic</button>
              </div>
              <div class="editor-source">
                <div class="editor-cm" ref={{ st.host }} {{ HE.handler' (EventType "wiki-input") (\ev -> Just $! Typed (typedText ev)) }}></div>
                {{ HH.element @I.HTMLtextarea (HH.ElemName "textarea") [HP.class_ "editor-text home-markdown", attr "aria-label" "The home page's Markdown", HE.onValueInput Typed] [HH.text st.original.body] }}
              </div>
              <p class="editor-hint">Wiki links start at the wiki root. This page has no attachments or space macros.</p>
            </div>
            {% if st.preview %}
              <section class="home-preview">
                <h1>{{ draft.title }}</h1>
                {{ Body.homeArticle FollowLink st.input.context draft.body }}
                {% if draft.showRecent %}{{ recentSection st }}{% end %}
                {% if draft.showSpaces %}{{ cards st }}{% end %}
              </section>
            {% end %}
          </section>
        |]

    card :: State -> Space -> H.ComponentHTML Action IslandSlots m
    card st s
      | mayView ctx s.id =
          [hh|
            <li class="space-card" data-space={{ s.id.text }}>
              <a class="space-card-link" {{ Router.linkProps ctx.router Followed (Space [s.slug]) }}>
                {{ spaceIcon ctx.icons s }}<span class="space-card-name">{{ s.name }}</span>
              </a>
              {% if not (T.null s.description) %}
                <p class="space-card-description">{{ s.description }}</p>
              {% end %}
              <p class="space-card-meta">{{ meta }}<span class="badge {{ if s.public then "badge-public" else "badge-private" :: Text }}">{{ if s.public then "Public" else "Private" :: Text }}</span></p>
            </li>
          |]
      | otherwise =
          [hh|
            <li class="space-card space-card-unviewable" data-space={{ s.id.text }}>
              <span class="space-card-link unviewable" title="You can see only a subspace of this space">
                {{ spaceIcon ctx.icons s }}<span class="space-card-name">{{ s.name }}</span>
              </span>
              <p class="space-card-description">You may open {{ openable }}.</p>
            </li>
          |]
      where
        ctx = st.input.context
        meta = T.intercalate " · " (catMaybes [pagesMeta, subspacesMeta]) <> " "
        pagesMeta = (\n -> counted n "page" "pages") <$> (st.counts >>= Map.lookup s.id)
        subspacesMeta = case length (childrenOf ctx.spaces (Just s.id)) of
          0 -> Nothing
          n -> Just (counted n "subspace" "subspaces")
        -- The subspaces under it the user may view, each a link.
        openable =
          intersperse
            (HH.text ", ")
            [ Router.link ctx.router Followed (Space (spacePathOf ctx.spaces x.id)) [] [HH.text (pathName ctx x)]
            | x <- ctx.spaces
            , descendsFrom ctx.spaces s.id x.id
            , x.id /= s.id
            , mayView ctx x.id
            ]

    -- A link to a new top-level space, for someone who may create one.
    newSpace :: Context -> Maybe (H.ComponentHTML Action IslandSlots m)
    newSpace ctx =
      guard (mayCreateSpace (principalOf ctx) (grantsOf ctx) Nothing)
        $> [hh|<a class="button new-space" {{ Router.linkProps ctx.router Followed (NewSpace Nothing) }}>New space</a>|]

    handleAction :: Action -> H.HalogenM State Action IslandSlots ViewOutput m ()
    handleAction = \case
      Initialize -> do
        recent <- H.liftEffect readRecent
        modify (\st -> st {recent})
        gets (\st -> st.counts) >>= \case
          Just _ -> H.raise Loaded
          Nothing -> load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.context.revision /= input.context.revision) load
      EditHome -> do
        st <- get
        when (hasGlobalPermission (principalOf st.input.context) (grantsOf st.input.context) Administer) $ do
          let home = st.input.context.session.homePage
          modify (\s -> s {draft = Just home, original = home, preview = False, problem = Nothing})
          H.getRef st.host >>= traverse_ (\el -> H.liftEffect (attachEditor el home.body))
      Cancel -> do
        closeEditor
        modify (\s -> s {draft = Nothing, preview = False, problem = Nothing})
      Title title -> change (\h -> h {title})
      Typed body -> change (\h -> h {body})
      Spaces showSpaces -> change (\h -> h {showSpaces})
      Recent showRecent -> change (\h -> h {showRecent})
      Preview preview -> modify (\s -> s {preview})
      Format command -> gets (\s -> s.host) >>= H.getRef >>= traverse_ (\el -> H.liftEffect (applyCommand el command))
      Save -> do
        st <- get
        unless st.saving $ for_ st.draft $ \draft -> do
          modify (\s -> s {saving = True, problem = Nothing})
          result <- lift (setHomePage draft)
          modify (\s -> s {saving = False})
          case result of
            Left e -> modify (\s -> s {problem = Just e})
            Right saved -> do
              current <- gets (\s -> s.draft)
              when (current == Just draft) $ do
                closeEditor
                modify (\s -> s {draft = Nothing})
              modify (\s -> s {input = s.input {context = s.input.context {session = s.input.context.session {homePage = saved}}}})
              H.raise (Changed Nothing)
      FollowLink target -> gets (\s -> s.input.context.router) >>= \router -> H.liftEffect (followArticleLink router target)
      Finalize -> closeEditor
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)

    change f = modify (\s -> s {draft = f <$> s.draft})
    closeEditor = gets (\s -> s.host) >>= H.getRef >>= traverse_ (H.liftEffect . detachEditor)

    -- Load the counts on a worker thread. Without them (the server could
    -- not be reached) the cards are shown without counts, and the shell is
    -- told all the same.
    load :: H.HalogenM State Action IslandSlots ViewOutput m ()
    load = do
      counts <- rightToMaybe <$> lift (attempt pageCounts)
      modify (\st -> st {counts = counts <|> st.counts})
      H.raise Loaded

-- | A space's name with its ancestors', as a path: @Team / Projects@.
pathName :: Context -> Space -> Text
pathName ctx s = T.intercalate " / " (map (\x -> x.name) (chainOf ctx s.id))

-- | A number of things, in words.
counted :: Int -> Text -> Text -> Text
counted n singular plural = show n <> " " <> if n == 1 then singular else plural
