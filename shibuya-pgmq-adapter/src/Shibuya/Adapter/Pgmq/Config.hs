-- | Configuration types for the PGMQ adapter.
module Shibuya.Adapter.Pgmq.Config
  ( -- * Main Configuration
    PgmqAdapterConfig (..),
    PgmqAdapterEnv (..),
    mkPgmqAdapterEnv,
    PgmqConfigError (..),
    validateConfig,

    -- * Polling Configuration
    PollingConfig (..),
    PollRetryConfig (..),

    -- * Prefetch Configuration
    PrefetchConfig (..),
    defaultPrefetchConfig,

    -- * Dead-Letter Queue Configuration
    DeadLetterConfig (..),
    DeadLetterTarget (..),

    -- * Smart Constructors
    directDeadLetter,
    topicDeadLetter,

    -- * FIFO Configuration
    FifoConfig (..),
    FifoReadStrategy (..),

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,
    defaultPollRetryConfig,
  )
where

import Data.Int (Int32, Int64)
import Data.Time (NominalDiffTime)
import GHC.Generics (Generic)
import Hasql.Pool qualified as Pool
import Numeric.Natural (Natural)
import Pgmq.Effectful (PgmqRuntimeError)
import Pgmq.Types (QueueName, RoutingKey)
import Pgmq.Types qualified as Pgmq

-- | Runtime resources and callbacks used by the adapter.
data PgmqAdapterEnv = PgmqAdapterEnv
  { -- | Connection pool used for operations that need one transaction.
    pool :: !Pool.Pool,
    -- | Called when the source stream dead-letters an over-retried message.
    onAutoDeadLetter :: Pgmq.Message -> IO (),
    -- | Called when an ack path fails after retry or fails permanently.
    onAckFailure :: Pgmq.Message -> PgmqRuntimeError -> IO ()
  }

-- | Build an adapter environment with no-op callbacks.
mkPgmqAdapterEnv :: Pool.Pool -> PgmqAdapterEnv
mkPgmqAdapterEnv pool =
  PgmqAdapterEnv
    { pool = pool,
      onAutoDeadLetter = const (pure ()),
      onAckFailure = \_ _ -> pure ()
    }

-- | Configuration for the PGMQ adapter.
data PgmqAdapterConfig = PgmqAdapterConfig
  { -- | Name of the queue to consume from.
    queueName :: !QueueName,
    -- | Visibility timeout in seconds. Messages become invisible for this duration after being read.
    visibilityTimeout :: !Int32,
    -- | Maximum number of messages to read per poll.
    batchSize :: !Int32,
    -- | Polling configuration.
    polling :: !PollingConfig,
    -- | Retry policy for transient errors during queue polling.
    pollRetry :: !PollRetryConfig,
    -- | Retry policy for transient errors during acknowledgement operations.
    ackRetry :: !PollRetryConfig,
    -- | Optional dead-letter queue configuration.
    deadLetterConfig :: !(Maybe DeadLetterConfig),
    -- | Optional visibility timeout used for 'AckHalt'. Falls back to 'visibilityTimeout'.
    haltVisibilityTimeout :: !(Maybe Int32),
    -- | Maximum deliveries before dead-lettering.
    --
    -- This is based on pgmq's readCount field, which counts deliveries, not
    -- handler failures. A value of 0 is valid and auto-dead-letters every
    -- message before processing.
    maxRetries :: !Int64,
    -- | Optional FIFO mode configuration.
    fifoConfig :: !(Maybe FifoConfig),
    -- | Optional concurrent prefetch configuration.
    --
    -- When 'Just', the polling stage runs on a background worker under
    -- effectful's 'ConcUnlift' strategy so streamly's @parBuffered@ may unlift
    -- 'Eff' off-thread (see "Shibuya.Adapter.Pgmq.Internal".@pgmqChunksPrefetch@).
    -- When 'Nothing' (the default), the source runs on the default 'SeqUnlift'
    -- strategy with no added overhead.
    --
    -- See 'PrefetchConfig' for the visibility-timeout trade-off and the bounded,
    -- loss-free shutdown behaviour (buffered messages are redelivered after
    -- their visibility timeout rather than released immediately).
    prefetchConfig :: !(Maybe PrefetchConfig)
  }
  deriving stock (Show, Eq, Generic)

