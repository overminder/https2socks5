import Control.Applicative
import Control.Concurrent.Async
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Data.Serialize
import Data.Word
import qualified Data.Map as M
import Pipes
import Pipes.Safe
import Pipes.Parse
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Binary as PB
import qualified Pipes.Concurrent as P
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Pipes.Network.TCP.Safe as T
import qualified Pipes.Network.TCP.TLS as S
import Network.Socket

import MyKey (mySecretKey)

main = do
  myIp <- getEnv "OPENSHIFT_DIY_IP"
  myPort <- getEnv "OPENSHIFT_DIY_PORT"
  T.serve (T.Host myIp) myPort $ \ (peer, _) -> do
  socks <- newMVar M.empty

