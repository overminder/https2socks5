{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Monad
import Crypto.Random.AESCtr -- random
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Network.Socket hiding (connect)
import qualified Network.Socket.ByteString as SB
import Network.TLS
import Network.TLS.Extra
import Pipes
import Pipes.Safe
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T
import qualified Pipes.Network.TCP.TLS as PTL
import System.IO

import qualified HttpType as H
import qualified Config
import Protocol
import ProxyHandler
import MyKey
import PipesUtil
import Socks5

listenHost = "localhost"
listenPort = "1080"

type DupChan = (Producer B.ByteString IO (), Consumer B.ByteString IO ())

noSession :: Socket -> IO DupChan
noSession s = return (T.fromSocket s 4096, T.toSocket s)

establishProxyAndTls :: Socket -> IO DupChan
establishProxyAndTls peer = do
  rng <- makeSystem

  let
    fromPeer = T.fromSocket peer 4096
    toPeer = T.toSocket peer
  -- Proxy conn
  runEffect $
    H.fromMessage (H.mkRequest H.CONNECT Config.serverUri "") >-> toPeer
  Right (_, fromPeer') <- next (fromPeer >->
                                parserToPipe (H.parseResponse $ return B.empty))

  -- establish tls
  let
    peerBackend = socketToBackend peer
  ctx <- contextNew peerBackend myTlsParam rng
  handshake ctx
  let
    tlsIn  = PTL.fromContext ctx
    tlsOut = PTL.toContext ctx
  putStrLn "established ssl connection"
  return (tlsIn, tlsOut)

socketToBackend s = Backend {
  backendFlush = return (),
  backendClose = close s,
  backendSend = SB.sendAll s,
  backendRecv = \ n -> recvAll n []
}
 where
  recvAll n out = do
    bs <- SB.recv s n
    let
      out' = bs : out
    case n - B.length bs of
      0  -> return . B.concat . reverse $ out'
      n' -> recvAll n' out'

myTlsParam = defaultParamsClient {
  pCiphers = [ cipher_RC4_128_MD5, cipher_RC4_128_SHA1, cipher_AES128_SHA1
             , cipher_AES256_SHA1, cipher_AES128_SHA256
             , cipher_AES256_SHA256]
}

connect :: (String, String) -> (Socket -> IO DupChan) -> IO ()
connect (host, port) mkSession = do
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
    fromC2S = bufferedPipe 4000 100 (PC.fromInput fromC2SQ >->
                                     logWith "c->s msg: " >->
                                     pipeWithP fromMessage) >-> 
              logWith "c->s chunked msg: "

    clientState = ClientState (PC.toOutput toC2SQ) mSockMap

  recvThread <- async $ runSafeT $
    T.connect host port $ \ (peer, peerAddr) -> lift $ do
      (fromPeer, toPeer) <- mkSession peer
      connectChunkedAsFetcher connOpt (fromPeer, toPeer)
                                      (PC.toOutput toS2CQ)
  sendThread <- async $ runSafeT $
    T.connect host port $ \ (peer, peerAddr) -> lift $ do
      (_, toPeer) <- mkSession peer
      connectChunkedAsSender connOpt toPeer fromC2S
  handleRespThread <- async $ runEffect $ for fromS2C $ \ msg -> lift $ do
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
        proxyReq = ProxyReq (logWith "toPeer " >-> toPeer)
                            (fromPeer' >-> logWith "fromPeer ")
                            peer
                            (BU8.toString connHost)
                            (show connPort)
                            mkUniq
      runSafeT $ clientHandleSocksReq proxyReq clientState

  mapM_ wait [recvThread, sendThread, handleRespThread, socks5AcceptThread]
 where
  connOpt = ConnectOpt {
    coSecret = (httpHeaderKeyName, mySecretKey),
    coHost = Config.serverHost
  }

connectLocal = connect (Config.serverHost, Config.serverPort) noSession
connectProxyAndThenSSL =
  connect (Config.proxyHost, Config.proxyPort) establishProxyAndTls

main = T.withSocketsDo connectLocal

