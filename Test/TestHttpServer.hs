{-# LANGUAGE OverloadedStrings #-}

import Pipes
import qualified Data.Map as M
import qualified Pipes.Network.TCP.Safe as T
import qualified Data.Attoparsec as A
import qualified Pipes.Attoparsec as PA
import Control.Monad.State.Strict

import qualified HttpType as H
import PipesUtil

main = T.withSocketsDo $ T.runSafeT $ T.serve (T.Host "localhost") "5678" $ \ (peer, _) -> do
  (`evalStateT` (T.fromSocket peer 4096 >-> logWith "fromPeer ")) $ do
    Right (_, msg) <- PA.parse H.parseRequest
    liftIO $ print msg
  runEffect $ H.fromMessage (H.mkResponse 200 "OK" M.empty "Hello") >->
                     T.toSocket peer
