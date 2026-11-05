-- | Version numbers as the tools print them (@9.14.1@, @v24.21.0@), and the
-- comparison the floors need: a version is at least a floor when its
-- numbers, read one by one from the left, are not smaller.
module Maker.Version
  ( atLeast
  , numbers
  , nodeMajor
  )
where

import Data.Char (isDigit)

-- | The numbers of a version, @"9.14.1"@ as @[9, 14, 1]@. A part counts by
-- its leading digits, as awk reads it, so @"9.14.1-rc1"@ is @[9, 14, 1]@; a
-- part without any ends the list, so @"x"@ is @[]@.
numbers :: String -> [Int]
numbers text = case span isDigit text of
  ("", _) -> []
  (digits, '.' : rest) -> read digits : numbers rest
  (digits, "") -> [read digits]
  (digits, _) -> [read digits]

-- | Whether the version is the floor or later. A number missing on either
-- side counts as 0, so @9.12@ is at least @9.12.0@ and @9.12.2@ at least
-- @9.12@; @9.10.3@ is not at least @9.12@. This is the comparison
-- toolchain/bootstrap.sh's @version_at_least@ makes.
atLeast :: String -> String -> Bool
atLeast found floor' = go (numbers found) (numbers floor')
  where
    go _ [] = True
    go [] gs = all (== 0) gs
    go (f : fs) (g : gs)
      | f > g = True
      | f < g = False
      | otherwise = go fs gs

-- | The major version of what @node --version@ prints (@v24.21.0@ as 24),
-- if it is one.
nodeMajor :: String -> Maybe Int
nodeMajor ('v' : rest) = case numbers rest of
  (major : _ : _) -> Just major
  _ -> Nothing
nodeMajor _ = Nothing
