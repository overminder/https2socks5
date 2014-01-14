{-# LANGUAGE OverloadedStrings #-}

import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.Attoparsec as PA
import qualified Data.Attoparsec as A
import qualified Data.Attoparsec.Char8 as AC8
import qualified Data.ByteString as B
import Control.Applicative

import qualified HttpType as H
import PipesUtil

--bs = mapM_ H.fromChunk ["a", "aaa"]
bs = mapM_ yield ["ab", "\r\n"]

myEol = A.string "\r\n"

main = do
  runEffect $
    --bs >-> parserToPipe H.parseChunk >-> P.show >-> P.stdoutLn
    bs >-> parserToPipe (A.string "ab" <* myEol) >-> P.show >-> P.stdoutLn
