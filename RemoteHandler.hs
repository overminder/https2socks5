import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Monad
import qualified Data.Map as M
import Pipes
import Pipes.Safe
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T

import qualified HttpType as H
import Protocol
import ProxyHandler
import MyKey
import PipesUtil

serve :: (String, String) -> IO ()
serve (host, port) = do
  mSockMap <- newMVar M.empty

  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded

  getIsFirst <- do
    m <- newMVar True
    return $ swapMVar m False
      
  let
    -- encoded msg -> msg
    fromC2S = PC.fromInput fromC2SQ >->
              --logWith "c->s chunk" >->
              parserToPipe parseMessage >-> logWith "c->s msg: "
    -- msg -> encoded msg
    fromS2C = --bufferedPipe 4000 10
                (PC.fromInput fromS2CQ >-> logWith "s->c msg: " >->
                 pipeWithP fromMessage)

  serverThread <- async $ runSafeT $
    T.serve (T.Host host) port $ \ (peer, peerAddr) -> do
      let
        fromPeer = T.fromSocket peer 4096
        toPeer = T.toSocket peer
      isFirst <- getIsFirst
      putStrLn $ "Client " ++ show peerAddr ++ " connected, isFirst = " ++
                 show isFirst
      let
        mayLog = id --if not isFirst then (>-> logWith "fromPeer ") else id
      serveChunkedStreamer serveOpt (mayLog fromPeer, toPeer)
                                    (fromS2C, PC.toOutput toC2SQ)
  handleThread <- async $ runEffect $ for fromC2S $ \ msg -> lift $ do
    serverHandleClientReq msg mSockMap (PC.toOutput toS2CQ)

  mapM_ wait [serverThread, handleThread]
 where
  serveOpt = ServeOpt (httpHeaderKeyName, mySecretKey)

main = T.withSocketsDo $ do
  serve ("localhost", "1234")
