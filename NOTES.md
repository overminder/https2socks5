### Data flow (dynamic)

  - C2S message loop: read from sock and dispatch to handlers
    * bs from sock -(dechunk)-> bs -(decode msg)-> msg

  - S2C message loop: read from mailbox(s2c) and write to sock
    * msg -(encode msg)-> bs -(chunkify)-> chunked bs

  - server conn handler: create two loops that
    * read from sock and write to mailbox(s2c)
      + bs -> data msg

    * read from mailbox(connId) and write to sock
      + same type

    When remote disconn, write disconn to mailbox(s2c).
      + disconn msg

  - server data handler: write to mailbox(connId)
    * same type

### Moar abstractions!

  First we can build a
      
      type DuplexChannel a = (Producer a IO (),
                              Consumer a IO ())

      type DuplexBSChannel = DuplexChannel B.ByteString

      serveDuplexHttps :: Ipv4Addr -> (DuplexChannel a -> IO ()) ->
                          (DuplexBSChannel -> IO (DuplexChannel a)) ->
                          SafeT (IO ())

      connectDuplexHttps :: URI -> (DuplexChannel a -> IO ()) ->
                            (DuplexBSChannel -> IO (DuplexChannel a)) ->
                            SafeT (IO ())

  For protocol handling, we can have

      -- Auth by http header and then start chunk codec
      authAndChunkify :: DuplexBSChannel -> IO DuplexBSChannel
      authAndChunkify (p, c) = do
        httpHeader <- (`evalStateT` p) (PA.parse parseHttpHeader)
        if notAuthed httpHeader
          then fakeResponse c >> throwIO $ userError "auth failed"
          else return $ chunkCodec (p, c)

      -- Socks handler
      acceptSocks :: DuplexBSChannel -> IO DuplexBSChannel
      acceptSocks (p, c) = do
        (`evalStateT` p) $ do
          init <- PA.parseSocksInit
          liftIO $ runEffect $ 

  For chunks, we can have

      chunkCodec :: DuplexBSChannel -> DuplexBSChannel
      chunkCodec (p, c) = ((`evalStateT` p) chunkParsePipe,
                          c >-> chunkEncodePipe)
       where
        chunkParsePipe = forever $ do
          Right (_, bs) <- PA.parse parseChunk
          yield bs

        chunkEncodePipe = forever $ do
          await >>= yield . encodeChunk

  Also we can have msg codec..

  And then we can have client/server pairs:

      runInitiator :: FwdOption -> DuplexChannel Message -> IO ()

      runAcceptor :: DuplexChannel Message -> IO ()
  
  Where the initiator will initiate the handshake.

  Then the internals:

      
