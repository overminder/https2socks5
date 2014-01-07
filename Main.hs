import qualified Config
import Control.Applicative
import Control.Concurrent.Async
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Data.Serialize
import Data.Word
import Pipes
import Pipes.Safe
import Pipes.Parse
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Binary as PB
import qualified Pipes.Concurrent as P
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Pipes.Network.TCP.Safe as T
import qualified Pipes.Network.TCP.TLS as S
import Network.Socket
import Network.Simple.TCP.TLS

kProxyHost = Config.proxyHost
kProxyPort = Config.proxyPort

data ProxyRequest
  = ProxyRequest {
    prHost :: Either Word32 B.ByteString,
    prPort :: Word16
  }
  deriving (Show)

handleSocks5Request :: Socket -> IO ()
handleSocks5Request peer = (`evalStateT` peerInput) $ do
  PA.parse parseSocks5Init
  liftIO $ runEffect $ replySocks5Init >-> peerOutput
  Right (_, req) <- PA.parse parseSocks5ConnReq
  liftIO $ print req
  runSafeT $ T.connect kProxyHost kProxyPort $ \ (proxyPeer, _) -> do
    let
      proxyOutput = T.toSocket proxyPeer
      proxyInput = T.fromSocket proxyPeer 4096
    liftIO $ do
      runEffect $ httpProxyReq req >-> proxyOutput
      runEffect $ proxyInput >-> checkProxyConnOk

      print $ "Start splicing for " ++ show req ++ " sock: " ++ show peer
      -- Start splicing
      w1 <- async $ do
        runEffect $ socks5TellConnSuccess 0 0 >-> peerOutput
        runEffect $ peerInput >-> proxyOutput
      runEffect $ proxyInput >-> peerOutput
      wait w1
    return ()
  return ()
 where
  peerInput = T.fromSocket peer 4096
  peerOutput = T.toSocket peer
  httpProxyReq req = do
    let
      Right host = prHost req
    yield $ BC8.pack "CONNECT "
    yield host
    yield $ BC8.pack (":" ++ show (prPort req))
    yield $ BC8.pack " HTTP/1.1 \r\n\r\n"

  checkProxyConnOk = do
    line <- await -- XXX: really do we read in line?
    liftIO $ print $ "proxy reply: " ++ show line

socks5TellConnSuccess :: Word32 -> Word16 -> Producer B.ByteString IO ()
socks5TellConnSuccess host port = do
  yield $ B.pack [5, 0, 0, 1]
  PB.encode host
  PB.encode port

parseSocks5Init :: A.Parser ()
parseSocks5Init = do
  protocolVersion
  n <- fromIntegral <$> nMethods
  methods n
  return ()
 where
  protocolVersion = A.word8 5
  nMethods = A.anyWord8
  methods n = A.take n

replySocks5Init :: Producer B.ByteString IO ()
replySocks5Init = do
  yield $ B.pack [5, 0] -- Ver(5), no auth(0)

parseSocks5ConnReq :: A.Parser ProxyRequest
parseSocks5ConnReq = do
  protocolVersion
  A.word8 1 -- command: conn
  A.word8 0 -- reserved
  addrType <- A.anyWord8
  dstHost <- case addrType of
    1 -> Left <$> A.anyWord32be
    3 -> do
      domainNameLen <- fromIntegral <$> A.anyWord8
      Right <$> A.take domainNameLen
    4 -> error "parseSocks5ConnReq: ipv6 not supported"
  dstPort <- A.anyWord16be
  return $ ProxyRequest dstHost dstPort
 where
  protocolVersion = A.word8 5

main = T.withSocketsDo $ do
  -- Socks5 accepter
  runSafeT $ T.serve (T.Host "127.0.0.1") "1080" $ \ (peer, peerAddr) -> do
    putStrLn $ show peerAddr ++ " connected"
    handleSocks5Request peer
    putStrLn $ show peerAddr ++ "'s request handling is done"

