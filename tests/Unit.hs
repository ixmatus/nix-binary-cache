module Main where

import ClassyPrelude
import Network.HTTP.Client (newManager, defaultManagerSettings)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Test.Hspec (hspec)
import Control.Monad.Trans.Except (runExceptT)
import Servant.Client

import Nix.Cache.Client
import Nix.Cache.Types
import qualified Nix.Cache.Types.Tests as TypesTests

-- | This function for easy testing.
run :: BaseUrl -> ClientReq a -> IO a
run baseUrl req = do
  manager <- newManager $ case baseUrlScheme baseUrl of
    Https -> tlsManagerSettings
    _ -> defaultManagerSettings
  runExceptT (req manager baseUrl) >>= \case
    Left err -> error $ show err
    Right x -> return x

-- | Make a request against the nixos cache.
runNixos :: ClientReq a -> IO a
runNixos = run nixosCacheUrl

main :: IO ()
main = hspec $ do
  TypesTests.nixCacheInfoSpec
  TypesTests.kvMapSpec
  TypesTests.fileHashSpec
