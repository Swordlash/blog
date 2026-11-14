-- | The viewer of a presentation in a page as a machine
-- ("Wiki.App.View.DeckViewer.Machine"), run on generated runs: the reader
-- signing out and in, the shell reloading, the embed naming another page,
-- the viewer's input given late (several changes in one), the link's
-- watch telling, the reads answered in any order, other people's writes
-- anywhere, even between the two reads of one fetch, moves through the
-- slides, and the viewer closing.
--
-- = The model's server
--
-- Read from @wiki-server@'s @Storage.hs@ and the viewer's @fetchDeck@:
--
-- * a fetch reads the page by its path (@getPageTx@, line 2321: refused
--   to someone who may not view the space, 'NotFound' for a path no page
--   has) and then, for a page of another space than the one embedding
--   it, the space's list of pages (@listPagesTx@, line 2264), each in a
--   transaction of its own: a write can fall between the two ('HandlePage'
--   and 'HandleList' are two steps). The deck is then the page as first
--   read, its links laid out against the list as read second;
-- * every way the page goes or changes: a save, a new body
--   (@savePageTx@, 3088), its kind changed to a document
--   (@setPageKindTx@, 3176), deleted (@deletePageTx@, 3199; a space
--   deleted, 2912, is the same to the viewer), made private (a grant
--   taken: the reader may no longer view it). A page moved (3114) is a
--   page no longer at its path, as deleted. Nothing tells the viewer:
--   the embedded page is not watched by the live channel, and the viewer
--   reads it again only for a new reading;
-- * no bounded buffer on this path: a read has no limit, the HTTP
--   backend's page content is cached until the first change of route
--   (@endPreload@) and a change of session empties the cache;
-- * a request carries the session it was sent in: a read sent before a
--   sign-out and handled after it reads as someone signed out.
--
-- The reader's side: a session of the reader's ends at a sign-out and
-- another begins at a sign-in, the same user's too; the backend lets go
-- of every owner's addresses at a sign-out
-- ("Wiki.App.Backend"'s 'releaseUrls', line 779). Of the encrypted spaces
-- only that is modelled: every deck's addresses are made under its read's
-- owner, as an encrypted page's attachments' are; the sealed reads are
-- left out.
--
-- = The rules
--
-- * one watch of the link runs at a time, and none after the viewer
--   closed;
-- * a deck shown was read for the reading the viewer was last given;
-- * a watch stopped starts no read;
-- * the addresses of the deck shown are not let go, once the viewer was
--   given the context as it is;
-- * every read's addresses are let go by the time the viewer closed;
-- * the slide and step shown are within the deck;
-- * once every input was given, every link rendered, every watch told and
--   every read answered, the viewer shows the answer to a read made for
--   its reading.
module Test.Deck
  ( spec
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck (Gen, Property, chooseInt, counterexample, elements, forAllShrinkShow, frequency, listOf, shrinkList)
import Test.QuickCheck qualified as QC
import Wiki.App.View.DeckViewer.Machine
import Wiki.Core.Slides (Deck (..), Slide (..), defaultDeckOptions)

-- | What a reading's session is, as the viewer compares it: the user
-- signed in, a value.
type S = Maybe Int

-- | What the deck shown is in the model: the page, its version, and the
-- version of the list of pages its links were laid out against.
type Shown = (Int, Int, Int)

type M = Model S Int () Shown

type E = Event S Int () Shown

-- | A page of the model's server.
data ServerPage = ServerPage
  { version :: Int
  , steps :: [Int]
  -- ^ Each slide's number of steps.
  , presentation :: Bool
  , private :: Bool
  , gone :: Bool
  }
  deriving stock (Show)

-- | The two pages an embed can name, and the version of the space's list
-- of pages.
data Server = Server
  { pages :: Map Int ServerPage
  , listVersion :: Int
  }
  deriving stock (Show)

firstServer :: Server
firstServer =
  Server
    { pages =
        Map.fromList
          [ (0, ServerPage {version = 1, steps = [1, 2], presentation = True, private = True, gone = False})
          , (1, ServerPage {version = 1, steps = [3], presentation = True, private = False, gone = False})
          ]
    , listVersion = 1
    }

-- | The deck of a page of the model's server.
deckOfSteps :: [Int] -> Deck
deckOfSteps ss = Deck {options = defaultDeckOptions, slides = [Slide {title = Nothing, body = [], notes = [], steps = s} | s <- ss]}

-- | What the reader's side is now: who is signed in, in which session,
-- the shell's revision, the page the embed names.
data Context = Context
  { user :: Maybe Int
  , sessionNo :: Int
  , rev :: Int
  , named :: Int
  }
  deriving stock (Eq, Show)

-- | A read out: the read's number, the context it was made for (its
-- reading), the session it was sent in, and how far the server got.
data Out = Out
  { fetch :: Int
  , madeFor :: Context
  , sentIn :: Int
  , pageRead :: Maybe (Maybe (Int, [Int]))
  -- ^ The page as read: 'Nothing' until read, then the version and steps
  -- of a presentation the reader may view, or 'Nothing' for the link.
  , answer :: Maybe (Maybe (Shown, Deck))
  -- ^ The answer, once the list is read too.
  }
  deriving stock (Show)

-- | A run under way.
data World = World
  { view :: M
  , server :: Server
  , context :: Context
  , given :: Context
  -- ^ The context the viewer was last given.
  , rendered :: Int
  -- ^ How many 'Rendered' the viewer has still to be told.
  , watchesRunning :: Map Int (Int, Context)
  -- ^ The browser's watches running, by the model's number, with the
  -- generation each tells and the reading it was started for.
  , nears :: [(Int, Int, Context)]
  -- ^ The watches' tellings not yet taken by the viewer: the watch, its
  -- generation, its reading.
  , outs :: [Out]
  , owners :: Map Int Bool
  -- ^ Every read's owner made, and whether it was let go.
  , readsMade :: Map Int Context
  -- ^ The reading each read was made for.
  , answers :: Map Int (Maybe Shown)
  -- ^ The answer to each read, once it came back: the page shown, or the
  -- link.
  , finished :: Bool
  , trace :: [Text]
  , faults :: [(Rule, Text)]
  }

data Step
  = SignOut
  | SignIn
  | Reload
  | Relink
  | -- | The viewer is given its input as the context is now.
    Give
  | -- | The viewer is told that its link is rendered.
    Render
  | -- | The watch at this place among those running tells.
    Tell Int
  | -- | The viewer takes the telling at this place.
    TakeNear Int
  | -- | The server reads the page for the read at this place.
    HandlePage Int
  | -- | The server reads the list for the read at this place.
    HandleList Int
  | -- | The answer at this place comes back.
    Deliver Int
  | Move Move
  | -- | Someone saves page k with a new body.
    Edit Int
  | -- | Someone makes page k a document, or a presentation again.
    Kind Int
  | -- | Someone deletes page k, or makes it again.
    Delete Int
  | -- | Someone makes page k private, or public again.
    Privatize Int
  | Finish
  deriving stock (Eq, Show)

genRun :: Gen [Step]
genRun =
  listOf $
    frequency
      [ (2, pure SignOut)
      , (2, pure SignIn)
      , (1, pure Reload)
      , (1, pure Relink)
      , (4, pure Give)
      , (4, pure Render)
      , (4, Tell <$> chooseInt (0, 1))
      , (4, TakeNear <$> chooseInt (0, 1))
      , (4, HandlePage <$> chooseInt (0, 1))
      , (4, HandleList <$> chooseInt (0, 1))
      , (5, Deliver <$> chooseInt (0, 1))
      , (2, Move <$> elements [minBound .. maxBound])
      , (1, Edit <$> chooseInt (0, 1))
      , (1, Kind <$> chooseInt (0, 1))
      , (1, Delete <$> chooseInt (0, 1))
      , (1, Privatize <$> chooseInt (0, 1))
      , (1, pure Finish)
      ]

shrinkRun :: [Step] -> [[Step]]
shrinkRun = shrinkList $ \case
  Tell i -> Tell <$> [0 .. i - 1]
  TakeNear i -> TakeNear <$> [0 .. i - 1]
  HandlePage i -> HandlePage <$> [0 .. i - 1]
  HandleList i -> HandleList <$> [0 .. i - 1]
  Deliver i -> Deliver <$> [0 .. i - 1]
  Edit k -> Edit <$> [0 .. k - 1]
  Kind k -> Kind <$> [0 .. k - 1]
  Delete k -> Delete <$> [0 .. k - 1]
  Privatize k -> Privatize <$> [0 .. k - 1]
  _ -> []

-- | The reading the viewer is given for a context.
readingOf :: Context -> Reading S Int
readingOf c = Reading {session = c.user, revision = c.rev, link = c.named}

-- | A run from its start: the viewer of page 0 for user 1, mounted.
start :: World
start =
  let c = Context {user = Just 1, sessionNo = 1, rev = 0, named = 0}
      w0 = World {view = initial (Linked (readingOf c) ()), server = firstServer, context = c, given = c, rendered = 0, watchesRunning = mempty, nears = [], outs = [], owners = mempty, readsMade = mempty, answers = mempty, finished = False, trace = [], faults = []}
   in event "mounted" Started w0

-- | The world after the viewer took an event, and carried out its
-- effects.
event :: Text -> E -> World -> World
event what e w0 = checked (noted (what <> named) w2)
  where
    (view, fx) = step e w0.view
    w1 = w0 {view}
    w2 = foldl' (flip effect) w1 fx
    named = if null fx then "" else " -> " <> T.intercalate ", " (map show fx)

-- | One effect carried out, as the component does.
effect :: Effect Int () -> World -> World
effect e w = case e of
  Watch n g -> w {watchesRunning = Map.insert n (g, w.given) w.watchesRunning}
  Unwatch n -> w {watchesRunning = Map.delete n w.watchesRunning}
  Fetch f _ () -> w {outs = w.outs <> [Out {fetch = f, madeFor = w.given, sentIn = w.context.sessionNo, pageRead = Nothing, answer = Nothing}], owners = Map.insert f False w.owners, readsMade = Map.insert f w.given w.readsMade}
  Release f -> w {owners = Map.insert f True w.owners}
  WhenRendered -> w {rendered = w.rendered + 1}

noted :: Text -> World -> World
noted what w = w {trace = (what <> "    [" <> summary w.view <> "]") : w.trace}

summary :: M -> Text
summary m =
  T.intercalate
    " "
    ( [ case m.loaded of
          Link -> "link"
          Ready (k, v, lv) _ -> "page " <> show k <> " v" <> show v <> " list " <> show lv <> " at " <> show m.current <> "." <> show m.shownStep
      ]
        <> ["watch " <> show n | Just n <- [m.watching]]
        <> ["shows read " <> show f | Just f <- [m.shownOwner]]
    )

-- | The world after a step.
play :: World -> Step -> World
play w = \case
  SignOut
    | isJust w.context.user -> signedAs Nothing w
    | otherwise -> w
  SignIn
    | isNothing w.context.user -> signedAs (Just 1) w
    | otherwise -> w
  Reload -> noted "the shell reloads" w {context = w.context {rev = w.context.rev + 1}}
  Relink -> noted "the embed names the other page" w {context = w.context {named = 1 - w.context.named}}
  Give
    | w.finished -> w
    | otherwise -> event "given its input" (Received (Linked (readingOf w.context) ())) w {given = w.context}
  Render
    | w.rendered > 0 -> event "the link is rendered" Rendered w {rendered = w.rendered - 1}
    | otherwise -> w
  Tell i -> case atMay (Map.toList w.watchesRunning) i of
    -- The browser's watch tells once and stops itself.
    Just (n, (g, c)) -> noted ("watch " <> show n <> " tells") w {watchesRunning = Map.delete n w.watchesRunning, nears = w.nears <> [(n, g, c)]}
    Nothing -> w
  TakeNear i -> case atMay w.nears i of
    Just (n, g, c) ->
      let owned = Map.keysSet w.owners
          w' = event ("told by watch " <> show n) (Near g) w {nears = [x | (j, x) <- zip [0 ..] w.nears, j /= i]}
          started = Map.keysSet w'.owners `Set.difference` owned
       in w' {faults = w'.faults <> [(Stale, "a read started by a watch for an earlier reading") | not (Set.null started), c /= w.given]}
    Nothing -> w
  HandlePage i -> onOut i (isNothing . (.pageRead)) $ \o -> noted ("the server reads page " <> show o.madeFor.named <> " for read " <> show o.fetch) (setOut o {pageRead = Just (pageFor o w)} w)
  HandleList i -> onOut i (\o -> isJust o.pageRead && isNothing o.answer) $ \o ->
    let answer = case o.pageRead of
          Just (Just (v, ss)) -> Just ((o.madeFor.named, v, w.server.listVersion), deckOfSteps ss)
          _ -> Nothing
     in noted ("the server reads the list for read " <> show o.fetch) (setOut o {answer = Just answer} w)
  Deliver i -> case atMay [o | o <- w.outs, isJust o.answer] i of
    Just o@Out {answer = Just a} -> event ("the answer to read " <> show o.fetch) (Fetched o.fetch a) w {outs = filter (\x -> x.fetch /= o.fetch) w.outs, answers = Map.insert o.fetch (fst <$> a) w.answers}
    _ -> w
  Move mv
    | w.finished -> w
    | otherwise -> event ("moves " <> show mv) (Go mv) w
  Edit k -> writing k ("saves page " <> show k) (\p -> p {version = p.version + 1, steps = if length p.steps > 1 then [2] else [1, 1, 2]})
  Kind k -> writing k ("changes the kind of page " <> show k) (\p -> p {version = p.version + 1, presentation = not p.presentation})
  Delete k -> writing k ("deletes or makes again page " <> show k) (\p -> p {gone = not p.gone})
  Privatize k -> writing k ("makes page " <> show k <> " private or public") (\p -> p {private = not p.private})
  Finish
    | w.finished -> w
    | otherwise -> closedCheck (event "goes away" Finished w {finished = True})
  where
    writing k what f = noted ("someone " <> what) w {server = w.server {pages = Map.adjust f k w.server.pages, listVersion = w.server.listVersion + 1}}
    onOut i ok f = maybe w f (atMay (filter ok w.outs) i)
    setOut o w' = w' {outs = [if x.fetch == o.fetch then o else x | x <- w'.outs]}

-- | A sign-out or a sign-in: another session, and the backend lets go of
-- every owner's addresses.
signedAs :: Maybe Int -> World -> World
signedAs user w =
  noted ("signs " <> maybe "out" (const "in") user) w {context = w.context {user, sessionNo = w.context.sessionNo + 1}, owners = map (const True) w.owners}

-- | The page as the server reads it for a read: a presentation the
-- reader may view, or the link. A read sent in an ended session is read
-- as someone signed out.
pageFor :: Out -> World -> Maybe (Int, [Int])
pageFor o w = case Map.lookup o.madeFor.named w.server.pages of
  Just p
    | not p.gone
    , p.presentation
    , not p.private || isJust readerNow ->
        Just (p.version, p.steps)
  _ -> Nothing
  where
    readerNow = if o.sentIn == w.context.sessionNo then o.madeFor.user else Nothing

-- | The world with every read's owner checked let go, once the viewer
-- closed.
closedCheck :: World -> World
closedCheck w = w {faults = w.faults <> [(Owners, "read " <> show f <> "'s addresses are still held after the viewer closed") | (f, False) <- Map.toList w.owners, f `notElem` map (.fetch) w.outs]}

-- | The world with what the viewer holds checked against the rules.
checked :: World -> World
checked w = w {faults = w.faults <> problems}
  where
    m = w.view
    problems =
      [(OneWatch, "watches running: " <> show (Map.keys w.watchesRunning)) | Map.size w.watchesRunning > (if w.finished then 0 else 1)]
        <> [ (ForReading, "the deck shown was read for " <> show c <> ", the viewer was given " <> show w.given)
           | Ready _ _ <- [m.loaded]
           , Just f <- [m.shownOwner]
           , Just c <- [readFor f]
           , c /= w.given
           ]
        <> [ (LiveAddresses, "the deck shown has the addresses of read " <> show f <> ", let go")
           | not w.finished
           , -- Given an older context, the viewer drops the deck when it is
             -- given the new one.
             w.given == w.context
           , Ready _ _ <- [m.loaded]
           , Just f <- [m.shownOwner]
           , Map.lookup f w.owners == Just True
           ]
        <> [ (InDeck, "slide " <> show m.current <> " step " <> show m.shownStep <> " of a deck of " <> show (map (\s -> s.steps) deck.slides))
           | Ready _ deck <- [m.loaded]
           , m.current < 1 || m.current > length deck.slides || m.shownStep < 1 || m.shownStep > stepsAt deck m.current
           ]
    readFor f = Map.lookup f w.readsMade

-- | The run settled: the input given as the context is now, every link
-- rendered, every watch told and taken, every read answered.
settled :: World -> World
settled w0 = go (40 :: Int) (play w0 Give)
  where
    go 0 w = w
    go n w
      | w.rendered > 0 = go (n - 1) (play w Render)
      | not (Map.null w.watchesRunning) = go (n - 1) (play w (Tell 0))
      | not (null w.nears) = go (n - 1) (play w (TakeNear 0))
      | any (isNothing . (.pageRead)) w.outs = go (n - 1) (play w (HandlePage 0))
      | any (isNothing . (.answer)) w.outs = go (n - 1) (play w (HandleList 0))
      | not (null w.outs) = go (n - 1) (play w (Deliver 0))
      | otherwise = w

-- | Whether a run, settled, shows the answer to a read made for its
-- reading: the server's page as read then, or the link.
settles :: World -> Property
settles w0 =
  counterexample (toS (T.unlines (reverse w.trace))) $
    counterexample (toS ("shows: " <> summary w.view <> "; the last read for the reading: " <> show lastFor)) $
      isJust lastFor && fmap fst lastFor == Just shown
  where
    w = settled w0
    shown = case w.view.loaded of
      Ready x _ -> Just x
      Link -> Nothing
    lastFor = head [(a, f) | (f, a) <- reverse (Map.toList w.answers), Map.lookup f w.readsMade == Just w.given]

-- | 'Rule' is each rule a run is checked against, as the module's Haddock
-- lists them.
data Rule = OneWatch | ForReading | Stale | LiveAddresses | Owners | InDeck
  deriving stock (Eq, Show, Enum, Bounded)

ruleText :: Rule -> [Char]
ruleText = \case
  OneWatch -> "runs one watch of its link at a time, and none once closed, on any run"
  ForReading -> "shows a deck only for the reading it was last given, on any run"
  Stale -> "starts no read for a watch of an earlier reading, on any run"
  LiveAddresses -> "shows no deck whose addresses were let go, on any run"
  Owners -> "lets go of every read's addresses by the time it closes, on any run"
  InDeck -> "shows a slide and a step within the deck, on any run"

verdict :: Rule -> World -> Property
verdict rule w =
  counterexample (toS (T.unlines (reverse w.trace)))
    . counterexample (toS (T.unlines ("Broken:" : [t | (r, t) <- w.faults, r == rule])))
    $ null [() | (r, _) <- w.faults, r == rule]

cases :: Int
cases = 20_000

spec :: Spec
spec = describe "Wiki.App.View.DeckViewer.Machine" $ modifyMaxSuccess (max cases) $ do
  for_ [minBound .. maxBound] $ \rule ->
    it (ruleText rule) $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          verdict rule (foldl' play start (run <> [Finish | rule == Owners]))
  it "drops a deck when the reader signs out and in again before it is given its input" $
    -- The same user's sign-out and sign-in, given to the viewer in one
    -- input: equal sessions, but the backend let go of the deck's
    -- addresses at the sign-out.
    [t | (LiveAddresses, t) <- (foldl' play start [Tell 0, TakeNear 0, HandlePage 0, HandleList 0, Deliver 0, SignOut, SignIn, Give]).faults] `shouldBe` []

  it "shows the answer to a read made for its reading once everything has come back" $
    QC.property $
      forAllShrinkShow genRun shrinkRun show $ \run ->
        settles (foldl' play start (filter (/= Finish) run))
