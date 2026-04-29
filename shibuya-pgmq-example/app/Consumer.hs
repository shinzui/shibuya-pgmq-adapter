-- | Message consumer for the PGMQ example.
--
-- Processes messages from orders, payments, and notifications queues
-- with different configurations and handler behaviors.
--
-- Usage:
--
-- @
-- export DATABASE_URL="postgres://user:pass@localhost/pgmq"
-- export OTEL_TRACING_ENABLED=true
-- export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
-- cabal run shibuya-pgmq-consumer
-- @
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Clock (getCurrentTime, secondsToNominalDiffTime)
import Effectful (IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Example.Config (AppConfig (..))
import Example.Config qualified as Config
import Example.Database
  ( backoffDemoQueueName,
    createQueues,
    dlqOrdersQueueName,
    dlqPaymentsQueueName,
    notificationsQueueName,
    ordersQueueName,
    paymentsQueueName,
    withDatabasePool,
  )
import Example.Telemetry (withTracing)
import Hasql.Pool qualified as Pool
import OpenTelemetry.Trace.Core qualified as OTel
import Pgmq.Effectful (runPgmqTraced)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Shibuya.Adapter.Pgmq
  ( FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    directDeadLetter,
    pgmqAdapter,
  )
import Shibuya.Adapter.Pgmq qualified as Pgmq
import Shibuya.App
  ( ProcessorId (..),
    ShutdownConfig (..),
    SupervisionStrategy (..),
    getAppMaster,
    mkProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Retry
  ( BackoffPolicy (..),
    Jitter (..),
    defaultBackoffPolicy,
    retryWithBackoff,
  )
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Metrics (MetricsServerConfig (..), withMetricsServer)
import Shibuya.Metrics qualified as Metrics
import Shibuya.Telemetry.Effect (runTracing)
import System.Environment (getArgs)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import System.Posix.Signals (installHandler, sigINT, sigTERM)
import System.Posix.Signals qualified as Signals
import System.Random (randomRIO)

--------------------------------------------------------------------------------
-- Handler Definitions
--------------------------------------------------------------------------------

-- | Orders handler: 10% random retry, validate JSON structure.
ordersHandler :: (IOE :> es) => Handler es Value
ordersHandler (Ingested {envelope = Envelope {payload, messageId = MessageId msgIdText}}) = do
  liftIO $ Text.putStrLn $ "[orders] Processing: " <> msgIdText

  -- Validate that payload has expected structure
  case parseMaybe parseOrder payload of
    Nothing -> do
      liftIO $ Text.putStrLn $ "[orders] Invalid JSON structure, sending to DLQ: " <> msgIdText
      pure $ AckDeadLetter (InvalidPayload "Missing orderId field")
    Just (OrderInfo {orderInfoId = ordId}) -> do
      -- Simulate 10% random retry for testing
      shouldRetry <- liftIO $ (< (0.1 :: Double)) <$> randomRIO (0, 1)
      if shouldRetry
        then do
          liftIO $ Text.putStrLn $ "[orders] Simulated failure, will retry: " <> msgIdText
          pure $ AckRetry (RetryDelay $ secondsToNominalDiffTime 5)
        else do
          liftIO $ Text.putStrLn $ "[orders] Processed order: " <> ordId
          -- Simulate some work
          liftIO $ threadDelay 10000 -- 10ms
          pure AckOk

-- | Simple order structure for validation.
newtype OrderInfo = OrderInfo {orderInfoId :: Text}

parseOrder :: Value -> Parser OrderInfo
parseOrder = withObject "Order" $ \v -> do
  orderId <- v .: "orderId"
  pure OrderInfo {orderInfoId = orderId}

-- | Payments handler: Validate amount, DLQ for invalid amounts.
paymentsHandler :: (IOE :> es) => Handler es Value
paymentsHandler (Ingested {envelope = Envelope {payload, messageId = MessageId msgIdText}}) = do
  liftIO $ Text.putStrLn $ "[payments] Processing: " <> msgIdText

  case parseMaybe parsePayment payload of
    Nothing -> do
      liftIO $ Text.putStrLn $ "[payments] Invalid JSON, sending to DLQ: " <> msgIdText
      pure $ AckDeadLetter (InvalidPayload "Invalid payment JSON")
    Just (PaymentInfo {paymentInfoId = payId, paymentInfoAmount = amt}) -> do
      -- DLQ for negative amounts (invalid)
      if amt < 0
        then do
          liftIO $ Text.putStrLn $ "[payments] Negative amount, sending to DLQ: " <> payId
          pure $ AckDeadLetter (InvalidPayload "Negative payment amount")
        else
          if amt > 10000
            then do
              -- Large amounts get special handling - send to DLQ for manual review
              liftIO $ Text.putStrLn $ "[payments] Large amount ($" <> Text.pack (show amt) <> "), sending to DLQ for review"
              pure $ AckDeadLetter (PoisonPill "Large amount requires manual review")
            else do
              liftIO $ Text.putStrLn $ "[payments] Processed payment: " <> payId <> " for $" <> Text.pack (show amt)
              -- Simulate processing time
              liftIO $ threadDelay 20000 -- 20ms for payment processing
              pure AckOk

-- | Simple payment structure for validation.
data PaymentInfo = PaymentInfo {paymentInfoId :: Text, paymentInfoAmount :: Double}

parsePayment :: Value -> Parser PaymentInfo
parsePayment = withObject "Payment" $ \v -> do
  paymentId <- v .: "paymentId"
  amount <- v .: "amount"
  pure PaymentInfo {paymentInfoId = paymentId, paymentInfoAmount = amount}

-- | Notifications handler: Fast processing, minimal logic.
notificationsHandler :: (IOE :> es) => Handler es Value
notificationsHandler (Ingested {envelope = Envelope {payload, messageId = MessageId msgIdText}}) = do
  -- Fast path - just acknowledge
  case parseMaybe parseNotification payload of
    Nothing -> do
      liftIO $ Text.putStrLn $ "[notifications] Invalid notification: " <> msgIdText
      pure AckOk -- Just ack invalid notifications, don't DLQ
    Just (NotificationInfo {notifInfoUserId = userId, notifInfoType = notifType}) -> do
      liftIO $ Text.putStrLn $ "[notifications] Sent " <> notifType <> " to user " <> userId
      -- Very fast - just 1ms simulated
      liftIO $ threadDelay 1000
      pure AckOk

-- | Simple notification structure.
data NotificationInfo = NotificationInfo {notifInfoUserId :: Text, notifInfoType :: Text}

parseNotification :: Value -> Parser NotificationInfo
parseNotification = withObject "Notification" $ \v -> do
  userId <- v .: "userId"
  notificationType <- v .: "notificationType"
  pure NotificationInfo {notifInfoUserId = userId, notifInfoType = notificationType}

-- | Backoff-demo handler. Fails the first three deliveries of every
-- message and succeeds on the fourth, demonstrating the exponential
-- spacing produced by 'retryWithBackoff'. Each delivery prints a line
-- showing the wallclock timestamp, message id, framework-tracked
-- @attempt@ counter, and (on retry) the chosen delay.
--
-- The per-message failure count lives in an 'IORef' map keyed by
-- 'MessageId'. The /delay/ decision is independent of that map; it is
-- computed by 'retryWithBackoff' from 'envelope.attempt', which the
-- pgmq adapter populates from pgmq's @read_count@ column. This split
-- keeps the demo's failure logic from accidentally feeding back into
-- the framework's delivery counter.
backoffDemoHandler ::
  (IOE :> es) =>
  IORef (Map MessageId Int) ->
  BackoffPolicy ->
  Handler es Value
backoffDemoHandler failuresRef policy ingested = do
  let env = ingested.envelope
      msgId = env.messageId
      attempt = fromMaybe (Attempt 0) env.attempt
  now <- liftIO getCurrentTime
  liftIO $
    Text.putStrLn $
      "["
        <> Text.pack (show now)
        <> "] msg="
        <> (case msgId of MessageId t -> t)
        <> " attempt="
        <> Text.pack (show attempt.unAttempt)
  currentFails <- liftIO $ atomicModifyIORef' failuresRef $ \m ->
    let n = Map.findWithDefault 0 msgId m
     in (Map.insert msgId (n + 1) m, n)
  if currentFails < 3
    then do
      decision <- retryWithBackoff policy env
      case decision of
        AckRetry (RetryDelay d) ->
          liftIO $ Text.putStrLn $ "  -> retry in " <> Text.pack (show d)
        _ -> pure ()
      pure decision
    else do
      liftIO $ Text.putStrLn "  -> success"
      pure AckOk

--------------------------------------------------------------------------------
-- Adapter Configuration
--------------------------------------------------------------------------------

-- | Orders adapter config: batch=5, StandardPolling(1s), DLQ
ordersAdapterConfig :: PgmqAdapterConfig
ordersAdapterConfig =
  (Pgmq.defaultConfig ordersQueueName)
    { batchSize = 5,
      polling = StandardPolling {pollInterval = 1},
      deadLetterConfig = Just $ directDeadLetter dlqOrdersQueueName True,
      maxRetries = 3
    }

-- | Payments adapter config: batch=1, LongPolling, FIFO, DLQ
paymentsAdapterConfig :: PgmqAdapterConfig
paymentsAdapterConfig =
  (Pgmq.defaultConfig paymentsQueueName)
    { batchSize = 1,
      polling =
        LongPolling
          { maxPollSeconds = 10,
            pollIntervalMs = 100
          },
      deadLetterConfig = Just $ directDeadLetter dlqPaymentsQueueName True,
      fifoConfig =
        Just
          FifoConfig
            { readStrategy = ThroughputOptimized
            },
      maxRetries = 3
    }

-- | Notifications adapter config: batch=20, short VT
-- NOTE: prefetch is disabled due to STM deadlock issue with streamly parBuffered
notificationsAdapterConfig :: PgmqAdapterConfig
notificationsAdapterConfig =
  (Pgmq.defaultConfig notificationsQueueName)
    { batchSize = 20,
      visibilityTimeout = 10, -- Short VT for fast processing
      polling = StandardPolling {pollInterval = 0.5},
      prefetchConfig = Nothing,
      maxRetries = 1 -- Don't retry notifications much
    }

-- | Backoff demo adapter config: batch=1, short polling, 5 retries.
--
-- Five retries permits the handler to fail three times before succeeding
-- on the fourth delivery without tripping pgmq's auto-DLQ. The 0.25-second
-- poll interval keeps observed wallclock gaps tight to the logged
-- @retry in Ts@ values.
backoffDemoAdapterConfig :: PgmqAdapterConfig
backoffDemoAdapterConfig =
  (Pgmq.defaultConfig backoffDemoQueueName)
    { batchSize = 1,
      visibilityTimeout = 1,
      polling = StandardPolling {pollInterval = 0.25},
      maxRetries = 5
    }

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  args <- getArgs
  case args of
    ("backoff-demo" : rest) ->
      runBackoffDemoMain (parseBackoffPolicy rest)
    _ -> runDefaultMain

-- | Pick a 'BackoffPolicy' from optional CLI flags.
--
-- Recognized:
--
-- * @nojitter@ — switches to deterministic 1\/2\/4\/... s spacing,
--   useful for confirming the math at a glance.
-- * @equaljitter@ — half-base + uniform half jitter.
parseBackoffPolicy :: [String] -> BackoffPolicy
parseBackoffPolicy ["nojitter"] = defaultBackoffPolicy {jitter = NoJitter}
parseBackoffPolicy ["equaljitter"] = defaultBackoffPolicy {jitter = EqualJitter}
parseBackoffPolicy _ = defaultBackoffPolicy

runDefaultMain :: IO ()
runDefaultMain = do
  Text.putStrLn "=== Shibuya PGMQ Consumer ==="
  Text.putStrLn ""

  AppConfig {connectionString, tracingEnabled, serviceName, metricsPort} <- Config.loadAppConfig
  Text.putStrLn "Configuration:"
  Text.putStrLn $ "  Tracing enabled: " <> Text.pack (show tracingEnabled)
  Text.putStrLn $ "  Service name: " <> serviceName
  Text.putStrLn $ "  Metrics port: " <> Text.pack (show metricsPort)
  Text.putStrLn ""

  -- Set up shutdown signal handling
  shutdownVar <- newEmptyMVar :: IO (MVar ())
  let signalHandler = Signals.CatchOnce $ putMVar shutdownVar ()
  _ <- installHandler sigINT signalHandler Nothing
  _ <- installHandler sigTERM signalHandler Nothing

  withDatabasePool connectionString $ \pool -> do
    Text.putStrLn "Connected to PostgreSQL"
    Text.putStrLn "Creating queues if needed..."
    createQueues pool
    Text.putStrLn "Queues ready"
    Text.putStrLn ""

    withTracing tracingEnabled serviceName $ \tracer -> do
      runConsumer pool tracer metricsPort shutdownVar

runBackoffDemoMain :: BackoffPolicy -> IO ()
runBackoffDemoMain policy = do
  Text.putStrLn "=== Shibuya PGMQ Backoff Demo ==="
  Text.putStrLn $ "Policy: " <> Text.pack (show policy)
  Text.putStrLn ""

  AppConfig {connectionString, tracingEnabled, serviceName} <- Config.loadAppConfig

  shutdownVar <- newEmptyMVar :: IO (MVar ())
  let signalHandler = Signals.CatchOnce $ putMVar shutdownVar ()
  _ <- installHandler sigINT signalHandler Nothing
  _ <- installHandler sigTERM signalHandler Nothing

  withDatabasePool connectionString $ \pool -> do
    Text.putStrLn "Connected to PostgreSQL"
    Text.putStrLn "Creating queues if needed..."
    createQueues pool
    Text.putStrLn "Queues ready (including backoff_demo)"
    Text.putStrLn ""

    failuresRef <- newIORef Map.empty

    withTracing tracingEnabled serviceName $ \tracer -> do
      runBackoffDemoConsumer pool tracer policy failuresRef shutdownVar

runBackoffDemoConsumer ::
  Pool.Pool ->
  OTel.Tracer ->
  BackoffPolicy ->
  IORef (Map MessageId Int) ->
  MVar () ->
  IO ()
runBackoffDemoConsumer pool tracer policy failuresRef shutdownVar = do
  eResult <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmqTraced pool tracer $ runTracing tracer $ do
    adapter <- pgmqAdapter backoffDemoAdapterConfig
    liftIO $ Text.putStrLn "Adapter created"

    let proc = mkProcessor adapter (backoffDemoHandler failuresRef policy)
    result <-
      runApp
        IgnoreFailures
        100
        [(ProcessorId "backoff-demo", proc)]

    case result of
      Left err -> do
        liftIO $ Text.putStrLn $ "Failed to start app: " <> Text.pack (show err)
      Right appHandle -> do
        liftIO $ Text.putStrLn "Backoff demo running. Press Ctrl+C to stop."
        liftIO $ Text.putStrLn ""

        liftIO $ takeMVar shutdownVar

        liftIO $ Text.putStrLn ""
        liftIO $ Text.putStrLn "Received shutdown signal, stopping gracefully..."

        let shutdownConfig = ShutdownConfig {drainTimeout = 30}
        drained <- stopAppGracefully shutdownConfig appHandle
        if drained
          then liftIO $ Text.putStrLn "All processors drained cleanly"
          else liftIO $ Text.putStrLn "Some processors were force-stopped"

  case eResult of
    Left err -> Text.putStrLn $ "Backoff demo error: " <> Text.pack (show err)
    Right _ -> pure ()

  Text.putStrLn "Backoff demo stopped."

runConsumer ::
  Pool.Pool ->
  OTel.Tracer ->
  Int ->
  MVar () ->
  IO ()
runConsumer pool tracer metricsPort shutdownVar = do
  eResult <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmqTraced pool tracer $ runTracing tracer $ do
    -- Create adapters
    ordersAdapter <- pgmqAdapter ordersAdapterConfig
    paymentsAdapter <- pgmqAdapter paymentsAdapterConfig
    notificationsAdapter <- pgmqAdapter notificationsAdapterConfig

    liftIO $ Text.putStrLn "Adapters created"

    -- Create processors
    let ordersProc = mkProcessor ordersAdapter ordersHandler
        paymentsProc = mkProcessor paymentsAdapter paymentsHandler
        notificationsProc = mkProcessor notificationsAdapter notificationsHandler
    -- Start the application
    result <-
      runApp
        IgnoreFailures
        100 -- inbox size
        [ (ProcessorId "orders", ordersProc),
          (ProcessorId "payments", paymentsProc),
          (ProcessorId "notifications", notificationsProc)
        ]

    case result of
      Left err -> do
        liftIO $ Text.putStrLn $ "Failed to start app: " <> Text.pack (show err)
      Right appHandle -> do
        liftIO $ Text.putStrLn "All processors started"
        liftIO $ Text.putStrLn ""

        -- Start metrics server
        let metricsConfig = Metrics.defaultConfig {port = metricsPort}
        liftIO $ withMetricsServer metricsConfig (getAppMaster appHandle) $ \_ -> do
          Text.putStrLn $ "Metrics server running on port " <> Text.pack (show metricsPort)
          Text.putStrLn $ "  - JSON:       http://localhost:" <> Text.pack (show metricsPort) <> "/metrics"
          Text.putStrLn $ "  - Prometheus: http://localhost:" <> Text.pack (show metricsPort) <> "/metrics/prometheus"
          Text.putStrLn $ "  - WebSocket:  ws://localhost:" <> Text.pack (show metricsPort) <> "/ws"
          Text.putStrLn $ "  - Health:     http://localhost:" <> Text.pack (show metricsPort) <> "/health"
          Text.putStrLn ""
          Text.putStrLn "Consumer running. Press Ctrl+C to stop."

          -- Wait for shutdown signal
          takeMVar shutdownVar

          Text.putStrLn ""
          Text.putStrLn "Received shutdown signal, stopping gracefully..."

        -- Graceful shutdown
        let shutdownConfig = ShutdownConfig {drainTimeout = 30}
        drained <- stopAppGracefully shutdownConfig appHandle
        if drained
          then liftIO $ Text.putStrLn "All processors drained cleanly"
          else liftIO $ Text.putStrLn "Some processors were force-stopped"

  case eResult of
    Left err -> Text.putStrLn $ "Consumer error: " <> Text.pack (show err)
    Right _ -> pure ()

  Text.putStrLn "Consumer stopped."
