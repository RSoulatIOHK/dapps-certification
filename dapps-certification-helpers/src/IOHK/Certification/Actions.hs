{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}
module IOHK.Certification.Actions where

import Data.Coerce
import Paths_dapps_certification_helpers
import System.Directory
import Network.URI hiding (path)
import Control.Exception
import Control.Concurrent.Async
import Control.Monad.IO.Unlift
import Data.Aeson.Internal
import Data.Aeson.Types
import Data.Time.Clock.POSIX
import Data.Text as T
import Data.Text.IO
import Data.Text.Encoding
import Data.ByteString as BS hiding (hPutStrLn, hPutStr)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Internal as LBS
import Data.ByteString.Base16
import System.Process.Typed
import System.Process (Pid, getPid)
import Data.Aeson.Parser
import Data.Aeson.Parser.Internal
import Observe.Event
import Observe.Event.Render.JSON
import Data.Void
import System.IO hiding (hPutStrLn, hPutStr)
import System.FilePath
import Control.Monad
import Control.Monad.Catch hiding (finally)
import Data.List.NonEmpty
import Data.Map as Map
import qualified Data.Vector as V
import Data.List as L
import Data.Acquire
import Control.Monad.Trans.Resource
import IOHK.Certification.Interface hiding (Success)
import Conduit
import Data.Conduit.Aeson

generateFlake :: EventBackend IO r GenerateFlakeSelector -> URI -> FilePath -> IO ()
generateFlake backend flakeref output = withEvent backend GenerateFlake \ev -> do
  addField ev $ GenerateRef flakeref
  addField ev $ GenerateDir output

  let lockBackend = narrowEventBackend LockFlake
                  $ subEventBackend ev
  lock <- lockRef lockBackend flakeref

  withSubEvent ev WriteFlakeNix \_ -> withFile (output </> "flake.nix") WriteMode \h -> do
    hPutStrLn h "{"
    hPutStrLn h "  inputs = {"
    hPutStr   h "    repo = " >> writeNix h lock >> hPutStrLn h ";"
    hPutStrLn h "    plutus-apps = {"
    hPutStrLn h "      url = \"github:input-output-hk/plutus-apps\";"
    hPutStrLn h "      flake = false;"
    hPutStrLn h "    };"
    hPutStrLn h "    dapps-certification = {"
    hPutStrLn h "      url = \"github:input-output-hk/dapps-certification\";"
    hPutStrLn h "      flake = false;"
    hPutStrLn h "    };"
    hPutStrLn h "  };"
    hPutStrLn h ""
    hPutStrLn h "  outputs = args: import ./outputs.nix args;"
    hPutStrLn h "}"

  withSubEvent ev CopyOutputsNix \_ -> do
    outputsNix <- getDataFileName "data/outputs.nix"
    copyFile outputsNix (output </> "outputs.nix")

  withSubEvent ev CopyCertify \_ -> do
    certify <- getDataFileName "data/Certify.hs"
    copyFile certify (output </> "Certify.hs")

buildFlake :: EventBackend IO r BuildFlakeSelector -> FilePath -> IO FilePath
buildFlake backend dir = do
    buildJson <- withEvent backend BuildingFlake \ev -> do
      let backend' = narrowEventBackend ReadNixBuild
                   $ subEventBackend ev
      readProcessLogStderr_ backend' cmd
    case eitherDecodeWith jsonEOF decodeBuild buildJson of
      Left (path, err) -> throw $ DecodeBuild path err
      Right (BuildResult {..} :| []) -> case Map.lookup "out" outputs of
        Just p -> pure p
        Nothing -> throw $ MissingOut drvPath
      Right (_ :| tl) -> throw . ExtraBuilds $ L.length tl
  where
    cmd = proc "nix" [ "build"
                     , "--refresh"
                     , "path:" ++ dir
                     , "--no-link"
                     , "--json"
                     , "--print-build-logs"
                     ]

