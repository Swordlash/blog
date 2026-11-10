-- | The application's routes: what they are, how each is written as an
-- address, and where a link written in a page leads.
--
-- Addresses are paths, under the base path the site is served from (a
-- @\<base href>@, read by "Halogen.Router"'s 'Halogen.Router.pageBase'), so
-- that the server can serve exactly the same addresses:
--
-- > /                              Home
-- > /edit/                         EditHome
-- > /source/                       HomeSource
-- > /history/                      HomeHistory Nothing AgainstPrevious
-- > /slides/                       HomeSlides 1 1
-- > /s/team/projects/              Space [team, projects]
-- > /s/blog/?page=2                Posts [blog] 2
-- > /s/team/projects/pages/        SpacePages [team, projects]
-- > /s/docs/p/markdown-guide/      Page [docs] [markdown-guide]
-- > /s/docs/p/tour/edit/           EditPage [docs] [tour]
-- > /s/docs/p/tour/source/         PageSource [docs] [tour]
-- > /s/docs/p/tour/history/        PageHistory [docs] [tour] Nothing AgainstPrevious
-- > /s/docs/p/tour/history/?version=2026-10-24T09%3A30%3A12.5Z&against=current
-- >                                PageHistory [docs] [tour] (Just …) AgainstCurrent
-- > /s/docs/p/presentations/slides/ PageSlides [docs] [presentations] 1 1
-- > /s/docs/p/presentations/slides/?slide=3&step=2
-- >                                PageSlides [docs] [presentations] 3 2
-- > /s/docs/edit/                  EditPage [docs] []
-- > /s/docs/source/                PageSource [docs] []
-- > /s/docs/history/               PageHistory [docs] [] Nothing AgainstPrevious
-- > /s/docs/slides/                PageSlides [docs] [] 1 1
-- > /s/docs/live-preview/          LivePreview [docs] []
-- > /s/docs/new-page/              NewPage [docs] Nothing
-- > /s/docs/new-page/tour/         NewPage [docs] (Just [tour])
-- > /new-space/                    NewSpace Nothing
-- > /new-space/team/               NewSpace (Just [team])
-- > /not-found/                    Unknown
-- > /admin/                        Admin Overview (written /admin/overview/)
-- > /admin/overview/               Admin Overview
-- > /admin/users/?q=ada&page=2&show=administrators
-- >                                Admin (Users (UserListing "ada" 2 OnlyAdministrators))
-- > /admin/groups/                 Admin Groups
-- > /search/?q=mermaid&space=docs  Search (Just "mermaid") (Just [docs]) True
-- > /search/?q=x&space=team&only   Search (Just "x") (Just [team]) False
-- > /invite/<secret>/              Invite (InvitationToken <secret>)
-- > /reset-password/<secret>/      ResetPassword (ResetToken <secret>)
-- > /verify-email/<secret>/        VerifyEmail (VerificationToken <secret>)
-- > /unsubscribe/<secret>/         Unsubscribe (UnsubscribeToken <secret>)
-- > /assistant/                    AssistantSettings
-- > /whats-new/                    WhatsNewPage
-- > /user-spaces/                  UserSpaces
-- > /s/docs/p/tour/?version=2026-10-24T09%3A30%3A12.5Z
-- >                                PageAtVersion [docs] [tour] 2026-10-24 09:30:12.5
-- > /l/4f1c-9a/?version=2026-10-24T09%3A30%3A12.5Z
-- >                                PermanentLink (PageId 4f1c-9a) (Just …)
-- > /l/4f1c-9a/                    PermanentLink (PageId 4f1c-9a) Nothing
--
-- Every address except the home's ends in a slash. On a static host each
-- route is a directory with an @index.html@ in it (the prerender writes
-- one per route), and a static host redirects @\/s\/docs@ to
-- @\/s\/docs\/@. An address without the slash is read as the same route,
-- so a typed or pasted one works too.
--
-- A space's path and a page's path are separated by the segment @p@. A
-- page's path starts under its space's home page, the root of the space's
-- pages ('Wiki.Core.Space.pagePath'), and the home page's path is empty:
-- the home page is the space's own address ('Space'), and its editor,
-- source, history, slides and live preview are under that address with no
-- @p@, as the front page's are under the top. An
-- edit route ends in @edit@, a page's source in @source@, its history in
-- @history@, its slides in @slides@, and a space's list of pages in
-- @pages@. A new page's route has @new-page@ after the space's path. A slug
-- may be any of these words too (a page titled "P"), so a slug that is one
-- of them is written with a @~@ before it (@\/s\/~p\/@), which no slug can
-- start with. That keeps every route's address unique: 'route' parses
-- back exactly the route it printed.
--
-- A page's permanent address names it by its id, under @l@
-- ('PermanentLink'), and one of its versions by the time it was saved:
-- the id never changes, so the address keeps leading to the page when the
-- page moves, and a version never changes either. No other route starts
-- with @l@; a space's path is always under @s@.
module Wiki.App.Route
  ( -- * Routes
    Route (..)
  , Against (..)
  , AdminSection (..)
  , UserListing (..)
  , UserFilter (..)
  , allUsers
  , adminSections
  , sectionName
  , sectionTitle
  , route
  , routeOfHref
  , spaceRouteOf
  , pageRoute
  , locationRoute
  , settledRoute

    -- * Links in pages
  , PageLink (..)
  , resolvePageLink
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.Type.Equality (type (~))
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (RouteDuplex (..), RouteDuplex', as, flag, many1, noArgs, param, prefix, root, segment, suffix)
import Halogen.Router.Duplex qualified as Duplex
import Protolude
import Wiki.Api.Account (InvitationToken (..))
import Wiki.Api.Security (ResetToken (..), UnsubscribeToken (..), VerificationToken (..))
import Wiki.Core.Id (PageId (..), SpaceId)
import Wiki.Core.Markdown.Link (Destination (..), classifyDestination, pageIdSegment, readPageIdSegment)
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Path (TreeNode (..), findChild, parsePath, renderPath, resolvePath, resolveUnder)
import Wiki.Core.Permission (spaceChain)
import Wiki.Core.Slug (Slug, mkSlug, slugText, slugify)
import Wiki.Core.Space (Space (slug))
import Wiki.Core.Space qualified as S

-- | A place in the application.
data Route
  = -- | The front page: the top-level spaces.
    Home
  | EditHome
  | HomeSource
  | HomeHistory (Maybe UTCTime) Against
  | HomeSlides Int Int
  | -- | A space, by its path from the top level. Entering it shows its home
    -- page ('Wiki.Core.Space.homePage'), whose address it is, or, for a
    -- space without one, its list of pages ('SpacePages').
    Space [Slug]
  | -- | A later page of a blog's posts ("Wiki.Core.Blog"): the space's
    -- path, and the page number, counted from 1. The page number is a
    -- parameter (@page@), so that a reload, or a link, comes back to it. The
    -- first page is the space's own route, 'Space', and a space that is not
    -- a blog shows what 'Space' shows at any page number.
    Posts [Slug] Int
  | -- | A space's pages and subspaces, with the actions on the space (its
    -- settings among them), by its path.
    SpacePages [Slug]
  | -- | A page: its space's path, and its own path among the space's pages
    -- ('Wiki.Core.Space.pagePath'). The home page's path is empty, and its
    -- route is 'Space' ('pageRoute'): a 'Page' with the empty path is
    -- written as the space's address.
    Page [Slug] [Slug]
  | -- | The editor for a page: its space's path, and its own path there.
    EditPage [Slug] [Slug]
  | -- | A page's Markdown, for anyone who may read the page: its space's
    -- path, and its own path there.
    PageSource [Slug] [Slug]
  | -- | The preview of a page being edited, in a window of its own, which
    -- follows its editor (WP5.36 of docs/PLAN.md,
    -- "Wiki.App.View.LivePreview"): its space's path, and its own path.
    LivePreview [Slug] [Slug]
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
    -- global 'Wiki.Core.Permission.Administer': one of its sections. The
    -- address @\/admin\/@ names no section and is read as the first,
    -- 'Overview', whose address the shell then puts in its place.
    Admin AdminSection
  | -- | A page's history, for anyone who may read the page: its space's
    -- path, its own path there, the version shown (by its time, the
    -- page's @updatedAt@ then; 'Nothing' for the latest), and what that
    -- version is compared with. They are parameters (@version@, and
    -- @against=current@), so that a version's address can be kept and
    -- shared.
    PageHistory [Slug] [Slug] (Maybe UTCTime) Against
  | -- | A page presented as slides ("Wiki.Core.Slides"), for anyone who may
    -- read the page: its space's path, its own path there, the slide
    -- shown and the step of it shown, each counted from 1. They are
    -- parameters (@slide@ and @step@, each left out at 1), so that a
    -- reload, or a link, comes back to them.
    PageSlides [Slug] [Slug] Int Int
  | -- | An invitation's page, by the secret its link carries: the form that
    -- creates the invited account (WP3.5 of docs/PLAN.md). Its 'Show' hides
    -- the secret, so that a log line that names a route does not reveal it.
    Invite InvitationToken
  | -- | A password reset's page, by the secret of the link mailed for it:
    -- the form that sets a new password (WP4.11 of docs/PLAN.md). Its
    -- 'Show' hides the secret, as an invitation's does.
    ResetPassword ResetToken
  | -- | The page of a link mailed to verify an e-mail address, by its
    -- secret.
    VerifyEmail VerificationToken
  | -- | The page of the unsubscribe link in a notification mail, by its
    -- secret: it turns those mails off.
    Unsubscribe UnsubscribeToken
  | -- | The writing assistant's settings, the signed-in user's own (WP4.19
    -- of docs/PLAN.md): their API keys, and the provider and model to use.
    AssistantSettings
  | -- | The page "What's new?" (WP5.66 of docs/PLAN.md): the server's
    -- version and build date, and the newest changelog entries.
    WhatsNewPage
  | -- | The finder of user spaces (WP5.72 of docs/PLAN.md): the personal
    -- spaces the reader may open, the starred ones first, and a field that
    -- finds the others by login or name. It is where the container "User
    -- subspaces" leads, since nobody may view the container itself.
    UserSpaces
  | -- | A page's permanent address: the page by its id
    -- ('Wiki.Core.Id.PageId'), which never changes, wherever the page is
    -- now. The application asks where the page is
    -- ('Wiki.App.Backend.pageLocation') and puts the page's own address in
    -- place of this one; the server answers the address with a redirect
    -- there ("Wiki.Server.App"). The id is written as
    -- 'Wiki.Core.Markdown.Link.pageIdSegment' writes it, and a link in a
    -- page reads it as 'Wiki.Core.Markdown.Link.classifyDestination' does.
    -- With a version (@?version=@, the time it was saved, as a history's
    -- address names it), the address leads to that version ('PageAtVersion'):
    -- what "Copy permanent link" copies. Without one, it leads to the page
    -- as it is.
    PermanentLink PageId (Maybe UTCTime)
  | -- | One version of a page, shown as the page is, with a note that says
    -- which version it is: its space's path, its own path there, and the
    -- version's time ('Wiki.Core.Version.updatedAt'), a parameter
    -- (@version@) after the page's own address. Where a page's permanent
    -- address with a version leads.
    PageAtVersion [Slug] [Slug] UTCTime
  deriving stock (Eq, Show)

-- | 'AdminSection' is a section of the administration: one page of it, with
-- an entry in the administration's navigation. Each section's address is
-- its name ('sectionName') under @\/admin\/@.
data AdminSection
  = -- | How the server is: its version, its data, the last backup, the
    -- errors it logged.
    Overview
  | -- | The users, a page at a time, as the address asks for them.
    Users UserListing
  | Groups
  | -- | Who may come in, what new accounts may do, and in a closed wiki the
    -- invitations.
    Permissions
  | -- | The server's own settings: its public address, mail, sign-in
    -- providers, the assistant's hosts.
    Server
  | -- | The editor's settings, for every page (WP5.41 of docs/PLAN.md):
    -- the kinds of box and the built-in math macros.
    EditorSettings
  | -- | The server's backups, and the wiki's data as one file: its export
    -- and import.
    Backups
  | -- | The audit log.
    Activity
  deriving stock (Eq, Show)

-- | 'UserListing' is which users the users section shows: the words
-- searched for (empty for everyone), the page, counted from 1, and a
-- filter. They are the address's parameters (@q@, @page@, @show@, each
-- left out when it has its first value), so that a page of users can be
-- kept and shared. How many users a page holds is the reader's own
-- choice, kept in their browser, so it is not in the address.
data UserListing = UserListing
  { search :: Text
  , page :: Int
  , only :: UserFilter
  }
  deriving stock (Eq, Show)

-- | Which users the users section keeps: everyone, or only one kind.
data UserFilter
  = Everyone
  | OnlyAdministrators
  | OnlyDisabled
  deriving stock (Eq, Show, Enum, Bounded)

-- | The first page of every user.
allUsers :: UserListing
allUsers = UserListing {search = "", page = 1, only = Everyone}

-- | The sections in the order the navigation lists them, each at its first
-- address.
adminSections :: [AdminSection]
adminSections = [Overview, Users allUsers, Groups, Permissions, Server, EditorSettings, Backups, Activity]

-- | A section's name, the last segment of its address: stable, lower
-- case.
sectionName :: AdminSection -> Text
sectionName = \case
  Overview -> "overview"
  Users _ -> "users"
  Groups -> "groups"
  Permissions -> "permissions"
  Server -> "server"
  EditorSettings -> "editor"
  Backups -> "backups"
  Activity -> "activity"

-- | A section's title, as the navigation and the page's heading show it.
sectionTitle :: AdminSection -> Text
sectionTitle = \case
  Overview -> "Overview"
  Users _ -> "Users"
  Groups -> "Groups"
  Permissions -> "Permissions"
  Server -> "Server"
  EditorSettings -> "Editor"
  Backups -> "Backups and data"
  Activity -> "Activity"

-- | What a version in a history is compared with.
data Against
  = -- | The version before it: what that save changed.
    AgainstPrevious
  | -- | The page as it is now: what has changed since.
    AgainstCurrent
  deriving stock (Eq, Show)

-- | The routes' codec. Parsing tries the routes in this order and takes the
-- first that parses the whole path. Since a written slug is never @p@,
-- @edit@, @source@, @history@, @slides@, @pages@ or @new-page@, no address
-- parses as two routes.
route :: RouteDuplex' Route
route =
  root $
    alternatives
      [ alternative (\case Home -> Just (); _ -> Nothing) (const Home) noArgs
      , alternative (\case EditHome -> Just (); _ -> Nothing) (const EditHome) (prefix "edit" (directory noArgs))
      , alternative (\case HomeSource -> Just (); _ -> Nothing) (const HomeSource) (prefix "source" (directory noArgs))
      , alternative (\case HomeHistory v a -> Just (v, a); _ -> Nothing) (uncurry HomeHistory) (prefix "history" (directory historyParams))
      , alternative (\case HomeSlides n k -> Just (n, k); _ -> Nothing) (uncurry HomeSlides) (prefix "slides" (directory slideParams))
      , -- Before 'Space' and 'Page', which parse the same path and ignore
        -- the query: this one parses it only with its parameter.
        alternative
          (\case PageAtVersion s p t -> Just ((s, p), t); _ -> Nothing)
          (\((s, p), t) -> PageAtVersion s p t)
          (prefix "s" (directory ((,) <$> Duplex.lmap fst pageOrHome <*> Duplex.lmap snd versionParam)))
      , -- Before 'Space', which parses the same path and ignores the
        -- query: this one parses it only with its parameter.
        alternative
          (\case Posts s n -> Just (s, n); _ -> Nothing)
          (uncurry Posts)
          (prefix "s" (directory ((,) <$> Duplex.lmap fst slugs <*> Duplex.lmap snd pageParam)))
      , alternative (\case Space s -> Just s; _ -> Nothing) Space (prefix "s" (directory slugs))
      , alternative (\case SpacePages s -> Just s; _ -> Nothing) SpacePages (prefix "s" (directory (suffix slugs "pages")))
      , alternative
          (\case Page s p -> Just (s, p); _ -> Nothing)
          (uncurry Page)
          (prefix "s" (directory (spaceAndPage Nothing)))
      , alternative
          (\case EditPage s p -> Just (s, p); _ -> Nothing)
          (uncurry EditPage)
          (prefix "s" (directory (spaceAndPage (Just "edit"))))
      , alternative
          (\case PageSource s p -> Just (s, p); _ -> Nothing)
          (uncurry PageSource)
          (prefix "s" (directory (spaceAndPage (Just "source"))))
      , alternative
          (\case LivePreview s p -> Just (s, p); _ -> Nothing)
          (uncurry LivePreview)
          (prefix "s" (directory (spaceAndPage (Just "live-preview"))))
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
      , alternative (\case Admin s -> Just s; _ -> Nothing) Admin (prefix "admin" adminSection)
      , alternative (\case AssistantSettings -> Just (); _ -> Nothing) (const AssistantSettings) (prefix "assistant" (directory noArgs))
      , alternative (\case WhatsNewPage -> Just (); _ -> Nothing) (const WhatsNewPage) (prefix "whats-new" (directory noArgs))
      , alternative (\case UserSpaces -> Just (); _ -> Nothing) (const UserSpaces) (prefix "user-spaces" (directory noArgs))
      , alternative
          (\case PageHistory s p v a -> Just ((s, p), (v, a)); _ -> Nothing)
          (\((s, p), (v, a)) -> PageHistory s p v a)
          ( prefix
              "s"
              (directory ((,) <$> Duplex.lmap fst (spaceAndPage (Just "history")) <*> Duplex.lmap snd historyParams))
          )
      , alternative
          (\case PageSlides s p n k -> Just ((s, p), (n, k)); _ -> Nothing)
          (\((s, p), (n, k)) -> PageSlides s p n k)
          (prefix "s" (directory ((,) <$> Duplex.lmap fst (spaceAndPage (Just "slides")) <*> Duplex.lmap snd slideParams)))
      , alternative
          (\case Invite t -> Just t; _ -> Nothing)
          Invite
          (prefix "invite" (directory (as (\t -> t.text) (Right . InvitationToken) segment)))
      , alternative
          (\case ResetPassword t -> Just t; _ -> Nothing)
          ResetPassword
          (prefix "reset-password" (directory (as (\t -> t.text) (Right . ResetToken) segment)))
      , alternative
          (\case VerifyEmail t -> Just t; _ -> Nothing)
          VerifyEmail
          (prefix "verify-email" (directory (as (\t -> t.text) (Right . VerificationToken) segment)))
      , alternative
          (\case Unsubscribe t -> Just t; _ -> Nothing)
          Unsubscribe
          (prefix "unsubscribe" (directory (as (\t -> t.text) (Right . UnsubscribeToken) segment)))
      , alternative
          (\case PermanentLink pid v -> Just (pid, v); _ -> Nothing)
          (uncurry PermanentLink)
          ( prefix
              "l"
              ( directory
                  ( (,)
                      <$> Duplex.lmap fst (as pageIdSegment (\t -> maybe (Left "no page id") Right (readPageIdSegment t)) segment)
                      <*> Duplex.lmap snd (Duplex.optional versionParam)
                  )
              )
          )
      ]
  where
    -- A space's path and a page's path, then the route's own word, if it
    -- has one. A page under the space's home page is written after @p@.
    -- The home page's own path is empty: its routes are written under the
    -- space's address with no @p@ (@\/s\/docs\/edit\/@), as the front page's
    -- are under the top (@\/edit\/@). The home page itself is the space's
    -- own route, 'Space': a 'Page' with the empty path is written as the
    -- space's address, and that address reads back as 'Space'.
    spaceAndPage :: Maybe Text -> RouteDuplex' ([Slug], [Slug])
    spaceAndPage word = RouteDuplex printer parser
      where
        after = maybe identity (flip suffix) word
        nested = (,) <$> Duplex.lmap fst slugs <*> Duplex.lmap snd (prefix "p" (after slugs))
        atHome = (,[]) <$> Duplex.lmap fst (after slugs)
        printer = \case
          (sp, []) -> atHome.printer (sp, [])
          sp -> nested.printer sp
        parser = nested.parser <|> (if isJust word then atHome.parser else empty)
    -- A page's path, after @p@, or the home page's, which is the space's
    -- own address: the page of 'PageAtVersion'.
    pageOrHome :: RouteDuplex' ([Slug], [Slug])
    pageOrHome = RouteDuplex (spaceAndPage Nothing).printer ((spaceAndPage Nothing).parser <|> ((,[]) <$> slugs.parser))
    optionalSlugs :: RouteDuplex' (Maybe [Slug])
    optionalSlugs = RouteDuplex (maybe mempty slugs.printer) ((Just <$> slugs.parser) <|> pure Nothing)
    searchParams :: RouteDuplex' (Maybe Text, Maybe [Slug], Bool)
    searchParams =
      (,,)
        <$> Duplex.lmap (\(q, _, _) -> q) (Duplex.optional (param "q"))
        <*> Duplex.lmap (\(_, s, _) -> s) (Duplex.optional (as renderPath readPath (param "space")))
        <*> Duplex.lmap (\(_, _, subspaces) -> subspaces) (not <$> Duplex.lmap not (flag (param "only")))
    -- A version is named by its time, written with every digit of its
    -- fraction so that it parses back as exactly the same time. A value
    -- that is not a time parses as left out, meaning the latest. Anything
    -- except @current@ compares with the version before.
    historyParams :: RouteDuplex' (Maybe UTCTime, Against)
    historyParams =
      (,)
        <$> Duplex.lmap fst (Duplex.optional versionParam)
        <*> Duplex.lmap
          snd
          ( (\a -> if a == Just "current" then AgainstCurrent else AgainstPrevious)
              <$> Duplex.lmap (\a -> if a == AgainstCurrent then Just "current" else Nothing) (Duplex.optional (param "against"))
          )
    -- The slide shown and its step, each counted from 1. The first is
    -- left out, and a value that is not a number parses as the first. A
    -- number past the deck's end, or the slide's, is for the view to bring
    -- back into range.
    slideParams :: RouteDuplex' (Int, Int)
    slideParams = (,) <$> Duplex.lmap fst (counted "slide") <*> Duplex.lmap snd (counted "step")
    -- A page of posts, counted from 1, always written; a value that is not
    -- a number parses as the first.
    pageParam :: RouteDuplex' Int
    pageParam = as show (\t -> Right (fromMaybe 1 (readMaybe t))) (param "page")
    -- A parameter that is not a path is parsed as the empty path, which
    -- names no space, instead of being refused: a refused optional
    -- parameter parses as left out, which would search every space instead.
    readPath :: Text -> Either Text [Slug]
    readPath = Right . fromRight [] . parsePath

-- | A version of a page, by its time, as the parameter @version@: written
-- with every digit of its fraction, so that it parses back as exactly the
-- same time. A value that is not a time is refused, which an optional
-- parameter reads as left out.
versionParam :: RouteDuplex' UTCTime
versionParam = as (toS . iso8601Show) (\t -> maybe (Left ("not a time: " <> t)) Right (iso8601ParseM (toS t))) (param "version")

-- | A number counted from 1, as a parameter left out at 1. A value that is
-- not a number parses as 1; one past the end of what it counts is for the
-- view to bring back into range.
counted :: Text -> RouteDuplex' Int
counted name =
  fromMaybe 1
    <$> Duplex.lmap
      (\n -> if n == 1 then Nothing else Just n)
      (Duplex.optional (as show (\t -> maybe (Left ("not a number: " <> t)) Right (readMaybe t)) (param name)))

-- | The sections of the administration, each a segment under @\/admin\/@.
-- The address with no segment is the first section's, and is parsed so
-- that an address kept from before the sections still works.
adminSection :: RouteDuplex' AdminSection
adminSection = RouteDuplex named.printer (named.parser <|> (Overview <$ (directory noArgs).parser))
  where
    named =
      alternatives
        [ section Overview
        , alternative (\case Users l -> Just l; _ -> Nothing) Users (prefix "users" (directory userListing))
        , section Groups
        , section Permissions
        , section Server
        , section EditorSettings
        , section Backups
        , section Activity
        ]
    section s = alternative (\x -> if x == s then Just () else Nothing) (const s) (prefix (sectionName s) (directory noArgs))

-- | The users section's parameters: @q@, @page@ and @show@, each left out
-- at its first value. A @show@ that names no filter parses as everyone.
userListing :: RouteDuplex' UserListing
userListing =
  UserListing
    <$> Duplex.lmap (\l -> l.search) (fromMaybe "" <$> Duplex.lmap (\q -> if T.null q then Nothing else Just q) (Duplex.optional (param "q")))
    <*> Duplex.lmap (\l -> l.page) (counted "page")
    <*> Duplex.lmap (\l -> l.only) (readFilter <$> Duplex.lmap writeFilter (Duplex.optional (param "show")))
  where
    writeFilter = \case
      Everyone -> Nothing
      OnlyAdministrators -> Just "administrators"
      OnlyDisabled -> Just "disabled"
    readFilter = \case
      Just "administrators" -> OnlyAdministrators
      Just "disabled" -> OnlyDisabled
      _ -> Everyone

-- | One or more slugs, one per segment.
slugs :: RouteDuplex' [Slug]
slugs = many1 slugSegment

-- | A slug as a segment, with the route's own words (@p@, @edit@, @source@,
-- @live-preview@, @history@, @slides@, @pages@, @new-page@) escaped.
slugSegment :: RouteDuplex' Slug
slugSegment = as written readSlug segment
  where
    written s = let t = slugText s in if t `elem` reserved then "~" <> t else t
    readSlug t = case T.stripPrefix "~" t of
      Just word | word `elem` reserved -> first show (mkSlug word)
      _
        | t `elem` reserved -> Left (t <> " separates paths here")
        | otherwise -> first show (mkSlug t)
    reserved = ["p", "edit", "source", "live-preview", "history", "slides", "pages", "new-page"] :: [Text]

-- | A route's address ends in a slash ('route' says why), and is parsed
-- without one too.
directory :: RouteDuplex i o -> RouteDuplex i o
directory codec = RouteDuplex withSlash.printer (withSlash.parser <|> codec.parser)
  where
    withSlash = suffix codec ""

-- | One constructor of 'Route' (or of 'AdminSection'): how to take its arguments out of a route
-- (or 'Nothing' for another constructor), how to make the route from them,
-- and their codec.
alternative :: (r -> Maybe a) -> (a -> r) -> RouteDuplex' a -> RouteDuplex r r
alternative match make codec =
  RouteDuplex (maybe mempty codec.printer . match) (make <$> codec.parser)

-- | The routes' alternatives as one codec: printed by the one that matches,
-- parsed by the first that reads the address.
alternatives :: [RouteDuplex r r] -> RouteDuplex r r
alternatives alts = RouteDuplex (\r -> foldMap (\a -> a.printer r) alts) (asum (map (\a -> a.parser) alts))

-- | The route a link's @href@ leads to, if it is one of the router's own
-- addresses (written by 'Router.href'). A click on a link that a page's
-- Markdown made is followed to this route. The fragment is not part of
-- the route, and the query only of a search's route.
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

-- | 'pageRoute' is the route of a page, from its space's path and its own
-- path ('Wiki.Core.Space.pagePath'): 'Page', or the space's own route,
-- 'Space', for the home page, whose path is empty.
pageRoute :: [Slug] -> [Slug] -> Route
pageRoute sp = \case
  [] -> Space sp
  path -> Page sp path

-- | 'locationRoute' is the route of a page where it is now, as
-- 'Wiki.App.Backend.pageLocation' answers it, and of one of its versions
-- if one is given: 'pageRoute' of its space's path and its own, or
-- 'PageAtVersion'. The wiki's own home page, whose space has no path, is
-- the front page ('Home'), with or without a version: the front page has
-- no route of a version.
locationRoute :: PageLocation -> Maybe UTCTime -> Route
locationRoute l version = case (l.space, version) of
  ([], _) -> Home
  (sp, Nothing) -> pageRoute sp l.page
  (sp, Just t) -> PageAtVersion sp l.page t

-- | 'settledRoute' is a route as the application shows it: a 'Page' with
-- the empty path, the home page's, is its space's own route ('pageRoute'),
-- which shows a blog's posts where the page alone would not. A route made
-- from a page's path goes through it before it is shown.
settledRoute :: Route -> Route
settledRoute = \case
  Page sp [] -> Space sp
  r -> r

-- | A link in a page to another place in the wiki: the route, and the
-- fragment the link names there (with its @#@, or empty).
data PageLink = PageLink Route Text
  deriving stock (Eq, Show)

-- | Where a link written in a page leads, for a destination that is a path
-- ('Wiki.Core.Markdown.Link.ToPath') or a page's permanent address
-- ('Wiki.Core.Markdown.Link.ToPageId'), or 'Nothing' when it names
-- nothing the wiki has (shown as a broken link).
--
-- A permanent address (@\/l\/\<page id>\/@) leads to the page with that
-- id, and with a version (@?version=@) to that version of it. A page of
-- this space is linked at its address as it is now ('PageAtVersion' with a
-- version), so the link is followed without a question to the backend.
-- Any other id is
-- linked at its permanent address ('PermanentLink'), which asks where the
-- page is when the link is followed: its space's pages are not at hand,
-- and the page may be one the reader may not view. Such a link is never
-- shown as broken.
--
-- A relative path is read as a browser reads it from the page's address
-- (@\/s\/docs\/p\/markdown-guide\/diagrams@ without a slash at the end):
-- against the page's parent, so that from @markdown-guide@ the link
-- @diagrams@ is a sibling and @markdown-guide\/diagrams@ is a child, @.@
-- is the parent and @..@ goes one level further up. Paths start under the
-- space's home page, the root of its pages, as the page's own path does
-- ('Wiki.Core.Space.pagePath'); going above the pages under it leads
-- nowhere, and the empty path is the space itself, the home page's
-- address. The page has to be among the space's pages. A path that starts
-- with the home page's own slug, as a page's address did before the home
-- page lost its segment, is read again without it
-- ('Wiki.Core.Path.resolveUnder'), and the link leads to the page's
-- address as it is now.
--
-- A path starting with @\/@ is from the top of the wiki. A page's own
-- address, as the route codec writes it without the deployment's prefix
-- (@\/s\/docs\/p\/guide\/@), is that page: what the editor's "Link to a
-- page" writes, since it names one page however the space's pages and
-- subspaces are named. A space's own address (@\/s\/docs\/@), the home
-- page's, is that space. Any other path from the top is a space's path and
-- a page's: the longest leading part of it that is a space's path names
-- the space, and the rest (if any) a page there. So a page that shares its
-- slug with a subspace of its space is reached by its own address, not by
-- the path. A page in another space is not checked, since its pages are
-- not at hand; the route shows that it is missing if it is.
--
-- A segment that is not a slug is read as a title would be ('slugify'), so
-- that a wiki link names a page by its title: @[[On-call]]@.
resolvePageLink
  :: (TreeNode node, NodeId node ~ PageId)
  => [Space]
  -- ^ Every space the reader can see the path of.
  -> [Slug]
  -- ^ The path of the page's space.
  -> Maybe (NodeId node)
  -- ^ The space's root, its home page ('Wiki.Core.Space.rootPage').
  -> [node]
  -- ^ The pages of that space: their summaries, or the pages themselves.
  -> [Slug]
  -- ^ The page's path.
  -> Text
  -- ^ The destination, as written.
  -> Maybe PageLink
resolvePageLink spaces spacePath home pages pagePath destination
  | ToPageId pid version fragment <- classifyDestination destination = Just (PageLink (byId pid version) fragment)
  | otherwise = do
      let (beforeFragment, fragment) = T.breakOn "#" destination
          pathPart = T.takeWhile (/= '?') beforeFragment
          segments = T.splitOn "/" pathPart
      target <- case T.uncons pathPart of
        Just ('/', _)
          | Right (Page sp pp) <- Duplex.parse route pathPart -> addressed sp pp
          -- A space's own address, the address of its home page.
          | Right (Space sp) <- Duplex.parse route pathPart -> Space sp <$ rightToMaybe (resolvePath (findChild spaces) sp)
          | otherwise -> absolute (filter (not . T.null) segments)
        _ -> relative segments
      pure (PageLink target fragment)
  where
    -- A page by its id: at its address ('Wiki.Core.Space.pagePath'), if
    -- it is one of this space's pages, and otherwise at its permanent
    -- address. The wiki's front page has no space path, and its links by
    -- id stay permanent addresses.
    byId pid version = fromMaybe (PermanentLink pid version) $ do
      guard (not (null spacePath))
      space <- lastMay =<< rightToMaybe (resolvePath (findChild spaces) spacePath)
      path <- S.pagePath space (\i -> find (\n -> nodeId n == i) pages) pid
      pure (locationRoute PageLocation {space = spacePath, page = path} version)

    -- A page by its own address: its space has to be one the reader can
    -- see, and a page of this space one it has.
    addressed sp pp = do
      _ <- rightToMaybe (resolvePath (findChild spaces) sp)
      if sp == spacePath
        then here pp
        else pure (pageRoute sp pp)

    relative segments = do
      path <- foldM step (take (length pagePath - 1) pagePath) segments
      if null path
        then pure (Space spacePath)
        else here path

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
          | spaceSlugs == spacePath -> here rest
          | otherwise -> pure (Page spaceSlugs rest)

    -- A page of this space by its path, at its address as it is now.
    here path = do
      chain <- rightToMaybe (resolveUnder rootNode (findChild pages) path)
      pure (pageRoute spacePath (map nodeSlug (withoutRoot chain)))
    rootNode = home >>= \r -> find (\n -> nodeId n == r) pages
    withoutRoot = \case
      top : rest | Just (nodeId top) == home -> rest
      chain -> chain

    asSlug s = rightToMaybe (mkSlug s) <|> slugify s
