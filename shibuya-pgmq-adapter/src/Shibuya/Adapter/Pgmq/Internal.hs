-- | Internal implementation details for the PGMQ adapter.
-- This module is not part of the public API and may change without notice.
module Shibuya.Adapter.Pgmq.Internal
  ( -- * Stream Construction
    pgmqSource,
    pgmqChunks,
    pgmqChunksPrefetch,
    pgmqMessages,
    releaseMessages,

    -- * Ingested Construction
    mkIngested,
    finalizeAutoDeadLetter,

    -- * AckHandle Construction
    mkAckHandle,
    mergeDlqHeaders,

    -- * Lease Construction
    mkLease,

    -- * Query Construction
    mkReadMessage,
    mkReadWithPoll,
    mkReadGrouped,
    mkReadGroupedWithPoll,

    -- * Utilities
    nominalToSeconds,
    retryingTransient,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime, nominalDiffTimeToSeconds)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful
  ( Eff,
    IOE,
    Limit (..),
    Persistence (..),
    UnliftStrategy (..),
    withUnliftStrategy,
    (:>),
  )
import Effectful.Error.Static (Error, catchError, throwError)
import Hasql.Pool qualified as Pool
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Pgmq.Effectful (PgmqRuntimeError, fromUsageError, isTransient)
import Pgmq.Effectful.Effect
  ( Pgmq,
    archiveMessage,
    batchChangeVisibilityTimeout,
    changeVisibilityTimeout,
    deleteMessage,
    readGrouped,
    readGroupedRoundRobin,
    readGroupedRoundRobinWithPoll,
    readGroupedWithPoll,
    readMessage,
    readWithPoll,
    setVisibilityTimeoutAt,
  )
import Pgmq.Hasql.Statements.Message qualified as Msg
import Pgmq.Hasql.Statements.Types
  ( BatchVisibilityTimeoutQuery (..),
    MessageQuery (..),
    ReadGrouped (..),
    ReadGroupedWithPoll (..),
    ReadMessage (..),
    ReadWithPollMessage (..),
    SendMessage (..),
    SendMessageWithHeaders (..),
    SendTopic (..),
    SendTopicWithHeaders (..),
    VisibilityTimeoutAtQuery (..),
    VisibilityTimeoutQuery (..),
  )
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Config
  ( DeadLetterConfig (..),
    DeadLetterTarget (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PgmqAdapterEnv (..),
    PollRetryConfig (..),
    PollingConfig (..),
  )
import Shibuya.Adapter.Pgmq.Convert
  ( mkDlqPayload,
    pgmqMessageToEnvelope,
  )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Types (TraceHeaders)
import Shibuya.Telemetry.Effect (Tracing)
import Shibuya.Telemetry.Propagation (currentTraceHeaders)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP
import Streamly.Data.Unfold qualified as Unfold

-- | Convert 'NominalDiffTime' to seconds as 'Int32', saturating at the
-- 'Int32' bounds.
--
-- Used when extending pgmq visibility timeouts ('AckRetry', 'AckHalt', and
-- lease extension). pgmq's @changeVisibilityTimeout@ accepts 'Int32'
-- seconds; values larger than @maxBound@ (~68 years) silently wrap under
-- the previous @ceiling . nominalDiffTimeToSeconds@ implementation. This
-- helper saturates instead, so a misconfigured 'BackoffPolicy.maxDelay'
-- produces a merely-very-long retry rather than a corrupt or
-- panic-inducing one.
nominalToSeconds :: NominalDiffTime -> Int32
nominalToSeconds dt =
  let seconds :: Double
      seconds = realToFrac (nominalDiffTimeToSeconds dt)
      maxSec :: Double
      maxSec = fromIntegral (maxBound :: Int32)
      minSec :: Double
      minSec = fromIntegral (minBound :: Int32)
      clamped = max minSec (min maxSec seconds)
   in ceiling clamped

-- | Create a ReadMessage query from config.
mkReadMessage :: PgmqAdapterConfig -> ReadMessage
mkReadMessage config =
  ReadMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      conditional = Nothing
    }

-- | Create a ReadWithPollMessage query from config.
mkReadWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadWithPollMessage
mkReadWithPoll config maxSec intervalMs =
  ReadWithPollMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs,
      conditional = Nothing
    }

-- | Create a ReadGrouped query from config.
mkReadGrouped :: PgmqAdapterConfig -> ReadGrouped
mkReadGrouped config =
  ReadGrouped
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize
    }

-- | Create a ReadGroupedWithPoll query from config.
mkReadGroupedWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadGroupedWithPoll
mkReadGroupedWithPoll config maxSec intervalMs =
  ReadGroupedWithPoll
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs
    }