-- TODO logging
runCertify :: FilePath -> ConduitT () Message ResIO ()
runCertify certify = do
    (k, p) <- allocateAcquire $ acquireProcessWait cfg
    let toMessage = await >>= \case
          Just (Right (_, v)) -> case fromJSON v of
            Error s -> liftIO $ fail s
            Success m -> do
              yield m
              toMessage
          Just (Left e) -> liftIO $ throw e
          Nothing -> release k
    sourceHandle (getStdout p) .| conduitArrayParserNoStartEither skipSpace .| toMessage
  where
    cfg = setStdout createPipe
        $ proc certify []

acquireProcessWait :: ProcessConfig i o e -> Acquire (Process i o e)
acquireProcessWait cfg = mkAcquireType (startProcess cfg) cleanup
  where
    cleanup p ReleaseException = stopProcess p
    cleanup p _ = finally (checkExitCode p) (stopProcess p)

newtype SHA1Hash = SHA1Hash ByteString

parseSHA1Hash :: Text -> Either ParseSHA1HashError SHA1Hash
parseSHA1Hash t = case decodeBase16 (encodeUtf8 t) of
  Left e -> Left $ NotBase16 e
  Right bs -> let len = BS.length bs in
    if len == 20
    then Right $ SHA1Hash bs
    else Left $ BadLength len

renderSHA1Hash :: SHA1Hash -> Text
renderSHA1Hash = encodeBase16 . coerce

data GitHubFlakeLock = GitHubFlakeLock
  { owner :: !Text
  , repo :: !Text
  , rev :: !SHA1Hash
  }

data FlakeLock = FlakeLock
  { lastModified :: !POSIXTime
  , narHash :: !Text -- Sigh https://github.com/haskell-crypto/cryptonite/issues/337
  , gitHubFlake :: !GitHubFlakeLock -- Assuming GH only for now...
  }

writeNix :: Handle -> FlakeLock -> IO ()
writeNix h (FlakeLock {..}) = do
    hPutStr h "{ "
    hPutStr h "lastModified = " >> hPutStr h (T.pack . show @Integer $ truncate lastModified) >> hPutStr h "; "
    hPutStr h "narHash = \"" >> hPutStr h narHash >> hPutStr h "\"; "
    hPutStr h "owner = \"" >> hPutStr h owner >> hPutStr h "\"; "
    hPutStr h "repo = \"" >> hPutStr h repo >> hPutStr h "\"; "
    hPutStr h "rev = \"" >> hPutStr h (renderSHA1Hash rev) >> hPutStr h "\"; "
    hPutStr h "type = \"github\"; "
    hPutStr h "}"
  where
    GitHubFlakeLock {..} = gitHubFlake

decodeFlakeLock :: Value -> IResult FlakeLock
decodeFlakeLock = iparse $ withObject "flake-metadata" \o -> do
    lock <- o .: "locked"
    flip (withObject "flake-lock") lock \o' -> do
      ty <- o' .: "type"
      when (ty /= ghTy) $
        parserThrowError [ (Key "locked"), (Key "type") ] ("invalid flake type " ++ show ty)

      lastModified <- o' .: "lastModified"
      narHash <- o' .: "narHash"

      owner <- o' .: "owner"
      repo <- o' .: "repo"
      rev <- o' .: "rev" >>= decodeRev [ (Key "locked"), (Key "rev") ]
      pure $ FlakeLock
        { gitHubFlake = GitHubFlakeLock {..}
        , ..
        }
  where
    ghTy :: Text
    ghTy = "github"

    decodeRev :: JSONPath -> Text -> Parser SHA1Hash
    decodeRev path r = case parseSHA1Hash r of
      Left (NotBase16 msg) ->
        parserThrowError path $ "rev " ++ (show r) ++ " is not valid base16: " ++ (show msg)
      Left (BadLength len) ->
        parserThrowError path $ "rev " ++ (show r) ++ " is a base16 string representing " ++ (show len) ++ " bytes, expecting 20"
      Right h -> pure h

logHandleText :: (MonadUnliftIO m)
              => EventBackend m r LogHandleSelector
              -> Handle
              -> m ()
