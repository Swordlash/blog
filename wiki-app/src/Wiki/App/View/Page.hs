-- | A page, read: its Markdown rendered as "Wiki.App.View.Body" renders it
-- (with its links resolved and its islands drawn), its attachments, and what
-- the current user may do to it (edit, add a page under it, rename, move,
-- delete). The URLs of its attachments are asked of the backend
-- ('attachmentUrl') once per load.
module Wiki.App.View.Page
  ( Input (..)
  , Slots
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Protolude hiding (State)
import Web.Event.Event (Event, preventDefault)
import Web.UIEvent.MouseEvent (MouseEvent)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Browser (followArticleClick)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (AttachmentId, PageId, SpaceId)
import Wiki.Core.Page (Page (attachments, body, id, parent, slug, space, title, updatedAt))
import Wiki.Core.Permission (mayMovePage)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name))

-- | The page at a path in a space the shell has loaded, with the space's
-- pages (for the links between them).
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , path :: [Slug]
  }

type Slots = Body.IslandSlots

data Loaded
  = Loading
  | Failed WikiError
  | -- | The page, and where each of its attachments is fetched from.
    Ready Page (Map AttachmentId Text)

data Mode
  = Viewing
  | Renaming Text
  | -- | Moving: the space chosen (an index into 'targetSpaces'), its pages,
    -- and the parent chosen among them ('Nothing' for its top level).
    Moving Int [Page] (Maybe PageId)
  | ConfirmingDelete