-- | Create a Lease for visibility timeout extension.
mkLease ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Lease es)
mkLease config msg = do
  lastVtRef <- liftIO $ newIORef msg.visibilityTime
  pure
    Lease
      { leaseId = Text.pack (show (Pgmq.unMessageId msg.messageId)),
        leaseExtend = \duration -> do
          now <- liftIO getCurrentTime
          lastVt <- liftIO $ readIORef lastVtRef
          let target = max lastVt (addUTCTime duration now)
          updated <-
            retryingTransient config.ackRetry $
              setVisibilityTimeoutAt $
                VisibilityTimeoutAtQuery
                  { queueName = config.queueName,
                    messageId = msg.messageId,
                    visibilityTime = target
                  }
          liftIO $ writeIORef lastVtRef updated.visibilityTime
      }

-- | Create an AckHandle for a message.
--
-- The 'AckDeadLetter' branch threads the *consumer's* current trace
-- context (looked up via 'currentTraceHeaders' against the active OTel
-- span) into the DLQ message's headers. The original producer's
-- @traceparent@/@tracestate@ are preserved under the
-- @x-shibuya-upstream-traceparent@ / @x-shibuya-upstream-tracestate@
-- keys so a DLQ post-mortem can walk back to the origin if it wants.
-- When tracing is disabled (or there is no active span at the call
-- site), the original headers are forwarded verbatim — exactly the
-- pre-0.5.0.0 behavior. See plan 1 / Finding F3 in the parent
-- shibuya repo's plan 9.
mkAckHandle ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  IORef Bool ->
  Pgmq.Message ->
  AckHandle es
mkAckHandle env config finalizedRef msg = AckHandle $ \decision -> do
  alreadyFinalized <- liftIO $ readIORef finalizedRef
  if alreadyFinalized
    then pure ()
    else do
      runDecision decision
      liftIO $ writeIORef finalizedRef True
  where
    queueName = config.queueName
    msgId = msg.messageId

    runDecision decision = retryingTransient config.ackRetry $ case decision of
      AckOk -> do
        -- Successfully processed - delete from queue
        void $ deleteMessage (MessageQuery queueName msgId)
      AckRetry (RetryDelay delay) -> do
        -- Retry after delay - extend visibility timeout
        let vtSeconds = nominalToSeconds delay
        void $
          changeVisibilityTimeout $
            VisibilityTimeoutQuery
              { queueName = queueName,
                messageId = msgId,
                visibilityTimeoutOffset = vtSeconds
              }
      AckDeadLetter reason -> do
        -- Handle dead-lettering
        case config.deadLetterConfig of
          Nothing ->
            -- No DLQ configured - just archive the message
            void $ archiveMessage (MessageQuery queueName msgId)
          Just dlqConfig -> do
            consumerHdrs <- currentTraceHeaders
            deadLetterTransactionally env config dlqConfig msg reason (mergeDlqHeaders consumerHdrs msg.headers)
      AckHalt _reason -> do
        -- Park the message by reassigning its visibility timeout. It becomes
        -- visible to any consumer after this many seconds, independent of restart.
        let vtSeconds = maybe config.visibilityTimeout id config.haltVisibilityTimeout
        void $
          changeVisibilityTimeout $
            VisibilityTimeoutQuery
              { queueName = queueName,
                messageId = msgId,
                visibilityTimeoutOffset = vtSeconds
              }