logHandleText backend h = go
  where
    go = do
      acqEv <- acquireEvent backend ReadingHandleLog
      join $ with acqEv \ev -> do
        chunk <- liftIO $ hGetChunk h
        if T.null chunk
          then pure $ pure ()
          else do
            addField ev chunk
            pure go

logDrainHandle :: (MonadUnliftIO m)
               => EventBackend m r DrainHandleSelector
               -> Handle
               -> (ByteString -> b -> m b)
               -> b
               -> m b
logDrainHandle backend h step = go
  where
    go st = do
      acqEv <- acquireEvent backend ReadingHandleDrain
      join $ with acqEv \ev -> do
        chunk <- liftIO $ hGetSome h LBS.defaultChunkSize
        if BS.null chunk
          then pure $ pure st
          else do
            addField ev $ BS.length chunk
            st' <- step chunk st
            pure $ go st'

-- Assume stderr is locale-specific text
readProcessLogStderr_
  :: (MonadUnliftIO m, MonadMask m, MonadFail m)
  => EventBackend m r ReadProcessSelector
  -> ProcessConfig stdin stdoutIgnored stderrIgnored
  -> m LBS.ByteString
readProcessLogStderr_ backend cfg = withEvent backend LaunchingProcess \launchEv -> do
    addField launchEv $ LaunchConfig cfg
    withProcessWait cfg' \p -> do
      Just pid <- liftIO . getPid $ unsafeProcessHandle p
      addField launchEv $ LaunchingPid pid
      finalize launchEv

      let launchEvRef = reference launchEv

          backend' = causedEventBackend launchEv

          readStderrBackend = narrowEventBackend ReadingStderr
                            $ backend'

          readStderr = logHandleText readStderrBackend $ getStderr p

          readStdoutBackend = narrowEventBackend ReadingStdout
                            $ backend'

          readStdout = (LBS.fromChunks . Prelude.reverse)
                    <$> logDrainHandle readStdoutBackend (getStdout p) (\bs -> pure . (bs :)) []

      withRunInIO \run -> withAsync (run readStdout) \stdoutAsync ->
        withAsync (run readStderr) \_ -> run $ do
          withEvent backend WaitingForProcess \waitEv -> do
            addProximate waitEv launchEvRef
            checkExitCode p
          liftIO $ wait stdoutAsync
  where
    cfg' = setStdout createPipe
         $ setStderr createPipe
         $ cfg

lockRef :: EventBackend IO r LockSelector -> URI -> IO FlakeLock
lockRef backend flakeref = withEvent backend LockingFlake \ev -> do
    addField ev $ LockingRef flakeref
    meta <- withSubEvent ev GettingMetadata \metaEv -> do
      let backend' = narrowEventBackend ReadNixFlakeMetadata
                   $ subEventBackend metaEv
      readProcessLogStderr_ backend' cmd
    case eitherDecodeWith jsonEOF decodeFlakeLock meta of
      Left (path, err) -> throw $ DecodeMeta path err
      Right lock -> do
        addField ev $ LockingLock lock
        pure lock
  where
    cmd = proc "nix" [ "flake"
                     , "--refresh"
                     , "metadata"
                     , "--no-update-lock-file"
                     , "--json"
                     , (uriToString id flakeref "")
                     ]

data BuildResult = BuildResult
  { drvPath :: !FilePath
  , outputs :: !(Map Text FilePath)
  }

decodeBuild :: Value -> IResult (NonEmpty BuildResult)
decodeBuild = iparse $ withArray "build-results" \builds -> do
    when (V.null builds) $
      parserThrowError [] "unexpectedly empty build-results"
    decoded <- V.mapM decodeResult builds
    pure $ V.unsafeHead decoded :| V.toList (V.unsafeTail decoded)
  where
    decodeResult :: Value -> Parser BuildResult
    decodeResult = withObject "build-result" \o -> BuildResult
      <$> o .: "drvPath"
      <*> o .: "outputs"

