{-# LANGUAGE QuasiQuotes #-}

-- | A space: its pages as a tree, its subspaces, and what the current user
-- may do to it (a new page, in the editor; a new subspace, renaming it, making it public or
-- private, moving it, deleting it). An action the rules forbid is not
-- offered; the backend checks the rules again, and a refusal is shown in
-- place.
module Wiki.App.View.Space
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Page (Page)
import Wiki.Core.Path (childrenOf)
import Wiki.Core.Permission (mayCreateSpace, mayMoveSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name, parent, public, slug))

-- | The space, as the shell has loaded it, with its pages.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  }

data Mode
  = Viewing
  | Renaming Text
  | -- | Moving to the destination at this index of 'destinations'.
    Moving Int
  | ConfirmingDelete

data State = State
  { input :: Input
  , mode :: Mode
  , problem :: Maybe WikiError
  }

data Action
  = Receive Input
  | Followed (Follow Route)
  | Open Mode
  | Typed Text
  | Chose Int
  | Submit
  | TogglePublic
  | Delete

component :: forall query m. (MonadWiki m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, mode = Viewing, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render State {input = Input {context = ctx, space, pages}, mode, problem} =
      [hh|
        <section class="space-view">
          <header class="view-header">
            <h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          <div class="actions">{{ actions ctx space }}</div>
          {{ form ctx space mode }}{{ errorView <$> problem }}
          <h2>Pages</h2>
          {{ pageList }}{{ subspaces ctx space }}
        </section>
      |]
      where
        pageList
          | null pages = [hh|<p class="empty">No pages yet.</p>|]
          | otherwise = pageTree ctx.router Followed (spacePathOf ctx.spaces space.id) pages Nothing

    actions :: Context -> Space -> [H.ComponentHTML Action Empty m]
    actions ctx space =
      [Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button"] [HH.text "New page"] | mayEdit ctx space.id]
        <> [ Router.link ctx.router Followed (NewSpace (Just path)) [HP.class_ "button"] [HH.text "New subspace"]
           | mayCreateSpace (principalOf ctx) (grantsOf ctx) (Just (chainOf ctx space.id))
           ]
        <> [button "Rename" (Open (Renaming space.name)) | admin]
        <> [button (if space.public then "Make private" else "Make public") TogglePublic | admin]
        <> [button "Move" (Open (Moving 0)) | admin, not (null (destinations ctx space))]
        <> [button "Delete" (Open ConfirmingDelete) | admin]
      where
        admin = mayAdminister ctx space.id
        path = spacePathOf ctx.spaces space.id

    form :: Context -> Space -> Mode -> Maybe (H.ComponentHTML Action Empty m)
    form ctx space = \case
      Viewing -> Nothing
      Renaming name -> Just (inForm (textField "New name" name Typed) "Rename")
      Moving chosen ->
        Just $
          inForm
            [hh|
              <label class="field">
                <span>Move to</span>
                <select onSelectedIndexChange={{ Chose }}>
                  {% for (n, d) in zip [0 ..] (destinations ctx space) %}
                    <option selected={{ n == chosen }}>{{ destinationName ctx d }}</option>
                  {% end %}
                </select>
              </label>
            |]
            "Move"
      ConfirmingDelete ->
        Just
          [hh|
            <div class="confirm" role="alertdialog">
              <p>Delete {{ space.name }}, with its subspaces and all their pages? This cannot be undone.</p>
              <button type="button" class="danger" onClick={{ const Delete }}>Delete</button>
              {{ button "Cancel" (Open Viewing) }}
            </div>
          |]

    inForm :: H.ComponentHTML Action Empty m -> Text -> H.ComponentHTML Action Empty m
    inForm field submit =
      [hh|
        <form class="inline-form" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
          {{ field }}
          <button type="submit" class="primary">{{ submit }}</button>
          {{ button "Cancel" (Open Viewing) }}
        </form>
      |]

    subspaces :: Context -> Space -> [H.ComponentHTML Action Empty m]
    subspaces ctx space = case childrenOf ctx.spaces (Just space.id) of
      [] -> []
      children ->
        [hhs|
          <h2>Subspaces</h2>
          <ul class="space-list">
            {% for s in children %}
              <li>{{ Router.link ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) [] [HH.text s.name] }}</li>
            {% end %}
          </ul>
        |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Receive input -> do
        old <- gets (\st -> st.input)
        -- What was open is about the space as it was: after a change, or on
        -- another space, it is closed.
        if old.space.id /= input.space.id || old.context.revision /= input.context.revision
          then put State {input, mode = Viewing, problem = Nothing}
          else modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Open mode -> modify (\st -> st {mode, problem = Nothing})
      Typed t -> modify $ \st -> case st.mode of
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      Chose n -> modify (\st -> st {mode = Moving n})
      Submit -> do
        State {input = Input {context = ctx, space}, mode} <- get
        case mode of
          Renaming name -> renameSpace space.id name >>= done (const Nothing)
          Moving n -> for_ (atMay (destinations ctx space) n) $ \destination ->
            moveSpace space.id (map (\d -> d.id) destination) >>= done (\moved -> Just (Space (destinationPath ctx destination <> [moved.slug])))
          _ -> pass
      TogglePublic -> do
        space <- gets (\st -> st.input.space)
        setSpacePublic space.id (not space.public) >>= done (const Nothing)
      Delete -> do
        Input {context = ctx, space} <- gets (\st -> st.input)
        let parentRoute = maybe Home (Space . spacePathOf ctx.spaces) space.parent
        deleteSpace space.id >>= done (const (Just parentRoute))

    done :: (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Empty ViewOutput m ()
    done next = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> st {mode = Viewing, problem = Nothing})
        H.raise (Changed (next a))

-- | Where the space may be moved: the top level, or under another space,
-- where the rules allow it and the move would not put the space inside
-- itself; not where it already is.
destinations :: Context -> Space -> [Maybe Space]
destinations ctx space =
  [ Nothing
  | isJust space.parent
  , mayMoveSpace who grants chain Nothing
  ]
    <> [ Just d
       | d <- ctx.spaces
       , Just d.id /= space.parent
       , not (descendsFrom ctx.spaces space.id d.id)
       , mayMoveSpace who grants chain (Just (chainOf ctx d.id))
       ]
  where
    who = principalOf ctx
    grants = grantsOf ctx
    chain = chainOf ctx space.id

destinationPath :: Context -> Maybe Space -> [Slug]
destinationPath ctx = maybe [] (spacePathOf ctx.spaces . (\d -> d.id))

destinationName :: Context -> Maybe Space -> Text
destinationName ctx = \case
  Nothing -> "The top level"
  Just d -> mconcat (intersperse " / " (map (\s -> s.name) (chainOf ctx d.id)))
