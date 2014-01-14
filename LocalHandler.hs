import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Monad
import qualified Data.Map as M
import qualified Data.ByteString.UTF8 as BU8
import Pipes
import Pipes.Safe
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T

import qualified HttpType as H
import Protocol
import ProxyHandler
import MyKey
import PipesUtil
import Socks5

serverHost = "localhost"
serverPort = "1234"
listenHost = "localhost"
listenPort = "1080"

connect :: (String, String) -> IO ()
connect (host, port) = do
  mSockMap <- newMVar M.empty

  -- Msg pipe
  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded
  -- raw bs pipe
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded

  -- XXX: persistent storage for the uniq gen
  mkUniq <- do
    x <- newMVar 1
    return $ do
      modifyMVar x $ \ i -> return (i + 1, i)

  let
    -- bs frag -> msg
    fromS2C = PC.fromInput fromS2CQ >->
              parserToPipe parseMessage >-> logWith "s->c msg: "
    -- msg -> bs
    fromC2S = bufferedPipe 4000 10 (PC.fromInput fromC2SQ >->
                                    logWith "c->s msg: " >->
                                    pipeWithP fromMessage) >-> 
              logWith "c->s chunked msg: "

    clientState = ClientState (PC.toOutput toC2SQ) mSockMap

  recvThread <- async $ runSafeT $
    T.connect host port $ \ (peer, peerAddr) -> lift $ do
      connectChunkedAsFetcher connOpt (T.fromSocket peer 4096, T.toSocket peer)
                                      (PC.toOutput toS2CQ)
  sendThread <- async $ runSafeT $
    T.connect host port $ \ (peer, peerAddr) -> lift $ do
      connectChunkedAsSender connOpt (T.toSocket peer)
                                     (fromC2S)
  handleRespThread <- async $ runEffect $ for fromS2C $ \ msg -> lift $ do
    putStrLn $ "Client got msg " ++ show msg
    clientHandleServerResp msg clientState

  socks5AcceptThread <- async $ runSafeT $
    T.serve (T.Host listenHost) listenPort $ \ (peer, peerAddr) -> do
      putStrLn $ "Got socks req from " ++ show peerAddr
      let
        toPeer = T.toSocket peer
        fromPeer = T.fromSocket peer 4096
      ((connHost, connPort), fromPeer') <- socks5Handshake (toPeer, fromPeer)
      putStrLn $ "Proxy req is " ++ show connHost ++ ":" ++ show connPort
      let
        proxyReq = ProxyReq toPeer fromPeer' (BU8.toString connHost)
                                             (show connPort)
                                             mkUniq
      runSafeT $ clientHandleSocksReq proxyReq clientState

  mapM_ wait [recvThread, sendThread, handleRespThread, socks5AcceptThread]
 where
  connOpt = ConnectOpt (httpHeaderKeyName, mySecretKey)

main = T.withSocketsDo $ do
  connect (serverHost, serverPort)

