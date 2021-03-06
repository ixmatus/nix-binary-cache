{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Functions for parsing a nix derivation.
module Nix.Derivation.Parser where

import ClassyPrelude hiding (try, readFile)
import Prelude (readFile)
import Text.Parsec
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T

import Nix.StorePath
import Nix.FileHash
import Nix.Derivation.Types
import Nix.Bin (NixCmdReturn(nixCmd))

-- | Parsec parser type.
type Parser a = Parsec [Char] () a

-- | Parses a string constant. Allows syntax for certain escape
-- sequences (\n, \t, etc), and otherwise anything after a '\'
-- will appear as-is (which allows " and \ to be escaped).
text :: Parser Text
text = char '"' >> loop [] where
  loop acc = do
    let continue c = loop (c:acc)
    anyChar >>= \case
      '"' -> return $ pack $ reverse acc
      '\\' -> anyChar >>= \case
        'n' -> continue '\n'
        'r' -> continue '\r'
        't' -> continue '\t'
        'b' -> continue '\b'
        c -> continue c
      c -> continue c

-- | Execute a parser surrounded by two characters.
surround :: Char -> Char -> Parser a -> Parser a
surround start stop p = char start *> p <* char stop

-- | Parse a store path surrounded by quotes.
quotedStorePath :: Parser StorePath
quotedStorePath = try $ do
  fullPath <- text
  case snd <$> parseFullStorePath fullPath of
    Left err -> fail err
    Right sp -> return sp

-- | Parse a derivation in the Parser monad.
derivationParser :: Parser Derivation
derivationParser = do
  let parens = surround '(' ')'
      brackets = surround '[' ']'
      sepCommas = flip sepBy (char ',')
      sepCommas1 = flip sepBy1 (char ',')
      textList = brackets $ sepCommas text
  -- All derivations start with this string.
  string "Derive"
  parens $ do
    -- Grab the output list. This is a comma-separated list of
    -- 4-tuples, like so:
    -- [("out","/nix/store/sldkfjslkdfj-foo","","")]
    -- Or if the output has a known hash, then the hash type and hash:
    -- [("out","/nix/store/xyz-foo","sha256","abc123")]
    outs <- brackets $ sepCommas1 $ do
      parens $ do
        outName <- OutputName <$> text
        char ','
        outPath <- quotedStorePath
        char ','
        text >>= \case
          "" -> do
            -- If the next text is empty, it means this isn't a
            -- fixed-output hash. Then the next string should also be
            -- empty, and that's the end.
            string ",\"\""
            return (outName, (outPath, Nothing))
          hashtype -> case getFileHashConstructor hashtype of
            -- If it's not empty, then it should correspond to a valid
            -- hash type, and there should be some non-empty hash
            -- string coming next.
            Left err -> fail err
            Right constructor -> do
              char ','
              hash <- text
              return (outName, (outPath, Just $ constructor hash))
    char ','
    -- Grab the input derivation list. A comma-separated list of
    -- 2-tuples like so:
    -- [("/nix/store/abc-bar",["out"]), ("/nix/store/xyz-bux",["out","dev"])]
    inDerivs <- brackets $ sepCommas $ do
      parens $ do
        inDName <- quotedStorePath
        char ','
        inDOutputs <- map OutputName <$> textList
        return (inDName, inDOutputs)
    -- Grab the input file list (not derivations). Just a list of
    -- strings.
    char ','
    inFiles <- brackets $ sepCommas quotedStorePath
    -- Grab the system info string.
    system <- char ',' >> text
    -- Grab the builder executable path.
    builder <- char ',' >> map unpack text
    -- Grab the builder arguments.
    builderArgs <- char ',' >> textList
    -- Grab the build environment, a list of 2-tuples.
    char ','
    buildEnv <- brackets $ sepCommas $ parens $ do
      key <- text
      value <- char ',' *> text
      return (key, value)
    return $ Derivation {
      derivOutputs = H.fromList outs,
      derivInputDerivations = H.fromList inDerivs,
      derivInputPaths = inFiles,
      derivSystem = system,
      derivBuilder = builder,
      derivArgs = builderArgs,
      derivEnv = H.fromList buildEnv
      }

-- | Parse a derivation string.
parseDerivString :: String -> Either String Derivation
parseDerivString s = case parse derivationParser "derivation" s of
  Left err -> Left $ show err
  Right deriv -> Right deriv

-- | Parse a derivation text.
parseDerivText :: Text -> Either String Derivation
parseDerivText s = case parse derivationParser "derivation" (unpack s) of
  Left err -> Left $ show err
  Right deriv -> Right deriv

-- | Parse a derivation file. Assumes the file exists.
parseDerivFile :: FilePath -> IO (Either String Derivation)
parseDerivFile p = parseDerivString <$> readFile p

-- | Parse a derivation file. Assumes the file exists and parses correctly.
parseDerivFromPath :: NixStoreDir -> StorePath -> IO Derivation
parseDerivFromPath sdir spath = parseDerivFile (spToFull sdir spath) >>= \case
  Left err -> error err
  Right deriv -> pure deriv

-- | Parse a derivation file from a storepath, using the NIX_STORE variable.
parseDerivFromPath' :: StorePath -> IO Derivation
parseDerivFromPath' p = getNixStoreDir >>= flip parseDerivFromPath p

-- | Parse a derivation file given its store prefix.
parseDerivFromPrefix :: StorePrefix -> IO Derivation
parseDerivFromPrefix (StorePrefix prefix) = do
  parseDerivFromPath' =<< findSpByPrefix prefix

parseDerivAndOutputs :: Text -> IO (Either String DerivationAndOutputs)
parseDerivAndOutputs txt = case T.split (=='!') (T.strip txt) of
  [path] -> parseDerivFile (unpack path) >>= \case
    Right deriv -> pure $ Right $ DerivationAndOutputs deriv Nothing
    Left err -> pure $ Left err
  [path, ""] -> parseDerivFile (unpack path) >>= \case
    Right deriv -> pure $ Right $ DerivationAndOutputs deriv Nothing
    Left err -> pure $ Left err
  [path, outputs] -> do
    let names = OutputName <$> T.split (==',') outputs
    parseDerivFile (unpack path) >>= \case
      Right deriv -> pure $ Right $ DerivationAndOutputs deriv (Just names)
      Left err -> pure $ Left err
  _ -> pure $ Left $ "Couldn't parse derivation/outputs indication " <> show txt


instance NixCmdReturn DerivationAndOutputs where
  nixCmd nixBin cmd args input = do
    nixCmd nixBin cmd args input >>= parseDerivAndOutputs >>= \case
      Left err -> error err
      Right res -> pure res
