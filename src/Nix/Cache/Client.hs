module Nix.Cache.Client where

import ClassyPrelude
import Servant.Client (BaseUrl(..), client, ServantError, Scheme(..))
import Network.HTTP.Client (Manager)
import Control.Monad.Trans.Except (ExceptT)
import Servant

import Nix.Cache.Types

-- | The nix cache API type.
type NixCacheAPI = "nix-cache-info" :> Get '[OctetStream] NixCacheInfo
              :<|> Capture "narinfo" StorePrefix :> Get '[BOctetStream] NarInfo

-- Make a client request returning a `t`.
type ClientReq t = Manager -> BaseUrl -> ExceptT ServantError IO t

-- | Define the client by pattern matching.
nixCacheInfo :: ClientReq NixCacheInfo
narInfo :: StorePrefix -> ClientReq NarInfo
nixCacheInfo
  :<|> narInfo = client (Proxy :: Proxy NixCacheAPI)

-- | Base URL of the nixos cache.
nixosCacheUrl :: BaseUrl
nixosCacheUrl = BaseUrl {
  baseUrlScheme = Https,
  baseUrlHost = "cache.nixos.org",
  baseUrlPort = 443,
  baseUrlPath = ""
  }