deadLetterTransactionally ::
  (Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  DeadLetterConfig ->
  Pgmq.Message ->
  DeadLetterReason ->
  Maybe Value ->
  Eff es ()
deadLetterTransactionally env config dlqConfig msg reason dlqHeaders = do
  result <- liftIO $ Pool.use env.pool session
  case result of
    Left err -> throwError (fromUsageError err)
    Right () -> pure ()
  where
    dlqBody = mkDlqPayload msg reason dlqConfig.includeMetadata
    sourceQuery = MessageQuery config.queueName msg.messageId
    session =
      Transaction.Sessions.transaction
        Transaction.Sessions.ReadCommitted
        Transaction.Sessions.Write
        tx
    tx = do
      case dlqConfig.dlqTarget of
        DirectQueue dlqQueueName ->
          case dlqHeaders of
            Just headers ->
              void $
                Transaction.statement
                  SendMessageWithHeaders
                    { queueName = dlqQueueName,
                      messageBody = dlqBody,
                      messageHeaders = Pgmq.MessageHeaders headers,
                      delay = Nothing
                    }
                  Msg.sendMessageWithHeaders
            Nothing ->
              void $
                Transaction.statement
                  SendMessage
                    { queueName = dlqQueueName,
                      messageBody = dlqBody,
                      delay = Nothing
                    }
                  Msg.sendMessage
        TopicRoute routingKey ->
          case dlqHeaders of
            Just headers ->
              void $
                Transaction.statement
                  SendTopicWithHeaders
                    { routingKey = routingKey,
                      messageBody = dlqBody,
                      messageHeaders = Pgmq.MessageHeaders headers,
                      delay = Nothing
                    }
                  Msg.sendTopicWithHeaders
            Nothing ->
              void $
                Transaction.statement
                  SendTopic
                    { routingKey = routingKey,
                      messageBody = dlqBody,
                      delay = Nothing
                    }
                  Msg.sendTopic
      void $ Transaction.statement sourceQuery Msg.deleteMessage

-- | Merge the consumer's current trace headers with the original
-- message's headers JSON for the DLQ-write path.
--
-- Rules:
--
-- * If the consumer has no active span (tracing disabled, or
--   producer-side path runs outside any 'withSpan'), forward the
--   original headers verbatim — matches the pre-0.5.0.0 behavior.
-- * Otherwise, the consumer's @traceparent@ overrides the original's
--   active @traceparent@; the original's @traceparent@ /
--   @tracestate@ (if present) move to
--   @x-shibuya-upstream-traceparent@ / @x-shibuya-upstream-tracestate@.
--
-- Returns 'Nothing' only if both inputs are empty (no consumer
-- context AND no original headers); in that case the caller falls
-- through to the no-headers @sendMessage@/@sendTopic@ path.
mergeDlqHeaders :: Maybe TraceHeaders -> Maybe Value -> Maybe Value
mergeDlqHeaders Nothing originalHeaders = originalHeaders
mergeDlqHeaders (Just consumerHdrs) originalHeaders =
  let originalObj = case originalHeaders of
        Just (Object obj) -> obj
        _ -> KeyMap.empty
      stashedUpstream = stashUpstreamTrace originalObj
      consumerEntries = traceHeadersToKeyMap consumerHdrs
      merged = stashedUpstream <> consumerEntries
   in if KeyMap.null merged
        then Nothing
        else Just (Object merged)
  where
    -- Move any active @traceparent@/@tracestate@ on the original
    -- headers under the @x-shibuya-upstream-*@ prefix so the
    -- consumer's value can take the active slot. Other keys pass
    -- through unchanged.
    stashUpstreamTrace obj =
      foldr
        (uncurry (rename obj))
        (KeyMap.delete "traceparent" (KeyMap.delete "tracestate" obj))
        [ ("traceparent", "x-shibuya-upstream-traceparent"),
          ("tracestate", "x-shibuya-upstream-tracestate")
        ]
    rename src srcKey dstKey acc =
      case KeyMap.lookup (Key.fromText srcKey) src of
        Just v -> KeyMap.insert (Key.fromText dstKey) v acc
        Nothing -> acc

    -- Convert TraceHeaders ([(ByteString, ByteString)]) to a JSON object.
    traceHeadersToKeyMap hdrs =
      KeyMap.fromList
        [ (Key.fromText (TE.decodeUtf8Lenient k), String (TE.decodeUtf8Lenient v))
        | (k, v) <- hdrs
        ]

-- | Create an Ingested from a pgmq Message.
-- Handles auto dead-lettering when maxRetries is exceeded.
mkIngested ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Maybe (Ingested es Value))
mkIngested env config msg = do
  finalizedRef <- liftIO $ newIORef False
  lease <- mkLease config msg
  let ackHandle = mkAckHandle env config finalizedRef msg
  -- Check if max retries exceeded
  if msg.readCount > config.maxRetries
    then do
      -- Auto dead-letter messages that exceed retry limit
      finalizeAutoDeadLetter
        msg
        env.onAutoDeadLetter
        env.onAckFailure
        (ackHandle.finalize (AckDeadLetter MaxRetriesExceeded))
      -- Return Nothing - this message won't be processed by handler
      pure Nothing
    else
      pure $
        Just
          Ingested
            { envelope = pgmqMessageToEnvelope msg,
              ack = ackHandle,
              lease = Just lease
            }

finalizeAutoDeadLetter ::
  (Error PgmqRuntimeError :> es, IOE :> es) =>
  Pgmq.Message ->
  (Pgmq.Message -> IO ()) ->
  (Pgmq.Message -> PgmqRuntimeError -> IO ()) ->
  Eff es () ->
  Eff es ()
finalizeAutoDeadLetter msg onAutoDeadLetter onAckFailure finalizeAction =
  (finalizeAction >> liftIO (onAutoDeadLetter msg))
    `catchError` \_callStack err -> liftIO (onAckFailure msg err)

