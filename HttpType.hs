{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

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

data Request
  = Request {
    rqMethod :: Method,
    rqPath :: B.ByteString,
    rqHeaders :: Headers,
    rqBody :: B.ByteString
  }
  deriving (Show, Eq)

data Method
  = GET
  | POST
  | CONNECT
  deriving (Show, Eq, Ord)

data Response
  = Response {
    rsStatus :: ResponseStatus,
    rsHeaders :: Headers,
    rsBody :: B.ByteString
  }
  deriving (Show, Eq)

data ResponseStatus
  = ResponseStatus {
    statCode :: Int,
    statDetail :: B.ByteString
  }
  deriving (Show, Eq)

data TransferEncoding
  = ContentLength Int
  | Chunked
  | TillDisconn
  deriving (Show)

mkRequest :: Method -> String -> B.ByteString -> Request
mkRequest meth uriStr body = mkRequestURI meth uri body
 where
  Just uri = parseURI uriStr

mkRequestURI :: Method -> URI -> B.ByteString -> Request
mkRequestURI meth (URI {..}) body = Request {
  rqMethod = meth,
  rqPath = path,
  rqHeaders = hostHeader,
  rqBody = body
}
 where
  hostHeader = M.singleton "Host" (mkHost uriAuthority)
  mkHost (Just (URIAuth {..})) = BC8.pack $ uriRegName ++ uriPort
  path = BC8.pack $ uriPath ++ uriQuery

mkLengthHeader body
  = M.singleton "Content-Length" (BC8.pack . show . B.length $ body)

mkResponse :: ResponseStatus -> Headers -> B.ByteString -> Response
mkResponse = Response

fromRequest' :: Monad m => Request ->
                (B.ByteString -> Producer B.ByteString m ()) ->
                Producer B.ByteString m ()
fromRequest' (Request {..}) bodyEncoder = do
  yield (BC8.pack . show $ rqMethod) *> yield " " *> yield rqPath
  yield " HTTP/1.1\r\n"
  mapM_ fromHeader (M.toList rqHeaders)
  yield "\r\n"
  bodyEncoder rqBody

fromRequest req@(Request {..}) = fromRequest' req' yield
 where
  req' = req {
    rqHeaders = mkLengthHeader rqBody `M.union` rqHeaders
  }

fromRequestChunked chunkSize req@(Request {..})
  = fromRequest' req' (yieldChunked chunkSize)
 where
  req' = req {
    rqHeaders = M.insert "Transfer-Encoding" "chunked" rqHeaders
  }

fromHeader :: Monad m => (CI.CI B.ByteString, B.ByteString) ->
                         Producer B.ByteString m ()
fromHeader (name, val)
  = yield (CI.original name) *> yield ": " *> yield val *> yield "\r\n"

parseRequest :: A.Parser B.ByteString -> A.Parser Request
parseRequest pBody = do
  meth <- pMethod <* AC8.space
  path <- pPath <* AC8.space
  ver <- pVer <* AC8.endOfLine
  headers <- M.fromList <$> pHeaders
  -- Check content-encoding or content-length
  body <- case bodyTransferEncoding headers of
    ContentLength len -> A.take len
    Chunked -> pChunked
    TillDisconn -> pBody
  return $ Request meth path headers body
 where
  pMethod = (AC8.string "GET" *> return GET) <|>
            (AC8.string "POST" *> return POST) <|>
            (AC8.string "CONNECT" *> return CONNECT) <?> "pMethod"
  pPath = A.takeWhile (not . AC8.isSpace_w8) <?> "pPath"

fromResponse :: Monad m => Response -> Producer B.ByteString m ()
fromResponse resp@(Response {..}) = fromResponse' resp' yield
 where
  resp' = resp {
    rsHeaders = mkLengthHeader rsBody `M.union` rsHeaders
  }

fromResponseChunked :: Monad m => Int -> Response -> Producer B.ByteString m ()
fromResponseChunked chunkSize resp@(Response {..})
  = fromResponse' resp' (yieldChunked chunkSize)
 where
  resp' = resp {
    rsHeaders = M.insert "Transfer-Encoding" "chunked" rsHeaders
  }

yieldChunked chunkSize bs
  | B.length bs == 0 = yieldChunked' bs
  | otherwise = yieldChunked' (B.take chunkSize bs)
             *> yieldChunked chunkSize (B.drop chunkSize bs)
yieldChunked' bs = do
  yield $ BC8.pack $ showHex (B.length bs) ""
  yield "\r\n"
  yield bs
  yield "\r\n"
    

fromResponse' :: Monad m => Response ->
                 (B.ByteString -> Producer B.ByteString m ()) -> 
                 Producer B.ByteString m ()
fromResponse' (Response {..}) bodyEncoder = do
  yield "HTTP/1.1 "
  yield (BC8.pack . show $ statCode rsStatus)
  yield " "
  yield $ statDetail rsStatus
  yield "\r\n"
  mapM_ fromHeader (M.toList rsHeaders)
  yield "\r\n"
  bodyEncoder rsBody

-- pBody is used to parse the rest (or ignore it if we've issued
-- a CONNECT method on a http proxy.
-- So the http codec is actually stateful... And Netty's HttpCodec is
-- (amusingly) doing the right thing!
parseResponse :: A.Parser B.ByteString -> A.Parser Response
parseResponse pBody = do
  ver <- pVer <* AC8.space
  code <- pStatCode <* AC8.space
  detail <- pStatDetail <* AC8.endOfLine
  headers <- M.fromList <$> pHeaders
  -- Check content-encoding or content-length
  body <- case bodyTransferEncoding headers of
    ContentLength len -> A.take len
    Chunked -> pChunked
    TillDisconn -> pBody
  return $ Response (ResponseStatus code detail) headers body
 where
  pStatCode = AC8.decimal
  pStatDetail = A.takeWhile (not . AC8.isEndOfLine)

pVer = AC8.string "HTTP/1.0" <|> AC8.string "HTTP/1.1" <?> "pVer"

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

-- XXX: lazy shall we?
pChunked = B.concat . reverse <$> pWithResult []
 where
  pWithResult res = do
    chunkLen <- (AC8.hexadecimal :: A.Parser Int) <* AC8.endOfLine
    chunk <- A.take chunkLen <* AC8.endOfLine
    case chunkLen of
      0 -> return res
      _ -> pWithResult (chunk : res)

