{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Data.Serialize
import Data.Word
import qualified Data.Map as M
import Pipes
import Pipes.Safe
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Binary as PB
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as PT
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import Network.Socket
import System.Environment

import MyKey (mySecretKey, httpHeaderKeyName)
import HttpType

type SockMap = M.Map Int ( --PC.Output B.ByteString
                           PC.Input B.ByteString
                         , STM () -- closer
                         )

data ProxyState
  = ProxyState {
    pxSockMap :: MVar SockMap,
    pxOutput :: PC.Output Message
  }

main :: IO ()
main = PT.withSocketsDo $ do
  myIp <- getEnv "OPENSHIFT_DIY_IP"
  myPort <- getEnv "OPENSHIFT_DIY_PORT"

  mSockMap <- newMVar M.empty

  runSafeT $ PT.serve (PT.Host myIp) myPort $ \ (peer, _) -> 
    (`runReaderT` mSockMap) $ httpReqHandleLoop peer

-- The same as the FwdOption in ssh-socks5-pipe
-- -D port, -RD remote-port,
-- -L local-port:remote-host:remote-port
-- -R remote-port:local-host:local-port,
--
-- For brevity, we only support -D for now
data ProxyType
  = AsConnector
  | AsListener {
    listenHost :: String,
    listenPort :: String
  }
  deriving (Show)

data Direction
  = ClientToServer
  | ServerToClient
  deriving (Show)

data Message
  = HandShake {
    hsStreamingDirection :: Direction
  }
  | Connect {
    connId :: Int,
    connHost :: String,
    connPort :: String
  }
  | ConnResult {
    connId :: Int,
    connIsSucc :: Bool,
    usingHost :: Maybe (String, String)
  }
  | Data {
    connId :: Int,
    dataToSend :: B.ByteString
  }
  | Disconn {
    connId :: Int,
    disconnReason :: String
  }
  deriving (Show)

-- We are using chunk streaming here -- client opens two connection
-- to the server, in which one is used by the client to send data to the server
-- and vise versa.
--
-- Pipes is used here to decouple chunk decoding, message parsing and
-- responsing.
--
-- connId is always supplied by the local handler. Note that therefore
-- it would be better to use Acid or whatever to store the connId
-- persistently.
httpReqHandshake :: Socket -> ReaderT (MVar SockMap) IO ()
httpReqHandshake peer = (`evalStateT` (PT.fromSocket peer 4096)) $ do
  Right (_, httpReq) <- PA.parse parseRequestHeader
  if M.lookup httpHeaderKeyName (rqHeaders httpReq) /= Just mySecretKey
    then makeFakeHttpResponse peer
    else do
      Right (_, hsMsg) <- PA.parse parseMessage
      case hsStreamingDirection hsMsg of
        ServerToClient -> runServerToClient peer
        ClientToServer -> runClientToServer peer
  
makeFakeHttpResponse peer = do
  liftIO $ runEffect $ fakeResp >-> PT.toSocket peer
 where
  fakeResp = do
    yield "HTTP/1.1 200 OK\r\n"
    yield "Host: nol-m9.rhcloud.com\r\n"
    yield "Content-Type: text/plain\r\n"
    yield "Content-Length: 15\r\n\r\n"
    yield "Hello, world!\r\n"

runServerToClient peer = do
  out <- asks pxOutput
  runEffect $ PC.fromOutput out >-> encodeMessage >->
              encodeChunk >-> PT.toSocket peer

runClientToServer _ = forever $ do
  Right (_, msg) <- PA.parse parseMessage
  case msg of
    Connect {..} -> doConnect connId connHost connPort
    Data {..} -> doSend connId dataToSend
    Disconn {..} -> doDisconn connId

doConnect connId host port = do
  mSockMap <- asks pxSockMap
  proxyOut <- asks pxOutput
  liftIO $ do
    -- Make a duplex channel for bytestring splicing
    (sockOut, sockIn, closer) <- PC.spawn' PC.Unbounded
    modifyMVar_ mSockMap $ return . M.insert connId (sockOut, closer)
    async $ runSafeT $ do
      -- Handle disconnection
      register $ do
        modifyMVar_ mSockMap $ return . M.delete connId
        yield (Disconn connId "remote closed") >-> PC.toOutput proxyOut
      -- Splice loop
      PT.connect host port $ \ (remote, _) -> do
        runEffect $ yield (ConnResult True Nothing) >-> PC.toOutput proxyOut
        liftIO $ async $ runEffect $
          PC.fromInput sockIn >-> PT.toSocket remote
        runEffect $
          PT.fromSocket remote 4096 >-> mkMsg connId >-> PC.toOutput proxyOut
  return ()
 where
  mkMsg connId = do
    bs <- await
    yield $ Data connId bs
    mkMsg connId

doSend connId bs = do
  mSockMap <- asks pxSockMap
  proxyOut <- asks pxOutput
  liftIO $ do
    mbMailbox <- withMVar mSockMap $ M.lookup connId
    case mbMailbox of
      Nothing -> do
        yield (Disconn connId "No such conn") >-> PC.toOutput proxyOut
        -- Nothing means that either the conn is closed or the
        -- connId is invalid.
      Just (sockOut, _) -> do
        runEffect $ yield bs >-> PC.toOutput sockOut

doDisconn connId = do
  mSockMap <- asks pxSockMap
  liftIO $ do
    mbMailbox <- withMVar mSockMap $ M.lookup connId
    case mbMailbox of
      Nothing -> return () -- Hmm... what to do?
      Just (_, closeMailbox) ->
        atomically closeMailbox

parseProxyRequest = undefined

