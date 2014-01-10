{-# LANGUAGE RecordWildCards, OverloadedStrings, NoMonomorphismRestriction #-}
module Protocol where

import Control.Concurrent.Async
import Control.Concurrent.STM
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
import qualified Pipes.Concurrent as PC
import qualified Pipes.Network.TCP.Safe as T
import qualified Data.Map as M
import System.Timeout
import Data.String (IsString, fromString)

import qualified HttpType as H
import MyKey

data StreamDirection
  = ToClient
  | ToServer
  deriving (Show, Read)

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

serveChunkedStreamer (ServeOpt {..}) (fromPeer, toPeer) (prod, cons) = do
  (Right (_, startLine), Right (_, headers))
    <- (`evalStateT` fromPeer)
       ((,) <$> (PA.parse H.parseReqStart) <*> (PA.parse H.parseHeaders))
  if serverCheckAuth headers
    then case getStreamAction headers of
      ToServer -> runEffect $ dechunkify fromPeer >-> cons
      ToClient -> runEffect $
        (H.fromStartLine mkRespStartLine *>
         H.fromHeaders mkChunkHeader *>
         chunkify prod) >-> toPeer
    else do
      throwIO $ userError "Auth failed"

connectChunkedAsFetcher (ConnectOpt {..}) (fromPeer, toPeer) cons = do
  runEffect $ H.fromStartLine mkReqStartLine >-> toPeer
  let
    headers = M.fromList [ ("Content-Length", "0")
                         , (httpHeaderKeyName, mySecretKey)
                         , (streamDirHeader, fromString (show ToClient))
                         ]
  -- s->c, in this case we should NOT send te:chunk.
  runEffect $ H.fromHeaders headers >-> toPeer
  (`evalStateT` fromPeer) $ do
    PA.parse (H.parseRespStart *> H.parseHeaders)
    forever $ do
      Right (_, bs) <- PA.parse H.parseChunk
      liftIO $ runEffect $ yield bs >-> cons

connectChunkedAsSender  (ConnectOpt {..}) toPeer prod = do
  runEffect $ H.fromStartLine mkReqStartLine >-> toPeer
  let
    headers = M.fromList [ ("Transfer-Encoding", "chunked")
                         , (httpHeaderKeyName, mySecretKey)
                         , (streamDirHeader, fromString (show ToServer))
                         ]
  runEffect $ do
    H.fromHeaders headers >-> toPeer
    chunkify prod >-> toPeer

getStreamAction m = read . BC8.unpack $ m M.! streamDirHeader
serverCheckAuth m = case M.lookup httpHeaderKeyName m of
  Just k | k == mySecretKey -> True
  _ -> False

mkReqStartLine = H.ReqLine H.POST "/" H.Http11
mkRespStartLine = H.RespLine H.Http11 200 "OK"
mkChunkHeader = M.singleton "Transfer-Encoding" "chunked"
mkReqHeaders (k, v) = M.fromList [ (fromString k, fromString v)
                                 , "Content-Length", "0"
                                 ]
mkReqHeadersChunked (k, v)
  = M.insert (fromString k) (fromString v) mkChunkHeader


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
-- XXX2 No manual error handling is done here. We rely on ghc's GC to
-- kill the thread. Though we do avoid infi loop by checking the result of
-- PC.recv..
bufferedPipe :: Int -> Int -> Producer B.ByteString IO () ->
                Producer B.ByteString IO ()
bufferedPipe bufSiz maxDelayMs prod = prod'
 where
  prod' = do
    (o, i) <- liftIO $ PC.spawn PC.Unbounded
    (o', i') <- liftIO $ PC.spawn PC.Single
    t1 <- liftIO $ async $ runEffect $ prod >-> PC.toOutput o
    liftIO $ async (recvLoop i o' [] 0)
    PC.fromInput i'
  recvLoop i o' currBs currLen = do
    let 
      sendAll xs = yield (B.concat . reverse $ xs) >-> PC.toOutput o'
    mbBs <- timeout maxDelayMs . atomically . PC.recv $ i
    case mbBs of
      Nothing -> do -- timeout
        runEffect $ sendAll currBs
        recvLoop i o' [] 0
      Just Nothing -> return () -- prod is closed
      Just (Just bs) ->
        let totalLen = currLen + B.length bs
         in if totalLen > bufSiz
              then (runEffect $ sendAll (bs : currBs)) *>
                   recvLoop i o' [] 0
              else recvLoop i o' (bs : currBs) totalLen