data ReadProcessSelector f where
  LaunchingProcess :: ReadProcessSelector LaunchField
  ReadingStderr :: forall f . LogHandleSelector f -> ReadProcessSelector f
  ReadingStdout :: forall f . DrainHandleSelector f -> ReadProcessSelector f
  WaitingForProcess :: ReadProcessSelector Void

renderReadProcessSelector :: RenderSelectorJSON ReadProcessSelector
renderReadProcessSelector LaunchingProcess = ("launching-process", renderLaunchField)
renderReadProcessSelector (ReadingStderr sel) = ( "reading-stderr:" <> k
                                                , renderField
                                                )
  where
    (k, renderField) = renderLogHandleSelector sel
renderReadProcessSelector (ReadingStdout sel) = ( "reading-stdout:" <> k
                                                , renderField
                                                )
  where
    (k, renderField) = renderDrainHandleSelector sel
renderReadProcessSelector WaitingForProcess = ("waiting-for-process", absurd)

data LaunchField
  = forall stdin stdoutIgnored stderrIgnored . LaunchConfig !(ProcessConfig stdin stdoutIgnored stderrIgnored)
  | LaunchingPid !Pid

renderLaunchField :: RenderFieldJSON LaunchField
renderLaunchField (LaunchConfig cfg) = ("launch-config", toJSON $ show cfg)
renderLaunchField (LaunchingPid pid) = ("launched-pid", toJSON $ toInteger pid)

data LogHandleSelector f where
  ReadingHandleLog :: LogHandleSelector Text

renderLogHandleSelector :: RenderSelectorJSON LogHandleSelector
renderLogHandleSelector ReadingHandleLog = ( "reading-chunk"
                                           , \t -> ("chunk-data", toJSON t)
                                           )

data DrainHandleSelector f where
  ReadingHandleDrain :: DrainHandleSelector Int

renderDrainHandleSelector :: RenderSelectorJSON DrainHandleSelector
renderDrainHandleSelector ReadingHandleDrain = ( "reading-chunk"
                                               , \sz -> ("chunk-size", toJSON sz)
                                               )
data LockSelector f where
  LockingFlake :: LockSelector LockingField
  GettingMetadata :: LockSelector Void
  ReadNixFlakeMetadata :: forall f . ReadProcessSelector f -> LockSelector f

renderLockSelector :: RenderSelectorJSON LockSelector
renderLockSelector LockingFlake = ("locking-flake", renderLockingField)
renderLockSelector GettingMetadata = ("getting-metadata", absurd)
renderLockSelector (ReadNixFlakeMetadata sel) = ( "reading-nix-flake-metadata-output:" <> procKey
                                                , procRender
                                                )
  where
    (procKey, procRender) = renderReadProcessSelector sel

data LockingField = LockingRef !URI
                  | LockingLock !FlakeLock

renderLockingField :: RenderFieldJSON LockingField
renderLockingField (LockingRef u) = ("flake-ref", toJSON (uriToString id u ""))
renderLockingField (LockingLock (FlakeLock {..})) = ("lock", lockJSON)
  where
    GitHubFlakeLock {..} = gitHubFlake
    lockJSON = object
      [ "lastModified" .= truncate @_ @Integer lastModified
      , "narHash" .= narHash
      , "owner" .= owner
      , "repo" .= repo
      , "rev" .= renderSHA1Hash rev
      ]

data GenerateFlakeSelector f where
  GenerateFlake :: GenerateFlakeSelector GenerateField
  LockFlake :: forall f . LockSelector f -> GenerateFlakeSelector f
  WriteFlakeNix :: GenerateFlakeSelector Void
  CopyOutputsNix :: GenerateFlakeSelector Void
  CopyCertify :: GenerateFlakeSelector Void

renderGenerateFlakeSelector :: RenderSelectorJSON GenerateFlakeSelector
renderGenerateFlakeSelector GenerateFlake = ("generate-flake", renderGenerateField)
renderGenerateFlakeSelector (LockFlake sel) = ( "lock-user-repo:" <> lockKey
                                              , lockRender
                                              )
  where
    (lockKey, lockRender) = renderLockSelector sel
