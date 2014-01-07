{-# LANGUAGE OverloadedStrings #-}

import qualified Config
import Control.Applicative
import Crypto.Random.AESCtr -- random
import Control.Monad.State.Strict
import qualified Data.ByteString as B
import Network.TLS
import Network.TLS.Extra
import Network.Socket
import qualified Network.Socket.ByteString as SB
import Pipes
import qualified Pipes.Network.TCP as PT
import qualified Pipes.Network.TCP.TLS as PTL
import qualified Pipes.Attoparsec as PA
import System.IO

import HttpType

socketToBackend s = Backend {
  backendFlush = return (),
  backendClose = close s,
  backendSend = SB.sendAll s,
  backendRecv = \ n -> recvAll n []
}
 where
  recvAll n out = do
    bs <- SB.recv s n
    let
      out' = bs : out
    case n - B.length bs of
      0  -> return . B.concat . reverse $ out'
      n' -> recvAll n' out'

myTlsParam = defaultParamsClient {
  pCiphers = [ cipher_RC4_128_MD5, cipher_RC4_128_SHA1, cipher_AES128_SHA1
             , cipher_AES256_SHA1, cipher_AES128_SHA256
             , cipher_AES256_SHA256]
}

main = PT.withSocketsDo $ do

  rng <- makeSystem

  PT.connect Config.proxyHost Config.proxyPort $ \ (peer, _) -> do
    runEffect $ do
      let
        proxyConnReq = mkRequest CONNECT "https://www.google.com:443/" ""
      fromRequest proxyConnReq >-> PT.toSocket peer
    resp1 <- (`evalStateT` (PT.fromSocket peer 4096))
             (PA.parse (parseResponse (return B.empty)))
    print resp1

    -- TLS conn
    let
      peerBackend = socketToBackend peer
    ctx <- contextNew peerBackend myTlsParam rng
    handshake ctx
    let
      tlsIn  = PTL.fromContext ctx
      tlsOut = PTL.toContext ctx

    runEffect $ do
      let
        httpConnReq = mkRequest GET "https://www.google.com:443/" ""
      fromRequest httpConnReq >-> tlsOut

    resp2 <- (`evalStateT` tlsIn)
             (PA.parse (parseResponse undefined))
    print resp2

