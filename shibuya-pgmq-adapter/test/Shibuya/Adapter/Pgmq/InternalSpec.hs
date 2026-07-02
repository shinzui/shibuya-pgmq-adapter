{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Adapter.Pgmq.InternalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.Time (NominalDiffTime, UTCTime (..), fromGregorian)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Hasql.Errors qualified as HasqlErrors
import Pgmq.Effectful (Pgmq, PgmqRuntimeError (..))
import Pgmq.Effectful.Effect qualified as PgmqEffect
import Pgmq.Hasql.Statements.Types (ReadGrouped (..), ReadMessage (..), ReadWithPollMessage (..))
import Pgmq.Types (Message (..), MessageBody (..), MessageId (..), parseQueueName)
import Shibuya.Adapter.Pgmq.Config
  ( PgmqAdapterConfig (..),
    PollRetryConfig (..),
    PollingConfig (..),
    defaultPollRetryConfig,
    defaultPollingConfig,
  )
import Shibuya.Adapter.Pgmq.Internal
  ( mergeDlqHeaders,
    mkReadGrouped,
    mkReadMessage,
    mkReadWithPoll,
    nominalToSeconds,
    pgmqChunks,
  )
import Streamly.Data.Stream qualified as Stream
import Test.Hspec

spec :: Spec
spec = do
  nominalToSecondsSpec
  mkReadMessageSpec
  mkReadWithPollSpec
  mkReadGroupedSpec
  pollRetrySpec
  mergeDlqHeadersSpec

-- | Tests for nominalToSeconds
nominalToSecondsSpec :: Spec
nominalToSecondsSpec = describe "nominalToSeconds" $ do
  it "converts whole seconds" $ do
    nominalToSeconds 5 `shouldBe` 5

  it "rounds up fractional seconds" $ do
    nominalToSeconds 5.1 `shouldBe` 6

  it "rounds up small fractions" $ do
    nominalToSeconds 5.001 `shouldBe` 6

  it "handles zero" $ do
    nominalToSeconds 0 `shouldBe` 0

  it "handles negative (rounds toward positive infinity)" $ do
    nominalToSeconds (-5.1) `shouldBe` (-5)

  describe "clamping" $ do
    it "exact 30 seconds passes through" $ do
      nominalToSeconds 30 `shouldBe` 30

    it "rounds up subsecond" $ do
      nominalToSeconds 0.1 `shouldBe` 1

    it "clamps a 100-year delay to maxBound :: Int32" $ do
      let hundredYears = 100 * 365 * 24 * 60 * 60 :: NominalDiffTime
      nominalToSeconds hundredYears `shouldBe` (maxBound :: Int32)

    it "clamps a very large negative delay to minBound :: Int32" $ do
      let hugelyNegative = negate (100 * 365 * 24 * 60 * 60) :: NominalDiffTime
      nominalToSeconds hugelyNegative `shouldBe` (minBound :: Int32)

-- | Tests for mkReadMessage
mkReadMessageSpec :: Spec
mkReadMessageSpec = describe "mkReadMessage" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 10,
            polling = defaultPollingConfig,
            pollRetry = defaultPollRetryConfig,
            ackRetry = defaultPollRetryConfig,
            deadLetterConfig = Nothing,
            haltVisibilityTimeout = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing
          }
      ReadMessage
        { queueName = queryQueueName,
          delay = queryDelay,
          batchSize = queryBatchSize,
          conditional = queryConditional
        } = mkReadMessage config

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets delay to visibilityTimeout" $ do
    queryDelay `shouldBe` 60

  it "sets batchSize from config" $ do
    queryBatchSize `shouldBe` Just 10

  it "sets conditional to Nothing" $ do
    queryConditional `shouldBe` Nothing

-- | Tests for mkReadWithPoll
mkReadWithPollSpec :: Spec
mkReadWithPollSpec = describe "mkReadWithPoll" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 10,
            polling = defaultPollingConfig,
            pollRetry = defaultPollRetryConfig,
            ackRetry = defaultPollRetryConfig,
            deadLetterConfig = Nothing,
            haltVisibilityTimeout = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing
          }
      ReadWithPollMessage
        { queueName = queryQueueName,
          delay = queryDelay,
          batchSize = queryBatchSize,
          maxPollSeconds = queryMaxPoll,
          pollIntervalMs = queryPollInterval,
          conditional = queryConditional
        } = mkReadWithPoll config 5 100

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets delay to visibilityTimeout" $ do
    queryDelay `shouldBe` 60

  it "sets batchSize from config" $ do
    queryBatchSize `shouldBe` Just 10

  it "sets maxPollSeconds from parameter" $ do
    queryMaxPoll `shouldBe` 5

  it "sets pollIntervalMs from parameter" $ do
    queryPollInterval `shouldBe` 100

  it "sets conditional to Nothing" $ do
    queryConditional `shouldBe` Nothing

