{-# LANGUAGE RecordWildCards, OverloadedStrings, NoMonomorphismRestriction #-}
module Protocol where

import Control.Concurrent.Async
import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Network.URI
import Pipes
import Pipes.Safe
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Network.TCP.Safe as T
import qualified Data.Map as M

import qualified HttpType as H

data StreamDirection
  = ToClient
  | ToServer
  deriving (Show)

streamDirHeader = "X-StreamDirection"

data ConnectOpt
  = ConnectOpt {
    coHttpProxy :: Maybe (String, String),
    coServerUri :: URI,
    coUseTls :: Bool,
    coSecret :: (String, String)
  }

data ServeOpt
  = ServeOpt {
    soListenOn :: (String, String),
    soSecret :: (String, String)
  }

serveChunkedStreamer (ServeOpt {..}) prod cons =
  T.serve (T.Host host) port $ \ (peer, peerAddr) -> do
    let fromPeer = T.fromSocket peer 4096
        toPeer = T.toSocket peer
    (startLine, headers) <- (`evalStateT` fromPeer)
                            ((,) <$> (PA.parse H.parseReqStart)
                                 <*> (PA.parse H.parseHeaders))
    if serverCheckAuth headers
      then case getStreamAction headers of
        ToServer -> runEffect $ dechunkify fromPeer >-> cons
        ToClient -> runEffect $
          (H.fromStartLine mkRespStartLine *>
           H.fromHeaders mkHeader *>
           chunkify prod) >-> toPeer
      else do
        throwIO $ userError $ "Auth failed for " ++ show peerAddr
 where
  (host, port) = soListenOn

getStreamAction = undefined
serverCheckAuth = undefined

mkReqStartLine = H.ReqLine H.POST "/" H.HTTP11
mkRespStartLine = H.RespLine H.HTTP11 200 "OK"
mkHeader = M.singleton "Transfer-Encoding" "chunked"

connectChunkedStreamer (ConnectOpt {..}) prod cons = do
  let
    (host, port) = case coHttpProxy of
      Nothing -> undefined
      Just (host, port) -> (host, port)
    establishProxyConn peer = return ()
    onConn streamDir (peer, _) = do
      let fromPeer = T.fromSocket peer 4096
          toPeer = T.toSocket peer
          headers = M.singleton streamDirHeader (BC8.pack . show $ streamDir)
          startLine = undefined
      establishProxyConn peer
      runEffect $ do
        H.fromStartLine (mkReqStartLine coSecret) >-> toPeer
        H.fromHeaders headers >-> toPeer
      case streamDir of
        ToClient -> runEffect $
          dechunkify fromPeer >-> cons
        ToServer -> runEffect $ chunkify prod >-> toPeer
  t1 <- async $ runSafeT $ T.connect host port (onConn ToClient)
  runSafeT $ T.connect host port (onConn ToServer)
  wait t1

dechunkify rawBs = (parsed >> return ()) >-> pipe
 where
  parsed = PA.parseMany H.parseChunk rawBs
  pipe = forever $ do
    (_, chunk) <- await
    yield chunk

chunkify bs = for bs H.fromChunk

-- Provides a buffering for small bs producer
-- XXX due to the fact that maxDelayMs is used, the pipe might be blocked
-- for a while AND several threads are involved.
bufferedPipe :: Int -> Int -> Producer B.ByteString IO () ->
                Producer B.ByteString IO ()
bufferedPipe bufSiz maxDelayMs prod = do
 where
  prod' = do
    (o, i) <- PC.spawn PC.Unbounded
    (o', i') <- PC.spawn PC.Single
    t1 <- async $ runEffect $ prod >-> o
    async (recvLoop i o' [] 0)
  recvLoop i o' currBs currLen = do
    mbBs <- timeout maxDelayMs . atomically . recv $ i
    case mbBs of
      Nothing -> do
        let
          allBs = B.concat . reverse $ currBs
        yield allBs >-> o'
        recvLoop i o' [] 0
      Just bs
        | currLen + B.length bs > bufSiz -> 
        | otherwise ->
