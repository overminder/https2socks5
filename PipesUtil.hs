module PipesUtil where

import Control.Applicative
import Control.Monad
import Control.Concurrent hiding (yield)
import Control.Concurrent.Async
import Control.Concurrent.STM
import qualified Data.Attoparsec as A
import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU8
import qualified Data.Serialize as S
import Pipes
import qualified Pipes.Concurrent as PC
import System.Timeout

-- XXX: not safe at all since parse exceptions and leftovers are omitted.
parserToPipe :: Monad m => A.Parser a -> Pipe B.ByteString a m ()
parserToPipe parseA = loop (A.parse parseA)
 where
  loop cont = do
    bs <- await
    if B.null bs -- Since null bs will choke attoparsec's parser
      then loop cont
      else handle (cont bs)

  handle result = case result of
    A.Fail leftOver ctx emsg -> error $
      "parserToPipe: fail with " ++ show leftOver ++ show ctx ++ show emsg
    A.Partial cont' -> loop cont'
    A.Done leftOver a -> do
      yield a
      handle (A.parse parseA leftOver)

pipeWith :: Monad m => (a -> b) -> Pipe a b m ()
pipeWith f = for cat (yield . f)

pipeWithM :: Monad m => (a -> m b) -> Pipe a b m ()
pipeWithM mf = for cat (lift . mf >=> yield)

-- XXX: this is right?
pipeWithP :: Monad m => (a -> Producer b m ()) -> Pipe a b m ()
pipeWithP p = do
  a <- await
  let
    loopWith wat = do
      eiB <- lift $ next wat
      case eiB of
        Left _ -> pipeWithP p
        Right (b, p') -> yield b >> loopWith p'
  loopWith (p a)

accumProd :: Monad m => Producer a m () -> m [a]
accumProd = go []
 where
  go out p = do
    ei <- next p
    case ei of
      Left _ -> return . reverse $ out
      Right (a, p') -> go (a:out) p'

-- Provides a buffering for small bs producer as well as dropping empty str
-- XXX due to the fact that maxDelayMs is used, the pipe might be blocked
-- for a while AND several threads are involved.
-- XXX2 No manual error handling is done here. We rely on ghc's GC to
-- kill the thread. Though we do avoid infi loop by checking the result of
-- PC.recv..
-- XXX: since async is used, it's impossible to run the pipe in places
-- other than IO with the wanted behavior (polling on both the input and the
-- output)
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
      -- Don't send if xs is empty
      sendAll xs = case xs of
        [] -> return ()
        _ -> yield (B.concat . reverse $ xs) >-> PC.toOutput o'
    mbBs <- timeout maxDelayMs . atomically . PC.recv $ i
    case mbBs of
      Nothing -> do -- timeout
        runEffect $ sendAll currBs
        recvLoop i o' [] 0
      Just Nothing -> runEffect $ sendAll currBs -- prod closed
      Just (Just bs) -> case B.null bs of
        True -> recvLoop i o' currBs currLen -- Ignore empty bs
        _ -> let totalLen = currLen + B.length bs
              in if totalLen > bufSiz
                   then (runEffect $ sendAll (bs : currBs)) *>
                        recvLoop i o' [] 0
                   else recvLoop i o' (bs : currBs) totalLen

mkIdempotent m = do
  mv <- newMVar m
  return $ do
    todo <- swapMVar mv (return ())
    todo

logWith title = forever $ do
  wat <- await
  liftIO $ putStr title >> print wat
  yield wat

runGet' g bs = case S.runGet g bs of
  Right a -> a
  Left e -> error $ show e

parseNetString :: A.Parser String
parseNetString = BU8.toString <$> parseNetBS

parseNetBS :: A.Parser B.ByteString
parseNetBS = do
  len <- fromIntegral . runGet' S.getWord32be <$> A.take 4
  A.take len

fromNetBS :: Monad m => B.ByteString -> Producer B.ByteString m ()
fromNetBS bs = do
  yield $ S.runPut $ S.putWord32be (fromIntegral $ B.length bs)
  yield bs

fromNetString :: Monad m => String -> Producer B.ByteString m ()
fromNetString = fromNetBS . BU8.fromString

fromWord32be i = yield (S.runPut $ S.putWord32be (fromIntegral i))

