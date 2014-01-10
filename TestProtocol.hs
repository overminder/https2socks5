import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import Control.Applicative
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Writer
import Test.QuickCheck
import Test.QuickCheck.Monadic
import Pipes
import qualified Pipes.Concurrent as PC

import Protocol

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
      serveChunkedStreamer undefined
                           (PC.fromInput remoteRecv, PC.toOutput remoteSend)
                           (PC.fromInput fromPipe, PC.toOutput toPipe')
    tClient <- async $ case direction of
      ToServer -> connectChunkedAsSender undefined
                                         (PC.toOutput localSend)
                                         (PC.fromInput fromPipe'')
      ToClient -> connectChunkedAsFetcher undefined
                                          (PC.fromInput localRecv,
                                           PC.toOutput localSend)
                                          (PC.toOutput toPipe'')
    case direction of
      ToServer -> do
        runEffect $ mapM_ yield bs >-> PC.toOutput toPipe''
        bs' <- aggregateResult $ PC.fromInput fromPipe'
        return $ bs' == bs
      ToClient -> do
        runEffect $ mapM_ yield bs >-> PC.toOutput toPipe
        bs' <- aggregateResult $ PC.fromInput fromPipe''
        return $ bs' == bs

aggregateResult :: Monad m => Producer a (WriterT [a] m) () -> m [a]
aggregateResult prod = execWriterT $ runEffect $ prod >-> forever aggr
 where
  aggr = await >>= lift . tell . (:[])

main = quickCheck testStreaming

