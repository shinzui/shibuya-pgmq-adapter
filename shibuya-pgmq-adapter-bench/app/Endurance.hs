-- | Endurance test for Shibuya with PGMQ adapter.
--
-- Runs for hours to verify stability under sustained load.
--
-- Environment variables:
--   PG_CONNECTION_STRING - PostgreSQL connection string (required)
--   DURATION_SECS        - Test duration in seconds (default: 14400 = 4 hours)
--   MESSAGES_PER_SECOND  - Target message rate (default: 100)
--   SAMPLE_INTERVAL_SECS - Metrics sampling interval (default: 30)
--   OUTPUT_CSV           - Path to output CSV file (default: endurance_metrics.csv)
--   LIFECYCLE_RUN_ID     - Unique queue suffix (default: process timestamp)
--   RESTART_AT_SECS      - Graceful stop/restart point (default: halfway)
--
-- Pass/Fail Criteria:
--   - Retained-memory trend passes EP-45's post-warmup analyzer
--   - Failed messages < 1%
--   - All produced messages processed
--
-- Usage:
--   PG_CONNECTION_STRING="host=localhost dbname=pgmq" cabal run endurance-test
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception qualified as Exception
import Control.Monad (forever, unless)
import Data.Aeson (Value, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import Database.PostgreSQL.Migrate qualified as Migrate
import Effectful (IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Pgmq.Effectful (runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Migration qualified as Migration
import Pgmq.Types (MessageBody (..), QueueName, parseQueueName)
import Shibuya.Adapter.Pgmq
  ( defaultConfig,
    mkPgmqAdapterEnv,
    pgmqAdapter,
  )
import Shibuya.App
  ( ProcessorId (..),
    ShutdownConfig (drainTimeout, totalShutdownTimeout),
    defaultAppConfig,
    defaultShutdownConfig,
    mkProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Handler (Handler)
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Environment (getEnv, lookupEnv)
import System.Exit (exitFailure)
import System.IO (Handle, IOMode (..), SeekMode (AbsoluteSeek), hFlush, hPutStrLn, hSeek, hSetFileSize, withFile)
import System.Mem (performMajorGC)
import Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

data EnduranceConfig = EnduranceConfig
  { connectionString :: !BS.ByteString,
    durationSecs :: !Int,
    messagesPerSecond :: !Int,
    sampleIntervalSecs :: !Int,
    outputCsv :: !FilePath,
    outputLedger :: !FilePath,
    runId :: !String,
    restartAtSecs :: !Int,
    shutdownDrainSecs :: !Int,
    shutdownTotalSecs :: !Int
  }
  deriving stock (Show)

loadConfig :: IO EnduranceConfig
loadConfig = do
  connStr <- getEnv "PG_CONNECTION_STRING"
  duration <- getEnvIntDefault "DURATION_SECS" 14400
  msgRate <- getEnvIntDefault "MESSAGES_PER_SECOND" 100
  sampleInterval <- getEnvIntDefault "SAMPLE_INTERVAL_SECS" 30
  csvPath <- getEnvDefault "OUTPUT_CSV" "endurance_metrics.csv"
  ledgerPath <- getEnvDefault "OUTPUT_LEDGER" (csvPath <> ".ledger.json")
  now <- getCurrentTime
  configuredRunId <- lookupEnv "LIFECYCLE_RUN_ID"
  let selectedRunId = maybe (formatTime defaultTimeLocale "%Y%m%d%H%M%S" now) id configuredRunId
  restartAt <- getEnvIntDefault "RESTART_AT_SECS" (duration `div` 2)
  shutdownDrain <- getEnvIntDefault "SHUTDOWN_DRAIN_SECS" 30
  shutdownTotal <- getEnvIntDefault "SHUTDOWN_TOTAL_SECS" 60
  pure
    EnduranceConfig
      { connectionString = BS.pack connStr,
        durationSecs = duration,
        messagesPerSecond = msgRate,
        sampleIntervalSecs = sampleInterval,
        outputCsv = csvPath,
        outputLedger = ledgerPath,
        runId = selectedRunId,
        restartAtSecs = max 1 (min (duration - 1) restartAt),
        shutdownDrainSecs = shutdownDrain,
        shutdownTotalSecs = shutdownTotal
      }

getEnvDefault :: String -> String -> IO String
getEnvDefault name def = do
  mVal <- lookupEnv name
  pure $ maybe def id mVal

getEnvIntDefault :: String -> Int -> IO Int
getEnvIntDefault name def = do
  mVal <- lookupEnv name
  pure $ maybe def id (mVal >>= readMaybe)

--------------------------------------------------------------------------------
-- Metrics Collection
--------------------------------------------------------------------------------

data Sample = Sample
  { timestamp :: !UTCTime,
    elapsedSecs :: !Int,
    messagesProduced :: !Int,
    messagesProcessed :: !Int,
    messagesFailed :: !Int,
    queueDepth :: !Int64,
    retainedBytes :: !Word64,
    maxLiveBytes :: !Word64
  }
  deriving stock (Show)

sampleToCsv :: Sample -> Text
sampleToCsv s =
  Text.intercalate
    ","
    [ Text.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" s.timestamp,
      Text.pack $ show s.elapsedSecs,
      Text.pack $ show s.messagesProduced,
      Text.pack $ show s.messagesProcessed,
      Text.pack $ show s.messagesFailed,
      Text.pack $ show s.queueDepth,
      Text.pack $ show s.retainedBytes,
      Text.pack $ show s.maxLiveBytes
    ]

csvHeader :: Text
csvHeader = "timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes"

--------------------------------------------------------------------------------
-- Pass/Fail Criteria
--------------------------------------------------------------------------------

data TestResult = TestResult
  { passed :: !Bool,
    initialMemory :: !Word64,
    finalMemory :: !Word64,
    memoryGrowthRatio :: !Double,
    totalProduced :: !Int,
    totalProcessed :: !Int,
    totalFailed :: !Int,
    failureRate :: !Double,
    errors :: ![Text]
  }
  deriving stock (Show)

data DeliveryLedger = DeliveryLedger
  { producedHandle :: !Handle,
    processedHandle :: !Handle,
    producedPath :: !FilePath,
    processedPath :: !FilePath,
    malformedDeliveries :: !(IORef Int)
  }

checkCriteria :: Word64 -> Word64 -> Int -> Int -> Int -> TestResult
checkCriteria initialMem finalMem produced processed failed =
  let memRatio :: Double
      memRatio = fromIntegral finalMem / max 1 (fromIntegral initialMem)
      failRate :: Double
      failRate = fromIntegral failed / max 1 (fromIntegral (processed + failed))
      processedRatio :: Double
      processedRatio = fromIntegral processed / max 1 (fromIntegral produced)
      errs =
        [ "Failure rate " <> Text.pack (show (failRate * 100)) <> "% (limit: 1%)"
        | failRate > 0.01
        ]
          ++ [ "Only processed " <> Text.pack (show (processedRatio * 100)) <> "% of messages"
             | processedRatio < 0.95
             ]
   in TestResult
        { passed = null errs,
          initialMemory = initialMem,
          finalMemory = finalMem,
          memoryGrowthRatio = memRatio,
          totalProduced = produced,
          totalProcessed = processed,
          totalFailed = failed,
          failureRate = failRate,
          errors = errs
        }

--------------------------------------------------------------------------------
-- Producer
--------------------------------------------------------------------------------

runProducer ::
  Pool.Pool ->
  QueueName ->
  Int ->
  TVar Int ->
  IORef Int ->
  DeliveryLedger ->
  TVar Bool ->
  IO ()
runProducer pool queue msgsPerSec countVar failedRef ledger stopVar = go 0
  where
    delayMicros = 1_000_000 `div` max 1 msgsPerSec

    go :: Int -> IO ()
    go !idx = do
      shouldStop <- readTVarIO stopVar
      unless shouldStop $ do
        let payload = object ["id" .= idx, "ts" .= show idx]
            msg =
              Q.SendMessage
                { queueName = queue,
                  messageBody = MessageBody payload,
                  delay = Nothing
                }
        result <- Pool.use pool $ Pgmq.sendMessage msg
        case result of
          Left _ -> atomicModifyIORef' failedRef (\n -> (n + 1, ()))
          Right _ -> do
            atomically $ modifyTVar' countVar (+ 1)
            recordProduced ledger idx
        threadDelay delayMicros
        go (idx + 1)

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------

makeHandler :: (IOE :> es) => IORef Int -> IORef Int -> DeliveryLedger -> Handler es Value
makeHandler successRef failRef ledger message = do
  let Message {envelope = Envelope {payload}} = message
      sequenceNumber = parseMaybe (withObject "EP-45 payload" (.: "id")) payload
  case sequenceNumber of
    Nothing -> do
      liftIO $ do
        atomicModifyIORef' failRef (\count -> (count + 1, ()))
        atomicModifyIORef' ledger.malformedDeliveries (\count -> (count + 1, ()))
      pure $ AckDeadLetter (InvalidPayload "EP-45 ledger id missing")
    Just value -> do
      liftIO $ do
        atomicModifyIORef' successRef (\count -> (count + 1, ()))
        recordProcessed ledger value
      pure AckOk

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

getMemoryBytes :: IO (Word64, Word64)
getMemoryBytes = do
  enabled <- getRTSStatsEnabled
  if enabled
    then do
      performMajorGC
      stats <- getRTSStats
      pure (gcdetails_live_bytes stats.gc, max_live_bytes stats)
    else pure (0, 0)

sampleMetrics ::
  Pool.Pool ->
  QueueName ->
  UTCTime ->
  TVar Int ->
  IORef Int ->
  IORef Int ->
  IO Sample
sampleMetrics pool queueName startTime producedVar processedRef failedRef = do
  now <- getCurrentTime
  produced <- readTVarIO producedVar
  processed <- readIORef processedRef
  failed <- readIORef failedRef
  (retainedBytes, maxLiveBytes) <- getMemoryBytes
  metricsResult <- Pool.use pool $ Pgmq.queueMetrics queueName
  depth <- case metricsResult of
    Left err -> error $ "Queue metrics error: " <> show err
    Right metrics -> pure metrics.queueLength

  pure
    Sample
      { timestamp = now,
        elapsedSecs = round $ diffUTCTime now startTime,
        messagesProduced = produced,
        messagesProcessed = processed,
        messagesFailed = failed,
        queueDepth = depth,
        retainedBytes = retainedBytes,
        maxLiveBytes = maxLiveBytes
      }

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn "=== Shibuya Endurance Test ==="
  putStrLn ""

  config <- loadConfig
  putStrLn $ "Configuration:"
  putStrLn $ "  Duration: " <> show config.durationSecs <> " seconds"
  putStrLn $ "  Target rate: " <> show config.messagesPerSecond <> " msg/s"
  putStrLn $ "  Sample interval: " <> show config.sampleIntervalSecs <> " seconds"
  putStrLn $ "  Output CSV: " <> config.outputCsv
  putStrLn $ "  Output ledger: " <> config.outputLedger
  putStrLn $ "  Run ID: " <> config.runId
  putStrLn $ "  Restart at: " <> show config.restartAtSecs <> " seconds"
  putStrLn ""

  let queueNameText = Text.pack ("ep45_" <> filter validQueueChar config.runId)
      queueName = case parseQueueName queueNameText of
        Left err -> error $ "Invalid queue name: " <> show err
        Right q -> q
  result <-
    Exception.bracket (createPool config.connectionString) Pool.release $ \pool -> do
      putStrLn "Connected to PostgreSQL"
      installSchema config.connectionString
      putStrLn "PGMQ schema installed"
      Exception.bracket_
        (createQueue pool queueName >> putStrLn ("Queue created: " <> Text.unpack queueNameText))
        (dropQueue pool queueName)
        (putStrLn "" >> runEnduranceTest config pool queueName)

  printResult result

  if result.passed
    then putStrLn "\n=== TEST PASSED ==="
    else do
      putStrLn "\n=== TEST FAILED ==="
      mapM_ (putStrLn . ("  - " <>) . Text.unpack) result.errors
      exitFailure
  where
    validQueueChar c =
      ('a' <= c && c <= 'z')
        || ('A' <= c && c <= 'Z')
        || ('0' <= c && c <= '9')
        || c == '_'

runEnduranceTest ::
  EnduranceConfig ->
  Pool.Pool ->
  QueueName ->
  IO TestResult
runEnduranceTest config pool queueName = do
  producedVar <- newTVarIO (0 :: Int)
  processedRef <- newIORef (0 :: Int)
  failedRef <- newIORef (0 :: Int)
  stopVar <- newTVarIO False

  (_, initialMem) <- getMemoryBytes
  startTime <- getCurrentTime
  putStrLn $ "Initial memory: " <> show initialMem <> " bytes"
  putStrLn $ "Starting test at: " <> show startTime
  putStrLn ""

  withDeliveryLedger config $ \ledger ->
    withFile config.outputCsv WriteMode $ \csvHandle -> do
      hPutStrLn csvHandle (Text.unpack csvHeader)
      hFlush csvHandle

      producerAsync <- async $ runProducer pool queueName config.messagesPerSecond producedVar failedRef ledger stopVar

      samplerAsync <- async $ runSampler config pool queueName startTime producedVar processedRef failedRef csvHandle

      putStrLn $ "Running for " <> show config.durationSecs <> " seconds..."
      runProcessorSegment config pool queueName processedRef failedRef ledger $ do
        threadDelay (config.restartAtSecs * 1_000_000)
        putStrLn "\nGraceful midpoint stop..."

      putStrLn "Restarting processor with the same durable queue..."
      let remainingSecs = config.durationSecs - config.restartAtSecs
      runProcessorSegment config pool queueName processedRef failedRef ledger $ do
        threadDelay (remainingSecs * 1_000_000)
        putStrLn "\nStopping producer and draining after restart..."
        atomically $ modifyTVar' stopVar (const True)
        wait producerAsync
        waitForDrain producedVar processedRef 30
        waitForQueueDrain pool queueName 30

      cancel samplerAsync
      finalSample <- sampleMetrics pool queueName startTime producedVar processedRef failedRef
      hPutStrLn csvHandle (Text.unpack $ sampleToCsv finalSample)
      hFlush csvHandle

      putStrLn "Processor stopped"

      -- Wait a bit for final processing
      threadDelay 1_000_000

      (_, finalMem) <- getMemoryBytes
      produced <- readTVarIO producedVar
      processed <- readIORef processedRef
      failed <- readIORef failedRef
      ledgerPassed <- writeDeliveryLedger config ledger

      let result = checkCriteria initialMem finalMem produced processed failed
      pure $ if ledgerPassed then result else result {passed = False, errors = result.errors <> ["Per-delivery ledger did not reconcile"]}

runProcessorSegment ::
  EnduranceConfig ->
  Pool.Pool ->
  QueueName ->
  IORef Int ->
  IORef Int ->
  DeliveryLedger ->
  IO () ->
  IO ()
runProcessorSegment config pool queueName processedRef failedRef ledger action = do
  let adapterConfig = defaultConfig queueName
      adapterEnv = mkPgmqAdapterEnv pool
  eResult <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq pool $ runTracingNoop $ do
    adapterResult <- pgmqAdapter adapterEnv adapterConfig
    adapter <- case adapterResult of
      Left err -> liftIO $ error $ "Invalid PGMQ adapter config: " <> show err
      Right value -> pure value
    let handler = makeHandler processedRef failedRef ledger
        processor = mkProcessor adapter handler
    result <- runApp defaultAppConfig [(ProcessorId "endurance", processor)]
    case result of
      Left err -> liftIO $ error $ "Failed to start app: " <> show err
      Right appHandle -> do
        liftIO action
        let shutdownConfig =
              defaultShutdownConfig
                { drainTimeout = fromIntegral config.shutdownDrainSecs,
                  totalShutdownTimeout = fromIntegral config.shutdownTotalSecs
                }
        drained <- stopAppGracefully shutdownConfig appHandle
        unless drained $ liftIO $ error "Shibuya application required forced shutdown"
  case eResult of
    Left err -> error $ "Pgmq error: " <> show err
    Right () -> pure ()

withDeliveryLedger :: EnduranceConfig -> (DeliveryLedger -> IO a) -> IO a
withDeliveryLedger config action =
  let producedPath = config.outputLedger <> ".produced.ids"
      processedPath = config.outputLedger <> ".processed.ids"
   in withFile producedPath ReadWriteMode $ \producedHandle ->
        withFile processedPath ReadWriteMode $ \processedHandle -> do
          hSetFileSize producedHandle 0
          hSetFileSize processedHandle 0
          malformedDeliveries <- newIORef 0
          action DeliveryLedger {producedHandle, processedHandle, producedPath, processedPath, malformedDeliveries}

recordProduced :: DeliveryLedger -> Int -> IO ()
recordProduced ledger value = hPutStrLn ledger.producedHandle (show value)

recordProcessed :: DeliveryLedger -> Int -> IO ()
recordProcessed ledger value = hPutStrLn ledger.processedHandle (show value)

writeDeliveryLedger :: EnduranceConfig -> DeliveryLedger -> IO Bool
writeDeliveryLedger config ledger = do
  producedValues <- readIdentityHandle ledger.producedPath ledger.producedHandle
  processedValues <- readIdentityHandle ledger.processedPath ledger.processedHandle
  malformed <- readIORef ledger.malformedDeliveries
  let produced = Set.fromList producedValues
      processed = Set.fromList processedValues
      duplicates = duplicateValues processedValues
  let missing = produced `Set.difference` processed
      unexpected = processed `Set.difference` produced
      passed = Set.null missing && Set.null unexpected && Set.null duplicates && malformed == 0
      artifact =
        object
          [ "schemaVersion" .= (1 :: Int),
            "adapter" .= ("pgmq" :: String),
            "runId" .= config.runId,
            "status" .= if passed then ("pass" :: String) else "fail",
            "producedIds" .= Set.toAscList produced,
            "processedIds" .= Set.toAscList processed,
            "duplicateIds" .= Set.toAscList duplicates,
            "missingIds" .= Set.toAscList missing,
            "unexpectedIds" .= Set.toAscList unexpected,
            "malformedDeliveries" .= malformed
          ]
  LBS.writeFile config.outputLedger (encode artifact)
  putStrLn $ "  Delivery ledger: " <> config.outputLedger <> " (" <> if passed then "pass)" else "fail)"
  pure passed

readIdentityHandle :: FilePath -> Handle -> IO [Int]
readIdentityHandle path handle = do
  hFlush handle
  hSeek handle AbsoluteSeek 0
  contents <- BS.hGetContents handle
  traverse parseIdentity (filter (not . BS.null) (BS.lines contents))
  where
    parseIdentity raw =
      maybe (ioError $ userError $ "Invalid delivery identity in " <> path) pure (readMaybe $ BS.unpack raw)

duplicateValues :: [Int] -> Set Int
duplicateValues = snd . foldl' step (Set.empty, Set.empty)
  where
    step (seen, duplicates) value
      | Set.member value seen = (seen, Set.insert value duplicates)
      | otherwise = (Set.insert value seen, duplicates)

waitForDrain :: TVar Int -> IORef Int -> Int -> IO ()
waitForDrain producedVar processedRef timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
      produced <- readTVarIO producedVar
      processed <- readIORef processedRef
      if processed >= produced
        then pure ()
        else
          if remaining > 0
            then threadDelay 100_000 >> loop (remaining - 1)
            else error $ "Timed out draining produced messages: produced=" <> show produced <> " processed=" <> show processed

waitForQueueDrain :: Pool.Pool -> QueueName -> Int -> IO ()
waitForQueueDrain pool queueName timeoutSecs = loop (timeoutSecs * 10)
  where
    loop remaining = do
      metricsResult <- Pool.use pool $ Pgmq.queueMetrics queueName
      depth <- case metricsResult of
        Left err -> error $ "Queue metrics error: " <> show err
        Right metrics -> pure metrics.queueLength
      if depth <= 0
        then pure ()
        else
          if remaining > 0
            then threadDelay 100_000 >> loop (remaining - 1)
            else error $ "Timed out draining PGMQ queue: depth=" <> show depth

runSampler ::
  EnduranceConfig ->
  Pool.Pool ->
  QueueName ->
  UTCTime ->
  TVar Int ->
  IORef Int ->
  IORef Int ->
  Handle ->
  IO ()
runSampler config pool queueName startTime producedVar processedRef failedRef csvHandle = forever $ do
  threadDelay (config.sampleIntervalSecs * 1_000_000)
  sample <- sampleMetrics pool queueName startTime producedVar processedRef failedRef
  let csvLine = sampleToCsv sample
  hPutStrLn csvHandle (Text.unpack csvLine)
  hFlush csvHandle
  putStrLn $
    "["
      <> show sample.elapsedSecs
      <> "s] produced="
      <> show sample.messagesProduced
      <> " processed="
      <> show sample.messagesProcessed
      <> " failed="
      <> show sample.messagesFailed
      <> " queue="
      <> show sample.queueDepth
      <> " retained="
      <> show (sample.retainedBytes `div` 1024 `div` 1024)
      <> "MB max-live="
      <> show (sample.maxLiveBytes `div` 1024 `div` 1024)
      <> "MB"

printResult :: TestResult -> IO ()
printResult result = do
  putStrLn ""
  putStrLn "=== Test Results ==="
  putStrLn $ "  Total produced: " <> show result.totalProduced
  putStrLn $ "  Total processed: " <> show result.totalProcessed
  putStrLn $ "  Total failed: " <> show result.totalFailed
  putStrLn $ "  Failure rate: " <> show (result.failureRate * 100) <> "%"
  putStrLn $ "  Initial memory: " <> show (result.initialMemory `div` 1024 `div` 1024) <> " MB"
  putStrLn $ "  Final memory: " <> show (result.finalMemory `div` 1024 `div` 1024) <> " MB"
  putStrLn $ "  Memory growth: " <> show result.memoryGrowthRatio <> "x"

--------------------------------------------------------------------------------
-- Database Helpers
--------------------------------------------------------------------------------

createPool :: BS.ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = Settings.connectionString (Text.pack (BS.unpack connStr))
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

-- | Install the pgmq schema via the native pg-migrate component.
--
-- The runner takes connection settings rather than the endurance pool: it
-- acquires its own connection for the migration advisory lock. Re-running
-- against an already-migrated database is a no-op.
installSchema :: BS.ByteString -> IO ()
installSchema connStr = do
  component <- case Migration.pgmqMigrations of
    Left err -> error $ "pgmq migration definition error: " <> show err
    Right component -> pure component
  plan <- case Migrate.migrationPlan (component :| []) of
    Left err -> error $ "pgmq migration plan error: " <> show err
    Right plan -> pure plan
  let connSettings = Settings.connectionString (Text.pack (BS.unpack connStr))
  result <- Migrate.runMigrationPlan Migrate.defaultRunOptions connSettings plan
  case result of
    Left err -> error $ "Migration error: " <> show err
    Right _report -> pure ()

createQueue :: Pool.Pool -> QueueName -> IO ()
createQueue pool qName = do
  result <- Pool.use pool $ Pgmq.createQueue qName
  case result of
    Left err -> error $ "Create queue error: " <> show err
    Right _ -> pure ()

dropQueue :: Pool.Pool -> QueueName -> IO ()
dropQueue pool qName = do
  _ <- Pool.use pool $ Pgmq.dropQueue qName
  pure ()
