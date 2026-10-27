-- | Worker instrumentation shared unchanged with the fixed pre-feature source.
-- Each observation ends after the adapter's acknowledgement has returned.
module WorkerPerformance (runWorker) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Control.Exception (throwIO)
import Control.Monad (forM, forM_, replicateM_, unless, void)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.List (sort)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (allocated_bytes, getRTSStats)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import PerformanceDatabase (configureBenchmarkQueue, runPgmqSession, stabilizeBenchmarkQueues, withPgmqPools)
import Pgmq.Effectful (PgmqRuntimeError, runPgmq)
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.CPUTime (getCPUTime)
import System.Mem (performMajorGC)

runWorker :: String -> Int -> Int -> Int -> (Pool.Pool -> IORef Bool -> IO (IO Value)) -> IO Value
runWorker scenario warmup sample seeds prepare = do
  let (workers, batch, bytes, fifo, route, metadata) = case scenario of
        "ack-one" -> (1, 1, 100 :: Int, False, "none" :: String, False)
        "ack-four" -> (4, 50, 10000, False, "none", False)
        "ack-load-one" -> (4, 1, 1000, False, "none", False)
        "ack-load-fifty" -> (4, 50, 1000, False, "none", False)
        "fifo-load-one" -> (4, 1, 1000, True, "none", False)
        "fifo-load-fifty" -> (4, 50, 1000, True, "none", False)
        "ack-fifo" -> (4, 50, 10000, True, "none", False)
        "dlq-direct-meta" -> (4, 50, 1000, False, "direct", True)
        "dlq-direct-small" -> (4, 50, 1000, False, "direct", False)
        "dlq-topic-meta" -> (4, 50, 1000, False, "topic", True)
        "dlq-topic-small" -> (4, 50, 1000, False, "topic", False)
        _ -> error "unknown scenario"
      queue = checked (Pgmq.parseQueueName "perf_source")
      dlq = checked (Pgmq.parseQueueName "perf_dlq")
      secondDlq = checked (Pgmq.parseQueueName "perf_dlq_two")
      key = checked (Pgmq.parseRoutingKey "perf.failed")
      pattern' = checked (Pgmq.parseTopicPattern "perf.#")
      config =
        (defaultConfig queue)
          { batchSize = batch,
            visibilityTimeout = 300,
            polling = StandardPolling 0.001,
            fifoConfig = if fifo then Just (FifoConfig HeadPerGroup) else Nothing,
            deadLetterConfig = case route of
              "direct" -> Just (directDeadLetter dlq metadata)
              "topic" -> Just (topicDeadLetter key metadata)
              _ -> Nothing
          }
      decision = if route == "none" then AckOk else AckDeadLetter MaxRetriesExceeded
  unless (warmup >= 0 && sample > 0 && seeds > 0) $ error "invalid durations or fixture size"
  result <- withPgmqPools $ \pool adminPool -> do
    runPgmqSession pool $ do
      mapM_ Sessions.createQueue [queue, dlq, secondDlq]
      whenTopic route $ do
        Sessions.bindTopic (Q.BindTopic pattern' dlq)
        Sessions.bindTopic (Q.BindTopic pattern' secondDlq)
    mapM_ (configureBenchmarkQueue pool) [queue, dlq, secondDlq]
    runPgmqSession pool $
      Session.statement () $
        Statement.unpreparable
          ( "insert into pgmq.q_perf_source (vt, message, headers) select now(), to_jsonb(repeat('x', "
              <> Text.pack (show (bytes - 2))
              <> ")), jsonb_build_object('x-pgmq-group', (i % 100)::text) from generate_series(1, "
              <> Text.pack (show seeds)
              <> ") i"
          )
          E.noParams
          D.noResult
    databaseSettings <-
      runPgmqSession pool $
        Session.statement () $
          Statement.unpreparable
            "select jsonb_build_object('server_version', current_setting('server_version'), 'shared_buffers', current_setting('shared_buffers'), 'work_mem', current_setting('work_mem'), 'fsync', current_setting('fsync'), 'synchronous_commit', current_setting('synchronous_commit'), 'max_connections', current_setting('max_connections'), 'autovacuum_naptime', current_setting('autovacuum_naptime'), 'max_wal_size', current_setting('max_wal_size'), 'checkpoint_timeout', current_setting('checkpoint_timeout'))"
            E.noParams
            (D.singleRow (D.column (D.nonNullable D.jsonb)))
    measuring <- newIORef False
    observations <- newIORef ([] :: [Double])
    finishAdmin <- prepare adminPool measuring
    stabilizeBenchmarkQueues pool [queue, dlq, secondDlq]
    threads <- forM [1 .. workers :: Int] $ \_ -> async $ do
      outcome <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq pool $ runTracingNoop $ do
        adapter <- pgmqAdapter (mkPgmqAdapterEnv pool) config >>= either (error . show) pure
        Stream.fold Fold.drain $
          Stream.mapM
            ( \message -> do
                start <- liftIO getMonotonicTimeNSec
                message.ack.finalize decision
                end <- liftIO getMonotonicTimeNSec
                liftIO $ do
                  active <- readIORef measuring
                  if active && (case message.envelope.cursor of Just (CursorInt n) -> n <= fromIntegral seeds; _ -> error "worker fixture requires an original source message ID") then atomicModifyIORef' observations (\xs -> (fromIntegral (end - start) / 1e6 : xs, ())) else pure ()
            )
            adapter.source
      either throwIO pure outcome
    threadDelay (warmup * 1000000)
    performMajorGC
    before <- getRTSStats
    cpuBefore <- getCPUTime
    start <- getMonotonicTimeNSec
    writeIORef measuring True
    replicateM_ sample $ threadDelay 1000000
    writeIORef measuring False
    end <- getMonotonicTimeNSec
    cpuAfter <- getCPUTime
    forM_ threads $ \worker ->
      poll worker >>= \case
        Nothing -> pure ()
        Just (Left err) -> throwIO err
        Just (Right ()) -> error "worker stopped before measurement completed"
    adminResult <- finishAdmin
    mapM_ cancel threads
    performMajorGC
    after <- getRTSStats
    samples <- sort <$> readIORef observations
    remaining <- runPgmqSession pool $ Sessions.queueMetrics queue
    databaseIO <-
      runPgmqSession pool $
        Session.statement () $
          Statement.unpreparable
            "select jsonb_build_object('blocksRead', blks_read, 'blocksHit', blks_hit, 'tempBytes', temp_bytes, 'blockReadTimeMs', blk_read_time, 'blockWriteTimeMs', blk_write_time) from pg_stat_database where datname = current_database()"
            E.noParams
            (D.singleRow (D.column (D.nonNullable D.jsonb)))
    maintenance <-
      runPgmqSession pool $
        Session.statement () $
          Statement.unpreparable
            "select jsonb_build_object('tables', (select jsonb_agg(jsonb_build_object('table', pg_class.relname, 'options', reloptions, 'autoVacuumCount', autovacuum_count, 'autoAnalyzeCount', autoanalyze_count, 'manualVacuumCount', vacuum_count, 'manualAnalyzeCount', analyze_count, 'deadTuples', n_dead_tup)) from pg_class join pg_namespace on pg_namespace.oid = relnamespace join pg_stat_all_tables on pg_stat_all_tables.relid = pg_class.oid where nspname = 'pgmq' and pg_class.relname like 'q_perf_%'), 'checkpointer', (select to_jsonb(c) from pg_stat_checkpointer c))"
            E.noParams
            (D.singleRow (D.column (D.nonNullable D.jsonb)))
    let count = length samples
        seconds = fromIntegral (end - start) / 1e9 :: Double
        p95 = if count == 0 then 0 else samples !! min (count - 1) (ceiling (0.95 * fromIntegral count :: Double) - 1)
        valid = count >= 1000 && remaining.queueLength > fromIntegral (workers * fromIntegral batch)
    pure $
      object
        [ "workerProcessCPUSeconds" .= (fromIntegral (cpuAfter - cpuBefore) / 1e12 :: Double),
          "databaseIOCounters" .= databaseIO,
          "maintenance" .= maintenance,
          "administration" .= adminResult,
          "databaseSettings" .= databaseSettings,
          "scenario" .= scenario,
          "warmupSeconds" .= warmup,
          "sampleSeconds" .= seconds,
          "seedCount" .= seeds,
          "committed" .= count,
          "remaining" .= remaining.queueLength,
          "throughput" .= (fromIntegral count / seconds),
          "p95Ms" .= p95,
          "allocatedPerCommit" .= (fromIntegral (allocated_bytes after - allocated_bytes before) / fromIntegral (max 1 count) :: Double),
          "latenciesMs" .= samples,
          "valid" .= valid,
          "workerConnections" .= (4 :: Int),
          "workers" .= workers,
          "batchSize" .= batch,
          "bodyBytes" .= bytes,
          "fifo" .= fifo,
          "metadata" .= metadata
        ]
  either (error . show) pure result
  where
    checked = either (error . show) id
    whenTopic route action = if route == "topic" then void action else pure ()
