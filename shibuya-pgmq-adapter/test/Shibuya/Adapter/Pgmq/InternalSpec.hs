{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Adapter.Pgmq.InternalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int32)
import Data.Time (NominalDiffTime)
import Pgmq.Hasql.Statements.Types (ReadGrouped (..), ReadMessage (..), ReadWithPollMessage (..))
import Pgmq.Types (parseQueueName)
import Shibuya.Adapter.Pgmq.Config
  ( PgmqAdapterConfig (..),
    defaultPollingConfig,
  )
import Shibuya.Adapter.Pgmq.Internal
  ( mergeDlqHeaders,
    mkReadGrouped,
    mkReadMessage,
    mkReadWithPoll,
    nominalToSeconds,
  )
import Test.Hspec

spec :: Spec
spec = do
  nominalToSecondsSpec
  mkReadMessageSpec
  mkReadWithPollSpec
  mkReadGroupedSpec
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
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
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
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
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
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
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
