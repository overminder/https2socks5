module Socks5 where

import Control.Applicative
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Binary as A
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Data.Word
import qualified Data.Char as Char
import qualified Data.List as List
import qualified Data.Serialize as S
import Pipes
import Pipes.Safe
import Pipes.Parse
import qualified Pipes.Attoparsec as PA

-- XXX: endianess
fromSocksResp :: Bool -> Word32 -> Word16 -> Producer B.ByteString IO ()
fromSocksResp isSucc host port = do
  yield $ B.pack [5, 0, 0, 1]
  yield $ S.runPut $ S.put host *> S.put port

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

-- XXX: endianess
itoaPure :: Word32 -> B.ByteString
itoaPure w32 = BC8.pack $ List.intercalate "." $ map show xs
 where
  xs = B.unpack $ S.runPut (S.put w32)

parseSocks5ConnReq :: A.Parser (B.ByteString, Word16)
parseSocks5ConnReq = do
  protocolVersion
  A.word8 1 -- command: conn
  A.word8 0 -- reserved
  addrType <- A.anyWord8
  dstHost <- case addrType of
    1 -> itoaPure <$> A.anyWord32be
    3 -> do
      domainNameLen <- fromIntegral <$> A.anyWord8
      A.take domainNameLen
    4 -> error "parseSocks5ConnReq: ipv6 not supported"
  dstPort <- A.anyWord16be
  return (dstHost, dstPort)
 where
  protocolVersion = A.word8 5

socks5Handshake (toPeer, fromPeer) = do
  (req, fromPeer') <- (`runStateT` fromPeer) $ do
    PA.parse parseSocks5Init
    lift $ runEffect $ replySocks5Init >-> toPeer
    Right (_, req) <- PA.parse parseSocks5ConnReq
    return req
  return (req, fromPeer')

