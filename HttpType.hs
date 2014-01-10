{-# LANGUAGE OverloadedStrings, RecordWildCards, NoMonomorphismRestriction #-}

module HttpType where

import Control.Applicative
import Control.Monad
import qualified Data.CaseInsensitive as CI
import qualified Data.Char as Char
import Data.Attoparsec ((<?>))
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Char8 as AC8
import qualified Data.Map as M
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC8
import Network.URI
import Pipes
import Numeric (showHex)

type Headers = M.Map (CI.CI B.ByteString) B.ByteString

data HttpVersion
  = Http10
  | Http11
  deriving (Eq)

instance Show HttpVersion where
  show Http10 = "HTTP/1.0"
  show Http11 = "HTTP/1.1"

data StartLine
  = ReqLine {
    rqMethod :: Method,
    rqPath :: B.ByteString,
    slVer :: HttpVersion
  }
  | RespLine {
    slVer :: HttpVersion,
    rsStatCode :: Int,
    rsReason :: B.ByteString
  }
  deriving (Show, Eq)

data Method
  = GET
  | POST
  | CONNECT
  deriving (Show, Eq, Ord)

data Message
  = Message {
    msgStart :: StartLine,
    msgHeaders :: Headers,
    msgBody :: B.ByteString
  }
  deriving (Show, Eq)

-- This is for easy parsing of body
data TransferEncoding
  = ContentLength Int
  | Chunked
  | TillDisconn
  deriving (Show)

mkRequest :: Method -> String -> B.ByteString -> Message
mkRequest meth uriStr body = mkRequestURI meth uri body
 where
  Just uri = parseURI uriStr

mkRequestURI :: Method -> URI -> B.ByteString -> Message
mkRequestURI meth (URI {..}) body = Message {
  msgStart = ReqLine meth path Http11,
  msgHeaders = hostHeader,
  msgBody = body
}
 where
  hostHeader = M.singleton "Host" (mkHost uriAuthority)
  mkHost (Just (URIAuth {..})) = BC8.pack $ uriRegName ++ uriPort
  path = BC8.pack $ uriPath ++ uriQuery

mkLengthHeader body
  = M.singleton "Content-Length" (BC8.pack . show . B.length $ body)

mkResponse :: Int -> B.ByteString -> Headers -> B.ByteString -> Message
mkResponse code reason headers body = Message {
  msgStart = RespLine Http11 code reason,
  msgHeaders = headers,
  msgBody = body
}

fromStartLine (ReqLine meth path ver) = do
  yield . BC8.pack . show $ meth
  yield " "
  yield path
  yield " "
  yield . BC8.pack . show $ ver
  yield "\r\n"

fromStartLine (RespLine ver code reason) = do
  yield . BC8.pack . show $ ver
  yield " "
  yield . BC8.pack . show $ code
  yield " "
  yield reason
  yield "\r\n"

fromMessage' :: Monad m => Message ->
                (B.ByteString -> Producer B.ByteString m ()) ->
                Producer B.ByteString m ()
fromMessage' (Message {..}) bodyEncoder = do
  fromStartLine msgStart
  mapM_ fromHeader (M.toList msgHeaders)
  yield "\r\n"
  bodyEncoder msgBody

fromMessage msg@(Message {..}) = fromMessage' msg' yield
 where
  msg' = msg {
    msgHeaders = mkLengthHeader msgBody `M.union` msgHeaders
  }

fromMessageChunked chunkSize msg@(Message {..})
  = fromMessage' msg' (yieldChunked chunkSize)
 where
  msg' = msg {
    msgHeaders = M.insert "Transfer-Encoding" "chunked" msgHeaders
  }

fromHeader :: Monad m => (CI.CI B.ByteString, B.ByteString) ->
                         Producer B.ByteString m ()
fromHeader (name, val)
  = yield (CI.original name) *> yield ": " *> yield val *> yield "\r\n"

