-- | The maker's terminal interface, after @ghcup tui@: the toolchain's
-- components with their state, refreshed on request, and the bootstrap run
-- from it to install what is missing. The deploy's screens join it in a
-- later phase (docs/PLAN.md, WP5.68).
module Maker.Tui (run) where

import Brick
  ( App (..)
  , AttrMap
  , AttrName
  , BrickEvent (..)
  , EventM
  , Widget
  , attrMap
  , attrName
  , defaultMain
  , get
  , hLimit
  , halt
  , padLeft
  , padTop
  , put
  , str
  , strWrap
  , suspendAndResume
  , vBox
  , withAttr
  , (<+>)
  )
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.Core (Padding (..))
import Graphics.Vty qualified as V
import Maker.Context (Context (..))
import Maker.Status (Component (..), State (..), status)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (proc, waitForProcess, withCreateProcess)

-- | What the screen shows: the components, and what the last action said.
data Screen = Screen
  { context :: Context
  , components :: [Component]
  , note :: String
  }

-- | Show the toolchain until the user quits.
run :: Context -> IO ()
run ctx = do
  components' <- status ctx
  _ <- defaultMain app Screen {context = ctx, components = components', note = ""}
  pure ()

app :: App Screen () ()
app =
  App
    { appDraw = draw
    , appChooseCursor = \_ _ -> Nothing
    , appHandleEvent = handle
    , appStartEvent = pure ()
    , appAttrMap = const theme
    }

draw :: Screen -> [Widget ()]
draw screen =
  [ vBox
      [ withAttr titleAttr (str "The wiki's toolchain")
      , padTop (Pad 1) (borderWithLabel (str " components ") (vBox (map row screen.components)))
      , padTop (Pad 1) (hLimit 100 (strWrap screen.note))
      , padTop (Pad 1) (withAttr helpAttr (str "i: install what is missing (toolchain/bootstrap.sh toolchain)   r: refresh   q: quit"))
      ]
  ]
  where
    row c = padLeft (Pad 1) (str (pad 18 c.name) <+> stateWidget c.state)
    stateWidget = \case
      Ready detail -> withAttr readyAttr (str "ready    ") <+> str detail
      Missing detail -> withAttr missingAttr (str "missing  ") <+> str detail
      Blocked detail -> withAttr blockedAttr (str "blocked  ") <+> str detail
    pad n s = s <> replicate (n - length s) ' '

handle :: BrickEvent () () -> EventM () Screen ()
handle = \case
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'r') []) -> do
    screen <- get
    suspendAndResume (refresh screen "")
  VtyEvent (V.EvKey (V.KChar 'i') []) -> do
    screen <- get
    suspendAndResume $ do
      putStrLn "Running toolchain/bootstrap.sh toolchain; its output follows."
      code <- withCreateProcess (proc "sh" [screen.context.root </> "toolchain" </> "bootstrap.sh", "toolchain"]) $ \_ _ _ p -> waitForProcess p
      putStrLn "Press Enter to go back."
      _ <- getLine
      refresh screen $ case code of
        ExitSuccess -> "The bootstrap finished."
        ExitFailure n -> "The bootstrap stopped with status " <> show n <> "; what it said is above it in the terminal's scrollback, and in ~/.wiki-toolchain/bootstrap.log."
  _ -> do
    screen <- get
    put screen

refresh :: Screen -> String -> IO Screen
refresh screen note' = do
  components' <- status screen.context
  pure screen {components = components', note = note'}

titleAttr, helpAttr, readyAttr, missingAttr, blockedAttr :: AttrName
titleAttr = attrName "title"
helpAttr = attrName "help"
readyAttr = attrName "ready"
missingAttr = attrName "missing"
blockedAttr = attrName "blocked"

theme :: AttrMap
theme =
  attrMap
    V.defAttr
    [ (titleAttr, V.withStyle V.defAttr V.bold)
    , (helpAttr, V.withForeColor V.defAttr V.brightBlack)
    , (readyAttr, V.withForeColor V.defAttr V.green)
    , (missingAttr, V.withForeColor V.defAttr V.yellow)
    , (blockedAttr, V.withForeColor V.defAttr V.red)
    ]