-- | Stream of message batches from pgmq.
-- Each element is a Vector of messages from a single poll.
-- This is the lowest-level stream that handles polling logic.
pgmqChunks ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM (retryingTransient config.pollRetry poll)
  where
    poll :: (Pgmq :> es, IOE :> es) => Eff es (Vector Pgmq.Message)
    poll = case config.fifoConfig of
      Nothing -> pollNonFifo
      Just fifo -> pollFifo fifo

    pollNonFifo :: (Pgmq :> es, IOE :> es) => Eff es (Vector Pgmq.Message)
    pollNonFifo = case config.polling of
      StandardPolling interval -> do
        result <- readMessage (mkReadMessage config)
        when (Vector.null result) $
          liftIO $
            threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs ->
        readWithPoll (mkReadWithPoll config maxSec intervalMs)

    pollFifo :: (Pgmq :> es, IOE :> es) => FifoConfig -> Eff es (Vector Pgmq.Message)
    pollFifo fifo = case config.polling of
      StandardPolling interval -> do
        result <- case fifo.readStrategy of
          ThroughputOptimized -> readGrouped (mkReadGrouped config)
          RoundRobin -> readGroupedRoundRobin (mkReadGrouped config)
        when (Vector.null result) $
          liftIO $
            threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs ->
        case fifo.readStrategy of
          ThroughputOptimized ->
            readGroupedWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
          RoundRobin ->
            readGroupedRoundRobinWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)

    nominalToMicros :: NominalDiffTime -> Int
    nominalToMicros t = floor (nominalDiffTimeToSeconds t * 1_000_000)

-- | Chunk polling with concurrent prefetch.
--
-- Wraps 'pgmqChunks' in streamly's @parBuffered@ so the next batches are polled
-- on a background worker while the current messages are processed. @parBuffered@
-- forks worker threads that must unlift @Eff es@ to @IO@; effectful's default
-- 'SeqUnlift' strategy throws when its unlift runs off-thread, which is the
-- historical prefetch deadlock. We therefore run the concurrent portion under
-- 'ConcUnlift' (which clones the effect environment per worker thread), scoped
-- locally with 'withUnliftStrategy' via 'Stream.morphInner' so the override is
-- in force at the moment @parBuffered@ forks — and so it does /not/ leak to the
-- non-prefetch path, which keeps running under 'SeqUnlift'.
--
-- 'Stream.morphInner' is applied /after/ @parBuffered@ so it wraps @parBuffered@'s
-- own forking step. Scoping the strategy at stream-construction time instead
-- would not work: the fork happens when the stream is run, not when it is built.
pgmqChunksPrefetch ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksPrefetch prefetchSettings config =
  pgmqChunks config
    & StreamP.parBuffered prefetchSettings
    & Stream.morphInner (withUnliftStrategy (ConcUnlift Ephemeral Unlimited))

retryingTransient ::
  (Error PgmqRuntimeError :> es, IOE :> es) =>
  PollRetryConfig ->
  Eff es a ->
  Eff es a
retryingTransient retry action = go 1 retry.initialBackoff
  where
    go attempt backoff =
      action `catchError` \_callStack err ->
        if isTransient err && attempt < retry.maxAttempts
          then do
            liftIO $ threadDelay (nominalToMicros backoff)
            go (attempt + 1) (min (backoff * 2) retry.maxBackoff)
          else throwError err

    nominalToMicros :: NominalDiffTime -> Int
    nominalToMicros t = floor (nominalDiffTimeToSeconds t * 1_000_000)

-- | Flatten message chunks into individual messages.
-- Uses Streamly's unfoldEach to expand each Vector into individual elements,
-- ensuring ALL messages from each batch are processed (not just the first).
pgmqMessages ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & Stream.filter (not . Vector.null) -- Skip empty batches
    & Stream.unfoldEach vectorUnfold -- Flatten Vector to individual elements
  where
    -- Unfold a Vector into a stream of elements using uncons
    vectorUnfold = Unfold.unfoldr Vector.uncons

-- | Create the message source stream.
-- This stream polls pgmq and yields Ingested messages.
-- Uses unfoldEach to process ALL messages from each batch, not just the first.
pgmqSource ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSource env config =
  pgmqMessages config
    & Stream.mapMaybeM (mkIngested env config) -- Convert + filter auto-DLQ'd messages

releaseMessages ::
  (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es) =>
  PgmqAdapterEnv ->
  PgmqAdapterConfig ->
  Vector Pgmq.Message ->
  Eff es ()
releaseMessages env config messages = do
  let msgIds = fmap (.messageId) (Vector.toList messages)
  retryingTransient
    config.ackRetry
    ( void $
        batchChangeVisibilityTimeout $
          BatchVisibilityTimeoutQuery
            { queueName = config.queueName,
              messageIds = msgIds,
              visibilityTimeoutOffset = 0
            }
    )
    `catchError` \_callStack err ->
      liftIO $ traverse_ (\message -> env.onAckFailure message err) messages
