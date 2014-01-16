{-# LANGUAGE RecordWildCards, OverloadedStrings, NoMonomorphismRestriction #-}
module Protocol.Chunked where

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
import qualified Data.Map as M
import System.Timeout
import Data.String (IsString, fromString)

import qualified HttpType as H
import MyKey
import PipesUtil

data StreamDirection
  = ToClient
  | ToServer
  deriving (Show, Read)

streamDirHeader = "X-StreamDirection"

data ConnectOpt
  = ConnectOpt {
    coSecret :: (String, String),
    coHost :: B.ByteString
  }

data ServeOpt
  = ServeOpt {
    soSecret :: (String, String)
  }

serve :: ServeOpt -> ( Producer B.ByteString IO ()
                     , Consumer B.ByteString IO ()
                     ) ->
                     ( Producer B.ByteString IO ()
                     , Consumer B.ByteString IO ()
                     ) -> IO ()
serve (ServeOpt {..}) (fromPeer, toPeer) (prod, cons) = do
  ((Right (_, startLine), Right (_, headers)), fromPeer')
    <- (`runStateT` fromPeer)
       ((,) <$> (PA.parse H.parseReqStart) <*> (PA.parse H.parseHeaders))
  if serverCheckAuth headers
    then case getStreamAction headers of
      ToServer -> runEffect $ fromPeer' >-> parserToPipe H.parseChunk >-> cons
      ToClient -> runEffect $
        (H.fromStartLine mkRespStartLine *>
         H.fromHeaders mkChunkHeader *>
         prod >-> pipeWithP H.fromChunk) >-> toPeer
    else do
      throwIO $ userError "Auth failed"

connectAsFetcher :: ConnectOpt -> ( Producer B.ByteString IO ()
                                  , Consumer B.ByteString IO ()
                                  ) -> Consumer B.ByteString IO () -> IO ()
connectAsFetcher (ConnectOpt {..}) (fromPeer, toPeer) cons = do
  runEffect $ H.fromStartLine (mkReqStartLine H.GET) >-> toPeer
  let
    headers = M.fromList [ (httpHeaderKeyName, mySecretKey)
                         , (streamDirHeader, fromString (show ToClient))
                         , ("Host", coHost)
                         ]
  -- s->c, in this case we should NOT send te:chunk.
  runEffect $ H.fromHeaders headers >-> toPeer

  fromPeer' <- (`execStateT` fromPeer) $
    PA.parse (H.parseRespStart *> H.parseHeaders)
  runEffect $ fromPeer' >-> parserToPipe H.parseChunk >-> cons

connectAsSender :: ConnectOpt -> ( Producer B.ByteString IO ()
                                 , Consumer B.ByteString IO ()
                                 ) -> Producer B.ByteString IO () -> IO ()
connectAsSender  (ConnectOpt {..}) (_fromPeer, toPeer) prod = do
  runEffect $ H.fromStartLine (mkReqStartLine H.POST) >-> toPeer
  let
    headers = M.fromList [ ("Transfer-Encoding", "chunked")
                         , (httpHeaderKeyName, mySecretKey)
                         , (streamDirHeader, fromString (show ToServer))
                         , ("Host", coHost)
                         ]
  runEffect $ do
    H.fromHeaders headers >-> toPeer
    prod >-> pipeWithP H.fromChunk >-> toPeer

getStreamAction m = read . BC8.unpack $ m M.! streamDirHeader
serverCheckAuth m = case M.lookup httpHeaderKeyName m of
  Just k | k == mySecretKey -> True
  _ -> False

mkReqStartLine meth = H.ReqLine meth "/" H.Http11
mkRespStartLine = H.RespLine H.Http11 200 "OK"
mkChunkHeader = M.singleton "Transfer-Encoding" "chunked"
mkReqHeaders (k, v) = M.fromList [ (fromString k, fromString v)
                                 , "Content-Length", "0"
                                 ]
mkReqHeadersChunked (k, v)
  = M.insert (fromString k) (fromString v) mkChunkHeader


