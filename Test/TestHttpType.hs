{-# LANGUAGE RankNTypes, OverloadedStrings #-}

module TestHttpType where

import Control.Applicative
import Control.Monad.Writer
import qualified Data.Map as M
import Test.QuickCheck
import Network.URI
import qualified Data.Attoparsec as A
import qualified Data.ByteString as B
import Pipes
import qualified Pipes.ByteString as PB

import HttpType hiding (Chunked)

instance Arbitrary B.ByteString where
  arbitrary = B.pack <$> arbitrary

instance Arbitrary Message where
  arbitrary = do
    isReq <- arbitrary
    if isReq
      then do
        meth <- elements [GET, POST, CONNECT]
        let Just uri = parseURI "http://www.google.com/?q=foobar"
        body <- case meth of
          POST -> arbitrary
          _ -> return B.empty
        return $ mkRequestURI meth uri body
      else do
        (code, detail) <- elements $ zip
          [200, 404, 500] ["OK", "Not Found", "Internal Server Error"]
        body <- arbitrary
        return $ mkResponse code detail M.empty body

data Chunked a
  = Chunked {
    cWat :: a,
    cSize :: Int
  }

instance Arbitrary a => Arbitrary (Chunked a) where
  arbitrary = Chunked <$> arbitrary <*> elements [1, 10, 100]

checkRoundTrip :: (Show a, Eq a) => A.Parser a ->
                  (a -> B.ByteString) -> a -> Bool
checkRoundTrip parseA toBs a = if a' == a''
  then True
  else error $ show (a', a'')
 where
  roundTrip = A.parse parseA . toBs
  A.Done rest  a'  = roundTrip a
  A.Done rest' a'' = roundTrip a'
  
checkMessageCodec :: Message -> Bool
checkMessageCodec = checkRoundTrip parseA toBs
 where
  parseA = parseMessage undefined
  toBs = runBSProducer . fromMessage

checkMessageChunkedCodec :: Message -> Bool
checkMessageChunkedCodec = checkRoundTrip parseA toBs
 where
  parseA = parseMessage undefined
  toBs = runBSProducer . fromMessageChunked 1

runBSProducer :: Producer B.ByteString (Writer [B.ByteString]) () ->
                 B.ByteString
runBSProducer p = B.concat $ execWriter $ runEffect effect
 where
  effect = p >-> consume
  consume = await >>= lift . tell . (:[]) >> consume