-- | Typed configuration validation errors.
data PgmqConfigError
  = InvalidBatchSize !Int32
  | InvalidVisibilityTimeout !Int32
  | InvalidStandardPollInterval !NominalDiffTime
  | InvalidLongPollSeconds !Int32
  | InvalidLongPollIntervalMs !Int32
  | InvalidMaxRetries !Int64
  | InvalidHaltVisibilityTimeout !Int32
  | InvalidPollRetryMaxAttempts !Int
  | InvalidPollRetryBackoff !NominalDiffTime !NominalDiffTime
  | InvalidAckRetryMaxAttempts !Int
  | InvalidAckRetryBackoff !NominalDiffTime !NominalDiffTime
  | InvalidPrefetchBufferSize !Natural
  deriving stock (Show, Eq, Generic)

-- | Validate adapter configuration before starting a source stream.
validateConfig :: PgmqAdapterConfig -> Either PgmqConfigError PgmqAdapterConfig
validateConfig config
  | config.batchSize < 1 = Left (InvalidBatchSize config.batchSize)
  | config.visibilityTimeout < 1 = Left (InvalidVisibilityTimeout config.visibilityTimeout)
  | Just halt <- config.haltVisibilityTimeout, halt < 1 = Left (InvalidHaltVisibilityTimeout halt)
  | config.maxRetries < 0 = Left (InvalidMaxRetries config.maxRetries)
  | Just prefetch <- config.prefetchConfig,
    prefetch.bufferSize == 0 =
      Left (InvalidPrefetchBufferSize prefetch.bufferSize)
  | otherwise = do
      validatePolling config.polling
      validateRetry InvalidPollRetryMaxAttempts InvalidPollRetryBackoff config.pollRetry
      validateRetry InvalidAckRetryMaxAttempts InvalidAckRetryBackoff config.ackRetry
      pure config
  where
    validatePolling = \case
      StandardPolling interval
        | interval <= 0 -> Left (InvalidStandardPollInterval interval)
        | otherwise -> Right ()
      LongPolling maxPollSeconds pollIntervalMs
        | maxPollSeconds < 1 -> Left (InvalidLongPollSeconds maxPollSeconds)
        | pollIntervalMs < 1 -> Left (InvalidLongPollIntervalMs pollIntervalMs)
        | otherwise -> Right ()

    validateRetry maxAttemptsErr backoffErr retry
      | retry.maxAttempts < 1 = Left (maxAttemptsErr retry.maxAttempts)
      | retry.initialBackoff < 0 || retry.maxBackoff < 0 =
          Left (backoffErr retry.initialBackoff retry.maxBackoff)
      | otherwise = Right ()

-- | Retry policy for transient database errors.
data PollRetryConfig = PollRetryConfig
  { -- | Total attempts, including the first attempt.
    maxAttempts :: !Int,
    -- | Delay before the first retry.
    initialBackoff :: !NominalDiffTime,
    -- | Maximum delay between retry attempts.
    maxBackoff :: !NominalDiffTime
  }
  deriving stock (Show, Eq, Generic)

-- | Configuration for concurrent prefetch.
--
-- When enabled, the polling stage buffers the next batches on a background
-- worker while the current messages are being processed, overlapping database
-- latency with handler work.
--
-- Trade-off: prefetched messages have their visibility timeout ticking while
-- buffered, so ensure
-- @bufferSize * batchSize * avgProcessingTime < visibilityTimeout@.
--
-- === Shutdown behaviour (no data loss)
--
-- Because prefetch reads message batches /ahead/ of processing, a shutdown can
-- leave up to @bufferSize * batchSize@ already-read messages sitting in the
-- prefetch buffer without being handed to a handler. Unlike the non-prefetch
-- path — which releases just-read, undispatched messages immediately on
-- shutdown — these buffered messages are not released promptly.
--
-- __No messages are lost.__ A pgmq read only sets a message's visibility
-- timeout; it never deletes the message. Any message that was read but not
-- acknowledged stays in the queue and pgmq redelivers it once its visibility
-- timeout expires. The only effect is that, after a shutdown, redelivery of
-- those buffered messages is /delayed/ by up to 'visibilityTimeout' seconds.
-- This is a bounded, at-least-once-safe edge case (delayed processing, not data
-- loss), inherent to reading ahead; it is verified by the adapter's test suite.
data PrefetchConfig = PrefetchConfig
  { -- | Number of batches to buffer ahead of consumption (default: 4).
    -- Higher values reduce latency but increase visibility-timeout pressure.
    -- Must be greater than zero (rejected by 'validateConfig' otherwise).
    bufferSize :: !Natural
  }
  deriving stock (Show, Eq, Generic)