fromHeaders = mapM_ fromHeader . M.toList

parseReqStart :: A.Parser StartLine
parseReqStart
  = ReqLine <$> pMethod <* AC8.space
            <*> pPath <* AC8.space
            <*> pVer <* AC8.endOfLine
 where
  pPath = A.takeWhile (not . AC8.isSpace_w8) <?> "pPath"

parseRespStart :: A.Parser StartLine
parseRespStart
  = RespLine <$> pVer <* AC8.space
             <*> pStatCode <* AC8.space
             <*> pStatDetail <* AC8.endOfLine
 where
  pStatCode = AC8.decimal
  pStatDetail = A.takeWhile (not . AC8.isEndOfLine)

pMethod
  = (AC8.string "GET" *> return GET) <|>
    (AC8.string "POST" *> return POST) <|>
    (AC8.string "CONNECT" *> return CONNECT) <?> "pMethod"

parseRequest :: A.Parser B.ByteString -> A.Parser Message
parseRequest pBody = do
  startLine <- parseReqStart
  headers <- parseHeaders
  -- Check content-encoding or content-length
  body <- case bodyTransferEncoding headers of
    ContentLength len -> A.take len
    Chunked -> pChunked
    TillDisconn -> pBody
  return $ Message startLine headers body

parseMessage :: A.Parser B.ByteString -> A.Parser Message
parseMessage pBody = parseRequest pBody <|> parseResponse pBody

yieldChunked chunkSize bs
  | B.length bs == 0 = fromChunk bs
  | otherwise = fromChunk (B.take chunkSize bs)
             *> yieldChunked chunkSize (B.drop chunkSize bs)

fromChunk bs = do
  yield $ BC8.pack $ showHex (B.length bs) ""
  yield "\r\n"
  yield bs
  yield "\r\n"
    

-- pBody is used to parse the rest (or ignore it if we've issued
-- a CONNECT method on a http proxy.
-- So the http codec is actually stateful... And Netty's HttpCodec is
-- (amusingly) doing the right thing!
parseResponse :: A.Parser B.ByteString -> A.Parser Message
parseResponse pBody = do
  startLine <- parseRespStart
  headers <- parseHeaders
  -- Check content-encoding or content-length
  body <- case bodyTransferEncoding headers of
    ContentLength len -> A.take len
    Chunked -> pChunked
    TillDisconn -> pBody
  return $ Message startLine headers body
 where

pVer = (Http10 <$ AC8.string "HTTP/1.0")
   <|> (Http11 <$ AC8.string "HTTP/1.1")
   <?> "pVer"

parseHeaders :: A.Parser Headers
parseHeaders = M.fromList <$> pHeaders
 where
  pHeaders = (:) <$> (pHeader <* AC8.endOfLine) <*> pHeaders
             <|> [] <$ AC8.endOfLine
  pHeader = do
    mbWord <- A.peekWord8
    if fmap AC8.isEndOfLine mbWord == Just True
      then fail "Not a header"
      else do
        name <- AC8.takeWhile (/= ':') <* AC8.char8 ':' <* AC8.space
        val <- A.takeWhile (not . AC8.isEndOfLine)
        return (CI.mk $ BC8.map Char.toLower name, val) <?> "pHeader"

bodyTransferEncoding headers = case M.lookup "content-length" headers of
  Nothing -> case M.lookup "transfer-encoding" headers of
    Nothing -> TillDisconn
    Just "chunked" -> Chunked
  Just bLen -> ContentLength $ read (BC8.unpack bLen)

parseChunk = do
  chunkLen <- (AC8.hexadecimal :: A.Parser Int) <* AC8.endOfLine
  A.take chunkLen <* AC8.endOfLine

-- XXX: lazy shall we?
pChunked = B.concat . reverse <$> pWithResult []
 where
  pWithResult res = do
    chunk <- parseChunk
    case B.length chunk of
      0 -> return res
      _ -> pWithResult (chunk : res)

