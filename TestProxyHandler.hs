{-# LANGUAGE OverloadedStrings, NoMonomorphismRestriction #-}

import Test.QuickCheck
import Test.QuickCheck.Monadic
import Control.Applicative
import Control.Monad
import Control.Monad.Identity
import Control.Concurrent hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.Async
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Pipes
import Pipes.Safe
import qualified Pipes.Prelude as P
import qualified Pipes.Concurrent as PC
import Network.Socket
import Test.QuickCheck.Instances

import ProxyHandler
import PipesUtil

arb = arbitrary

instance Arbitrary Message where
  arbitrary = do
    tag <- elements [1, 2, 3, 4]
    case tag of
      1 -> Connect <$> arb <*> arb <*> arb
      2 -> ConnResult <$> arb <*> arb <*> arb <*> arb
      3 -> Data <$> arb <*> arb
      4 -> Disconn <$> arb <*> arb

main = quickCheck testCodecMessage

testCodecMessage m = if m == m'
  then True
  else error $ show "fail: given " ++ show m ++ " but got " ++ show m'
 where
   Right (m', _) = runIdentity $ next $
    fromMessage m >-> parserToPipe parseMessage

testServer = do
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded
  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded

  serverSockMap <- newMVar M.empty

  ts <- async $ do
    runEffect $ for (PC.fromInput fromC2SQ) $ \ msg -> liftIO $ do
      putStrLn $ "server got msg " ++ show msg
      serverHandleClientReq msg serverSockMap (PC.toOutput toS2CQ)
    putStrLn "server handle thread done"

  putStrLn $ "client sending conn msg"
  runEffect $ yield (Connect 1 "127.0.0.1" "1234") >-> PC.toOutput toC2SQ
  Just cmsg1 <- atomically $ PC.recv fromS2CQ
  putStrLn $ "client got reply: " ++ show cmsg1

  putStrLn $ "start send/recv loop"
  forever $ do
    runEffect $ yield (Data 1 "HAI\r\n") >-> PC.toOutput toC2SQ
    Just cmsg2 <- atomically $ PC.recv fromS2CQ
    putStrLn $ "client got reply: " ++ show cmsg2

  mapM_ wait [ts]

testClient = do
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded
  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded

  (toC2LQ, fromC2LQ) <- PC.spawn PC.Unbounded
  (toL2CQ, fromL2CQ) <- PC.spawn PC.Unbounded

  clientSockMap <- newMVar (M.singleton 1 (PC.fromInput fromL2CQ,
                                           PC.toOutput toC2LQ,
                                           return()))
  clientMkUniq <- do
    x <- newMVar 1
    return $ do
      modifyMVar x $ \ i -> return (i + 1, i)

  let
    clientState = ClientState (PC.toOutput toC2SQ) clientSockMap

  tc <- async $ do
    runEffect $ for (PC.fromInput fromS2CQ) $ \ msg -> liftIO $ do
      putStrLn $ "client got msg " ++ show msg
      clientHandleServerResp msg clientState
    putStrLn "client handle thread done"

  putStrLn "send proxy req to client (assuming it's done)"
  putStrLn "send conn ok from server to client"
  runEffect $ yield (ConnResult 1 True 0 0) >-> PC.toOutput toS2CQ

  tsend <- async $ do
    putStrLn "try send some to remote"
    runEffect $ yield "To remote" >-> PC.toOutput toL2CQ
    runEffect $ PC.fromInput fromC2SQ >-> P.show >-> P.stdoutLn

  trecv <- async $ do
    putStrLn "send remote data to local"
    runEffect $ yield (Data 1 "Hello") >-> PC.toOutput toS2CQ
    runEffect $ PC.fromInput fromC2LQ >-> P.show >-> P.stdoutLn

  mapM_ wait [tc, tsend, trecv]


testBoth = do
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded
  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded

  serverSockMap <- newMVar M.empty
  clientSockMap <- newMVar M.empty
  clientMkUniq <- do
    x <- newMVar 1
    return $ do
      modifyMVar x $ \ i -> return (i + 1, i)

  let
    clientState = ClientState (PC.toOutput toC2SQ) clientSockMap

  tc <- async $ do
    runEffect $ for (PC.fromInput fromS2CQ) $ \ msg -> liftIO $ do
      putStrLn $ "client got msg " ++ show msg
      clientHandleServerResp msg clientState
    putStrLn "client handle thread done"

  ts <- async $ do
    runEffect $ for (PC.fromInput fromC2SQ) $ \ msg -> liftIO $ do
      putStrLn $ "server got msg " ++ show msg
      serverHandleClientReq msg serverSockMap (PC.toOutput toS2CQ)
    putStrLn "server handle thread done"

  (toC2LQ, fromC2LQ) <- PC.spawn PC.Unbounded
  (toL2CQ, fromL2CQ) <- PC.spawn PC.Unbounded
  let
    proxyReq = ProxyReq (PC.toOutput toC2LQ)
                        (PC.fromInput fromL2CQ)
                        "127.0.0.1"
                        "1234"
                        clientMkUniq

  -- New lets try to make a proxy req
  tp <- async $ do
    runSafeT $ clientHandleSocksReq proxyReq clientState
    putStrLn "proxy req handle thread done"

  -- and send something!
  forever $ do
    runEffect $ yield "Hello, World!\r\n" >-> PC.toOutput toL2CQ
    Just got <- atomically $ PC.recv fromC2LQ
    B.putStr got
    putStrLn ""

  mapM_ wait [tc, ts, tp]

