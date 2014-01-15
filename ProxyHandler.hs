{-# LANGUAGE RecordWildCards #-}

-- Most of the things are generic enough.. Although some socks5-specific
-- codecs exist here. Consider moving them away?

module ProxyHandler where

import Control.Applicative
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad
import Data.Word
import qualified Data.Serialize as S
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import qualified Data.Map as M
import qualified Data.Attoparsec as A
import Pipes
import Pipes.Safe
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T
import Network.Socket

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

type SockMap = M.Map Int (Producer B.ByteString IO (),
                          Consumer B.ByteString IO (),
                          IO ())

runGet' g bs = case S.runGet g bs of
  Right a -> a
  Left e -> error $ show e

parseMessage :: A.Parser Message
parseMessage = do
  tag <- A.anyWord8
  connId <- fromIntegral . runGet' S.getWord32be <$> A.take 4
  case tag of
    1 -> Connect connId <$> (BU8.toString <$> parseNetString)
                        <*> (BU8.toString <$> parseNetString)
    2 -> ConnResult connId <$> (num2Bool <$> A.anyWord8)
                           <*> (runGet' S.get <$> A.take 4)
                           <*> (runGet' S.get <$> A.take 2)
    3 -> Data connId <$> parseNetString
    4 -> Disconn connId <$> (BU8.toString <$> parseNetString)
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

parseNetString :: A.Parser B.ByteString
parseNetString = do
  len <- fromIntegral . runGet' S.getWord32be <$> A.take 4
  A.take len

fromNetBS :: Monad m => B.ByteString -> Producer B.ByteString m ()
fromNetBS bs = do
  yield $ S.runPut $ S.putWord32be (fromIntegral $ B.length bs)
  yield bs

fromNetString :: Monad m => String -> Producer B.ByteString m ()
fromNetString = fromNetBS . BU8.fromString

serverHandleClientReq :: Message -> MVar SockMap ->
                         Consumer Message IO () -> IO ()
serverHandleClientReq msg mSockMap toClient = case msg of
  Connect {..} -> do
    -- XXX: conn error handling
    async $ runSafeT $ T.connect connHost connPort $ \ (peer, peerAddr) -> do
      -- Make a client->remote queue here.
      -- Note we don't need a remote->client queue since
      -- we are going to run remote->client loop here.
      let
        SockAddrInet portNo hostAddr = peerAddr
      (toC2RQ, fromC2RQ, seal2) <- lift $ PC.spawn' PC.Unbounded
      onClose <- lift $ mkIdempotent $ do
        atomically seal2
        runEffect $ yield (Disconn connId "remote closed") >-> toClient
        modifyMVar_ mSockMap $ return . M.delete connId
        putStrLn $ "server handle: " ++ show peerAddr ++ " onclose"
        -- Correctly shutdown the sock since pipes-network-safe dont do that
        shutdown peer ShutdownBoth
      register onClose
      lift $ do
        modifyMVar_ mSockMap $
          return . M.insert connId (undefined, PC.toOutput toC2RQ, onClose)
        t1 <- async $ do
          runEffect $ do
            yield (ConnResult connId True hostAddr (fromIntegral portNo))
              >-> toClient
            T.fromSocket peer 4096 >-> pipeWith (Data connId) >-> toClient
          putStrLn "remote splice loop done (t1, remote closed)"
        t2 <- async $ do
          runEffect $ PC.fromInput fromC2RQ >-> T.toSocket peer
          putStrLn "remote splice loop done (t2, local closed)"
        waitAny [t1, t2]
      -- No need to wait for t1 since it will be closed when clientQ is sealed
    return ()

  Data {..} -> do
    mbSock <- withMVar mSockMap $ return . M.lookup connId
    case mbSock of
      Just (_, toC2RQ, _) -> do
        runEffect $ yield dataToSend >-> toC2RQ
      Nothing ->
        runEffect $ yield (Disconn connId "no such conn") >-> toClient

  Disconn {..} -> do
    let
      runMaybeT f m = join (maybe (return ()) f <$> m)
      runSeal (_, _, x) = x
    runMaybeT runSeal $ withMVar mSockMap $ return . M.lookup connId 

clientHandleServerResp :: Message -> ClientState -> IO () 
clientHandleServerResp msg (ClientState {..}) = case msg of
  ConnResult {..} -> do
    -- XXX: exception handling
    Just (fromL2CQ, toC2LQ, _) <- withMVar prSockMap $
      return . M.lookup connId
    -- Write socks reply to that sock
    runEffect $ fromSocksResp connIsSucc usingHost usingPort >-> toC2LQ
    -- and start splicing
    async $ runEffect $ fromL2CQ >->
                        pipeWith (Data connId) >->
                        toServerQ
    return ()
  Data {..} -> do
    -- XXX: exception handling
    Just (_, toC2LQ, _) <- withMVar prSockMap $ return . M.lookup connId
    runEffect $ yield dataToSend >-> toC2LQ
  Disconn {..} -> do
    -- XXX: exception handling
    Just (_, _, seal) <- withMVar prSockMap $ return . M.lookup connId
    -- XXX: run in another thread?
    seal

clientHandleSocksReq :: ProxyReq -> ClientState -> SafeT IO ()
clientHandleSocksReq (ProxyReq {..}) (ClientState {..}) = do
  sockId <- lift $ mkUniq
  -- make queues so as to provide non-blocking streams
  -- for the server resp handler to use
  (toC2LQ, fromC2LQ, seal1) <- lift $ PC.spawn' PC.Unbounded
  (toL2CQ, fromL2CQ, seal2) <- lift $ PC.spawn' PC.Unbounded

  onClose <- lift $ mkIdempotent $ do
    atomically $ seal1 >> seal2
    modifyMVar_ prSockMap $ return . M.delete sockId
    putStrLn $ "proxy handle: " ++ prHost ++ ":" ++ prPort ++ " onclose"
  register onClose

  lift $ do
    modifyMVar_ prSockMap $
      return . M.insert sockId (PC.fromInput fromL2CQ,
                                PC.toOutput toC2LQ, onClose)

    -- XXX: shall we run this in another thread?
    runEffect $ yield (Connect sockId prHost prPort) >-> toServerQ

    -- Start threaded recv/send loop on the queue
    -- The loop will be interrupted and stopped by disconn's calling seal
    t1 <- async $ do
      runEffect $ PC.fromInput fromC2LQ >-> toLocal
      putStrLn $ "proxyReq loop t1 done, C2LQ closed"
    t2 <- async $ do
      runEffect $ fromLocal >-> PC.toOutput toL2CQ
      putStrLn $ "proxyReq loop t2 done, fromLocal has no data"
    waitAny [t1, t2]
    return ()

