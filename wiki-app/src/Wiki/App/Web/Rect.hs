{-# LANGUAGE TemplateHaskell #-}

-- | Where an element is drawn: its box in the window, read from the
-- browser's @getBoundingClientRect@ through fields ('boxOf'), as decision
-- 30 of docs/PLAN.md has the browser's objects read. haskell-halogen's
-- 'Element' has no such member yet, so this module reads it through a
-- newtype of its own over the element ('Measured'); the member belongs in
-- core, beside 'Element', when core next changes. Natively every box is
-- empty.
--
-- The avatar's crop ("Wiki.App.View.Avatar") places its starting selection
-- with it ('centredSquare'), and the browser tests measure the page with
-- it.
module Wiki.App.Web.Rect
  ( Box (..)
  , boxOf
  , centredSquare
  )
where

import Halogen.JSBits (Inert, JSVal)
import Halogen.JSBits.Fields (Member (..), jsFields)
import Protolude
-- With its constructor: the FFI passes the value inside the newtype.
import Web.DOM.Internal.Types (Element (..))

-- | 'Box': a box in the window, its left, top, right and bottom edges in
-- CSS pixels.
data Box = Box {left :: Double, top :: Double, right :: Double, bottom :: Double}
  deriving stock (Eq, Show)

-- | An element, to be measured.
newtype Measured = Measured Element
  deriving newtype (Inert)

-- | The browser's @DOMRect@: an element's box, its CSS transform included,
-- as a picture Cropper.js scales is drawn.
newtype Rect = Rect JSVal
  deriving newtype (Inert)

$( jsFields
     ''Measured
     [ Method "getBoundingClientRect" [t|IO Rect|]
     ]
 )

$( jsFields
     ''Rect
     [ Fixed "left" ''Double
     , Fixed "top" ''Double
     , Fixed "right" ''Double
     , Fixed "bottom" ''Double
     ]
 )

-- | Where an element is drawn now.
boxOf :: (MonadIO m) => Element -> m Box
boxOf element = liftIO $ do
  r <- (Measured element).getBoundingClientRect
  pure Box {left = r.left, top = r.top, right = r.right, bottom = r.bottom}

-- | The largest square inside the part of a picture that lies within an
-- area, centred in that part, as its left and top edges from the area's
-- and its side; 'Nothing' when no square fits. The side is a whole number
-- of pixels, one less than fits, because Cropper.js rounds a selection to
-- whole pixels and the square must stay inside the picture.
centredSquare :: Box -> Box -> Maybe (Double, Double, Double)
centredSquare area picture
  | side > 0 = Just (x + (width - side) / 2, y + (height - side) / 2, side)
  | otherwise = Nothing
  where
    x = max picture.left area.left - area.left
    y = max picture.top area.top - area.top
    width = min picture.right area.right - area.left - x
    height = min picture.bottom area.bottom - area.top - y
    side = max 0 (fromIntegral (floor (min width height) :: Int) - 1)
