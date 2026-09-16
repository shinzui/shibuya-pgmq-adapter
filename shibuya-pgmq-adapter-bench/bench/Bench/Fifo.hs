module Bench.Fifo (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueueWithHeaders,
    uniqueQueueName,
  )
import Control.Exception (bracket)
import Control.Monad (replicateM, replicateM_, unless, when)
import Data.List (sort)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Hasql
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), QueueName)
import Test.Tasty.Bench (Benchmark, Benchmarkable (..), bench, bgroup, nfIO)
import Text.Printf (printf)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "fifo"
    [ groupedBenchmarks pool config,
      roundRobinBenchmarks pool config,
      groupCountBenchmarks pool config,
      safeDrainBenchmarks pool config
    ]

groupedBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
groupedBenchmarks pool config =
  bgroup
    "grouped"
    [ bench "read-10" $ nfIO $ withFifoQueue pool config "grp10" 5000 10 $ \q -> runReadGrouped pool q 10,
      bench "read-50" $ nfIO $ withFifoQueue pool config "grp50" 5000 10 $ \q -> runReadGrouped pool q 50
    ]

roundRobinBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
roundRobinBenchmarks pool config =
  bgroup
    "round-robin"
    [ bench "read-10" $ nfIO $ withFifoQueue pool config "rr10" 5000 10 $ \q -> runReadGroupedRR pool q 10,
      bench "read-50" $ nfIO $ withFifoQueue pool config "rr50" 5000 10 $ \q -> runReadGroupedRR pool q 50
    ]

groupCountBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
groupCountBenchmarks pool config =
  bgroup
    "group-count"
    [ bench "single-group" $ nfIO $ withFifoQueue pool config "g1" 1000 1 $ \q -> runReadGrouped pool q 50,
      bench "10-groups" $ nfIO $ withFifoQueue pool config "g10" 1000 10 $ \q -> runReadGrouped pool q 50,
      bench "100-groups" $ nfIO $ withFifoQueue pool config "g100" 1000 100 $ \q -> runReadGrouped pool q 50
    ]

withFifoQueue :: Pool.Pool -> BenchConfig -> String -> Int -> Int -> (QueueName -> IO a) -> IO a
withFifoQueue pool config suffix count numGroups action = do
  let queue = benchQueueName ("fifo_" <> Text.pack suffix)
  createBenchQueue pool queue
  runSession pool $ Pgmq.createFifoIndex queue
  seedQueueWithHeaders pool queue count numGroups Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runReadGrouped :: Pool.Pool -> QueueName -> Int -> IO ()
runReadGrouped pool queue batchSize = do
  let req = Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = fromIntegral batchSize}
  msgs <- runSession pool $ Pgmq.readGrouped req
  deleteMessages pool queue msgs

runReadGroupedRR :: Pool.Pool -> QueueName -> Int -> IO ()
runReadGroupedRR pool queue batchSize = do
  let req = Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = fromIntegral batchSize}
  msgs <- runSession pool $ Pgmq.readGroupedRoundRobin req
  deleteMessages pool queue msgs

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()

data DrainFixture = DrainFixture
  { fixtureName :: !String,
    fixtureMessages :: !Int,
    fixtureGroups :: !Int
  }

data DrainMode
  = LegacyGroupedOne
  | GroupedHead !Int

data DrainResult = DrainResult
  { readStatements :: !Int,
    elapsedSeconds :: !Double
  }

safeDrainBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
safeDrainBenchmarks pool config =
  bgroup
    "safe-fifo-drain"
    [ safeDrainMatrix pool config (DrainFixture "10k-one-group" 10_000 1),
      safeDrainMatrix pool config (DrainFixture "10k-100-groups" 10_000 100),
      safeDrainMatrix pool config (DrainFixture "100k-10k-groups" 100_000 10_000)
    ]

safeDrainMatrix :: Pool.Pool -> BenchConfig -> DrainFixture -> Benchmark
safeDrainMatrix pool config fixture =
  bench fixture.fixtureName $
    Benchmarkable $ \outerRuns ->
      replicateM_ (fromIntegral outerRuns) $ do
        samples <-
          replicateM config.safeDrainRuns $ do
            baseline <- runSafeDrain pool config fixture LegacyGroupedOne
            heads <- traverse (runSafeDrain pool config fixture . GroupedHead) [1, 10, 50]
            pure (baseline, zip [1, 10, 50] heads)
        reportDrainMatrix fixture samples

