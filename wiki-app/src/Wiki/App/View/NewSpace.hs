{-# LANGUAGE QuasiQuotes #-}

-- | The form for a new space, at the top level or under another space. Only
-- someone the rules let create a space there is shown the form; the backend
-- checks again, and a refusal is shown in place.
module Wiki.App.View.NewSpace
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event, preventDefault)
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Permission (mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name, slug))

data Input = Input
  { context :: Context
  , parent :: Maybe [Slug]
  -- ^ The path of the space to create it under, or 'Nothing' for the top
  -- level.
  }

data State = State
  { input :: Input
  , draft :: Text
  -- ^ The name typed so far.
  , problem :: Maybe WikiError
  }

data Action = Receive Input | Followed (Follow Route) | Typed Text | Submit Event

component :: forall query m. (MonadWiki m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, draft = "", problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render State {input = Input {context = ctx, parent}, draft, problem} = case where_ ctx parent of
      Left e ->
        [hh|
          <section class="new-space-view">
            <h1>New space</h1>
            {{ errorView e }}
          </section>
        |]
      Right chain ->
        [hh|
          <section class="new-space-view">
            <h1>{{ maybe "New space" (\c -> "New space in " <> spaceNames c) chain }}</h1>
            <p>A new space is private: only you can see it until you grant others permissions or make it public.</p>
            <form class="inline-form" onSubmit={{ Submit }}>
              {{ textField "Name" draft Typed }}
              <button type="submit" class="primary">Create</button>
              {{ Router.link ctx.router Followed (maybe Home (Space . map (\s -> s.slug)) chain) [HP.class_ "button"] [HH.text "Cancel"] }}
            </form>
            {{ errorView <$> problem }}
          </section>
        |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Receive input -> modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Typed draft -> modify (\st -> st {draft})
      Submit ev -> do
        H.liftEffect (preventDefault ev)
        State {input = Input {context = ctx, parent}, draft} <- get
        for_ (rightToMaybe (where_ ctx parent)) $ \chain ->
          createSpace ((\c -> (\s -> s.id) <$> lastMay c) =<< chain) draft >>= \case
            Left e -> modify (\st -> st {problem = Just e})
            Right space -> do
              modify (\st -> st {draft = "", problem = Nothing})
              H.raise (Changed (Just (Space (maybe [] (map (\s -> s.slug)) chain <> [space.slug]))))

-- | The chain of the space to create the new one under ('Nothing' for the
-- top level), if it exists and the rules let the current user create a
-- space there.
where_ :: Context -> Maybe [Slug] -> Either WikiError (Maybe [Space])
where_ ctx parent = do
  chain <- traverse (maybe (Left NotFound) Right . findSpace ctx.spaces) parent
  if mayCreateSpace (principalOf ctx) (grantsOf ctx) chain then Right chain else Left Forbidden

spaceNames :: [Space] -> Text
spaceNames = mconcat . intersperse " / " . map (\s -> s.name)
