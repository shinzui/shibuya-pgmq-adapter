module Main (main) where

import Bench.Ack qualified as Ack
import Bench.Concurrent qualified as Concurrent
import Bench.Fifo qualified as Fifo
import Bench.MultiQueue qualified as MultiQueue
import Bench.Raw qualified as Raw
import Bench.Read qualified as Read
import Bench.Send qualified as Send
import Bench.Throughput qualified as Throughput
import BenchConfig (BenchConfig (..), loadConfig)
import BenchSetup (installPgmqSchema, withBenchPool)
import Test.Tasty.Bench (bgroup, defaultMain)

main :: IO ()
main = do
  config <- loadConfig
  withBenchPool config $ \pool -> do
    -- Install pgmq schema (idempotent)
    installPgmqSchema config.connectionString

    -- These Tasty actions include fixture setup and cleanup. Their reported
    -- times describe a queue lifecycle, not an isolated operation latency.
    defaultMain
      [ bgroup
          "queue-lifecycle"
          [ Send.benchmarks pool config,
            Read.benchmarks pool config,
            Ack.benchmarks pool config,
            Fifo.benchmarks pool config,
            MultiQueue.benchmarks pool config,
            Throughput.benchmarks pool config,
            Concurrent.benchmarks pool config,
            Raw.benchmarks pool config
          ]
      ]
