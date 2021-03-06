-- | Haskell representation of nix store paths.
module Nix.StorePath where

import ClassyPrelude hiding (try)
import Data.Aeson (ToJSON, FromJSON)
import Data.HashSet (HashSet)
import Servant (MimeUnrender(..), OctetStream)
import Servant.HTML.Lucid (HTML)
import System.Environment (getEnv)
import System.FilePath (takeFileName, takeDirectory, isAbsolute)
import System.Process (readCreateProcess, shell)
import Text.Regex.PCRE.Heavy (scan, re)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Nix.Bin (NixCmdReturn(nixCmd))

-- | The nix store directory.
newtype NixStoreDir = NixStoreDir FilePath
  deriving (Show, Eq, Generic, Hashable, IsString, ToJSON, FromJSON)

-- | The 32-character prefix of an object in the nix store.
newtype StorePrefix = StorePrefix Text
  deriving (Show, Eq, Ord, Generic, Hashable, IsString)

-- | The hash and name of an object in the nix store.
data StorePath = StorePath {spPrefix :: StorePrefix, spName :: Text}
  deriving (Eq, Ord, Generic)

instance Show StorePath where
  show (StorePath (StorePrefix prefix) name) = unpack (prefix <> "-" <> name)

instance Hashable StorePath

-- | A dependency tree, represented as a mapping from a store path to
-- its set of (immediate, not transitive) dependent paths.
type PathTree = HashMap StorePath PathSet

-- | A set of store paths.
type PathSet = HashSet StorePath

-- | Path to an object in the nix store.
type FullStorePath = (NixStoreDir, StorePath)

-- | Read the NIX_STORE variable to get the path to the nix store.
getNixStoreDir :: IO NixStoreDir
getNixStoreDir = NixStoreDir <$> getEnv "NIX_STORE"

-- | Parse a nix store path from text. The input text should be a
-- basepath, not a full path (i.e., it should not be
-- '/nix/store/xyz-foo', but instead should be 'xyz-foo').
parseStorePath :: Text -> Either String StorePath
parseStorePath txt =
  case scan [re|^([\w\d]{32})-(.*)|] txt of
    [(_, [StorePrefix -> hash, name])] -> Right $ StorePath hash name
    _ -> Left $ show txt <> " does not appear to be a store basepath"

-- | Parse a store path. The source can be either a full (absolute)
-- path or a store (base) path.
permissiveParseStorePath :: Text -> Either String StorePath
permissiveParseStorePath txt = do
  case (parseStorePath txt, parseFullStorePath txt) of
    (Right spath, _) -> pure spath
    (_, Right (_, spath)) -> pure spath
    (Left err1, Left err2) -> Left $ concat [
      "Not a base store path (", show err1, ") and not an absolute ",
      "store path (", show err2, ")"
      ]

-- | Parse a store path from text. Probably not super efficient but oh well.
parseFullStorePath :: Text -> Either String FullStorePath
parseFullStorePath (T.unpack -> p) = case (takeDirectory p, takeFileName p) of
  (d, _) | not (isAbsolute d) -> do
    Left ("store path must be absolute: " <> show d <> " (" <> p <> ")")
  (_, "") -> Left ("basename of store path " <> show p <> " is empty")
  (storeDir, base) -> do
    storePath <- parseStorePath (T.pack base)
    pure (NixStoreDir storeDir, storePath)

-- | Parse a StorePath in the IO monad. The input can be absolute or base.
ioParseStorePath :: MonadIO io => Text -> io StorePath
ioParseStorePath txt = liftIO $ case permissiveParseStorePath txt of
  Left err -> error err
  Right sp -> return sp

-- | Parse a full store path in the IO monad.
ioParseFullStorePath :: MonadIO io => Text -> io FullStorePath
ioParseFullStorePath txt = liftIO $ case parseFullStorePath txt of
  Left err -> error err
  Right result -> return result

-- | Given a nix store dir and a store path, produce a full file path.
spToFull :: NixStoreDir -> StorePath -> FilePath
spToFull (NixStoreDir storeDir) p = storeDir </> spToPath p

-- | Same as above, but uses a FullStorePath, when that's more concise.
spToFull' :: FullStorePath -> FilePath
spToFull' = uncurry spToFull

-- | Convert a StorePath to Text.
spToText :: StorePath -> Text
spToText (StorePath (StorePrefix hash) name) = hash <> "-" <> name

-- | Convert a StorePath to a FilePath.
spToPath :: StorePath -> FilePath
spToPath = unpack . spToText

-- | Find a nix store path by its store prefix. If multiple paths
-- satisfy the prefix, the first one will be taken.
findSpByPrefix :: Text -> IO StorePath
findSpByPrefix prefix = do
  NixStoreDir dir <- getNixStoreDir
  let cmd = "ls " <> dir <> " | grep '^" <> unpack prefix <> "'"
  result <- readCreateProcess (shell cmd) ""
  case parseFullStorePath $ pack result of
    Left err -> error err
    Right (_, sp) -> return sp

-- | Find a nix store path by suffix. If multiple paths satisfy the
-- suffix, the first one will be taken.
findSpBySuffix :: Text -> IO StorePath
findSpBySuffix prefix = do
  NixStoreDir dir <- getNixStoreDir
  let cmd = "ls " <> dir <> " | grep '" <> unpack prefix <> "$'"
  result <- readCreateProcess (shell cmd) ""
  case parseFullStorePath $ pack result of
    Left err -> error err
    Right (_, sp) -> return sp

-- | Find a nix store path by some text that appears in the path. If
-- multiple paths satisfy the search, the first one will be taken.
findSp :: Text -> IO StorePath
findSp text = do
  NixStoreDir dir <- getNixStoreDir
  let cmd = "ls " <> dir <> " | grep '" <> unpack text <> "'"
  result <- readCreateProcess (shell cmd) ""
  case parseFullStorePath $ pack result of
    Left err -> error err
    Right (_, sp) -> return sp

-- | Return an abbreviated version of a store path, e.g. for
-- debugging. Uses only the first 6 characters of the prefix.
abbrevSP :: StorePath -> Text
abbrevSP (StorePath (StorePrefix hash) name) = T.take 6 hash <> "-" <> name

instance MimeUnrender OctetStream StorePath where
  mimeUnrender _ = map snd . parseFullStorePath . T.decodeUtf8 . toStrict

instance MimeUnrender HTML StorePath where
  mimeUnrender _ = map snd . parseFullStorePath . T.decodeUtf8 . toStrict

instance NixCmdReturn FullStorePath where
  nixCmd nixBin cmd args input = do
    rawPath <- nixCmd nixBin cmd args input
    ioParseFullStorePath rawPath

instance NixCmdReturn StorePath where
  nixCmd nixBin cmd args input = do
    ioParseStorePath =<< nixCmd nixBin cmd args input

instance NixCmdReturn [StorePath] where
  nixCmd nixBin cmd args input = do
    rawPaths <- nixCmd nixBin cmd args input
    forM (T.lines rawPaths) $ \line ->
      ioParseStorePath line
