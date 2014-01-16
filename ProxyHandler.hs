{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

-- Most of the things are generic enough.. Although some socks5-specific
-- codecs exist here. Consider moving them away?

module ProxyHandler where

import Control.Applicative
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad
import Control.Exception
import Data.Word
import Data.Time.Clock
import qualified Data.Serialize as S
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import qualified Data.Map as M
import qualified Data.Attoparsec as A
import Pipes
import Pipes.Safe hiding (try)
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T
import Network.Socket
import System.IO.Error

import PipesUtil
import Socks5

-- XXX: generate codec instead? Well.. since pipes.attoparsec is not good,
-- I would assume pipes.binary is also not good.
data Message
  = Connect {
    connId :: Int,
    connHost :: String,
    connPort :: String
  }
  | ConnResult {
    connId :: Int,
    connIsSucc :: Bool,
    usingHost :: Word32,
    usingPort :: Word16
  }
  | Data {
    connId :: Int,
    dataToSend :: B.ByteString
  }
  | Disconn {
    connId :: Int,
    disconnReason :: String
  }
  deriving (Show, Eq)

--data ProxyReq
--  = ProxyReq {
--    prHost :: String,
--    prPort :: String,
--  }

data ProxyReq
  = ProxyReq {
    -- Only available for the proxy req handler
    toLocal :: Consumer B.ByteString IO (),
    fromLocal :: Producer B.ByteString IO (),
    prPeer :: Socket,
    prHost :: String,
    prPort :: String,
    mkUniq :: IO Int
  }

data ClientState
  = ClientState {
    -- available for both the proxy req handler and the server resp handler
    toServerQ :: Consumer Message IO (),
    prSockMap :: MVar SockMap
  }

type SockMap = M.Map Int (Consumer Message IO (), -- data/disconn handled 
                                                  -- by the sock local loop
                          IO () -- closer
                          )

parseMessage :: A.Parser Message
parseMessage = do
  tag <- A.anyWord8
  connId <- fromIntegral . runGet' S.getWord32be <$> A.take 4
  case tag of
    1 -> Connect connId <$> parseNetString
                        <*> parseNetString
    2 -> ConnResult connId <$> (num2Bool <$> A.anyWord8)
                           <*> (runGet' S.get <$> A.take 4)
                           <*> (runGet' S.get <$> A.take 2)
    3 -> Data connId <$> parseNetBS
    4 -> Disconn connId <$> parseNetString
 where
  num2Bool 0 = False
  num2Bool 1 = True

fromMessage :: Monad m => Message -> Producer B.ByteString m ()
fromMessage (Connect {..}) = do
  yield $ S.runPut $ S.putWord8 1 *>
                     S.putWord32be (fromIntegral connId)
  fromNetString connHost
  fromNetString connPort
 
fromMessage (ConnResult {..}) = yield $ S.runPut $ do
  S.putWord8 2
  S.putWord32be (fromIntegral connId)
  S.putWord8 (if connIsSucc then 1 else 0)
  S.put usingHost
  S.put usingPort

fromMessage (Data {..}) = do
  yield $ S.runPut $ S.putWord8 3
  yield $ S.runPut $ S.putWord32be (fromIntegral connId)
  fromNetBS dataToSend

fromMessage (Disconn {..}) = do
  yield $ S.runPut $ S.putWord8 4
  yield $ S.runPut $ S.putWord32be (fromIntegral connId)
  fromNetString disconnReason

async_ = async >=> const (return ())

debugMsg msg = case msg of
  Connect {..} -> "[Connect#" ++ show connId  ++ " " ++
                  connHost ++ ":" ++ connPort ++ "]"
  ConnResult {..} -> "[ConnResult#" ++ show connId  ++ " " ++
                     show connIsSucc ++ "]"
  Data {..} -> "[Data#" ++ show connId  ++ " " ++
               show (B.length dataToSend) ++ "Bytes]"
  Disconn {..} -> "[Disconn#" ++ show connId  ++ " " ++ disconnReason ++ "]"

logMsg title = forever $ do
  msg <- await
  liftIO $ putStr title >> putStrLn (debugMsg msg)
  yield msg

isDisconn (Disconn {..}) = True
isDisconn _ = False

serverHandleClientReq :: Message -> MVar SockMap ->
                         Consumer Message IO () -> IO ()
serverHandleClientReq msg mSockMap toClientQ = case msg of
  Connect {..} -> async_ $ do
    -- XXX: conn error handling
    let doConn = T.connect connHost connPort 
    --putStrLn $ "connecting to " ++ connHost ++ ":" ++ connPort
    ei <- tryIOError $ runSafeT $ doConn $ \ (peer, peerAddr) -> do
      --lift $ putStrLn $ "connected to " ++ show peerAddr
      -- Make a client->remote queue here.
      -- Note we don't need a remote->client queue since
      -- we are going to run remote->client loop here.
      let
        SockAddrInet portNo hostAddr = peerAddr
        toPeer = T.toSocket peer
        fromPeer = T.fromSocket peer 4096
      (toS2RQ, fromS2RQ, seal) <- lift $ PC.spawn' PC.Unbounded
      -- Note that finalizers are ran in the reverse direction
      mapM_ register [ do putStrLn $
                            "server handle: " ++ show peerAddr ++ " onclose"
                          -- Correctly shutdown the sock
                          -- since pipes-network-safe dont do that
                          shutdown peer ShutdownBoth
                     , atomically seal
                     , modifyMVar_ mSockMap $ return . M.delete connId
                     , runEffect $
                         yield (Disconn connId "") >-> toClientQ
                     ]
      lift $ do
        let
          toS2RQ_ = PC.toOutput toS2RQ
        modifyMVar_ mSockMap $
          return . M.insert connId (toS2RQ_, atomically seal)
        t1 <- async $ do
          runEffect $ do
            yield (ConnResult connId True hostAddr (fromIntegral portNo))
              >-> toClientQ
            fromPeer >-> pipeWith (Data connId) >-> toClientQ
        t2 <- async $ do
          runEffect $ for (PC.fromInput fromS2RQ) $ \ msg -> case msg of
            Data {..} -> yield dataToSend >-> toPeer
            Disconn {..} -> lift $ atomically seal
            _ -> error $ "server loop t2: got unexpected msg: " ++ debugMsg msg
        (_, res) <- waitAnyCatch [t1, t2]
        putStrLn $ "remote splice loop done " ++ show res
      -- No need to wait for t1 since it will be closed when clientQ is sealed
    case ei of
      Left e -> do
        -- conn failure
        putStrLn $ "conn failure: " ++ show e
        runEffect $ yield (ConnResult connId False 0 0) >-> toClientQ
      Right r -> do
        return ()
  _ -> do
    -- Handover to the socket
    -- See bug #1
    mbSock <- withMVar mSockMap $ return . M.lookup (connId msg)
    case mbSock of
      Just (toS2RQ, _) -> do
        runEffect $ yield msg >-> toS2RQ
      Nothing
        | isDisconn msg -> return ()  -- to avoid echoing..
        | otherwise -> runEffect $ yield (Disconn (connId msg) "no such conn")
                                         >-> toClientQ

-- Hard lifting done on the c2l loop
clientHandleServerResp :: Message -> ClientState -> IO () 
clientHandleServerResp msg (ClientState {..}) = do
  mbSock <- withMVar prSockMap $ return . M.lookup (connId msg)
  case mbSock of
    Just (toC2LQ, _) ->
      runEffect $ yield msg >-> toC2LQ
    Nothing
      | isDisconn msg -> return ()  -- to avoid echoing..
      | otherwise -> runEffect $ yield (Disconn (connId msg) "no such conn")
                                 >-> toServerQ

clientHandleSocksReq :: ProxyReq -> ClientState -> SafeT IO ()
clientHandleSocksReq (ProxyReq {..}) (ClientState {..}) = do
  sockId <- lift $ mkUniq
  -- make queues so as to provide non-blocking streams
  -- for the server resp handler to use
  (toC2LQ, fromC2LQ, seal) <- lift $ PC.spawn' PC.Unbounded

  mapM_ register [ shutdown prPeer ShutdownBoth
                 , atomically seal
                 , modifyMVar_ prSockMap $ return . M.delete sockId
                 , do putStrLn $ "proxy handle: " ++ prHost ++
                                 ":" ++ prPort ++ " onclose"
                      runEffect $ yield (Disconn sockId "local closed") >->
                                  toServerQ
                 ]

  lift $ do
    modifyMVar_ prSockMap $
      return . M.insert sockId (PC.toOutput toC2LQ, atomically seal)

    -- XXX: shall we run this in another thread?
    runEffect $ yield (Connect sockId prHost prPort) >-> toServerQ

    -- Start client->local msg loop
    t1 <- async $ runEffect $ for (PC.fromInput fromC2LQ) $ \ msg -> case msg of
      Data {..} -> yield dataToSend >-> toLocal
      Disconn {..} -> lift $ atomically seal
      ConnResult {..} -> do
        fromSocksResp connIsSucc usingHost usingPort >-> toLocal
        if connIsSucc
          then
            -- Splicing loop already started in handle proxy
            -- Though I could make a lock... but for the sake of avoiding
            -- deadlock, I decide not to make one.
            return ()
          else
            lift $ atomically seal
      _ -> error $ "client t1: unexpected msg: " ++ debugMsg msg
    -- and local->client bs loop (according to socks5 protocol, no data will
    -- be sent before proxy server acked the conn succ)
    t2 <- async $ do
      runEffect $ fromLocal >-> pipeWith (Data sockId) >-> toServerQ
    waitAnyCatch [t1, t2]
    putStrLn $ "proxyReq loop t1 or t2 done"
    return ()

