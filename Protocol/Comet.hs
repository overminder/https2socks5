{-# LANGUAGE RecordWildCards, OverloadedStrings, NoMonomorphismRestriction #-}
module Protocol.Comet (
  serve,
  connectAsFetcher,
  connectAsSender,
  ConnectOpt(..),
  ServeOpt(..),
) where

-- Implements http duplex streaming using long-polling

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Applicative
import Control.Exception
import Control.Monad
import Control.Monad.Identity
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Network.URI
import Pipes
import Pipes.Safe
import qualified Pipes.Attoparsec as PA
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Pipes.Concurrent as PC
import qualified Data.Map as M
import System.Timeout
import Data.String (IsString, fromString)

import qualified HttpType as H
import MyKey
import PipesUtil

data Message
  = Send B.ByteString
  | SendOk
  | Poll Int -- timeout
  | PollTimeout
  deriving (Show, Eq)

fromMessage :: Monad m => Message -> Producer B.ByteString m ()
fromMessage msg = case msg of
  Send bs     -> fromWord32be 1 *> fromNetBS bs
  SendOk      -> fromWord32be 2
  Poll us     -> fromWord32be 3 *> fromWord32be us
  PollTimeout -> fromWord32be 4

parseMessage :: A.Parser Message
parseMessage = do
  tag <- A.anyWord32be
  case tag of
    1 -> Send <$> parseNetBS
    2 -> pure SendOk
    3 -> Poll . fromIntegral <$> A.anyWord32be
    4 -> pure PollTimeout

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
serve opt@(ServeOpt {..}) (fromPeer, toPeer) (prod, cons)
  = (`evalStateT` fromPeer) $ serveLoop opt toPeer (prod, cons)

serveLoop opt@(ServeOpt {..}) toPeer (prod, cons) = do
  Right (_, H.Message {..}) <- PA.parse H.parseRequest
  if serverCheckAuth msgHeaders
    then do
      let Right msg = A.parseOnly parseMessage msgBody
      case msg of
        Send bs -> do
          lift $ runEffect $ do
            yield bs >-> cons
            fromRespMsg SendOk >-> toPeer
          serveLoop opt toPeer (prod, cons)

        Poll timeoutus -> do
          mbBs <- liftIO $ timeout timeoutus $ next prod
          case mbBs of
            Nothing -> do -- Timeout
              lift $ runEffect $ fromRespMsg PollTimeout >-> toPeer
              serveLoop opt toPeer (prod, cons)
            Just (Right (bs, prod')) -> do
              lift $ runEffect $ (fromRespMsg $ Send bs) >-> toPeer
              serveLoop opt toPeer (prod', cons)

        _ -> error $ "Comat.serve: unexpected message: " ++ show msg
    else do
      liftIO $ throwIO $ userError "Auth failed"
 where
  fromRespMsg msg = H.fromMessage $ H.mkResponse 200 "OK" M.empty
                                       (runBSProducer (fromMessage msg))

connectAsFetcher :: ConnectOpt -> ( Producer B.ByteString IO ()
                                  , Consumer B.ByteString IO ()
                                  ) -> Consumer B.ByteString IO () -> IO ()
connectAsFetcher (ConnectOpt {..}) (fromPeer, toPeer) cons = do
  let
    headers = M.fromList [ (httpHeaderKeyName, mySecretKey)
                         , ("Host", coHost)
                         ]
  (`evalStateT` fromPeer) $ fetchLoop headers toPeer cons

fetchLoop headers toPeer cons = do
  lift $ runEffect $ fromReqMsg headers (Poll 5000000) >-> toPeer
  Right (_, H.Message {..}) <- PA.parse H.parseResponse
  let Right msg = A.parseOnly parseMessage msgBody
  case msg of
    Send bs -> do
      lift $ runEffect $ yield bs >-> cons
      fetchLoop headers toPeer cons
    PollTimeout ->
      fetchLoop headers toPeer cons
    _ -> error $ "fetchLoop: unexpected msg: " ++ show msg

connectAsSender :: ConnectOpt -> ( Producer B.ByteString IO ()
                                 , Consumer B.ByteString IO ()
                                 ) -> Producer B.ByteString IO () -> IO ()
connectAsSender (ConnectOpt {..}) (fromPeer, toPeer) prod = do
  let
    headers = M.fromList [ (httpHeaderKeyName, mySecretKey)
                         , ("Host", coHost)
                         ]
  (`evalStateT` fromPeer) $ sendLoop headers toPeer prod

sendLoop headers toPeer prod = do
  Right (bs, prod') <- lift $ next prod
  lift $ runEffect $ fromReqMsg headers (Send bs) >-> toPeer
  _ <- PA.parse H.parseResponse
  sendLoop headers toPeer prod'

fromReqMsg hs msg = H.fromMessage hMsg
 where
  body = runBSProducer (fromMessage msg)
  hMsg = H.mkRequestPathHeader H.POST "/" hs body


serverCheckAuth m = case M.lookup httpHeaderKeyName m of
  Just k | k == mySecretKey -> True
  _ -> False

runBSProducer = B.concat . runIdentity . accumProd
