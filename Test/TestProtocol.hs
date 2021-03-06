import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Control.Applicative
import qualified Control.Concurrent as C
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Identity
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Pipes
import qualified Pipes.Concurrent as PC

import Protocol.Comet
import Protocol.Chunked (StreamDirection (..))
import PipesUtil
import qualified HttpType as H

newtype SomeChunks = SomeChunks { deChunk :: [B.ByteString] }
  deriving (Show)

instance Arbitrary B.ByteString where
  arbitrary = BU8.fromString <$> arbitrary

instance Arbitrary SomeChunks where
  arbitrary = do
    n <- elements [1, 5, 10]
    SomeChunks <$> replicateM n arbitrary

instance Arbitrary StreamDirection where
  arbitrary = do
    wat <- arbitrary
    if wat
      then return ToClient
      else return ToServer

testStreaming direction (SomeChunks bs) = monadicIO doPreparation
 where
  doPreparation = run $ do
    [(localSend, remoteRecv),
     (remoteSend, localRecv),
     (toPipe, fromPipe),     -- (fetcher) read by server and sent to client
     (toPipe', fromPipe'),   -- (sender) writen by server
     (toPipe'', fromPipe'')] -- (sender) read by client and sent to server
                             -- (fetcher) writen by client
      <- replicateM 5 $ PC.spawn PC.Unbounded
    tServer <- async $
      serve undefined
            (PC.fromInput remoteRecv, PC.toOutput remoteSend)
            (PC.fromInput fromPipe, PC.toOutput toPipe')
    tClient <- async $ case direction of
      ToServer -> connectAsSender undefined
                                         (PC.fromInput localRecv,
                                          PC.toOutput localSend)
                                         (PC.fromInput fromPipe'')
      ToClient -> connectAsFetcher undefined
                                          (PC.fromInput localRecv,
                                           PC.toOutput localSend)
                                          (PC.toOutput toPipe'')
    case direction of
      ToServer -> do
        runEffect $ mapM_ yield bs >-> PC.toOutput toPipe''
        bs' <- accumProd $ PC.fromInput fromPipe'
        return $ bs' == bs
      ToClient -> do
        runEffect $ mapM_ yield bs >-> PC.toOutput toPipe
        bs' <- accumProd $ PC.fromInput fromPipe''
        return $ bs' == bs

testParserToPipe :: [B.ByteString] -> Bool
testParserToPipe xs = xs == xs'
 where
  xs' = runIdentity $
    accumProd $ mapM_ H.fromChunk xs >-> parserToPipe H.parseChunk

testBufferedPipe xss = monadicIO doPreparation
 where
  doPreparation :: PropertyM IO Bool
  doPreparation = run $ do
    let
      slowTransmit x = (liftIO $ C.threadDelay 1000) >> yield x
      fastTransmit x = yield x
      xs = B.concat xss
      yields = each xss
      slows = bufferedPipe 10 2000 yields
      fasts = bufferedPipe 100 500 yields
    xs' <- B.concat <$> accumProd slows
    xs'' <- B.concat <$> accumProd fasts
    return $ xs == xs' && xs == xs''

main = quickCheck testStreaming

