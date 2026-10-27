{-# LANGUAGE TemplateHaskell #-}

-- | The JSON instances of the wiki's records, derived by Template Haskell.
--
-- They were derived from each type's 'GHC.Generics.Generic' representation
-- until WP5.9 of docs/PLAN.md; aeson's "Data.Aeson.TH" writes the same
-- instances from the same 'Options' for less of the compiler's work (a
-- sixth less allocation for @wiki-api@, a tenth for @wiki-core@, natively).
-- On WebAssembly a package's first splice also starts GHC's external
-- interpreter, some twenty seconds per build of the package that runs one.
--
-- With one difference this module takes away: aeson's splices write a
-- 'toEncoding' of their own, which writes an object's keys in the order the
-- record declares its fields, where an instance that only has a 'toJSON'
-- (as a derived 'Generic' one did) is encoded through the 'Value' it gives,
-- whose keys come out sorted. The API's bodies, the page's preload and what
-- the demo keeps in IndexedDB have always been written that second way, and
-- clients and tests compare them as text, so 'deriveValueJSON' and
-- 'deriveValueToJSON' are aeson's splices with their 'toEncoding' left out:
-- the class's default, through 'toJSON', writes the bytes it always has.
-- Parsing has no such difference, so 'deriveFromJSON' is aeson's own.
--
-- Where a splice goes: right after its type, where it can. A top-level
-- splice ends a group of declarations, and a group sees nothing declared
-- after it: no type, no function, no instance. So a splice comes below the
-- instances of the types its type holds; and where declarations above it
-- name types or functions declared below it (a servant record of routes
-- above the bodies it names, a record above the records it holds, a module
-- written from the top down), the splices go below those, or all at the end
-- of the module, each after those of the types its type holds.
module Wiki.Core.Json
  ( deriveValueJSON
  , deriveValueToJSON
  , deriveFromJSON
  , Options (..)
  , defaultOptions
  )
where

import Data.Aeson (ToJSON (toEncoding))
import Data.Aeson.TH (Options (..), defaultOptions, deriveFromJSON, deriveToJSON)
import Language.Haskell.TH (Dec (..), Name, Pat (..), Q)
import Protolude

-- | The 'Data.Aeson.ToJSON' and 'Data.Aeson.FromJSON' instances of a type,
-- as 'Data.Aeson.TH.deriveJSON' writes them, encoded through 'toJSON'.
deriveValueJSON :: Options -> Name -> Q [Dec]
deriveValueJSON options name = (<>) <$> deriveValueToJSON options name <*> deriveFromJSON options name

-- | The 'Data.Aeson.ToJSON' instance of a type, as
-- 'Data.Aeson.TH.deriveToJSON' writes it, encoded through 'toJSON'.
deriveValueToJSON :: Options -> Name -> Q [Dec]
deriveValueToJSON options name = map withoutEncoding <$> deriveToJSON options name
  where
    withoutEncoding = \case
      InstanceD overlap context instanceHead methods -> InstanceD overlap context instanceHead (filter (not . definesEncoding) methods)
      other -> other
    definesEncoding = \case
      FunD method _ -> method == 'toEncoding
      ValD (VarP method) _ _ -> method == 'toEncoding
      _ -> False
