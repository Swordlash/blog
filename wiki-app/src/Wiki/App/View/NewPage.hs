{-# LANGUAGE QuasiQuotes #-}

-- | The form for a new page: its title, and what it starts from, under the
-- page the route names or at the space's top level. Creating it makes the
-- page at once, with its body, and opens the editor on it, so that the page has an id from
-- the start: files can be attached to it before anything is written, and
-- the editor has only ever to save a page that exists. A page made and
-- then left without a word written stays, empty; deleting it is the page's
-- Delete, as for any other.
--
-- A page starts blank, or from a template ("Wiki.Core.Template"): one of
-- the space's own (its pages flagged 'Wiki.Core.Page.template'), or one the
-- wiki has built in (meeting notes, a decision record, a how-to guide). A
-- template's body is copied into the new page with @{{title}}@, @{{date}}@
-- and @{{author}}@ filled in: the title typed, today's date (UTC, as ISO
-- 8601 writes it) and the display name of whoever makes it.
--
-- Only someone the rules let edit the space is shown the form; the backend
-- checks again, and a refusal is shown in place. The title's input is not
-- controlled (the component never sets its text), so no render between a
-- key and its input event can take a typed character back.
module Wiki.App.View.NewPage
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (getCurrentTime, utctDay)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (PageId)
import Wiki.Core.Page (Page, templatePages)
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name))
import Wiki.Core.Template (Placeholders (Placeholders), builtinTemplates, fillTemplate)
import Wiki.Core.Template qualified as Template
import Wiki.Core.User (User (displayName))

-- | The space the shell has loaded, with its pages, and where in it the
-- page goes.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , parent :: Maybe [Slug]
  -- ^ The path of the page to put it under, or 'Nothing' for the space's
  -- top level.
  }

data State = State
  { input :: Input
  , title :: Text
  -- ^ The title typed so far.
  , start :: Start
  -- ^ What the page starts from.
  , creating :: Bool
  , problem :: Maybe WikiError
  }

-- | What a new page starts from.
data Start
  = Blank
  | -- | One of the space's templates.
    SpaceTemplate PageId
  | -- | One of the wiki's own, by its key.
    BuiltIn Text
  deriving stock (Eq, Show)

data Action = Receive Input | Followed (Follow Route) | Typed Text | Chose Start | Submit

component :: forall query m. (MonadWiki m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, title = "", start = Blank, creating = False, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="new-page-view">
          <h1>{{ headingOf input }}</h1>
          {{ body }}
          {{ errorView <$> st.problem }}
        </section>
      |]
      where
        input = st.input
        ctx = input.context
        body = case under input of
          _ | isNothing ctx.session.user -> [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To write pages, choose who you are at the top right.</p>|]
          _ | not (mayEdit ctx input.space.id) -> errorView Forbidden
          Left e -> errorView e
          Right _ ->
            [hh|
              <form class="inline-form new-page-form" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
                <label class="field">
                  <span>Title</span>
                  <input type="text" class="new-page-title" onValueInput={{ Typed }} required autofocus>
                </label>
                <fieldset class="new-page-start">
                  <legend>Start from</legend>
                  {{ choice Blank "Blank" "An empty page." }}
                  {% for t in templatePages input.pages %}
                    {{ choice (SpaceTemplate t.id) t.title ("A template of " <> input.space.name <> ".") }}
                  {% end %}
                  {% for t in builtinTemplates %}
                    {{ choice (BuiltIn t.key) t.title "Built in." }}
                  {% end %}
                </fieldset>
                <button type="submit" class="primary" disabled={{ st.creating }}>Create and edit</button>
                {{ Router.link ctx.router Followed (leaving input) [HP.class_ "button"] [HH.text "Cancel"] }}
              </form>
            |]

        choice :: Start -> Text -> Text -> H.ComponentHTML Action Empty m
        choice start label hint =
          [hh|
            <label class="check new-page-choice">
              <input type="radio" name="new-page-start" checked={{ start == st.start }} onChange={{ const (Chose start) }}>
              <span>{{ label }} <small class="check-help">{{ hint }}</small></span>
            </label>
          |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Receive input -> modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Typed title -> modify (\st -> st {title})
      Chose start -> modify (\st -> st {start})
      Submit -> do
        st <- get
        case under st.input of
          Right parentPage | not st.creating -> do
            modify (\s -> s {creating = True, problem = Nothing})
            body <- startingBody st
            result <- createPage st.input.space.id ((\p -> p.id) <$> parentPage) st.title body
            modify (\s -> s {creating = False})
            case result of
              Left e -> modify (\s -> s {problem = Just e})
              -- The editor, on the page just made: the shell reloads the
              -- space's pages, which now have it, and goes there.
              Right page ->
                H.raise (Changed (Just (EditPage (spacePathOf st.input.context.spaces st.input.space.id) (fromMaybe [] st.input.parent <> [page.slug]))))
          _ -> pass

-- | The new page's body: nothing, or the template chosen with its
-- placeholders filled in. A template of the space's that is not among its
-- pages any more (deleted since the form was shown) starts it blank.
startingBody :: (MonadIO n) => State -> n Text
startingBody st = case st.start of
  Blank -> pure ""
  SpaceTemplate pid -> filled (maybe "" (\p -> p.body) (find (\p -> p.id == pid) st.input.pages))
  BuiltIn key -> filled (maybe "" (\t -> t.body) (find (\t -> t.key == key) builtinTemplates))
  where
    filled body = do
      today <- utctDay <$> liftIO getCurrentTime
      let author = maybe "" (\u -> u.displayName) st.input.context.session.user
      pure (fillTemplate Placeholders {Template.title = T.strip st.title, Template.date = today, Template.author = author} body)

-- | The page the new one goes under, if the route names one; 'Nothing' for
-- the space's top level; 'NotFound' for a path that names no page.
under :: Input -> Either WikiError (Maybe Page)
under input = case input.parent of
  Nothing -> Right Nothing
  Just path -> maybe (Left NotFound) (Right . Just) (pageAt input.pages path)

pageAt :: [Page] -> [Slug] -> Maybe Page
pageAt pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

headingOf :: Input -> Text
headingOf input = case input.parent of
  Nothing -> "New page in " <> input.space.name
  Just parent -> "New page under " <> maybe "a page" (\p -> p.title) (pageAt input.pages parent)

-- | Where Cancel goes: where the page would have been made.
leaving :: Input -> Route
leaving input = case input.parent of
  Just parent -> Page spacePath parent
  Nothing -> Space spacePath
  where
    spacePath = spacePathOf input.context.spaces input.space.id
