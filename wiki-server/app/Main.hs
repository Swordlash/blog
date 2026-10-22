-- | The wiki's server. There is none yet: Phase 2 of docs/PLAN.md writes it
-- (servant over SQLite, serving wiki-app's files). Until then this says so,
-- and exists so that the package, native only, is part of every build.
module Main (main) where

import Protolude

main :: IO ()
main = putText "wiki-server: there is no server yet; the wiki runs in the browser (npm run serve-wasm)."
