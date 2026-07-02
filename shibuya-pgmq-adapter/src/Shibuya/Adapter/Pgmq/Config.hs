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
    fifoConfig :: !(Maybe FifoConfig)
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
  deriving stock (Show, Eq, Generic)

-- | Validate adapter configuration before starting a source stream.
validateConfig :: PgmqAdapterConfig -> Either PgmqConfigError PgmqAdapterConfig
validateConfig config
  | config.batchSize < 1 = Left (InvalidBatchSize config.batchSize)
  | config.visibilityTimeout < 1 = Left (InvalidVisibilityTimeout config.visibilityTimeout)
  | Just halt <- config.haltVisibilityTimeout, halt < 1 = Left (InvalidHaltVisibilityTimeout halt)
  | config.maxRetries < 0 = Left (InvalidMaxRetries config.maxRetries)
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
      fifoConfig = Nothing
    }
