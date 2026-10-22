-- | A space: its pages as a tree, its subspaces, and what the current user
-- may do to it (a new page, a new subspace, renaming it, making it public or
-- private, moving it, deleting it). An action the rules forbid is not
-- offered; the backend checks the rules again, and a refusal is shown in
-- place.
module Wiki.App.View.Space
  ( Input (..)
  , component
  )
where

import DOM.HTML.Indexed qualified as I
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Protolude hiding (State)
import Web.Event.Event (Event, preventDefault)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Page (Page (slug))
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
  | NewPage Text
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
  | Submit Event
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
      HH.section
        [HP.class_ "space-view"]
        ( [ HH.header
              [HP.class_ "view-header"]
              [ HH.h1_ [HH.text space.name]
              , HH.span [HP.classes ["badge", if space.public then "badge-public" else "badge-private"]] [HH.text (if space.public then "Public" else "Private")]
              ]
          , HH.div [HP.class_ "actions"] (actions ctx space)
          ]
            <> form ctx space mode
            <> foldMap (pure . errorView) problem
            <> [ HH.h2_ [HH.text "Pages"]
               , if null pages
                   then HH.p [HP.class_ "empty"] [HH.text "No pages yet."]
                   else pageTree ctx.router Followed (spacePathOf ctx.spaces space.id) pages Nothing
               ]
            <> subspaces ctx space
        )

    actions :: Context -> Space -> [H.ComponentHTML Action Empty m]
    actions ctx space =
      [button "New page" (Open (NewPage "")) | mayEdit ctx space.id]
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

    form :: Context -> Space -> Mode -> [H.ComponentHTML Action Empty m]
    form ctx space = \case
      Viewing -> []
      NewPage title -> [inForm [textField "Title of the new page" title Typed] "Create"]
      Renaming name -> [inForm [textField "New name" name Typed] "Rename"]
      Moving chosen ->
        [ inForm
            [ HH.label
                [HP.class_ "field"]
                [ HH.span_ [HH.text "Move to"]
                , HH.select
                    [HE.onSelectedIndexChange Chose]
                    [ HH.option [HP.selected (n == chosen)] [HH.text (destinationName ctx d)]
                    | (n, d) <- zip [0 ..] (destinations ctx space)
                    ]
                ]
            ]
            "Move"
        ]
      ConfirmingDelete ->
        [ HH.div
            [HP.class_ "confirm", attr "role" "alertdialog"]
            [ HH.p_ [HH.text ("Delete " <> space.name <> ", with its subspaces and all their pages? This cannot be undone.")]
            , HH.button [HP.type_ I.ButtonButton, HP.class_ "danger", HE.onClick (const Delete)] [HH.text "Delete"]
            , button "Cancel" (Open Viewing)
            ]
        ]

    inForm :: [H.ComponentHTML Action Empty m] -> Text -> H.ComponentHTML Action Empty m
    inForm fields submit =
      HH.form
        [HP.class_ "inline-form", HE.onSubmit Submit]
        (fields <> [HH.button [HP.type_ I.ButtonSubmit, HP.class_ "primary"] [HH.text submit], button "Cancel" (Open Viewing)])

    subspaces :: Context -> Space -> [H.ComponentHTML Action Empty m]
    subspaces ctx space = case childrenOf ctx.spaces (Just space.id) of
      [] -> []
      children ->
        [ HH.h2_ [HH.text "Subspaces"]
        , HH.ul
            [HP.class_ "space-list"]
            [ HH.li_ [Router.link ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) [] [HH.text s.name]]
            | s <- children
            ]
        ]

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
        NewPage _ -> st {mode = NewPage t}
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      Chose n -> modify (\st -> st {mode = Moving n})
      Submit ev -> do
        H.liftEffect (preventDefault ev)
        State {input = Input {context = ctx, space}, mode} <- get
        let path = spacePathOf ctx.spaces space.id
        case mode of
          NewPage title ->
            createPage space.id Nothing title ("# " <> title <> "\n")
              >>= done (\p -> Just (Page path [p.slug]))
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
