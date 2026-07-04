-- | PGMQ adapter for the Shibuya queue processing framework.
--
-- This adapter integrates with [pgmq](https://github.com/tembo-io/pgmq)
-- (PostgreSQL Message Queue) using the pgmq-hs client library.
--
-- == Example Usage
--
-- @
-- import Shibuya.App (runApp, QueueProcessor (..))
-- import Shibuya.Adapter.Pgmq
-- import Pgmq.Effectful (runPgmq)
-- import Hasql.Pool qualified as Pool
--
-- main :: IO ()
-- main = do
--   pool <- Pool.acquire 10 Nothing connectionSettings
--   case parseQueueName "orders" of
--     Left err -> print err
--     Right queueName -> do
--       let config = defaultConfig queueName
--       runEff
--         . runPgmq pool
--         $ do
--             Right adapter <- pgmqAdapter (mkPgmqAdapterEnv pool) config
--             result <- runApp IgnoreFailures 100
--               [ (ProcessorId "orders", QueueProcessor adapter handleOrder)
--               ]
--             -- ...
-- @
--
-- == Message Lifecycle
--
-- 1. Messages are read from pgmq with a visibility timeout
-- 2. During processing, messages are invisible to other consumers
-- 3. On 'AckOk', messages are deleted from the queue
-- 4. On 'AckRetry', visibility timeout is extended
-- 5. On 'AckDeadLetter', messages are archived or sent to DLQ
-- 6. On 'AckHalt', visibility timeout is extended and processor stops
--
-- == Retry Handling
--
-- pgmq tracks retry attempts via the 'readCount' field. When a message's
-- 'readCount' exceeds 'maxRetries' in the config, it is automatically
-- dead-lettered before being passed to the handler.
--
-- The current attempt (zero-indexed) is exposed on the envelope as
-- @envelope.attempt :: Maybe Attempt@. Handlers wanting exponential
-- backoff can use 'Shibuya.Core.Retry.retryWithBackoff':
--
-- @
-- import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)
--
-- handler ingested = do
--   result <- tryProcess ingested.envelope.payload
--   case result of
--     Right () -> pure AckOk
--     Left _  -> retryWithBackoff defaultBackoffPolicy ingested.envelope
-- @
--
-- The adapter clamps any 'Shibuya.Core.Ack.RetryDelay' to fit within
-- pgmq's @Int32@ second range (~68 years), so a long
-- 'Shibuya.Core.Retry.BackoffPolicy.maxDelay' is safe.
--
-- == FIFO Support
--
-- For ordered message processing, configure 'fifoConfig'. Messages are
-- grouped by the @x-pgmq-group@ header. Two strategies are available:
--
-- * 'ThroughputOptimized': Fill batches from the same group (SQS-like)
-- * 'RoundRobin': Fair distribution across groups
module Shibuya.Adapter.Pgmq
  ( -- * Adapter
    pgmqAdapter,

    -- * Configuration
    PgmqAdapterConfig (..),
    PgmqAdapterEnv (..),
    mkPgmqAdapterEnv,
    PgmqConfigError (..),
    PollingConfig (..),
    PollRetryConfig (..),
    PrefetchConfig (..),
    DeadLetterConfig (..),
    DeadLetterTarget (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    validateConfig,

    -- * Smart Constructors
    directDeadLetter,
    topicDeadLetter,

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,
    defaultPollRetryConfig,
    defaultPrefetchConfig,

    -- * Topic Management (pgmq 1.11.0+)
    bindQueueTopics,
    unbindQueueTopics,
    listQueueTopicBindings,
    testTopicRouting,

    -- * Re-exports from pgmq
    QueueName,
    parseQueueName,
    queueNameToText,

    -- ** Topic Types (pgmq 1.11.0+)
    RoutingKey,
    parseRoutingKey,
    routingKeyToText,
    TopicPattern,
    parseTopicPattern,
    topicPatternToText,
    TopicBinding (..),
    RoutingMatch (..),
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Function ((&))
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Pgmq.Effectful (PgmqRuntimeError)
import Pgmq.Effectful.Effect (Pgmq)
import Pgmq.Effectful.Effect qualified as PgmqEff
import Pgmq.Hasql.Statements.Types qualified as PgmqTypes
import Pgmq.Types
  ( QueueName,
    RoutingKey,
    RoutingMatch (..),
    TopicBinding (..),
    TopicPattern,
    parseQueueName,
    parseRoutingKey,
    parseTopicPattern,
    queueNameToText,
    routingKeyToText,
    topicPatternToText,
  )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq.Config
  ( DeadLetterConfig (..),
    DeadLetterTarget (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PgmqAdapterEnv (..),
    PgmqConfigError (..),
    PollRetryConfig (..),
    PollingConfig (..),
    PrefetchConfig (..),
    defaultConfig,
    defaultPollRetryConfig,
    defaultPollingConfig,
    defaultPrefetchConfig,
    directDeadLetter,
    mkPgmqAdapterEnv,
    topicDeadLetter,
    validateConfig,
  )
import Shibuya.Adapter.Pgmq.Internal (mkIngested, pgmqChunks, pgmqChunksPrefetch, releaseMessages)
import Shibuya.Core.Ingested (Ingested)
import Shibuya.Telemetry.Effect (Tracing)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP
import Streamly.Data.Unfold qualified as Unfold

-- | Create a PGMQ adapter with the given configuration.
--
-- The adapter provides:
--
-- * A stream of messages from the configured queue
-- * Automatic visibility timeout management
-- * Lease extension capability for long-running handlers
-- * Dead-letter queue support (optional)
-- * FIFO ordering support (optional)
-- * Typed configuration validation
--
-- == Effect Requirements
--
-- This adapter requires the 'Pgmq' effect to be available in your effect stack.
-- You must run 'Pgmq.Effectful.runPgmq' with a connection pool before using
-- this adapter.
--
-- == Example
--
-- @
-- Right adapter <- pgmqAdapter env config
-- runApp IgnoreFailures 100
--   [ (ProcessorId "my-processor", QueueProcessor adapter myHandler)
--   ]
-- @
pgmqAdapter ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Eff es (Either PgmqConfigError (Adapter es Value))
pgmqAdapter env config =
  case validateConfig config of
    Left err -> pure (Left err)
    Right validConfig -> do
      shutdownVar <- liftIO $ newTVarIO False
      let messageSource = pgmqSourceWithShutdown env validConfig shutdownVar
      pure $
        Right
          Adapter
            { adapterName = "pgmq:" <> queueNameToText validConfig.queueName,
              source = messageSource,
              shutdown = liftIO $ atomically $ writeTVar shutdownVar True
            }

-- | Poll in chunks so a shutdown can release messages that were read from pgmq
-- but not yet handed to Shibuya's bounded inbox.
pgmqSourceWithShutdown ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  TVar Bool ->
  Stream (Eff es) (Ingested es Value)
pgmqSourceWithShutdown env config shutdownVar =
  chunkStream
    & Stream.filter (not . Vector.null)
    & Stream.takeWhileM keepChunk
    & Stream.unfoldEach (Unfold.unfoldr Vector.uncons)
    & Stream.mapMaybeM (mkIngested env config)
  where
    -- Only the polling stage is prefetched (and only under a locally-scoped
    -- ConcUnlift, see 'pgmqChunksPrefetch'). The shutdown gate, flatten, and
    -- 'mkIngested'/finalization stages stay on the consumer thread. When
    -- prefetch is disabled the stream is exactly 'pgmqChunks config', running
    -- under the default SeqUnlift strategy with no added overhead.
    chunkStream = case config.prefetchConfig of
      Nothing -> pgmqChunks config
      Just prefetch ->
        pgmqChunksPrefetch (StreamP.maxBuffer (fromIntegral prefetch.bufferSize)) config
    keepChunk chunk = do
      isShutdown <- liftIO $ readTVarIO shutdownVar
      if isShutdown
        then do
          releaseMessages env config chunk
          pure False
        else pure True

--------------------------------------------------------------------------------
-- Topic Management (pgmq 1.11.0+)
--------------------------------------------------------------------------------

-- | Bind multiple topic patterns to a queue.
-- Each pattern is bound idempotently (re-binding an existing pattern is a no-op).
--
-- Example:
--
-- @
-- bindQueueTopics ordersQueueName
--   [ pattern | Right pattern <- [parseTopicPattern "orders.#", parseTopicPattern "*.created"] ]
-- @
bindQueueTopics ::
  (Pgmq :> es) =>
  QueueName ->
  [TopicPattern] ->
  Eff es ()
bindQueueTopics queueName patterns =
  forM_ patterns $ \tp ->
    PgmqEff.bindTopic
      PgmqTypes.BindTopic
        { topicPattern = tp,
          queueName = queueName
        }

-- | Unbind multiple topic patterns from a queue.
-- Returns silently for patterns that were not bound.
unbindQueueTopics ::
  (Pgmq :> es) =>
  QueueName ->
  [TopicPattern] ->
  Eff es ()
unbindQueueTopics queueName patterns =
  forM_ patterns $ \tp ->
    PgmqEff.unbindTopic
      PgmqTypes.UnbindTopic
        { topicPattern = tp,
          queueName = queueName
        }

-- | List all topic bindings for a specific queue.
listQueueTopicBindings ::
  (Pgmq :> es) =>
  QueueName ->
  Eff es [TopicBinding]
listQueueTopicBindings = PgmqEff.listTopicBindingsForQueue

-- | Test which queues a routing key would match, without sending any messages.
-- Useful for validating topic routing configuration.
testTopicRouting ::
  (Pgmq :> es) =>
  RoutingKey ->
  Eff es [RoutingMatch]
testTopicRouting = PgmqEff.testRouting