renderGenerateFlakeSelector WriteFlakeNix = ("write-flake.nix", absurd)
renderGenerateFlakeSelector CopyOutputsNix = ("copy-outputs.nix", absurd)
renderGenerateFlakeSelector CopyCertify = ("copy-certify.hs", absurd)

data GenerateField = GenerateRef !URI
                   | GenerateDir !FilePath

renderGenerateField :: RenderFieldJSON GenerateField
renderGenerateField (GenerateRef uri) = ("flake-ref", toJSON (uriToString id uri ""))
renderGenerateField (GenerateDir dir) = ("dir", toJSON dir)

data BuildFlakeSelector f where
  BuildingFlake :: BuildFlakeSelector Void
  ReadNixBuild :: forall f . ReadProcessSelector f -> BuildFlakeSelector f

renderBuildFlakeSelector :: RenderSelectorJSON BuildFlakeSelector
renderBuildFlakeSelector BuildingFlake = ("building-flake", absurd)
renderBuildFlakeSelector (ReadNixBuild sel) = ( "reading-nix-build:" <> procKey
                                              , procRender
                                              )
  where
    (procKey, procRender) = renderReadProcessSelector sel

data ParseSHA1HashError
  = NotBase16 !Text
  | BadLength !Int

data LockException = DecodeMeta !JSONPath !String

instance Show LockException where
  show (DecodeMeta path str) = "decoding metadata: " ++ formatError path str

instance ToJSON LockException where
  toJSON (DecodeMeta path msg) = object
    [ "render-lock-exception" .= object
      [ "msg" .= msg
      , "json-path" .= (renderElement <$> path)
      , "type" .= String "decode-meta"
      ]
    ]
  toEncoding (DecodeMeta path msg) = pairs
    ( "render-lock-exception" .= object
      [ "msg" .= msg
      , "json-path" .= (renderElement <$> path)
      , "type" .= String "decode-meta"
      ]
    )

renderElement :: JSONPathElement -> Value
renderElement (Key k) = object [ "key" .= k ]
renderElement (Index i) = object [ "index" .= i ]

instance Exception LockException where
  toException = jsonExceptionToException
  fromException = jsonExceptionFromException

data BuildException = DecodeBuild !JSONPath !String
                    | MissingOut !FilePath
                    | ExtraBuilds !Int

instance Show BuildException where
  show (DecodeBuild path str) = "decoding nix build output: " ++ formatError path str
  show (MissingOut path) = "missing output 'out' of drv " ++ path
  show (ExtraBuilds ct) = "found " ++ show ct ++ " extra builds"

instance ToJSON BuildException where
  toJSON (DecodeBuild path str) = object
    [ "render-build-exception" .= object
      [ "msg" .= str
      , "json-path" .= (renderElement <$> path)
      , "type" .= String "decode-build"
      ]
    ]
  toJSON (MissingOut drv) = object
    [ "render-build-exception" .= object
      [ "drv" .= drv
      , "type" .= String "missing-out"
      ]
    ]
  toJSON (ExtraBuilds ct) = object
    [ "render-build-exception" .= object
      [ "count" .= ct
      , "type" .= String "extra-builds"
      ]
    ]
  toEncoding (DecodeBuild path str) = pairs
    ( "render-build-exception" .= object
      [ "msg" .= str
      , "json-path" .= (renderElement <$> path)
      , "type" .= String "decode-build"
      ]
    )
  toEncoding (MissingOut drv) = pairs
    ( "render-build-exception" .= object
      [ "drv" .= drv
      , "type" .= String "missing-out"
      ]
    )
  toEncoding (ExtraBuilds ct) = pairs
    ( "render-build-exception" .= object
      [ "count" .= ct
      , "type" .= String "extra-builds"
      ]
    )

instance Exception BuildException where
  toException = jsonExceptionToException
  fromException = jsonExceptionFromException