-- | The one rule for answers that come late (WP5.95 of docs/PLAN.md): an
-- answer of a kind is taken only if no newer answer of that kind was
-- taken already.
--
-- A view asks the backend for something and takes the answer whenever it
-- comes. Two asks of the same kind can be out at once: a reload asked for
-- while the first load is still out, a change of route and back, the live
-- channel saying "changed" twice. Their answers can come in the other
-- order. Without the rule, the older answer, taken last, stays on the
-- screen until something asks again.
--
-- What "newer" means depends on the answer:
--
-- * A page has an order of its own, its version ('takesPage'). A later
--   ask can return an older version: a fetch asked for before a save and
--   answered after it. So the page's version decides, whatever the order
--   of the asks.
-- * An answer with no order of its own (a page's threads, the pages that
--   link to a page, a space's pages, who is signed in and the spaces) is
--   ordered by its ask ('Asks'): the answer to a later ask is newer than
--   the answer to an earlier one.
--
-- An answer is taken as soon as it comes if nothing newer was taken. So the
-- answer to an earlier ask is shown until the answer to the later one
-- comes, and never after it. A failure is an answer like any other: the
-- latest ask's failure replaces an earlier ask's success, as a reload that
-- fails would, and an earlier success that comes after the failure is
-- dropped.
--
-- The ticket of an ask is taken in the step that starts the ask
-- ('asking'), and compared in the step that takes the answer
-- ('answered'): each is one step of the view's program, with no wait
-- between reading 'Asks' and writing it.
module Wiki.App.View.Latest
  ( Asks
  , Ask
  , noAsks
  , newAsk
  , takes
  , madeAfter
  , stillAnswerable
  , supersede
  , asking
  , answered
  , superseded
  , takesPage
  )
where

import Protolude
import Wiki.Core.Page (Page (id, updatedAt))

-- | 'Asks' is what a view knows of the asks of one kind it made: how many
-- it made, and which of them gave the newest answer taken. A view keeps
-- one for each kind of answer it takes in its state.
data Asks = Asks
  { asked :: Int
  -- ^ How many asks of the kind were made: the number of the latest.
  , taken :: Int
  -- ^ The number of the ask whose answer is shown, or of the latest ask
  -- when something newer than every answer was put in their place
  -- ('supersede').
  }
  deriving stock (Eq, Show)

-- | 'Ask' is the ticket of one ask: its number among the asks of its kind.
newtype Ask = Ask Int
  deriving stock (Eq, Show)

-- | No ask made yet.
noAsks :: Asks
noAsks = Asks {asked = 0, taken = 0}

-- | A new ask of the kind: its ticket, and the asks with it.
newAsk :: Asks -> (Ask, Asks)
newAsk a = (Ask (a.asked + 1), a {asked = a.asked + 1})

-- | The asks after the answer to this ask is taken, or 'Nothing' when it
-- is not taken: the answer to a later ask, or something newer, was taken
-- already.
takes :: Ask -> Asks -> Maybe Asks
takes (Ask n) a
  | n > a.taken = Just a {taken = n}
  | otherwise = Nothing

-- | Whether an ask was made after the asks were as given: what the view
-- learnt another way while the asks were so (a message of the live
-- channel) is older than the answer to an ask made after it, and may be
-- newer than the answer to an ask made before.
madeAfter :: Ask -> Asks -> Bool
madeAfter (Ask n) a = n > a.asked

-- | Whether the answer to an ask made by the time the asks were as first
-- given can still be taken, the asks being now as second given: what the
-- view learnt another way then is kept while it may be newer than an
-- answer still to come.
stillAnswerable :: Asks -> Asks -> Bool
stillAnswerable then' now = then'.asked > now.taken

-- | The asks after something newer than the answer to every ask out was
-- put in their place: a whole answer that came another way (the live
-- channel's), or the view gone to show something else. None of the
-- answers to those asks is taken after this.
supersede :: Asks -> Asks
supersede a = a {taken = a.asked}

-- | Begin an ask of a kind, in one step: its ticket, kept with the asks
-- in the state.
asking :: (MonadState st m) => (st -> Asks) -> (Asks -> st -> st) -> m Ask
asking get' set' = state (\st -> let (a, after) = newAsk (get' st) in (a, set' after st))

-- | The answer to an ask, in one step: if nothing newer of its kind was
-- taken, the state with the answer's change made and the ask marked as
-- taken. Whether the answer was taken.
answered :: (MonadState st m) => (st -> Asks) -> (Asks -> st -> st) -> Ask -> (st -> st) -> m Bool
answered get' set' a change =
  state $ \st -> case takes a (get' st) of
    Just after -> (True, change (set' after st))
    Nothing -> (False, st)

-- | The state with something newer than every answer of the kind put in
-- its place, as 'supersede' says, and the change that puts it there, in
-- one step.
superseded :: (st -> Asks) -> (Asks -> st -> st) -> (st -> st) -> st -> st
superseded get' set' change st = change (set' (supersede (get' st)) st)

-- | Whether a view takes a page it was given (a fetch's answer, a save's),
-- with the page it shows: not when the two are the same page (the same
-- 'Page.id') and the one given is an older version.
--
-- A version is the page's @updatedAt@, which the backend sets on every
-- save of the title or the text, later than the one before. Restoring an
-- old version saves it again, as a newer version, which is taken. A page
-- deleted and made again at the same address has another id, and is
-- taken. The same version is taken: it has the same title and text.
-- What a save does not version (the page's place in the tree, the
-- template mark, the attachments) comes as the answer has it, which a
-- late answer may have older.
--
-- So the order the answers come in cannot put an older version back: a
-- fetch asked for before a save and answered after it is dropped.
takesPage :: Maybe Page -> Page -> Bool
takesPage shown given = case shown of
  Just page | page.id == given.id -> given.updatedAt >= page.updatedAt
  _ -> True
