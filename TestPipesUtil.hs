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

pbs = each (replicate 10 "a")

main = do
  runEffect $ bufferedPipe 20 1000000 pbs >-> P.show >-> P.stdoutLn
