-- | The application's frame, around whatever the route shows: a header with
-- the site's name, breadcrumbs, the place for a search box and the demo's
-- user switcher; a sidebar with the tree of spaces, the current space's
-- pages under it; and the content of the route.
--
-- The shell holds what every view needs and loads it itself: who is signed
-- in, the tree of spaces, and the space the route is in with its pages
-- (through 'getSpace' and 'listPages', so that a space the user may not see
-- is refused in place). The views are child components ("Wiki.App.View.*"):
-- a space, a page, the form for a new space. They are handed that context,
-- and they tell the shell when they have changed the wiki ('Changed'), which
-- it then reloads, counting up the context's revision so that they reload
-- what they hold as well, and goes where the change leads.
--
-- The route is the router's ('Router.current' at the start, then
-- 'Router.changes'), so links, the back and forward buttons and a reload all
-- arrive at the same place.
module Wiki.App.Shell
  ( Input (..)
  , Query (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Row (type (.+), type (.==))
import Data.Set qualified as Set
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError, anonymous)
import Wiki.App.Browser (setDocumentTitle)
import Wiki.App.DemoUsers (MonadDemoUsers (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.App.View.NewSpace qualified as NewSpaceView
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.Space qualified as SpaceView
import Wiki.Core.Id (SpaceId, UserId)
import Wiki.Core.Page (Page (id, title))
import Wiki.Core.Path (PathError (..), childrenOf, findChild, resolvePath)
import Wiki.Core.Permission (mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name, public, slug))
import Wiki.Core.User (User (..))

-- | The router, and a route the home page invites a newcomer to (the
-- demo's tour), if there is one.
data Input = Input
  { router :: Router Route
  , welcome :: Maybe Route
  }

-- | Whether the shell has loaded everything the route shows; when it has,
-- the document's title for it. The prerender waits for this before it
-- takes the page's HTML.
data Query a = Settled (Maybe Text -> a)

type Slots =
  ("space" .== H.Slot (Const Void) ViewOutput ())
    .+ ("page" .== H.Slot (Const Void) ViewOutput ())
    .+ ("newSpace" .== H.Slot (Const Void) ViewOutput ())

-- | The space the route is in, as far as it has been loaded.
data Here
  = NoSpace
  | LoadingSpace [Slug]
  | SpaceFailed [Slug] WikiError
  | InSpace [Slug] Space [Page]

data State = State
  { router :: Router Route
  , welcome :: Maybe Route
  , route :: Route
  , session :: Session
  , users :: [User]
  , spaces :: [Space]
  , here :: Here
  , collapsed :: Set SpaceId
  , generation :: Int
  -- ^ The views' 'revision': how many times the wiki has been reloaded
  -- after a change.
  , menuOpen :: Bool
  , settled :: Bool
  }

data Action
  = Initialize
  | Arrived Route
  | Followed (Follow Route)
  | Toggle SpaceId
  | ToggleMenu
  | SwitchTo (Maybe UserId)
  | FromView ViewOutput

component
  :: forall output m
   . (MonadWiki m, MonadDemoUsers m, MonadIslands m, MonadUUID m, MonadIO m)
  => H.Component Query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \Input {router, welcome} -> do
          route <- Router.current router
          pure
            State
              { router
              , welcome
              , route
              , session = anonymous
              , users = []
              , spaces = []
              , here = NoSpace
              , collapsed = mempty
              , generation = 0
              , menuOpen = False
              , settled = False
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.initialize = Just Initialize
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      HH.div
        [HP.class_ "wiki"]
        [ header st
        , HH.div
            [HP.class_ "wiki-body"]
            [ sidebar st
            , HH.main [HP.class_ "wiki-content"] [content st]
            ]
        ]

    header :: State -> H.ComponentHTML Action Slots m
    header st =
      HH.header
        [HP.class_ "wiki-header"]
        [ Router.link st.router Followed Home [HP.class_ "wiki-brand"] [HH.text "Wiki"]
        , breadcrumbs st
        , -- Where the search box goes (WP1.8).
          HH.div [HP.class_ "wiki-search"] []
        , userSwitcher st
        ]

    breadcrumbs :: State -> H.ComponentHTML Action Slots m
    breadcrumbs st =
      HH.nav
        [HP.class_ "breadcrumbs", attr "aria-label" "Breadcrumbs"]
        [ HH.ol_ $ case unsnoc (crumbs st) of
            Nothing -> []
            Just (before, final) ->
              map crumb before <> [HH.li_ [HH.span [attr "aria-current" "page"] [HH.text (fst final)]]]
        ]
      where
        crumb (label, target) = HH.li_ [maybe (HH.span [HP.class_ "unviewable"] [HH.text label]) (\r -> Router.link st.router Followed r [] [HH.text label]) target]

    userSwitcher :: State -> H.ComponentHTML Action Slots m
    userSwitcher st =
      HH.div
        [HP.class_ "user-switcher"]
        ( HH.button
            [ HP.type_ I.ButtonButton
            , HP.class_ "user-switcher-toggle"
            , attr "aria-expanded" (if st.menuOpen then "true" else "false")
            , HE.onClick (const ToggleMenu)
            ]
            [HH.text (maybe "Not signed in" (\u -> u.displayName) st.session.user)]
            : [ HH.ul
                  [HP.class_ "user-menu"]
                  [ HH.li_
                      [ HH.button
                          [ HP.type_ I.ButtonButton
                          , HP.class_ "user-option"
                          , attr "data-login" (maybe "" (\u -> u.login) candidate)
                          , attr "aria-pressed" (if ((\u -> u.id) <$> candidate) == ((\u -> u.id) <$> st.session.user) then "true" else "false")
                          , HE.onClick (const (SwitchTo ((\u -> u.id) <$> candidate)))
                          ]
                          [HH.text (maybe "Nobody (not signed in)" (\u -> u.displayName <> " (" <> u.login <> ")") candidate)]
                      ]
                  | candidate <- Nothing : map Just st.users
                  ]
              | st.menuOpen
              ]
        )

    sidebar :: State -> H.ComponentHTML Action Slots m
    sidebar st =
      HH.nav
        [HP.class_ "wiki-sidebar", attr "aria-label" "Spaces"]
        ( [HH.h2_ [HH.text "Spaces"], spaceLevel st Nothing]
            <> [ Router.link st.router Followed (NewSpace Nothing) [HP.class_ "new-space-link"] [HH.text "New space"]
               | mayCreateSpace (principalOf (context st)) st.session.grants Nothing
               ]
        )

    spaceLevel :: State -> Maybe SpaceId -> H.ComponentHTML Action Slots m
    spaceLevel st parent = HH.ul [HP.class_ "space-tree"] (map (spaceNode st) (childrenOf st.spaces parent))

    spaceNode :: State -> Space -> H.ComponentHTML Action Slots m
    spaceNode st s =
      HH.li
        [HP.classes ("space-node" : ["current" | current])]
        ( [ HH.div
              [HP.class_ "space-row"]
              ( [ HH.button
                    [ HP.type_ I.ButtonButton
                    , HP.class_ "tree-toggle"
                    , attr "aria-expanded" (if open then "true" else "false")
                    , attr "aria-label" ((if open then "Collapse " else "Expand ") <> s.name)
                    , HE.onClick (const (Toggle s.id))
                    ]
                    [HH.text (if open then "▾" else "▸")]
                | hasChildren
                ]
                  <> [spaceLabel]
              )
          ]
            <> pagesHere
            <> [spaceLevel st (Just s.id) | hasChildren, open]
        )
      where
        ctx = context st
        path = spacePathOf st.spaces s.id
        hasChildren = not (null (childrenOf st.spaces (Just s.id)))
        open = not (s.id `Set.member` st.collapsed)
        current = case st.here of
          InSpace _ here _ -> here.id == s.id
          _ -> False
        spaceLabel
          | mayView ctx s.id =
              Router.link st.router Followed (Space path) ([HP.class_ "space-link"] <> [attr "aria-current" "page" | current && isSpaceRoute st.route]) [HH.text s.name]
          | otherwise =
              HH.span [HP.class_ "unviewable", HP.title "You do not have permission to see this space"] [HH.text s.name]
        pagesHere = case st.here of
          InSpace _ here pages | here.id == s.id, not (null pages) -> [pageTree st.router Followed path pages ((\p -> p.id) <$> currentPage st)]
          _ -> []

    content :: State -> H.ComponentHTML Action Slots m
    content st = case st.route of
      Home -> home st
      Unknown -> notFound st
      NewSpace parent -> HH.slot "newSpace" () NewSpaceView.component NewSpaceView.Input {context = context st, parent} FromView
      _ -> case st.here of
        NoSpace -> notFound st
        LoadingSpace _ -> HH.p [HP.class_ "loading"] [HH.text "Loading…"]
        SpaceFailed _ e -> errorView e
        InSpace _ space pages -> case st.route of
          Page _ path -> HH.slot "page" () PageView.component PageView.Input {context = context st, space, pages, path} FromView
          EditPage spacePath path ->
            HH.section
              [HP.class_ "edit-placeholder"]
              [ HH.h1_ [HH.text ("Editing " <> maybe "a page" (\p -> p.title) (currentPageOf pages path))]
              , HH.p_ [HH.text "The editor is not here yet: it comes with the next version of the demo."]
              , Router.link st.router Followed (Page spacePath path) [HP.class_ "button"] [HH.text "Back to the page"]
              ]
          _ -> HH.slot "space" () SpaceView.component SpaceView.Input {context = context st, space, pages} FromView

    home :: State -> H.ComponentHTML Action Slots m
    home st =
      HH.section
        [HP.class_ "home"]
        ( [ HH.h1_ [HH.text "Welcome to the wiki"]
          , HH.p_ [HH.text "Spaces hold pages written in Markdown, and spaces can hold other spaces. Who may read, edit or administer a space is up to its permissions; a public space is open to everyone."]
          ]
            <> [ HH.p [HP.class_ "welcome"] [HH.text "New here? ", Router.link st.router Followed r [] [HH.text "Take the tour"], HH.text "."]
               | Just r <- [st.welcome]
               ]
            <> [ HH.h2_ [HH.text "Spaces"]
               , case childrenOf st.spaces Nothing of
                   [] -> HH.p [HP.class_ "empty"] [HH.text "There are no spaces you can see."]
                   roots -> HH.ul [HP.class_ "space-list"] (map (rootSpace st) roots)
               ]
            <> [ Router.link st.router Followed (NewSpace Nothing) [HP.class_ "button"] [HH.text "New space"]
               | mayCreateSpace (principalOf (context st)) st.session.grants Nothing
               ]
        )

    rootSpace :: State -> Space -> H.ComponentHTML Action Slots m
    rootSpace st s
      | mayView (context st) s.id =
          HH.li_
            [ Router.link st.router Followed (Space [s.slug]) [] [HH.text s.name]
            , HH.span [HP.classes ["badge", if s.public then "badge-public" else "badge-private"]] [HH.text (if s.public then "Public" else "Private")]
            ]
      | otherwise =
          HH.li_ [HH.span [HP.class_ "unviewable", HP.title "You can see only a subspace of this space"] [HH.text s.name]]

    notFound :: State -> H.ComponentHTML Action Slots m
    notFound st =
      HH.section
        [HP.class_ "not-found"]
        [ HH.h1_ [HH.text "Not found"]
        , HH.p_ [HH.text "There is nothing at this address."]
        , Router.link st.router Followed Home [HP.class_ "button"] [HH.text "Go to the front page"]
        ]

    handleAction :: Action -> H.HalogenM State Action Slots output m ()
    handleAction = \case
      Initialize -> do
        router <- gets (\st -> st.router)
        void $ H.subscribe (Arrived <$> Router.changes router)
        loadWorld
        loadHere True
      Arrived r -> do
        before <- gets (\st -> st.route)
        unless (r == before) $ do
          modify (\st -> st {route = r, settled = False, menuOpen = False})
          loadHere False
      Followed f -> gets (\st -> st.router) >>= (`Router.follow` f)
      Toggle sid -> modify $ \st ->
        st {collapsed = if sid `Set.member` st.collapsed then Set.delete sid st.collapsed else Set.insert sid st.collapsed}
      ToggleMenu -> modify (\st -> st {menuOpen = not st.menuOpen})
      SwitchTo user -> do
        modify (\st -> st {menuOpen = False, settled = False})
        switchTo user
        reload Nothing
      FromView (Changed next) -> reload next
      FromView Loaded -> settle

    -- After a change: everything again, and every view's own data too.
    reload :: Maybe Route -> H.HalogenM State Action Slots output m ()
    reload next = do
      loadWorld
      modify (\st -> st {generation = st.generation + 1})
      for_ next $ \r -> modify (\st -> st {route = r, settled = False})
      loadHere True
      -- The router is told last, so that the route it announces is the one
      -- already shown, which 'Arrived' leaves alone.
      router <- gets (\st -> st.router)
      for_ next (Router.navigate router)

    loadWorld :: H.HalogenM State Action Slots output m ()
    loadWorld = do
      s <- session
      us <- listUsers
      ss <- listSpaces
      modify (\st -> st {session = s, users = us, spaces = ss})

    -- The space the route is in, unless it is the one loaded already
    -- (or even so, if forced).
    loadHere :: Bool -> H.HalogenM State Action Slots output m ()
    loadHere again = do
      st <- get
      case spaceOfRoute st.route of
        Nothing -> modify (\s -> s {here = NoSpace})
        Just path
          | not again, hereIs path st.here -> pass
          | otherwise -> do
              -- Reloading the space being shown keeps it on screen meanwhile.
              unless (hereIs path st.here) $ modify (\s -> s {here = LoadingSpace path})
              result <- runExceptT $ do
                space <- ExceptT (getSpace path)
                pages <- ExceptT (listPages space.id)
                pure (InSpace path space pages)
              -- Unless the route has moved on to another space meanwhile.
              now <- gets (\s -> s.route)
              when (spaceOfRoute now == Just path) $
                modify (\s -> s {here = either (SpaceFailed path) identity result})
      st' <- get
      H.liftEffect (setDocumentTitle (documentTitle st'))
      -- A page's view says when it has loaded the page; everything else is
      -- loaded now.
      unless (waitsForPage st') settle

    settle :: H.HalogenM State Action Slots output m ()
    settle = modify (\st -> st {settled = True})

    handleQuery :: Query a -> H.HalogenM State Action Slots output m (Maybe a)
    handleQuery (Settled reply) = do
      st <- get
      pure (Just (reply (if st.settled then Just (documentTitle st) else Nothing)))

context :: State -> Context
context st = Context {router = st.router, session = st.session, spaces = st.spaces, revision = st.generation}

spaceOfRoute :: Route -> Maybe [Slug]
spaceOfRoute = \case
  Space path -> Just path
  Page path _ -> Just path
  EditPage path _ -> Just path
  _ -> Nothing

isSpaceRoute :: Route -> Bool
isSpaceRoute = \case
  Space _ -> True
  _ -> False

hereIs :: [Slug] -> Here -> Bool
hereIs path = \case
  InSpace p _ _ -> p == path
  SpaceFailed p _ -> p == path
  LoadingSpace p -> p == path
  NoSpace -> False

waitsForPage :: State -> Bool
waitsForPage st = case (st.route, st.here) of
  (Page _ _, InSpace {}) -> True
  _ -> False

currentPageOf :: [Page] -> [Slug] -> Maybe Page
currentPageOf pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

currentPage :: State -> Maybe Page
currentPage st = case (st.route, st.here) of
  (Page _ path, InSpace _ _ pages) -> currentPageOf pages path
  (EditPage _ path, InSpace _ _ pages) -> currentPageOf pages path
  _ -> Nothing

-- | What the route is, as far as it has been loaded: a title for it.
crumbs :: State -> [(Text, Maybe Route)]
crumbs st = case st.route of
  Home -> []
  Space path -> spaceCrumbs path
  Page path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath
  EditPage path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath <> [("Edit", Nothing)]
  NewSpace parent -> foldMap spaceCrumbs parent <> [("New space", Nothing)]
  Unknown -> [("Not found", Nothing)]
  where
    spaceCrumbs path =
      [ (s.name, if mayView (context st) s.id then Just (Space (spacePathOf st.spaces s.id)) else Nothing)
      | s <- either (\e -> e.resolved) identity (resolvePath (findChild st.spaces) path)
      ]
    pageCrumbs path pagePath = case st.here of
      InSpace _ _ pages ->
        [ (p.title, Just (Page path (pagePathOf pages p.id)))
        | p <- either (\e -> e.resolved) identity (resolvePath (findChild pages) pagePath)
        ]
      _ -> []

documentTitle :: State -> Text
documentTitle st = case reverse (map fst (crumbs st)) of
  [] -> "Wiki"
  names -> mconcat (intersperse " · " (take 2 names)) <> " · Wiki"
