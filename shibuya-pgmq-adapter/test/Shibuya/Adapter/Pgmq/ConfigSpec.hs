module Shibuya.Adapter.Pgmq.ConfigSpec (spec) where

import Pgmq.Types (parseQueueName, parseRoutingKey)
import Shibuya.Adapter.Pgmq.Config
import Test.Hspec

spec :: Spec
spec = do
  defaultConfigSpec
  defaultPollingConfigSpec
  defaultPollRetryConfigSpec
  validateConfigSpec
  deadLetterTargetSpec
  smartConstructorSpec

-- | Tests for defaultConfig
defaultConfigSpec :: Spec
defaultConfigSpec = describe "defaultConfig" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config = defaultConfig queueName

  it "sets queueName from parameter" $ do
    config.queueName `shouldBe` queueName

  it "sets visibilityTimeout to 30" $ do
    config.visibilityTimeout `shouldBe` 30

  it "sets batchSize to 1" $ do
    config.batchSize `shouldBe` 1

  it "uses StandardPolling with 1 second interval" $ do
    case config.polling of
      StandardPolling interval -> interval `shouldBe` 1
      _ -> expectationFailure "Expected StandardPolling"

  it "uses the default poll retry policy" $ do
    config.pollRetry `shouldBe` defaultPollRetryConfig

  it "uses the default ack retry policy" $ do
    config.ackRetry `shouldBe` defaultPollRetryConfig

  it "sets deadLetterConfig to Nothing" $ do
    config.deadLetterConfig `shouldBe` Nothing

  it "sets haltVisibilityTimeout to Nothing" $ do
    config.haltVisibilityTimeout `shouldBe` Nothing

  it "sets maxRetries to 3" $ do
    config.maxRetries `shouldBe` 3

  it "sets fifoConfig to Nothing" $ do
    config.fifoConfig `shouldBe` Nothing

-- | Tests for defaultPollingConfig
defaultPollingConfigSpec :: Spec
defaultPollingConfigSpec = describe "defaultPollingConfig" $ do
  it "is StandardPolling" $ do
    case defaultPollingConfig of
      StandardPolling _ -> pure ()
      _ -> expectationFailure "Expected StandardPolling"

  it "has 1 second interval" $ do
    case defaultPollingConfig of
      StandardPolling interval -> interval `shouldBe` 1
      _ -> expectationFailure "Expected StandardPolling"

defaultPollRetryConfigSpec :: Spec
defaultPollRetryConfigSpec = describe "defaultPollRetryConfig" $ do
  let PollRetryConfig
        { maxAttempts = retryMaxAttempts,
          initialBackoff = retryInitialBackoff,
          maxBackoff = retryMaxBackoff
        } = defaultPollRetryConfig

  it "retries five total attempts by default" $ do
    retryMaxAttempts `shouldBe` 5

  it "starts with a 100ms backoff" $ do
    retryInitialBackoff `shouldBe` 0.1

  it "caps backoff at five seconds" $ do
    retryMaxBackoff `shouldBe` 5

validateConfigSpec :: Spec
validateConfigSpec = describe "validateConfig" $ do
  let queueName = case parseQueueName "validate_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      base = defaultConfig queueName

  it "accepts the default config" $ do
    validateConfig base `shouldBe` Right base

  it "rejects batchSize below one" $ do
    validateConfig base {batchSize = 0} `shouldBe` Left (InvalidBatchSize 0)

  it "rejects visibilityTimeout below one" $ do
    validateConfig base {visibilityTimeout = 0} `shouldBe` Left (InvalidVisibilityTimeout 0)

  it "rejects non-positive standard polling interval" $ do
    validateConfig base {polling = StandardPolling 0} `shouldBe` Left (InvalidStandardPollInterval 0)

  it "rejects invalid long polling fields" $ do
    validateConfig base {polling = LongPolling 0 100} `shouldBe` Left (InvalidLongPollSeconds 0)
    validateConfig base {polling = LongPolling 10 0} `shouldBe` Left (InvalidLongPollIntervalMs 0)

  it "rejects negative maxRetries but accepts zero" $ do
    validateConfig base {maxRetries = -1} `shouldBe` Left (InvalidMaxRetries (-1))
    validateConfig base {maxRetries = 0} `shouldBe` Right base {maxRetries = 0}

  it "rejects invalid halt visibility timeout" $ do
    validateConfig base {haltVisibilityTimeout = Just 0} `shouldBe` Left (InvalidHaltVisibilityTimeout 0)

  it "rejects invalid retry policies" $ do
    let invalidAttempts = defaultPollRetryConfig {maxAttempts = 0}
        invalidBackoff = defaultPollRetryConfig {initialBackoff = -1}
    validateConfig base {pollRetry = invalidAttempts} `shouldBe` Left (InvalidPollRetryMaxAttempts 0)
    validateConfig base {ackRetry = invalidAttempts} `shouldBe` Left (InvalidAckRetryMaxAttempts 0)
    validateConfig base {pollRetry = invalidBackoff} `shouldBe` Left (InvalidPollRetryBackoff (-1) 5)
    validateConfig base {ackRetry = invalidBackoff} `shouldBe` Left (InvalidAckRetryBackoff (-1) 5)

-- | Tests for DeadLetterTarget
deadLetterTargetSpec :: Spec
deadLetterTargetSpec = describe "DeadLetterTarget" $ do
  let queueName = case parseQueueName "dlq_test" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      routingKey = case parseRoutingKey "dlq.errors" of
        Right r -> r
        Left e -> error $ "Unexpected: " <> show e

  it "DirectQueue holds a queue name" $ do
    let target = DirectQueue queueName
    case target of
      DirectQueue q -> q `shouldBe` queueName
      TopicRoute _ -> expectationFailure "Expected DirectQueue"

  it "TopicRoute holds a routing key" $ do
    let target = TopicRoute routingKey
    case target of
      TopicRoute r -> r `shouldBe` routingKey
      DirectQueue _ -> expectationFailure "Expected TopicRoute"

  it "DirectQueue and TopicRoute are not equal" $ do
    DirectQueue queueName `shouldNotBe` TopicRoute routingKey

-- | Tests for smart constructors
smartConstructorSpec :: Spec
smartConstructorSpec = describe "Smart constructors" $ do
  let queueName = case parseQueueName "dlq_test" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      routingKey = case parseRoutingKey "dlq.errors" of
        Right r -> r
        Left e -> error $ "Unexpected: " <> show e

  describe "directDeadLetter" $ do
    it "creates a DeadLetterConfig with DirectQueue target" $ do
      let config = directDeadLetter queueName True
      config.dlqTarget `shouldBe` DirectQueue queueName

    it "sets includeMetadata correctly" $ do
      let config = directDeadLetter queueName False
      config.includeMetadata `shouldBe` False

  describe "topicDeadLetter" $ do
    it "creates a DeadLetterConfig with TopicRoute target" $ do
      let config = topicDeadLetter routingKey True
      config.dlqTarget `shouldBe` TopicRoute routingKey

    it "sets includeMetadata correctly" $ do
      let config = topicDeadLetter routingKey False
      config.includeMetadata `shouldBe` False
