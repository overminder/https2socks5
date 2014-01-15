-- This is used to run a long-running test

import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import qualified Data.Map as M
import Pipes
import Pipes.Safe
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T
import System.IO.Error

import qualified HttpType as H
import ProxyHandler
import MyKey
import PipesUtil

runTest = do
  mSockMap <- newMVar M.empty
  mts <- newMVar []

  (toC2SQ, fromC2SQ) <- PC.spawn PC.Unbounded
  (toS2CQ, fromS2CQ) <- PC.spawn PC.Unbounded

  mkUniq <- do
    x <- newMVar 1
    return $ do
      modifyMVar x $ \ i -> return (i + 1, i)

  serverThread <- async $ runEffect $ for (PC.fromInput fromC2SQ) $
    \ msg -> lift $ do
      serverHandleClientReq msg mSockMap (PC.toOutput toS2CQ)

  mkClientThread <- async $ replicateM_ 100 $ do
    threadDelay (100000) -- ever 1 seconds
    i <- mkUniq
    let client = mkClient i (PC.toOutput toC2SQ)
    t <- async client
    modifyMVar_ mts $ return . (t:)
    return ()

  mapM_ wait [serverThread, mkClientThread]
  ts <- withMVar mts return
  mapM_ wait ts

host = "127.0.0.1"
mkPort i = show (i + 10000)
mkToSend i = map (BC8.pack . show) [1..(i + 1000)]

mkClient i toC2S = do
  let port = mkPort i
      toSend = mkToSend i

  -- simply listen on somewhere and connect to that endpoint.
  listenThread <- async $ do
    mOut <- newMVar []
    let
      toOut = forever $ do
        x <- await
        liftIO $ modifyMVar_ mOut $ return . (x:)
    tryIOError $ runSafeT $ runEffect $
      T.fromServe 4096 (T.Host host) port >-> toOut
    withMVar mOut $ return . B.concat . reverse

  threadDelay 1500000 -- wait for the listener to start

  connThread <- async $ do
    runEffect $ do
      -- conn
      yield (Connect i host port) >-> toC2S

      liftIO $ threadDelay 1000000 -- wait for the connection to be established

      -- conn ok
      --[ConnResult _ True _ _] <- fromS2C

      -- Send and disconn
      each (map (Data i) toSend) >-> toC2S

      --liftIO $ threadDelay 1000000 -- wait for things to be sent

      yield (Disconn i "") >-> toC2S

  bs <- wait listenThread
  let toSends = B.concat toSend
  if toSends == bs
    then putStrLn $ show i ++ " is ok."
    else putStrLn $ show i ++ " is NOT ok: " ++ show (B.length toSends) ++
                    ", got " ++ show (B.length bs)

main = T.withSocketsDo $ runTest