-- | Tests for mkReadGrouped
mkReadGroupedSpec :: Spec
mkReadGroupedSpec = describe "mkReadGrouped" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 20,
            polling = defaultPollingConfig,
            pollRetry = defaultPollRetryConfig,
            ackRetry = defaultPollRetryConfig,
            deadLetterConfig = Nothing,
            haltVisibilityTimeout = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing
          }
      ReadGrouped
        { queueName = queryQueueName,
          visibilityTimeout = queryVt,
          qty = queryQty
        } = mkReadGrouped config

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets visibilityTimeout from config" $ do
    queryVt `shouldBe` 60

  it "sets qty to batchSize" $ do
    queryQty `shouldBe` 20

pollRetrySpec :: Spec
pollRetrySpec = describe "pgmqChunks poll retry" $ do
  it "retries transient poll errors and returns the successful batch" $ do
    calls <- newIORef (0 :: Int)
    let cfg = retryTestConfig 5
    result <-
      runStubPgmq calls (transientThenSuccess 2) $
        Stream.toList (Stream.take 1 (pgmqChunks cfg))
    result `shouldBe` Right [Vector.singleton testMessage]
    readIORef calls `shouldReturn` 3

  it "does not retry permanent poll errors" $ do
    calls <- newIORef (0 :: Int)
    let cfg = retryTestConfig 5
    result <-
      runStubPgmq calls (const (Left permanentError)) $
        Stream.toList (Stream.take 1 (pgmqChunks cfg))
    result `shouldBe` Left permanentError
    readIORef calls `shouldReturn` 1

  it "stops retrying after maxAttempts is exhausted" $ do
    calls <- newIORef (0 :: Int)
    let cfg = retryTestConfig 2
    result <-
      runStubPgmq calls (const (Left transientError)) $
        Stream.toList (Stream.take 1 (pgmqChunks cfg))
    result `shouldBe` Left transientError
    readIORef calls `shouldReturn` 2

-- | Tests for mergeDlqHeaders, the helper that injects the failing
-- consumer's trace context onto a DLQ message while preserving the
-- original producer's trace under x-shibuya-upstream-* keys.
mergeDlqHeadersSpec :: Spec
mergeDlqHeadersSpec = describe "mergeDlqHeaders" $ do
  it "with no consumer headers, forwards original headers verbatim" $ do
    let original =
          Just $
            object
              [ "traceparent" .= ("00-producer-trace-id-pid-01" :: String),
                "tracestate" .= ("vendor=opaque" :: String),
                "custom" .= ("value" :: String)
              ]
    mergeDlqHeaders Nothing original `shouldBe` original

  it "with no consumer headers and no original, returns Nothing" $ do
    mergeDlqHeaders Nothing Nothing `shouldBe` Nothing

  it "consumer's traceparent overrides original's, original moves under x-shibuya-upstream-traceparent" $ do
    let original =
          Just $
            object
              [ "traceparent" .= ("00-producer-trace-id-pid-01" :: String),
                "tracestate" .= ("vendor=opaque" :: String),
                "custom" .= ("preserved" :: String)
              ]
        consumerHdrs =
          Just
            [ ("traceparent", "00-consumer-trace-id-cid-01"),
              ("tracestate", "consumer=ok")
            ]
    case mergeDlqHeaders consumerHdrs original of
      Just (Object obj) -> do
        KeyMap.lookup "traceparent" obj
          `shouldBe` Just (String "00-consumer-trace-id-cid-01")
        KeyMap.lookup "tracestate" obj
          `shouldBe` Just (String "consumer=ok")
        KeyMap.lookup "x-shibuya-upstream-traceparent" obj
          `shouldBe` Just (String "00-producer-trace-id-pid-01")
        KeyMap.lookup "x-shibuya-upstream-tracestate" obj
          `shouldBe` Just (String "vendor=opaque")
        KeyMap.lookup "custom" obj
          `shouldBe` Just (String "preserved")
      other -> expectationFailure $ "expected merged Object, got " <> show other

  it "consumer's headers carry through when original headers are absent" $ do
    let consumerHdrs =
          Just
            [ ("traceparent", "00-consumer-trace-id-cid-01"),
              ("tracestate", "consumer=ok")
            ]
    case mergeDlqHeaders consumerHdrs Nothing of
      Just (Object obj) -> do
        KeyMap.lookup "traceparent" obj
          `shouldBe` Just (String "00-consumer-trace-id-cid-01")
        KeyMap.lookup "tracestate" obj
          `shouldBe` Just (String "consumer=ok")
        KeyMap.lookup "x-shibuya-upstream-traceparent" obj `shouldBe` Nothing
        KeyMap.lookup "x-shibuya-upstream-tracestate" obj `shouldBe` Nothing
      other -> expectationFailure $ "expected merged Object, got " <> show other

  it "original's tracestate is stashed even when consumer has no tracestate" $ do
    let original =
          Just $
            object
              [ "traceparent" .= ("00-producer-trace-id-pid-01" :: String),
                "tracestate" .= ("vendor=opaque" :: String)
              ]
        consumerHdrs = Just [("traceparent", "00-consumer-trace-id-cid-01")]
    case mergeDlqHeaders consumerHdrs original of
      Just (Object obj) -> do
        KeyMap.lookup "traceparent" obj
          `shouldBe` Just (String "00-consumer-trace-id-cid-01")
        KeyMap.lookup "tracestate" obj `shouldBe` Nothing
        KeyMap.lookup "x-shibuya-upstream-traceparent" obj
          `shouldBe` Just (String "00-producer-trace-id-pid-01")
        KeyMap.lookup "x-shibuya-upstream-tracestate" obj
          `shouldBe` Just (String "vendor=opaque")
      other -> expectationFailure $ "expected merged Object, got " <> show other

  it "leniently decodes non-UTF8 trace headers" $ do
    let consumerHdrs = Just [(BS.pack [0xff, 0xfe], BS.pack [0xff])]
    mergeDlqHeaders consumerHdrs Nothing `shouldSatisfy` \case
      Just (Object obj) -> not (KeyMap.null obj)
      _ -> False