data State = State
  { input :: Input
  , loaded :: Loaded
  , mode :: Mode
  , problem :: Maybe WikiError
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | ArticleClicked MouseEvent
  | Open Mode
  | Typed Text
  | StartMove
  | ChoseSpace Int
  | ChoseParent Int
  | Submit Event
  | Delete

component :: forall query m. (MonadWiki m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, loaded = Loading, mode = Viewing, problem = Nothing}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render State {input, loaded, mode, problem} = case loaded of
      Loading -> HH.p [HP.class_ "loading"] [HH.text "Loading…"]
      Failed e -> errorView e
      Ready page urls ->
        HH.div
          [HP.class_ "page-view"]
          ( [HH.div [HP.class_ "actions"] (actions input page) | mayEdit input.context page.space]
              <> form input page mode
              <> foldMap (pure . errorView) problem
              <> Body.heading page.title page.body
              <> [body input page urls]
              <> attachments page urls
              <> [HH.footer [HP.class_ "page-meta"] [HH.text ("Last changed " <> day page.updatedAt)]]
          )

    actions :: Input -> Page -> [H.ComponentHTML Action Slots m]
    actions input page =
      [ Router.link input.context.router Followed (EditPage spacePath input.path) [HP.class_ "button"] [HH.text "Edit"]
      , Router.link input.context.router Followed (NewPage spacePath (Just input.path)) [HP.class_ "button"] [HH.text "New subpage"]
      , button "Rename" (Open (Renaming page.title))
      , button "Move" StartMove
      , button "Delete" (Open ConfirmingDelete)
      ]
      where
        spacePath = spacePathOf input.context.spaces input.space.id

    form :: Input -> Page -> Mode -> [H.ComponentHTML Action Slots m]
    form input page = \case
      Viewing -> []
      Renaming title -> [inForm [textField "New title" title Typed] "Rename"]
      Moving chosen targetPages parent ->
        let spaces = targetSpaces input.context page
            target = (\s -> s.id) <$> atMay spaces chosen
            parents = Nothing : map Just (allowedParents page target targetPages)
         in [ inForm
                [ select "Move to the space" ChoseSpace [(n == chosen, spaceName input.context s) | (n, s) <- zip [0 ..] spaces]
                , select "Under" ChoseParent [(p == parent, maybe "Its top level" (\q -> q.title) (findPage targetPages =<< p)) | p <- parents]
                ]
                "Move"
            ]
      ConfirmingDelete ->
        [ HH.div
            [HP.class_ "confirm", attr "role" "alertdialog"]
            [ HH.p_ [HH.text ("Delete " <> page.title <> ", with the pages under it and their attachments? This cannot be undone.")]
            , HH.button [HP.type_ I.ButtonButton, HP.class_ "danger", HE.onClick (const Delete)] [HH.text "Delete"]
            , button "Cancel" (Open Viewing)
            ]
        ]

    select :: Text -> (Int -> Action) -> [(Bool, Text)] -> H.ComponentHTML Action Slots m
    select label onChoose choices =
      HH.label
        [HP.class_ "field"]
        [ HH.span_ [HH.text label]
        , HH.select [HE.onSelectedIndexChange onChoose] [HH.option [HP.selected chosen] [HH.text name] | (chosen, name) <- choices]
        ]

    inForm :: [H.ComponentHTML Action Slots m] -> Text -> H.ComponentHTML Action Slots m
    inForm fields submit =
      HH.form
        [HP.class_ "inline-form", HE.onSubmit Submit]
        (fields <> [HH.button [HP.type_ I.ButtonSubmit, HP.class_ "primary"] [HH.text submit], button "Cancel" (Open Viewing)])

    body :: Input -> Page -> Map AttachmentId Text -> H.ComponentHTML Action Slots m
    body input page urls =
      Body.article
        ArticleClicked
        Body.Place {context = input.context, space = input.space, pages = input.pages, path = input.path, attachments = page.attachments, urls}
        page.body

    attachments :: Page -> Map AttachmentId Text -> [H.ComponentHTML Action Slots m]
    attachments page urls = case page.attachments of
      [] -> []
      files ->
        [ HH.section
            [HP.class_ "attachments"]
            [ HH.h2_ [HH.text "Attachments"]
            , HH.ul_
                [ HH.li_
                    [ HH.a [HP.href (Map.findWithDefault "" a.id urls), HP.download a.name] [HH.text a.name]
                    , HH.span [HP.class_ "attachment-meta"] [HH.text (a.mediaType <> ", " <> fileSize a.size)]
                    ]
                | a <- files
                ]
            ]
        ]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize -> load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path
        when elsewhere $ modify (\st -> st {loaded = Loading})
        when (elsewhere || old.context.revision /= input.context.revision) $ do
          modify (\st -> st {mode = Viewing, problem = Nothing})
          load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      ArticleClicked click -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleClick router click)
      Open mode -> modify (\st -> st {mode, problem = Nothing})
      Typed t -> modify $ \st -> case st.mode of
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      StartMove -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spaces = targetSpaces input.context page
            here = fromMaybe 0 (head [n | (n, s) <- zip [0 ..] spaces, s.id == page.space])
        modify (\st -> st {mode = Moving here input.pages page.parent, problem = Nothing})
      ChoseSpace n -> withPage $ \page -> do
        ctx <- gets (\st -> st.input.context)
        for_ (atMay (targetSpaces ctx page) n) $ \s ->
          listPages s.id >>= \case
            Left e -> modify (\st -> st {problem = Just e})
            Right ps -> modify (\st -> st {mode = Moving n ps Nothing})
      ChoseParent n -> withPage $ \page ->
        modify $ \st -> case st.mode of
          Moving chosen ps _ ->
            let target = (\s -> s.id) <$> atMay (targetSpaces st.input.context page) chosen
             in st {mode = Moving chosen ps (join (atMay (Nothing : map Just (allowedParents page target ps)) n))}
          other -> st {mode = other}
      Submit ev -> do
        H.liftEffect (preventDefault ev)
        withPage $ \page -> do
          State {input, mode} <- get
          let ctx = input.context
          case mode of
            Renaming title ->
              savePage page.id page.updatedAt title page.body >>= done (const Nothing)
            Moving chosen ps parent -> for_ (atMay (targetSpaces ctx page) chosen) $ \target ->
              movePage page.id target.id parent
                >>= done (\moved -> Just (Page (spacePathOf ctx.spaces target.id) (maybe [] (pagePathOf ps) parent <> [moved.slug])))
            _ -> pass
      Delete -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spacePath = spacePathOf input.context.spaces input.space.id
            parentRoute = maybe (Space spacePath) (const (Page spacePath (take (length input.path - 1) input.path))) page.parent
        deletePage page.id >>= done (const (Just parentRoute))

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      result <- getPage input.space.id input.path
      loaded <- case result of
        Left e -> pure (Failed e)
        Right page -> Ready page . Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      -- Only if the page asked for is still the one to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path) $ do
        modify (\st -> st {loaded})
        H.raise Loaded

    withPage :: (Page -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage k =
      gets (\st -> st.loaded) >>= \case
        Ready page _ -> k page
        _ -> pass

    done :: (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Slots ViewOutput m ()
    done next = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> st {mode = Viewing, problem = Nothing})
        H.raise (Changed (next a))

-- | The spaces a page may be moved to: those where the rules allow it.
targetSpaces :: Context -> Page -> [Space]
targetSpaces ctx page =
  [ s
  | s <- ctx.spaces
  , mayMovePage (principalOf ctx) (grantsOf ctx) (chainOf ctx page.space) (chainOf ctx s.id)
  ]

-- | The pages of the target space a page may be put under: in its own space,
-- not itself or one of the pages under it.
allowedParents :: Page -> Maybe SpaceId -> [Page] -> [PageId]
allowedParents page target ps
  | target == Just page.space = [p.id | p <- ps, p.id /= page.id, page.id `notElem` ancestorsOf p]
  | otherwise = [p.id | p <- ps]
  where
    ancestorsOf p = case p.parent of
      Nothing -> []
      Just q -> q : maybe [] ancestorsOf (findPage ps q)

findPage :: [Page] -> PageId -> Maybe Page
findPage ps pid = find (\p -> p.id == pid) ps

spaceName :: Context -> Space -> Text
spaceName ctx s = mconcat (intersperse " / " (map (\c -> c.name) (chainOf ctx s.id)))

day :: UTCTime -> Text
day = toS . formatTime defaultTimeLocale "%-d %B %Y"