-- | Polling strategy for reading messages.
data PollingConfig
  = -- | Standard polling with sleep between reads when queue is empty.
    StandardPolling
      { -- | Interval between polls when no messages are available.
        pollInterval :: !NominalDiffTime
      }
  | -- | Long polling blocks in PostgreSQL until messages are available or the wait expires.
    LongPolling
      { -- | Maximum seconds to wait for messages.
        maxPollSeconds :: !Int32,
        -- | Interval between database checks in milliseconds.
        pollIntervalMs :: !Int32
      }
  deriving stock (Show, Eq, Generic)

-- | Target for dead-lettered messages.
data DeadLetterTarget
  = -- | Send directly to a specific queue.
    DirectQueue !QueueName
  | -- | Route via topic pattern matching.
    TopicRoute !RoutingKey
  deriving stock (Show, Eq, Generic)

-- | Configuration for dead-letter queue handling.
data DeadLetterConfig = DeadLetterConfig
  { -- | Where to send dead-lettered messages.
    dlqTarget :: !DeadLetterTarget,
    -- | Whether to include original message metadata in DLQ message.
    includeMetadata :: !Bool
  }
  deriving stock (Show, Eq, Generic)

-- | Create a dead-letter config targeting a specific queue directly.
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig
directDeadLetter queueName metadata =
  DeadLetterConfig
    { dlqTarget = DirectQueue queueName,
      includeMetadata = metadata
    }

-- | Create a dead-letter config using topic-based routing.
topicDeadLetter :: RoutingKey -> Bool -> DeadLetterConfig
topicDeadLetter routingKey metadata =
  DeadLetterConfig
    { dlqTarget = TopicRoute routingKey,
      includeMetadata = metadata
    }

-- | FIFO queue configuration for ordered message processing.
data FifoConfig = FifoConfig
  { -- | Strategy for reading messages from FIFO queue.
    readStrategy :: !FifoReadStrategy
  }
  deriving stock (Show, Eq, Generic)

-- | Strategy for reading messages from FIFO queues.
data FifoReadStrategy
  = -- | Fill batch from same message group first.
    ThroughputOptimized
  | -- | Fair round-robin distribution across groups.
    RoundRobin
  deriving stock (Show, Eq, Generic)

-- | Default polling configuration using standard polling with 1 second interval.
defaultPollingConfig :: PollingConfig
defaultPollingConfig = StandardPolling {pollInterval = 1}

-- | Default retry policy for transient database errors.
defaultPollRetryConfig :: PollRetryConfig
defaultPollRetryConfig =
  PollRetryConfig
    { maxAttempts = 5,
      initialBackoff = 0.1,
      maxBackoff = 5
    }

-- | Default prefetch configuration: buffers 4 batches ahead.
defaultPrefetchConfig :: PrefetchConfig
defaultPrefetchConfig = PrefetchConfig {bufferSize = 4}

-- | Default adapter configuration.
defaultConfig :: QueueName -> PgmqAdapterConfig
defaultConfig name =
  PgmqAdapterConfig
    { queueName = name,
      visibilityTimeout = 30,
      batchSize = 1,
      polling = defaultPollingConfig,
      pollRetry = defaultPollRetryConfig,
      ackRetry = defaultPollRetryConfig,
      deadLetterConfig = Nothing,
      haltVisibilityTimeout = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing
    }
