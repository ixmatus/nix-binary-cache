-- | Getting and registering NARs via subprocessing with the nix-store CLI.
module Nix.Nar.Subprocess where

import ClassyPrelude

import Nix.Nar.Types (Nar, NarExport(neMetadata), NarMetadata(nmStorePath))
import Nix.Nar.Serialization (runGet_, runPut_)
import Nix.Bin (NixBinDir, nixCmd)
import Nix.StorePath (StorePath, NixStoreDir, spToFull, spToPath)
import qualified Data.ByteString.Lazy as BL

-- | Ask nix for an archive of a store object.
getNar :: NixBinDir -> NixStoreDir -> StorePath -> IO Nar
getNar nixBin nsdir spath = do
  let path = spToFull nsdir spath
  narBytes <- nixCmd nixBin "store" ["--dump", path] ""
  case runGet_ (fromStrict narBytes) of
    Right nar -> pure nar
    Left err -> error $ concat ["In file " <> show path <> ":\n", err]

-- | Ask nix for an export of a store object.
getNarExport :: NixBinDir -> NixStoreDir -> StorePath -> IO NarExport
getNarExport nixBin nsdir spath = do
  let path = spToFull nsdir spath
  narBytes <- nixCmd nixBin "store" ["--export", path] ""
  case runGet_ (fromStrict narBytes) of
    Right nar -> pure nar
    Left err -> error $ concat ["In file " <> show path <> ":\n", err]

-- | Import a nix export into the nix store.
importNarExport :: NixBinDir -> NarExport -> IO ()
importNarExport nixBin export = do
  let path = nmStorePath $ neMetadata export
      bytes = runPut_ export
  nixCmd nixBin "store" ["--import"] bytes
    `catch` \(e :: SomeException) -> do
      let p = "/tmp/" <> spToPath path
      putStrLn $ "writing bytes to " <> tshow p
      BL.writeFile p bytes
      error $ "When importing " <> show path <> ": " <> show e
