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
-- > /new-space/                    NewSpace Nothing
-- > /new-space/team/               NewSpace (Just [team])
-- > /not-found/                    Unknown
--
-- Every address but the home's ends in a slash, because each is a directory
-- with an @index.html@ in it on a static host (the prerender writes one per
-- route), and a static host redirects @\/s\/docs@ to @\/s\/docs\/@. An address
-- without the slash is read as the same route, so a typed or pasted one
-- works too.
--
-- A space's path and a page's path are separated by the segment @p@, and an
-- edit route ends in @edit@; a slug may be either word too (a page titled
-- "P"), so a slug that is one of them is written with a @~@ before it
-- (@\/s\/~p\/@), which no slug can start with. That keeps every route's
-- address its own: 'route' reads back exactly the route it wrote.
module Wiki.App.Route
  ( -- * Routes
    Route (..)
  , route
  , routeOfHref
  , spaceRouteOf

    -- * Links in pages
  , PageLink (..)
  , resolvePageLink
  )
where

import Data.Text qualified as T
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (RouteDuplex (..), RouteDuplex', as, many1, noArgs, prefix, root, segment, suffix)
import Halogen.Router.Duplex qualified as Duplex
import Protolude
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Page (Page)
import Wiki.Core.Path (findChild, resolvePath)
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
  | -- | The editor for a page (reserved: the editor is WP1.6).
    EditPage [Slug] [Slug]
  | -- | The form for a new space, at the top level or under a space.
    NewSpace (Maybe [Slug])
  | -- | An address that is none of the above.
    Unknown
  deriving stock (Eq, Show)

-- | The routes' codec. Parsing tries the routes in this order and takes the
-- first that reads the whole path; since a slug is never @p@ or @edit@ as
-- written, no address reads as two routes.
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
          (\case NewSpace parent -> Just parent; _ -> Nothing)
          NewSpace
          (prefix "new-space" (directory optionalSlugs))
      , alternative (\case Unknown -> Just (); _ -> Nothing) (const Unknown) (prefix "not-found" (directory noArgs))
      ]
  where
    spaceAndPage :: (RouteDuplex' [Slug] -> RouteDuplex' [Slug]) -> RouteDuplex' ([Slug], [Slug])
    spaceAndPage after = (,) <$> Duplex.lmap fst slugs <*> Duplex.lmap snd (prefix "p" (after slugs))
    optionalSlugs :: RouteDuplex' (Maybe [Slug])
    optionalSlugs = RouteDuplex (maybe mempty slugs.printer) ((Just <$> slugs.parser) <|> pure Nothing)

-- | One or more slugs, one per segment.
slugs :: RouteDuplex' [Slug]
slugs = many1 slugSegment

-- | A slug as a segment, with the route's own words (@p@, @edit@) escaped.
slugSegment :: RouteDuplex' Slug
slugSegment = as written readSlug segment
  where
    written s = let t = slugText s in if t `elem` reserved then "~" <> t else t
    readSlug t = case T.stripPrefix "~" t of
      Just word | word `elem` reserved -> first show (mkSlug word)
      _
        | t `elem` reserved -> Left (t <> " separates paths here")
        | otherwise -> first show (mkSlug t)
    reserved = ["p", "edit"] :: [Text]

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
-- Markdown made is followed to. The fragment and the query are not part of
-- the route.
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
