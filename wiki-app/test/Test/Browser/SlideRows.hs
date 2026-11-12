{-# LANGUAGE TemplateHaskell #-}

-- | The rows of a presentation's slide mode (WP5.103 of docs/PLAN.md) over
-- a master CodeMirror, in a browser, on hosts of a harness of their own:
-- the master is the editor's CodeMirror ('attachEditor'), each row a
-- CodeMirror over one range of its text ('attachRow'), in a child
-- component in a keyed list, its range cut by "Wiki.Core.SlideRows".
--
-- What the slide mode rests on, shown before it is built: typing in a row
-- is the master's typing, one undo step a word and one a row; an undo run
-- from a row takes back the last change wherever it was, the master's
-- cursor and the row that change was in following it; a master hidden
-- with @display: none@ still moves to a problem, selects and scrolls, and
-- tells of its input and its cursor's line; the completion of mentions and
-- emoji, asked through the master's host, answers in the row that asked;
-- a reorder of the keyed list keeps an open row's CodeMirror, the same
-- element with its text and selection; and a row that starts in the
-- middle of one of the master's lines (after a lone carriage return, or
-- after @\\r\\n\\n@, which the Markdown parser reads as one line break)
-- shows and edits its range, carriage returns included, byte for byte.
module Test.Browser.SlideRows (spec) where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Aeson (decodeStrict)
import Data.List (lookup, zip3)
import Data.Row (Empty, type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Protolude hiding (State, find)
import Test.Hspec.Halogen
import Web.DOM.Internal.Types qualified as Web
import Web.Event.Event (EventType (..))
import Wiki.App.Editor.Browser (answerEmoji, answerMention, attachEditor, attachRow, detachRow, emojiAsked, mentionAsked)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.SlideRows (Row (..), RowKey (..), Rows (..), cutRows, rowStarts)
import Wiki.Core.User (Login (..), User (..))

$( browserJS
     ["jsbits/test-slide-rows.js"]
     [ ("js_master_ready", "wiki_test_rows_master_ready", Safe, [t|IO Bool|])
     , ("js_row_ready", "wiki_test_rows_row_ready", Safe, [t|Int -> IO Bool|])
     , ("js_master_text", "wiki_test_rows_master_text", Safe, [t|IO JSText|])
     , ("js_master_selection", "wiki_test_rows_master_selection", Safe, [t|IO JSText|])
     , ("js_row_text", "wiki_test_rows_text", Safe, [t|Int -> IO JSText|])
     , ("js_row_range", "wiki_test_rows_range", Safe, [t|Int -> IO JSText|])
     , ("js_row_selection", "wiki_test_rows_selection", Safe, [t|Int -> IO JSText|])
     , ("js_row_select", "wiki_test_rows_select", Safe, [t|Int -> Int -> Int -> IO ()|])
     , ("js_row_completing", "wiki_test_rows_completing", Safe, [t|Int -> IO JSText|])
     , ("js_watch", "wiki_test_rows_watch", Safe, [t|IO ()|])
     , ("js_told", "wiki_test_rows_told", Safe, [t|IO JSText|])
     , ("js_problem", "wiki_test_rows_problem", Safe, [t|Int -> Int -> IO ()|])
     , ("js_next_problem", "wiki_test_rows_next_problem", Safe, [t|IO JSText|])
     , ("js_master_select", "wiki_test_rows_master_select", Safe, [t|Int -> Int -> IO JSText|])
     , ("js_master_panels", "wiki_test_rows_master_panels", Safe, [t|IO Int|])
     , ("js_master_shown", "wiki_test_rows_master_shown", Safe, [t|IO Bool|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadUUID m) => Spec
spec m = do
  it "sends typing in a row to the master, one undo step a word and one a row" $ runPage $ do
    ui <- start deck [1, 2]
    -- At the end of row 1's text, then of row 2's.
    typeAt ui 1 (rowLength deck 1) " word"
    let once = insertAt (rowEnd deck 1) " word" deck
    masterText `shouldReturn` once
    rowText 1 `shouldReturn` rowOf once 1
    typeAt ui 2 (rowLength deck 2) " more"
    let twice = insertAt (rowEnd deck 2 + T.length " word") " more" once
    masterText `shouldReturn` twice
    rowText 2 `shouldReturn` rowOf twice 2
    -- Ctrl+Z in row 2 takes back its word, whole; again, row 1's word,
    -- whole, which row 1 shows.
    press "Control+z"
    eventually $ masterText `shouldReturn` once
    rowText 2 `shouldReturn` rowOf deck 2
    press "Control+z"
    eventually $ masterText `shouldReturn` deck
    rowText 1 `shouldReturn` rowOf deck 1
    -- And Ctrl+Y brings row 1's back.
    press "Control+y"
    eventually $ masterText `shouldReturn` once
    rowText 1 `shouldReturn` rowOf once 1

  it "takes back from a row the last change, made in another row, with the master's cursor in that row, open or closed" $ runPage $ do
    ui <- start deck [1, 2]
    typeAt ui 2 (rowLength deck 2) " more"
    let typed = insertAt (rowEnd deck 2) " more" deck
    masterText `shouldReturn` typed
    -- The focus in row 1, Ctrl+Z there.
    selectIn 1 3 3
    press "Control+z"
    eventually $ masterText `shouldReturn` deck
    rowText 2 `shouldReturn` rowOf deck 2
    rowText 1 `shouldReturn` rowOf deck 1
    (_, head') <- masterSelection
    head' `shouldSatisfy` within (rowRange deck 2)
    -- Row 2 closed, the same: the change is undone in the master alone,
    -- the cursor where row 2 is.
    typeAt ui 2 (rowLength deck 2) " more"
    masterText `shouldReturn` typed
    closeRow ui 2
    selectIn 1 3 3
    press "Control+z"
    eventually $ masterText `shouldReturn` deck
    (_, head'') <- masterSelection
    head'' `shouldSatisfy` within (rowRange deck 2)

  it "keeps a master hidden by display: none moving to a problem, selecting and scrolling, with no panel, and telling of its input and cursor's line" $ runPage $ do
    ui <- start deck [1, 3]
    void (query ui (H.mkTell (HideMaster True)))
    eventually $ unsafeIOToPageM js_master_shown `shouldReturn` False
    unsafeIOToPageM js_watch
    typeAt ui 1 (rowLength deck 1) "!"
    let typed = insertAt (rowEnd deck 1) "!" deck
    masterText `shouldReturn` typed
    told <- toldEvents
    told `shouldSatisfy` elem "input"
    told `shouldSatisfy` any ("line " `T.isPrefixOf`)
    -- A problem in row 3: the master goes to it, and row 3 shows the
    -- master's selection.
    let (problemFrom, problemTo) = (rowStart typed 3 + 3, rowStart typed 3 + 8)
    unsafeIOToPageM (js_problem problemFrom problemTo)
    (fromJSText <$> unsafeIOToPageM js_next_problem) `shouldReturn` ""
    masterSelection `shouldReturn` (problemFrom, problemTo)
    rowSelection 3 `shouldReturn` (3, 8)
    (fromJSText <$> unsafeIOToPageM (js_master_select (rowStart typed 2) (rowStart typed 2 + 2))) `shouldReturn` ""
    masterSelection `shouldReturn` (rowStart typed 2, rowStart typed 2 + 2)
    unsafeIOToPageM js_master_panels `shouldReturn` 0
    toldEvents >>= (`shouldSatisfy` ((> length told) . length))

  it "completes a mention and an emoji in the row that asked, through the master's host" $ runPage $ do
    ui <- start deck [2]
    typeAt ui 2 (rowLength deck 2) " :smi"
    eventually $ rowCompleting 2 `shouldReturn` "active"
    _ <- find ui ".rows-list li[data-key=\"2\"] .cm-tooltip-autocomplete"
    -- CodeMirror takes no choice in the list's first 75 ms.
    unsafeIOToPageM (threadDelay 100_000)
    press "Tab"
    let emoji = insertAt (rowEnd deck 2) " :smile:" deck
    eventually $ masterText `shouldReturn` emoji
    rowText 2 `shouldReturn` rowOf emoji 2
    text <- rowContent ui 2
    typeText text " @ad"
    eventually $ rowCompleting 2 `shouldReturn` "active"
    _ <- find ui ".rows-list li[data-key=\"2\"] .cm-tooltip-autocomplete"
    -- CodeMirror takes no choice in the list's first 75 ms.
    unsafeIOToPageM (threadDelay 100_000)
    press "Enter"
    let mention = insertAt (rowEnd deck 2) " :smile: @ada " deck
    eventually $ masterText `shouldReturn` mention
    rowText 2 `shouldReturn` rowOf mention 2

  it "moves an open row's CodeMirror with the list, the same element with its text and selection" $ runPage $ do
    ui <- start deck [1, 2]
    selectIn 2 3 6
    before2 <- find ui ".rows-list li[data-key=\"2\"] .cm-editor"
    before1 <- find ui ".rows-list li[data-key=\"1\"] .cm-editor"
    void (query ui (H.mkTell (Reorder [0, 2, 3, 1])))
    keysShown ui `shouldReturn` ["0", "2", "3", "1"]
    after2 <- find ui ".rows-list li[data-key=\"2\"] .cm-editor"
    after1 <- find ui ".rows-list li[data-key=\"1\"] .cm-editor"
    after2 `shouldBeSameElement` before2
    after1 `shouldBeSameElement` before1
    rowText 2 `shouldReturn` rowOf deck 2
    rowSelection 2 `shouldReturn` (3, 6)
    -- And it is still the master's: typing in it after the move.
    typeAt ui 2 (rowLength deck 2) "!"
    masterText `shouldReturn` insertAt (rowEnd deck 2) "!" deck

  it "shows and edits a row that starts inside one of the master's lines, carriage returns and all" $ runPage $ do
    ui <- start returns [1, 2]
    -- Row 1 starts after a lone carriage return, row 2 after "\r\n\n":
    -- inside the master's first and second lines.
    map (rowOf returns) [0, 1, 2] `shouldBe` ["# Deck 😀", "## One\r\n", "## Two\rx\r\nmore\n"]
    rowText 1 `shouldReturn` rowOf returns 1
    rowText 2 `shouldReturn` rowOf returns 2
    rowRangeShown 1 `shouldReturn` rowRange returns 1
    rowRangeShown 2 `shouldReturn` rowRange returns 2
    typeAt ui 1 (rowLength returns 1) "X"
    let typedOne = insertAt (rowEnd returns 1) "X" returns
    masterText `shouldReturn` typedOne
    rowText 1 `shouldReturn` rowOf typedOne 1
    -- After the carriage return inside row 2.
    typeAt ui 2 (T.length "## Two\r") "Y"
    let typedTwo = insertAt (rowStart typedOne 2 + T.length "## Two\r") "Y" typedOne
    masterText `shouldReturn` typedTwo
    rowText 2 `shouldReturn` rowOf typedTwo 2
    press "Control+z"
    eventually $ masterText `shouldReturn` typedOne
  where
    start :: forall s. Text -> [Int] -> PageM s (Mounted s Query Void m)
    start text open = do
      ui <- mount m harness text
      eventuallyWithin 10000 $ unsafeIOToPageM js_master_ready `shouldReturn` True
      for_ open $ \k -> do
        void (query ui (H.mkTell (OpenRow k)))
        eventually $ unsafeIOToPageM (js_row_ready k) `shouldReturn` True
      pure ui

    closeRow :: forall s. Mounted s Query Void m -> Int -> PageM s ()
    closeRow ui k = do
      void (query ui (H.mkTell (CloseRow k)))
      eventually $ unsafeIOToPageM (js_row_ready k) `shouldReturn` False

    rowContent :: forall s. Mounted s Query Void m -> Int -> PageM s (Element s)
    rowContent ui k = find ui (".rows-list li[data-key=\"" <> show k <> "\"] .cm-content")

    -- Put the cursor in a row, and type there key by key.
    typeAt :: forall s. Mounted s Query Void m -> Int -> Int -> Text -> PageM s ()
    typeAt ui k at typed = do
      content <- rowContent ui k
      selectIn k at at
      typeText content typed

    selectIn :: forall s. Int -> Int -> Int -> PageM s ()
    selectIn k anchor head' = unsafeIOToPageM (js_row_select k anchor head') >> settle

    masterText :: forall s. PageM s Text
    masterText = fromJSText <$> unsafeIOToPageM js_master_text

    rowText :: forall s. Int -> PageM s Text
    rowText k = fromJSText <$> unsafeIOToPageM (js_row_text k)

    rowCompleting :: forall s. Int -> PageM s Text
    rowCompleting k = fromJSText <$> unsafeIOToPageM (js_row_completing k)

    masterSelection :: forall s. PageM s (Int, Int)
    masterSelection = pairOf . fromJSText <$> unsafeIOToPageM js_master_selection

    rowSelection :: forall s. Int -> PageM s (Int, Int)
    rowSelection k = pairOf . fromJSText <$> unsafeIOToPageM (js_row_selection k)

    rowRangeShown :: forall s. Int -> PageM s (Int, Int)
    rowRangeShown k = pairOf . fromJSText <$> unsafeIOToPageM (js_row_range k)

    toldEvents :: forall s. PageM s [Text]
    toldEvents = (\t -> fromMaybe [] (decodeStrict (encodeUtf8 (fromJSText t)))) <$> unsafeIOToPageM js_told

    keysShown :: forall s. Mounted s Query Void m -> PageM s [Text]
    keysShown ui = findAll ui ".rows-list > li" >>= traverse (fmap (fromMaybe "") . (`getAttribute` "data-key"))

    within :: (Int, Int) -> Int -> Bool
    within (a, b) x = x >= a && x <= b

-- | A pair read from JSON @[a, b]@, (-1, -1) for anything else.
pairOf :: Text -> (Int, Int)
pairOf t = case decodeStrict (encodeUtf8 t) of
  Just [a, b] -> (a, b)
  _ -> (-1, -1)

-- | A deck with an emoji (two UTF-16 units, one character) before rows 2
-- and 3.
deck :: Text
deck = "# Deck\n\n## One 😀\n\nAlpha.\n\n## Two\n\nBeta.\n\n## Three\n\nGamma.\n"

-- | A deck whose rows start inside the master's lines: row 1 after a lone
-- carriage return, row 2 after @\\r\\n\\n@; an emoji before both.
returns :: Text
returns = "# Deck 😀\r## One\r\n\n## Two\rx\r\nmore\n"

-- | The rows of a text, cut fresh.
rowsOf :: Text -> Rows
rowsOf = fst . cutRows (RowKey 0)

rowOf :: Text -> Int -> Text
rowOf text k = maybe "" (\r -> r.text) (atMay (rowsOf text).rows k)

rowStart :: Text -> Int -> Int
rowStart text k = fromMaybe 0 (atMay (rowStarts (rowsOf text)) k)

rowLength :: Text -> Int -> Int
rowLength text k = T.length (rowOf text k)

rowEnd :: Text -> Int -> Int
rowEnd text k = rowStart text k + rowLength text k

rowRange :: Text -> Int -> (Int, Int)
rowRange text k = (rowStart text k, rowEnd text k)

insertAt :: Int -> Text -> Text -> Text
insertAt at piece text = T.take at text <> piece <> T.drop at text

----------------------------------------------------------------------
-- The harness

-- | What a test asks of the harness: a row opened or closed, the list in
-- another order of keys, the master hidden or shown.
data Query a
  = OpenRow Int a
  | CloseRow Int a
  | Reorder [Int] a
  | HideMaster Bool a

data State = State
  { text :: Text
  , ranges :: [(Int, (Int, Int))]
  -- ^ Each row's key and range, in characters, from the fresh cut.
  , order :: [Int]
  , opened :: [Int]
  , hidden :: Bool
  , masterRef :: H.RefLabel
  , masterHost :: Maybe Web.Element
  }

data Action
  = Initialize
  | MentionAsked Int Text
  | EmojiAsked Int Text

type Slots = ("row" .== H.Slot (Const Void) Void Int)

-- | The master, with the textarea it takes the place of, and a keyed list
-- of rows over a text, one per row of its fresh cut, closed.
harness :: forall m. (MonadIO m, MonadUUID m) => H.Component Query Text Void m
harness =
  H.mkComponent
    H.ComponentSpec
      { initialState = \text -> do
          ref <- H.newRefLabel "rows-master"
          let cut = rowsOf text
              starts = rowStarts cut
              ranges = [(k, (s, s + T.length r.text)) | (k, r, s) <- zip3 [0 ..] cut.rows starts]
          pure State {text, ranges, order = map fst ranges, opened = [], hidden = False, masterRef = ref, masterHost = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.handleQuery = handleQuery, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      HH.div_
        [ HH.div
            ( [ HP.class_ (HH.ClassName "rows-master")
              , HP.ref st.masterRef
              , HE.handler' (EventType "wiki-mention") (\ev -> uncurry MentionAsked <$> mentionAsked ev)
              , HE.handler' (EventType "wiki-emoji") (\ev -> uncurry EmojiAsked <$> emojiAsked ev)
              ]
                <> [HP.attr (HH.AttrName "style") "display: none" | st.hidden]
            )
            []
        , HH.element @I.HTMLtextarea (HH.ElemName "textarea") [HP.class_ (HH.ClassName "rows-text"), HP.attr (HH.AttrName "style") "display: none"] [HH.text st.text]
        , HH.keyed
            @I.HTMLol
            (HH.ElemName "ol")
            [HP.class_ (HH.ClassName "rows-list")]
            [ (show k, HH.li [HP.attr (HH.AttrName "data-key") (show k)] [HH.slot "row" k row RowInput {master = st.masterHost, start, end, open = k `elem` st.opened} absurd])
            | k <- st.order
            , Just (start, end) <- [lookup k st.ranges]
            ]
        ]

    handleAction :: Action -> H.HalogenM State Action Slots Void m ()
    handleAction = \case
      Initialize -> do
        st <- get
        found <- H.getRef st.masterRef
        modify (\s -> s {masterHost = found})
        traverse_ (\host -> H.liftEffect (attachEditor host st.text)) found
      MentionAsked i _ ->
        gets (\st -> st.masterHost) >>= traverse_ (\host -> H.liftEffect (answerMention host i (Just [ada])))
      EmojiAsked i _ ->
        gets (\st -> st.masterHost) >>= traverse_ (\host -> H.liftEffect (answerEmoji host i [("smile", "😄")]))

    handleQuery :: Query a -> H.HalogenM State Action Slots Void m (Maybe a)
    handleQuery = \case
      OpenRow k next -> modify (\st -> st {opened = ordNub (k : st.opened)}) $> Just next
      CloseRow k next -> modify (\st -> st {opened = filter (/= k) st.opened}) $> Just next
      Reorder keys next -> modify (\st -> st {order = keys}) $> Just next
      HideMaster h next -> modify (\st -> st {hidden = h}) $> Just next

    ada = User {id = UserId "ada", login = Login "ada", displayName = "Ada Lovelace", avatar = Nothing}

-- | A row's input: the master's host, its range in characters, and whether
-- it is open.
data RowInput = RowInput
  { master :: Maybe Web.Element
  , start :: Int
  , end :: Int
  , open :: Bool
  }

data RowState = RowState
  { input :: RowInput
  , ref :: H.RefLabel
  , attached :: Bool
  }

data RowAction = RowSync | RowReceive RowInput | RowGone

-- | A row: a host its CodeMirror is put in while it is open, and let go of
-- when it closes or goes.
row :: forall m. (MonadIO m, MonadUUID m) => H.Component (Const Void) RowInput Void m
row =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> (\ref -> RowState {input, ref, attached = False}) <$> H.newRefLabel "rows-host"
      , render = \st -> HH.div [HP.class_ (HH.ClassName "rows-host"), HP.ref st.ref] []
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just RowSync
              , H.receive = Just . RowReceive
              , H.finalize = Just RowGone
              }
      }
  where
    handleAction :: RowAction -> H.HalogenM RowState RowAction Empty Void m ()
    handleAction = \case
      RowSync -> sync
      RowReceive input -> modify (\st -> st {input}) >> sync
      RowGone -> gets (\st -> st.ref) >>= H.getRef >>= traverse_ (H.liftEffect . detachRow)

    sync :: H.HalogenM RowState RowAction Empty Void m ()
    sync = do
      st <- get
      host <- H.getRef st.ref
      case (st.input.open, st.attached, st.input.master, host) of
        (True, False, Just master, Just h) -> do
          H.liftEffect (attachRow master h st.input.start st.input.end False)
          modify (\s -> s {attached = True})
        (False, True, _, Just h) -> do
          H.liftEffect (detachRow h)
          modify (\s -> s {attached = False})
        _ -> pass
