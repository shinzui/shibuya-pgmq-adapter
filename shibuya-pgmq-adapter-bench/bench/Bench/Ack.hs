module Bench.Ack (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
  )
import Control.Exception (finally)
import Control.Monad (unless)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), MessageId, QueueName)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "ack"
    [ deleteBenchmarks pool config,
      archiveBenchmarks pool config,
      vtBenchmarks pool config,
      popBenchmarks pool config
    ]

deleteBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
deleteBenchmarks pool config =
  bgroup
    "delete"
    [ bench "single" $ nfIO $ withSeededQueue pool config "del1" 10000 $ runDeleteSingle pool,
      bench "batch-10" $ nfIO $ withSeededQueue pool config "del10" 10000 $ \q -> runDeleteBatch pool q 10,
      bench "batch-100" $ nfIO $ withSeededQueue pool config "del100" 10000 $ \q -> runDeleteBatch pool q 100
    ]

archiveBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
archiveBenchmarks pool config =
  bgroup
    "archive"
    [ bench "single" $ nfIO $ withSeededQueue pool config "arch1" 10000 $ runArchiveSingle pool,
      bench "batch-10" $ nfIO $ withSeededQueue pool config "arch10" 10000 $ \q -> runArchiveBatch pool q 10
    ]

vtBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
vtBenchmarks pool config =
  bgroup
    "set-vt"
    [ bench "single" $ nfIO $ withSeededQueue pool config "vt1" 10000 $ runSetVtSingle pool,
      bench "batch-10" $ nfIO $ withSeededQueue pool config "vt10" 10000 $ \q -> runSetVtBatch pool q 10
    ]

popBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
popBenchmarks pool config =
  bgroup
    "pop"
    [ bench "single" $ nfIO $ withSeededQueue pool config "pop1" 10000 $ runPopSingle pool,
      bench "batch-10" $ nfIO $ withSeededQueue pool config "pop10" 10000 $ \q -> runPopBatch pool q 10
    ]

withSeededQueue :: Pool.Pool -> BenchConfig -> String -> Int -> (QueueName -> IO a) -> IO a
withSeededQueue pool config suffix count action = do
  let queue = benchQueueName ("ack_" <> Text.pack suffix)
  createBenchQueue pool queue
  seedQueue pool queue count Small
  action queue `finally` do
    purgeQueue pool queue
    if config.skipCleanup then pure () else dropBenchQueue pool queue

readMessages :: Pool.Pool -> QueueName -> Int -> IO [MessageId]
readMessages pool queue n = do
  let req = Q.ReadMessage {queueName = queue, delay = 300, batchSize = Just (fromIntegral n), conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage req
  unless (V.length msgs == n) $ fail "benchmark fixture returned an incomplete batch"
  pure $ V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs

runDeleteSingle :: Pool.Pool -> QueueName -> IO ()
runDeleteSingle pool queue = do
  msgIds <- readMessages pool queue 1
  case msgIds of
    (msgId : _) -> do
      _ <- runSession pool $ Pgmq.deleteMessage Q.MessageQuery {queueName = queue, messageId = msgId}
      pure ()
    [] -> fail "benchmark fixture returned no message"

runDeleteBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runDeleteBatch pool queue n = do
  msgIds <- readMessages pool queue n
  if null msgIds
    then fail "benchmark fixture returned no messages"
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()

runArchiveSingle :: Pool.Pool -> QueueName -> IO ()
runArchiveSingle pool queue = do
  msgIds <- readMessages pool queue 1
  case msgIds of
    (msgId : _) -> do
      _ <- runSession pool $ Pgmq.archiveMessage Q.MessageQuery {queueName = queue, messageId = msgId}
      pure ()
    [] -> fail "benchmark fixture returned no message"

runArchiveBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runArchiveBatch pool queue n = do
  msgIds <- readMessages pool queue n
  if null msgIds
    then fail "benchmark fixture returned no messages"
    else do
      _ <- runSession pool $ Pgmq.batchArchiveMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()

runSetVtSingle :: Pool.Pool -> QueueName -> IO ()
runSetVtSingle pool queue = do
  msgIds <- readMessages pool queue 1
  case msgIds of
    (msgId : _) -> do
      _ <- runSession pool $ Pgmq.changeVisibilityTimeout Q.VisibilityTimeoutQuery {queueName = queue, messageId = msgId, visibilityTimeoutOffset = 60}
      pure ()
    [] -> fail "benchmark fixture returned no message"

runSetVtBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runSetVtBatch pool queue n = do
  msgIds <- readMessages pool queue n
  if null msgIds
    then fail "benchmark fixture returned no messages"
    else do
      _ <- runSession pool $ Pgmq.batchChangeVisibilityTimeout Q.BatchVisibilityTimeoutQuery {queueName = queue, messageIds = msgIds, visibilityTimeoutOffset = 60}
      pure ()

runPopSingle :: Pool.Pool -> QueueName -> IO ()
runPopSingle pool queue = do
  _ <- runSession pool $ Pgmq.pop Q.PopMessage {queueName = queue, qty = Just 1}
  pure ()

runPopBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runPopBatch pool queue n = do
  _ <- runSession pool $ Pgmq.pop Q.PopMessage {queueName = queue, qty = Just (fromIntegral n)}
  pure ()
