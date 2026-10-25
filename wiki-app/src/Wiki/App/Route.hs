-- | Where the application is: its routes, how each is written as an address,
-- and where a link written in a page leads.
--
-- Addresses are paths, under the base path the site is served from (a
-- @\<base href>@, read by "Halogen.Router"'s 'Halogen.Router.pageBase'), so
-- that the server of Phase 2 can serve the very same addresses:
--
-- > /                              Home
-- > /s/team/projects/              Space [team, projects]
-- > /s/docs/p/markdown-guide/      Page [docs] [markdown-guide]
-- > /s/docs/p/tour/edit/           EditPage [docs] [tour]
-- > /s/docs/p/tour/source/         PageSource [docs] [tour]
-- > /s/docs/p/tour/history/        PageHistory [docs] [tour] Nothing AgainstPrevious
-- > /s/docs/p/tour/history/?version=2026-10-24T09%3A30%3A12.5Z&against=current
-- >                                PageHistory [docs] [tour] (Just …) AgainstCurrent
-- > /s/docs/p/presentations/slides/ PageSlides [docs] [presentations] 1
-- > /s/docs/p/presentations/slides/?slide=3
-- >                                PageSlides [docs] [presentations] 3
-- > /s/docs/new-page/              NewPage [docs] Nothing
-- > /s/docs/new-page/tour/         NewPage [docs] (Just [tour])
-- > /new-space/                    NewSpace Nothing
-- > /new-space/team/               NewSpace (Just [team])
-- > /not-found/                    Unknown
-- > /admin/                        Admin
-- > /search/?q=mermaid&space=docs  Search (Just "mermaid") (Just [docs]) True
-- > /search/?q=x&space=team&only   Search (Just "x") (Just [team]) False
--
-- Every address but the home's ends in a slash, because each is a directory
-- with an @index.html@ in it on a static host (the prerender writes one per
-- route), and a static host redirects @\/s\/docs@ to @\/s\/docs\/@. An address
-- without the slash is read as the same route, so a typed or pasted one
-- works too.
--
-- A space's path and a page's path are separated by the segment @p@, an
-- edit route ends in @edit@, a page's source in @source@, its history in
-- @history@, its slides in @slides@, and a new page's
-- route has @new-page@ after the space's path; a slug may be any of these
-- words too (a page titled "P"), so
-- a slug that is one of them is written with a @~@ before it (@\/s\/~p\/@),
-- which no slug can start with. That keeps every route's
-- address its own: 'route' reads back exactly the route it wrote.
module Wiki.App.Route
  ( -- * Routes
    Route (..)
  , Against (..)
  , route
  , routeOfHref
  , spaceRouteOf

    -- * Links in pages
  , PageLink (..)
  , resolvePageLink
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (RouteDuplex (..), RouteDuplex', as, flag, many1, noArgs, param, prefix, root, segment, suffix)
import Halogen.Router.Duplex qualified as Duplex
import Protolude
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Page (Page)
import Wiki.Core.Path (findChild, parsePath, renderPath, resolvePath)
import Wiki.Core.Permission (spaceChain)
import Wiki.Core.Slug (Slug, mkSlug, slugText, slugify)
import Wiki.Core.Space (Space (slug))

-- | A place in the application.
data Route
  = -- | The front page: the top-level spaces.
    Home
  | -- | A space, by its path from the top level: its pages and subspaces.
    Space [Slug]
  | -- | A page: its space's path, and its own path among the space's pages.
    Page [Slug] [Slug]
  | -- | The editor for a page: its space's path, and its own path there.
    EditPage [Slug] [Slug]
  | -- | A page's Markdown, for anyone who may read the page: its space's
    -- path, and its own path there.
    PageSource [Slug] [Slug]
  | -- | The form for a new space, at the top level or under a space.
    NewSpace (Maybe [Slug])
  | -- | An address that is none of the above.
    Unknown
  | -- | The editor for a new page in a space: the space's path, and the path
    -- of the page to put it under, or 'Nothing' for the space's top level.
    NewPage [Slug] (Maybe [Slug])
  | -- | The results of a search: the words, if any; the path of the space
    -- searched, or 'Nothing' for every space (a path that is not one is
    -- empty, which names no space); and whether its subspaces are
    -- searched too. They are the query's parameters (@q@, @space@, and
    -- @only@ when the subspaces are left out), so that the address of a
    -- search can be kept and shared like any other.
    Search (Maybe Text) (Maybe [Slug]) Bool
  | -- | The administration of the wiki as a whole, for whoever holds the
    -- global 'Wiki.Core.Permission.Administer'.
    Admin
  | -- | A page's history, for anyone who may read the page: its space's
    -- path, its own path there, the version shown (by its time, the
    -- page's @updatedAt@ then; 'Nothing' for the latest), and what that
    -- version is compared with. They are parameters (@version@, and
    -- @against=current@), so that a version's address can be kept and
    -- shared.
    PageHistory [Slug] [Slug] (Maybe UTCTime) Against
  | -- | A page presented as slides ("Wiki.Core.Slides"), for anyone who may
    -- read the page: its space's path, its own path there, and the slide
    -- shown, counted from 1. The slide is a parameter (@slide@, left out
    -- for the first), so that a reload, or a link, comes back to it.
    PageSlides [Slug] [Slug] Int
  deriving stock (Eq, Show)

-- | What a version in a history is compared with.
data Against
  = -- | The version before it: what that save changed.
    AgainstPrevious
  | -- | The page as it is now: what has changed since.
    AgainstCurrent
  deriving stock (Eq, Show)

-- | The routes' codec. Parsing tries the routes in this order and takes the
-- first that reads the whole path; since a slug is never @p@, @edit@,
-- @source@, @history@, @slides@ or @new-page@ as written, no address reads
-- as two routes.
route :: RouteDuplex' Route
route =
  root $
    alternatives
      [ alternative (\case Home -> Just (); _ -> Nothing) (const Home) noArgs
      , alternative (\case Space s -> Just s; _ -> Nothing) Space (prefix "s" (directory slugs))
      , alternative
          (\case Page s p -> Just (s, p); _ -> Nothing)
          (uncurry Page)
          (prefix "s" (directory (spaceAndPage identity)))
      , alternative
          (\case EditPage s p -> Just (s, p); _ -> Nothing)
          (uncurry EditPage)
          (prefix "s" (directory (spaceAndPage (`suffix` "edit"))))
      , alternative
          (\case PageSource s p -> Just (s, p); _ -> Nothing)
          (uncurry PageSource)
          (prefix "s" (directory (spaceAndPage (`suffix` "source"))))
      , alternative
          (\case NewSpace parent -> Just parent; _ -> Nothing)
          NewSpace
          (prefix "new-space" (directory optionalSlugs))
      , alternative (\case Unknown -> Just (); _ -> Nothing) (const Unknown) (prefix "not-found" (directory noArgs))
      , alternative
          (\case NewPage s p -> Just (s, p); _ -> Nothing)
          (uncurry NewPage)
          (prefix "s" (directory ((,) <$> Duplex.lmap fst slugs <*> Duplex.lmap snd (prefix "new-page" optionalSlugs))))
      , alternative
          (\case Search q s subspaces -> Just (q, s, subspaces); _ -> Nothing)
          (\(q, s, subspaces) -> Search q s subspaces)
          (prefix "search" (directory searchParams))
      , alternative (\case Admin -> Just (); _ -> Nothing) (const Admin) (prefix "admin" (directory noArgs))
      , alternative
          (\case PageHistory s p v a -> Just ((s, p), (v, a)); _ -> Nothing)
          (\((s, p), (v, a)) -> PageHistory s p v a)
          ( prefix
              "s"
              (directory ((,) <$> Duplex.lmap fst (spaceAndPage (`suffix` "history")) <*> Duplex.lmap snd historyParams))
          )
      , alternative
          (\case PageSlides s p n -> Just ((s, p), n); _ -> Nothing)
          (\((s, p), n) -> PageSlides s p n)
          (prefix "s" (directory ((,) <$> Duplex.lmap fst (spaceAndPage (`suffix` "slides")) <*> Duplex.lmap snd slideParam)))
      ]
  where
    spaceAndPage :: (RouteDuplex' [Slug] -> RouteDuplex' [Slug]) -> RouteDuplex' ([Slug], [Slug])
    spaceAndPage after = (,) <$> Duplex.lmap fst slugs <*> Duplex.lmap snd (prefix "p" (after slugs))
    optionalSlugs :: RouteDuplex' (Maybe [Slug])
    optionalSlugs = RouteDuplex (maybe mempty slugs.printer) ((Just <$> slugs.parser) <|> pure Nothing)
    searchParams :: RouteDuplex' (Maybe Text, Maybe [Slug], Bool)
    searchParams =
      (,,)
        <$> Duplex.lmap (\(q, _, _) -> q) (Duplex.optional (param "q"))
        <*> Duplex.lmap (\(_, s, _) -> s) (Duplex.optional (as renderPath readPath (param "space")))
        <*> Duplex.lmap (\(_, _, subspaces) -> subspaces) (not <$> Duplex.lmap not (flag (param "only")))
    -- A version is named by its time, written with every digit of its
    -- fraction so that it reads back as the very time; one that is not a
    -- time reads as left out, the latest. Anything but @current@ compares
    -- with the version before.
    historyParams :: RouteDuplex' (Maybe UTCTime, Against)
    historyParams =
      (,)
        <$> Duplex.lmap fst (Duplex.optional (as (toS . iso8601Show) (\t -> maybe (Left ("not a time: " <> t)) Right (iso8601ParseM (toS t))) (param "version")))
        <*> Duplex.lmap
          snd
          ( (\a -> if a == Just "current" then AgainstCurrent else AgainstPrevious)
              <$> Duplex.lmap (\a -> if a == AgainstCurrent then Just "current" else Nothing) (Duplex.optional (param "against"))
          )
    -- The slide shown, counted from 1: the first is left out, and a
    -- number that is not one reads as the first. One past the deck's end is
    -- the view's to bring back into it.
    slideParam :: RouteDuplex' Int
    slideParam =
      fromMaybe 1
        <$> Duplex.lmap
          (\n -> if n == 1 then Nothing else Just n)
          (Duplex.optional (as show (\t -> maybe (Left ("not a number: " <> t)) Right (readMaybe t)) (param "slide")))
    -- A parameter that is not a path is read as the empty path, which names
    -- no space, rather than refused: an optional parameter that is refused
    -- reads as left out, which would search every space instead.
    readPath :: Text -> Either Text [Slug]
    readPath = Right . fromRight [] . parsePath

-- | One or more slugs, one per segment.
slugs :: RouteDuplex' [Slug]
slugs = many1 slugSegment

-- | A slug as a segment, with the route's own words (@p@, @edit@, @source@,
-- @history@, @slides@, @new-page@) escaped.
slugSegment :: RouteDuplex' Slug
slugSegment = as written readSlug segment
  where
    written s = let t = slugText s in if t `elem` reserved then "~" <> t else t
    readSlug t = case T.stripPrefix "~" t of
      Just word | word `elem` reserved -> first show (mkSlug word)
      _
        | t `elem` reserved -> Left (t <> " separates paths here")
        | otherwise -> first show (mkSlug t)
    reserved = ["p", "edit", "source", "history", "slides", "new-page"] :: [Text]

-- | A route's address ends in a slash ('route' says why), and is read
-- without one too.
directory :: RouteDuplex i o -> RouteDuplex i o
directory codec = RouteDuplex withSlash.printer (withSlash.parser <|> codec.parser)
  where
    withSlash = suffix codec ""

-- | One constructor of 'Route': how to take its arguments out of a route
-- (or 'Nothing' for another constructor), how to make the route from them,
-- and their codec.
alternative :: (Route -> Maybe a) -> (a -> Route) -> RouteDuplex' a -> RouteDuplex Route Route
alternative match make codec =
  RouteDuplex (maybe mempty codec.printer . match) (make <$> codec.parser)

-- | The routes' alternatives as one codec: printed by the one that matches,
-- parsed by the first that reads the address.
alternatives :: [RouteDuplex Route Route] -> RouteDuplex Route Route
alternatives alts = RouteDuplex (\r -> foldMap (\a -> a.printer r) alts) (asum (map (\a -> a.parser) alts))

-- | The route a link's @href@ leads to, if it is one of the router's own
-- addresses ('Router.href' wrote it): what a click on a link the page's
-- Markdown made is followed to. The fragment is not part of the route, and
-- the query only of a search's.
routeOfHref :: Router Route -> Text -> Maybe Route
routeOfHref router href = do
  -- The home's address is the base, with a slash after it.
  rest <- T.stripPrefix (T.dropWhileEnd (== '/') (Router.href router Home)) href
  case T.uncons rest of
    Just ('/', _) -> rightToMaybe (Duplex.parse route rest)
    _ -> Nothing

-- | The route of a space, from its id, among the spaces given.
spaceRouteOf :: [Space] -> SpaceId -> Route
spaceRouteOf spaces sid = case spaceChain spaces sid of
  [] -> Unknown
  chain -> Space (map (\s -> s.slug) chain)

-- | A link in a page to another place in the wiki: the route, and the
-- fragment the link names there (with its @#@, or empty).
data PageLink = PageLink Route Text
  deriving stock (Eq, Show)

-- | Where a link written in a page leads, for a destination that is a path
-- ('Wiki.Core.Markdown.Link.ToPath'), or 'Nothing' when it names nothing
-- the wiki has (shown as a broken link).
--
-- A relative path is read as a browser reads it from the page's address
-- (@\/s\/docs\/p\/markdown-guide\/diagrams@ without a slash at the end):
-- against the page's parent, so that from @markdown-guide@ the link
-- @diagrams@ is a sibling and @markdown-guide\/diagrams@ is a child, @.@
-- is the parent and @..@ goes one level further up. Going above the space's
-- top-level pages leads nowhere. The page has to be among the space's pages;
-- the empty path is the space itself.
--
-- A path starting with @\/@ is from the top of the wiki: the longest
-- leading part of it that is a space's path names the space, and the rest
-- (if any) a page there. A page in another space is not checked, since its
-- pages are not at hand; the route shows that it is missing if it is.
--
-- A segment that is not a slug is read as a title would be ('slugify'), so
-- that a wiki link names a page by its title: @[[On-call]]@.
resolvePageLink
  :: [Space]
  -- ^ Every space the reader can see the path of.
  -> [Slug]
  -- ^ The path of the page's space.
  -> [Page]
  -- ^ The pages of that space.
  -> [Slug]
  -- ^ The page's path.
  -> Text
  -- ^ The destination, as written.
  -> Maybe PageLink
resolvePageLink spaces spacePath pages pagePath destination = do
  let (beforeFragment, fragment) = T.breakOn "#" destination
      pathPart = T.takeWhile (/= '?') beforeFragment
      segments = T.splitOn "/" pathPart
  target <- case T.uncons pathPart of
    Just ('/', _) -> absolute (filter (not . T.null) segments)
    _ -> relative segments
  pure (PageLink target fragment)
  where
    relative segments = do
      path <- foldM step (take (length pagePath - 1) pagePath) segments
      if null path
        then pure (Space spacePath)
        else Page spacePath path <$ rightToMaybe (resolvePath (findChild pages) path)

    step path = \case
      "" -> Just path
      "." -> Just path
      ".." -> fst <$> unsnoc path
      s -> (\slug -> path <> [slug]) <$> asSlug s

    absolute segments = do
      wanted <- traverse asSlug segments
      let chains = [chain | n <- reverse [1 .. length wanted], Right chain <- [resolvePath (findChild spaces) (take n wanted)]]
      chain <- head chains
      let spaceSlugs = map (\s -> s.slug) chain
      case drop (length spaceSlugs) wanted of
        [] -> pure (Space spaceSlugs)
        rest
          | spaceSlugs == spacePath -> Page spaceSlugs rest <$ rightToMaybe (resolvePath (findChild pages) rest)
          | otherwise -> pure (Page spaceSlugs rest)

    asSlug s = rightToMaybe (mkSlug s) <|> slugify s