runSafeDrain :: Pool.Pool -> BenchConfig -> DrainFixture -> DrainMode -> IO DrainResult
runSafeDrain pool config fixture mode =
  bracket setup cleanup $ \queue -> do
    start <- getMonotonicTimeNSec
    readCount <- drainQueue pool queue fixture.fixtureMessages mode
    end <- getMonotonicTimeNSec
    pure
      DrainResult
        { readStatements = readCount,
          elapsedSeconds = nanosecondsToSeconds (end - start)
        }
  where
    setup = do
      let fixtureKey = Text.pack (show fixture.fixtureMessages <> "_" <> show fixture.fixtureGroups)
      queue <- uniqueQueueName ("sfd_" <> fixtureKey <> "_" <> modeSuffix mode)
      createBenchQueue pool queue
      runSession pool $ Pgmq.createFifoIndex queue
      seedQueueWithHeaders pool queue fixture.fixtureMessages fixture.fixtureGroups Small
      pure queue

    cleanup queue =
      unless config.skipCleanup (dropBenchQueue pool queue)

drainQueue :: Pool.Pool -> QueueName -> Int -> DrainMode -> IO Int
drainQueue pool queue expected mode = go expected 0
  where
    go remaining readCount
      | remaining == 0 = pure readCount
      | otherwise = do
          messages <- runSession pool $ readBatch queue mode
          if V.null messages
            then fail $ "safe FIFO drain stalled with " <> show remaining <> " messages remaining"
            else do
              deleteMessages pool queue messages
              go (remaining - V.length messages) (readCount + 1)

readBatch :: QueueName -> DrainMode -> Hasql.Session (V.Vector Message)
readBatch queue = \case
  LegacyGroupedOne ->
    Pgmq.readGrouped Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = 1}
  GroupedHead batch ->
    Pgmq.readGroupedHead Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = fromIntegral batch}

reportDrainMatrix :: DrainFixture -> [(DrainResult, [(Int, DrainResult)])] -> IO ()
reportDrainMatrix fixture samples = do
  let baselines = map fst samples
      baselineMedian = median (map (.elapsedSeconds) baselines)
  reportMode fixture "legacy-grouped" 1 baselines Nothing
  mapM_
    ( \batch -> do
        let results = [result | (_, heads) <- samples, (candidate, result) <- heads, candidate == batch]
            ratio = median (map (.elapsedSeconds) results) / baselineMedian
        reportMode fixture "grouped-head" batch results (Just ratio)
    )
    [1, 10, 50]

reportMode :: DrainFixture -> String -> Int -> [DrainResult] -> Maybe Double -> IO ()
reportMode fixture mode batch results ratio = do
  let times = map (.elapsedSeconds) results
      readSamples = map (.readStatements) results
      expectedReads =
        if mode == "grouped-head"
          then ceilingDiv fixture.fixtureMessages (min batch fixture.fixtureGroups)
          else fixture.fixtureMessages
      medianSeconds = median times
      p95Seconds = percentile 0.95 times
      throughput = fromIntegral fixture.fixtureMessages / medianSeconds
      gate = maybe "baseline" (\value -> if value <= 1.2 then "pass" else "fail") ratio :: String
      ratioText = maybe "-" (printf "%.3f") ratio :: String
  unless (all (== expectedReads) readSamples) $
    fail $
      "unexpected safe FIFO read count: expected " <> show expectedReads <> ", got " <> show readSamples
  when (maybe False (> 1.2) ratio) $
    fail $
      "grouped-head safe drain exceeded the 20 percent gate with ratio " <> ratioText
  printf
    "SAFE-FIFO-DRAIN fixture=%s messages=%d groups=%d mode=%s batch=%d samples=%d reads=%s median=%.6fs p95=%.6fs throughput=%.2fmsg/s ratio=%s gate=%s\n"
    fixture.fixtureName
    fixture.fixtureMessages
    fixture.fixtureGroups
    mode
    batch
    (length results)
    (show readSamples)
    medianSeconds
    p95Seconds
    throughput
    ratioText
    gate

median :: [Double] -> Double
median values =
  case sort values of
    [] -> error "median requires at least one sample"
    sorted
      | odd count -> sorted !! midpoint
      | otherwise -> (sorted !! (midpoint - 1) + sorted !! midpoint) / 2
      where
        count = length sorted
        midpoint = count `div` 2

percentile :: Double -> [Double] -> Double
percentile quantile values =
  case sort values of
    [] -> error "percentile requires at least one sample"
    sorted -> sorted !! max 0 (min (length sorted - 1) (ceiling (quantile * fromIntegral (length sorted)) - 1))

modeSuffix :: DrainMode -> Text.Text
modeSuffix = \case
  LegacyGroupedOne -> "legacy_1"
  GroupedHead batch -> "heads_" <> Text.pack (show batch)

nanosecondsToSeconds :: Word64 -> Double
nanosecondsToSeconds value = fromIntegral value / 1_000_000_000

ceilingDiv :: Int -> Int -> Int
ceilingDiv numerator denominator = (numerator + denominator - 1) `div` denominator