retryTestConfig :: Int -> PgmqAdapterConfig
retryTestConfig attempts =
  let queueName = case parseQueueName "retry_test" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
   in PgmqAdapterConfig
        { queueName = queueName,
          visibilityTimeout = 30,
          batchSize = 1,
          polling = StandardPolling {pollInterval = 0},
          pollRetry =
            PollRetryConfig
              { maxAttempts = attempts,
                initialBackoff = 0,
                maxBackoff = 0
              },
          ackRetry = defaultPollRetryConfig,
          deadLetterConfig = Nothing,
          haltVisibilityTimeout = Nothing,
          maxRetries = 3,
          fifoConfig = Nothing
        }

runStubPgmq ::
  IORef Int ->
  (Int -> Either PgmqRuntimeError (Vector.Vector Message)) ->
  Eff '[Pgmq, Error PgmqRuntimeError, IOE] a ->
  IO (Either PgmqRuntimeError a)
runStubPgmq calls respond action =
  runEff $
    runErrorNoCallStack $
      interpret
        ( \_ -> \case
            PgmqEffect.ReadMessage _ -> nextPoll
            PgmqEffect.ReadWithPoll _ -> nextPoll
            PgmqEffect.ReadGrouped _ -> nextPoll
            PgmqEffect.ReadGroupedWithPoll _ -> nextPoll
            PgmqEffect.ReadGroupedRoundRobin _ -> nextPoll
            PgmqEffect.ReadGroupedRoundRobinWithPoll _ -> nextPoll
            _ -> error "unexpected Pgmq operation in retry test"
        )
        action
  where
    nextPoll = do
      n <- liftIO $ atomicModifyIORef' calls (\c -> let c' = c + 1 in (c', c'))
      case respond n of
        Left err -> throwError err
        Right batch -> pure batch

transientThenSuccess :: Int -> Int -> Either PgmqRuntimeError (Vector.Vector Message)
transientThenSuccess failures n
  | n <= failures = Left transientError
  | otherwise = Right (Vector.singleton testMessage)

transientError :: PgmqRuntimeError
transientError = PgmqAcquisitionTimeout

permanentError :: PgmqRuntimeError
permanentError =
  PgmqConnectionError (HasqlErrors.AuthenticationConnectionError "bad password")

testMessage :: Message
testMessage =
  Message
    { messageId = MessageId 1,
      visibilityTime = testTime,
      enqueuedAt = testTime,
      lastReadAt = Nothing,
      readCount = 1,
      body = MessageBody Null,
      headers = Nothing
    }

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0
